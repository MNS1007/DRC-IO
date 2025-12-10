#!/usr/bin/env python3
"""
DRC-IO Controller - Dynamic Resource Control for I/O

This controller implements dynamic I/O prioritization in Kubernetes clusters.
It monitors workload behavior and dynamically adjusts I/O scheduling parameters
to ensure high-priority workloads receive guaranteed I/O resources while
batch workloads are throttled as needed.

Architecture:
- Runs as a DaemonSet on each node
- Monitors cgroup I/O metrics via sysfs
- Applies I/O weights using cgroup v2 io.weight
- Exposes Prometheus metrics for observability

Workload Classification:
- High Priority (HP): Real-time services (e.g., GNN inference)
- Low Priority (LP): Batch jobs (e.g., data processing)
"""

import os
import sys
import time
import logging
import signal
import json
from pathlib import Path
from datetime import datetime
from collections import defaultdict
from prometheus_client import Counter, Gauge, Histogram, start_http_server
from kubernetes import client, config, watch
import threading

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Prometheus metrics
WORKLOAD_DISCOVERY = Counter(
    'drcio_workload_discovery_total',
    'Total workload discoveries',
    ['workload_type', 'priority']
)

IO_WEIGHT_APPLIED = Counter(
    'drcio_io_weight_applied_total',
    'Total I/O weight adjustments applied',
    ['workload_type', 'priority']
)

CURRENT_IO_WEIGHT = Gauge(
    'drcio_io_weight',
    'Current I/O weight value',
    ['pod_name', 'namespace', 'priority']
)

IO_BYTES_READ = Gauge(
    'drcio_io_bytes_read',
    'Bytes read from disk',
    ['pod_name', 'namespace', 'priority']
)

IO_BYTES_WRITE = Gauge(
    'drcio_io_bytes_write',
    'Bytes written to disk',
    ['pod_name', 'namespace', 'priority']
)

CONTROL_LOOP_DURATION = Histogram(
    'drcio_control_loop_duration_seconds',
    'Duration of control loop execution'
)

ACTIVE_PODS = Gauge(
    'drcio_active_pods',
    'Number of active pods under management',
    ['priority']
)

# Global state
shutdown_requested = False


##############################################################################
# Cgroup I/O Management
##############################################################################

class CgroupIOManager:
    """
    Manages cgroup v2 I/O controls for container workloads.
    """

    def __init__(self):
        self.cgroup_root = Path("/sys/fs/cgroup")
        self.cgroup_v2_enabled = self._check_cgroup_v2()

        if self.cgroup_v2_enabled:
            logger.info("✓ cgroup v2 detected and enabled")
        else:
            logger.warning("⚠ cgroup v2 not available, I/O control will be limited")

    def _check_cgroup_v2(self):
        """Check if cgroup v2 is available."""
        # Check for unified hierarchy
        try:
            with open("/proc/mounts", "r") as f:
                for line in f:
                    if "cgroup2" in line:
                        return True
        except Exception as e:
            logger.error(f"Failed to check cgroup version: {e}")

        return False

    def get_pod_cgroup_path(self, pod_uid):
        """
        Find the cgroup path for a pod.

        Args:
            pod_uid: Kubernetes pod UID

        Returns:
            Path object to the pod's cgroup directory, or None if not found
        """
        # Common cgroup paths for different container runtimes
        possible_paths = [
            # containerd
            self.cgroup_root / "kubepods.slice" / f"kubepods-pod{pod_uid}.slice",
            self.cgroup_root / "kubepods" / f"pod{pod_uid}",
            # docker
            self.cgroup_root / "kubepods" / "burstable" / f"pod{pod_uid}",
            self.cgroup_root / "kubepods" / "besteffort" / f"pod{pod_uid}",
        ]

        for path in possible_paths:
            if path.exists():
                return path

        # Search for pod UID in cgroup hierarchy
        try:
            for path in self.cgroup_root.rglob(f"*{pod_uid}*"):
                if path.is_dir():
                    return path
        except Exception as e:
            logger.debug(f"Error searching for cgroup: {e}")

        return None

    def get_io_stats(self, cgroup_path):
        """
        Read I/O statistics from cgroup.

        Args:
            cgroup_path: Path to cgroup directory

        Returns:
            Dict with I/O statistics
        """
        stats = {
            'rbytes': 0,
            'wbytes': 0,
            'rios': 0,
            'wios': 0
        }

        try:
            # Read io.stat (cgroup v2)
            io_stat_file = cgroup_path / "io.stat"
            if io_stat_file.exists():
                with open(io_stat_file, 'r') as f:
                    for line in f:
                        parts = line.split()
                        if len(parts) < 2:
                            continue

                        # Parse device stats
                        for item in parts[1:]:
                            if '=' in item:
                                key, value = item.split('=')
                                if key in stats:
                                    stats[key] += int(value)

        except Exception as e:
            logger.debug(f"Failed to read I/O stats from {cgroup_path}: {e}")

        return stats

    def set_io_weight(self, cgroup_path, weight):
        """
        Set I/O weight for a cgroup.

        Args:
            cgroup_path: Path to cgroup directory
            weight: I/O weight value (1-10000, default 100)

        Returns:
            True if successful, False otherwise
        """
        if not self.cgroup_v2_enabled:
            logger.debug("cgroup v2 not available, skipping I/O weight setting")
            return False

        try:
            io_weight_file = cgroup_path / "io.weight"

            if not io_weight_file.exists():
                logger.debug(f"io.weight not found at {cgroup_path}")
                return False

            # Validate weight range
            weight = max(1, min(10000, int(weight)))

            # Write weight
            with open(io_weight_file, 'w') as f:
                f.write(f"default {weight}\n")

            logger.debug(f"Set I/O weight to {weight} for {cgroup_path}")
            return True

        except PermissionError:
            logger.error(f"Permission denied writing to {io_weight_file}")
            return False
        except Exception as e:
            logger.error(f"Failed to set I/O weight: {e}")
            return False

    def get_current_io_weight(self, cgroup_path):
        """
        Get current I/O weight for a cgroup.

        Args:
            cgroup_path: Path to cgroup directory

        Returns:
            Current I/O weight value, or None if unavailable
        """
        try:
            io_weight_file = cgroup_path / "io.weight"

            if not io_weight_file.exists():
                return None

            with open(io_weight_file, 'r') as f:
                line = f.readline().strip()
                # Format: "default 100" or "default 100\n8:0 200"
                if line.startswith("default"):
                    return int(line.split()[1])

        except Exception as e:
            logger.debug(f"Failed to read I/O weight: {e}")

        return None


##############################################################################
# DRC-IO Controller
##############################################################################

class DRCIOController:
    """
    Main controller for DRC-IO system.
    """

    # I/O weight configuration
    IO_WEIGHTS = {
        'high': 1000,    # High priority (10x baseline)
        'medium': 100,   # Medium priority (baseline)
        'low': 10        # Low priority (1/10 baseline)
    }

    # Priority labels
    PRIORITY_LABEL = "drcio.io/priority"

    def __init__(self, node_name=None):
        self.node_name = node_name or os.getenv('NODE_NAME', 'unknown')
        self.namespace = os.getenv('NAMESPACE', 'default')

        # Initialize Kubernetes client
        try:
            # Try in-cluster config first
            config.load_incluster_config()
            logger.info("✓ Loaded in-cluster Kubernetes config")
        except:
            try:
                # Fall back to kubeconfig
                config.load_kube_config()
                logger.info("✓ Loaded kubeconfig")
            except Exception as e:
                logger.error(f"Failed to load Kubernetes config: {e}")
                sys.exit(1)

        self.k8s_api = client.CoreV1Api()

        # Initialize cgroup manager
        self.cgroup_mgr = CgroupIOManager()

        # Pod tracking
        self.managed_pods = {}  # pod_uid -> pod_info
        self.pod_stats = defaultdict(lambda: {'last_rbytes': 0, 'last_wbytes': 0})

        logger.info(f"✓ DRC-IO Controller initialized for node: {self.node_name}")

    def run(self):
        """Run the main control loop."""
        logger.info("=" * 60)
        logger.info("Starting DRC-IO Controller")
        logger.info("=" * 60)
        logger.info(f"Node: {self.node_name}")
        logger.info(f"Namespace: {self.namespace}")
        logger.info("=" * 60)

        # Start pod discovery thread
        discovery_thread = threading.Thread(target=self._pod_discovery_loop, daemon=True)
        discovery_thread.start()

        # Run main control loop
        self._control_loop()

    def _pod_discovery_loop(self):
        """Continuously discover and track pods on this node."""
        logger.info("Starting pod discovery loop...")

        while not shutdown_requested:
            try:
                # List pods on this node
                field_selector = f"spec.nodeName={self.node_name},status.phase=Running"
                pods = self.k8s_api.list_pod_for_all_namespaces(
                    field_selector=field_selector,
                    timeout_seconds=10
                )

                current_pod_uids = set()

                for pod in pods.items:
                    pod_uid = pod.metadata.uid.replace('-', '_')
                    current_pod_uids.add(pod_uid)

                    # Check if pod has DRC-IO priority label
                    labels = pod.metadata.labels or {}
                    priority = labels.get(self.PRIORITY_LABEL, 'medium')

                    # Add or update pod
                    if pod_uid not in self.managed_pods:
                        self.managed_pods[pod_uid] = {
                            'name': pod.metadata.name,
                            'namespace': pod.metadata.namespace,
                            'priority': priority,
                            'uid': pod_uid
                        }

                        WORKLOAD_DISCOVERY.labels(
                            workload_type='pod',
                            priority=priority
                        ).inc()

                        logger.info(
                            f"Discovered pod: {pod.metadata.namespace}/{pod.metadata.name} "
                            f"(priority: {priority})"
                        )

                # Remove pods that are no longer running
                removed_pods = set(self.managed_pods.keys()) - current_pod_uids
                for pod_uid in removed_pods:
                    pod_info = self.managed_pods.pop(pod_uid)
                    logger.info(f"Removed pod: {pod_info['namespace']}/{pod_info['name']}")

                # Update active pod counts
                priority_counts = defaultdict(int)
                for pod_info in self.managed_pods.values():
                    priority_counts[pod_info['priority']] += 1

                for priority, count in priority_counts.items():
                    ACTIVE_PODS.labels(priority=priority).set(count)

            except Exception as e:
                logger.error(f"Error in pod discovery: {e}", exc_info=True)

            # Sleep before next discovery
            time.sleep(10)

    def _control_loop(self):
        """Main control loop for I/O management."""
        logger.info("Starting control loop...")

        while not shutdown_requested:
            loop_start = time.time()

            try:
                self._apply_io_controls()
                self._collect_metrics()

            except Exception as e:
                logger.error(f"Error in control loop: {e}", exc_info=True)

            # Record loop duration
            loop_duration = time.time() - loop_start
            CONTROL_LOOP_DURATION.observe(loop_duration)

            # Sleep until next iteration
            sleep_time = max(0, 5 - loop_duration)  # 5-second interval
            time.sleep(sleep_time)

    def _apply_io_controls(self):
        """Apply I/O weights to managed pods."""
        for pod_uid, pod_info in self.managed_pods.items():
            # Find cgroup path
            cgroup_path = self.cgroup_mgr.get_pod_cgroup_path(pod_uid)

            if not cgroup_path:
                logger.debug(f"Cgroup not found for pod {pod_info['name']}")
                continue

            # Get target I/O weight based on priority
            priority = pod_info['priority']
            target_weight = self.IO_WEIGHTS.get(priority, self.IO_WEIGHTS['medium'])

            # Get current weight
            current_weight = self.cgroup_mgr.get_current_io_weight(cgroup_path)

            # Apply weight if different
            if current_weight != target_weight:
                success = self.cgroup_mgr.set_io_weight(cgroup_path, target_weight)

                if success:
                    IO_WEIGHT_APPLIED.labels(
                        workload_type='pod',
                        priority=priority
                    ).inc()

                    logger.info(
                        f"Applied I/O weight {target_weight} to "
                        f"{pod_info['namespace']}/{pod_info['name']} (priority: {priority})"
                    )

            # Update metrics
            CURRENT_IO_WEIGHT.labels(
                pod_name=pod_info['name'],
                namespace=pod_info['namespace'],
                priority=priority
            ).set(target_weight)

    def _collect_metrics(self):
        """Collect I/O metrics from managed pods."""
        for pod_uid, pod_info in self.managed_pods.items():
            # Find cgroup path
            cgroup_path = self.cgroup_mgr.get_pod_cgroup_path(pod_uid)

            if not cgroup_path:
                continue

            # Get I/O stats
            stats = self.cgroup_mgr.get_io_stats(cgroup_path)

            # Update Prometheus metrics
            IO_BYTES_READ.labels(
                pod_name=pod_info['name'],
                namespace=pod_info['namespace'],
                priority=pod_info['priority']
            ).set(stats['rbytes'])

            IO_BYTES_WRITE.labels(
                pod_name=pod_info['name'],
                namespace=pod_info['namespace'],
                priority=pod_info['priority']
            ).set(stats['wbytes'])

            # Calculate rates
            last_stats = self.pod_stats[pod_uid]
            read_rate = stats['rbytes'] - last_stats['last_rbytes']
            write_rate = stats['wbytes'] - last_stats['last_wbytes']

            # Update last stats
            self.pod_stats[pod_uid]['last_rbytes'] = stats['rbytes']
            self.pod_stats[pod_uid]['last_wbytes'] = stats['wbytes']

            if read_rate > 0 or write_rate > 0:
                logger.debug(
                    f"Pod {pod_info['name']}: "
                    f"read={self._format_bytes(read_rate)}/s, "
                    f"write={self._format_bytes(write_rate)}/s"
                )

    @staticmethod
    def _format_bytes(bytes_value):
        """Format bytes in human-readable format."""
        for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
            if bytes_value < 1024.0:
                return f"{bytes_value:.2f} {unit}"
            bytes_value /= 1024.0
        return f"{bytes_value:.2f} PB"


##############################################################################
# Signal Handling
##############################################################################

def signal_handler(signum, frame):
    """Handle shutdown signals."""
    global shutdown_requested

    logger.info(f"Received signal {signum}, initiating graceful shutdown...")
    shutdown_requested = True


##############################################################################
# Main Entry Point
##############################################################################

def main():
    """Main entry point."""
    # Register signal handlers
    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)

    # Get configuration from environment
    metrics_port = int(os.getenv('METRICS_PORT', 9100))
    node_name = os.getenv('NODE_NAME')

    if not node_name:
        logger.error("NODE_NAME environment variable not set")
        sys.exit(1)

    # Start Prometheus metrics server
    logger.info(f"Starting Prometheus metrics server on port {metrics_port}...")
    start_http_server(metrics_port)

    # Create and run controller
    try:
        controller = DRCIOController(node_name=node_name)
        controller.run()

        logger.info("✓ Controller stopped gracefully")
        sys.exit(0)

    except Exception as e:
        logger.error(f"Controller failed: {str(e)}", exc_info=True)
        sys.exit(1)


if __name__ == '__main__':
    main()
