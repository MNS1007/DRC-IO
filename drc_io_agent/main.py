#!/usr/bin/env python3
"""
Dynamic Resource Controller for Input and Output Scheduling (Node Agent)

Main controller loop that:
1. Detects high/low priority pods based on group-id labels
2. Identifies cgroup paths for containers
3. Applies I/O bandwidth limits to low priority workloads
4. Exposes metrics and status endpoints
"""

import os
import sys
import time
import logging
import signal
from typing import Dict, List, Set
from flask import Flask, jsonify
from threading import Thread

from k8s_utils import (
    load_k8s_config,
    get_node_name,
    list_pods_on_node,
    group_pods_by_priority
)
from cgroup_utils import (
    find_pod_cgroup_paths,
    discover_block_device,
    apply_io_limit,
    get_current_io_limits
)

# Configuration
POLL_INTERVAL = int(os.environ.get("POLL_INTERVAL", "5"))  # seconds
SHARED_MOUNT_PATH = os.environ.get("SHARED_MOUNT_PATH", "/mnt/features")
READ_BANDWIDTH_LIMIT = os.environ.get("READ_BANDWIDTH_LIMIT", "200M")
WRITE_BANDWIDTH_LIMIT = os.environ.get("WRITE_BANDWIDTH_LIMIT", "50M")
METRICS_PORT = int(os.environ.get("METRICS_PORT", "8080"))

# Global state
app = Flask(__name__)
controller_state = {
    "node_name": "",
    "high_priority_pods": [],
    "low_priority_pods": [],
    "cgroups_with_limits": {},
    "last_update": None,
    "error_count": 0,
    "last_error": None
}

# Thread-safe lock would be needed for production, but keeping simple for now
running = True


def setup_logging():
    """Configure logging."""
    log_level = os.environ.get("LOG_LEVEL", "INFO").upper()
    logging.basicConfig(
        level=getattr(logging, log_level, logging.INFO),
        format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S"
    )


def signal_handler(signum, frame):
    """Handle shutdown signals gracefully."""
    global running
    logging.info("Received shutdown signal, stopping controller...")
    running = False


def discover_block_device_for_shared_volume() -> str:
    """
    Discover the block device for the shared volume.
    Caches the result since it shouldn't change during runtime.
    """
    device = discover_block_device(SHARED_MOUNT_PATH)
    if not device:
        raise RuntimeError(f"Could not discover block device for {SHARED_MOUNT_PATH}")
    return device


def apply_limits_to_low_priority_pods(low_priority_pods: List[Dict], device: str):
    """
    Apply I/O bandwidth limits to all containers in low priority pods.
    
    Args:
        low_priority_pods: List of pod dictionaries with group-id=lp
        device: Block device identifier (major:minor format)
    """
    cgroups_with_limits = {}
    
    for pod in low_priority_pods:
        pod_name = pod.get("name", "unknown")
        cgroup_paths = find_pod_cgroup_paths(pod)
        
        for cgroup_path in cgroup_paths:
            success = apply_io_limit(
                cgroup_path,
                device,
                READ_BANDWIDTH_LIMIT,
                WRITE_BANDWIDTH_LIMIT
            )
            
            if success:
                cgroups_with_limits[cgroup_path] = {
                    "pod": pod_name,
                    "device": device,
                    "rbps": READ_BANDWIDTH_LIMIT,
                    "wbps": WRITE_BANDWIDTH_LIMIT
                }
                logging.info(
                    f"Applying input and output limit rbps={READ_BANDWIDTH_LIMIT} "
                    f"wbps={WRITE_BANDWIDTH_LIMIT} to cgroup {cgroup_path} "
                    f"for pod {pod_name}"
                )
            else:
                logging.warning(
                    f"Failed to apply I/O limit to cgroup {cgroup_path} for pod {pod_name}"
                )
    
    return cgroups_with_limits


def controller_loop():
    """Main controller loop that periodically updates I/O limits."""
    global controller_state
    
    logger = logging.getLogger(__name__)
    
    try:
        # Load Kubernetes configuration
        load_k8s_config()
        node_name = get_node_name()
        controller_state["node_name"] = node_name
        logger.info(f"Controller starting on node: {node_name}")
        
        # Discover block device once (shouldn't change)
        try:
            device = discover_block_device_for_shared_volume()
            logger.info(f"Discovered block device {device} for shared volume {SHARED_MOUNT_PATH}")
        except RuntimeError as e:
            logger.error(f"Failed to discover block device: {e}")
            controller_state["last_error"] = str(e)
            controller_state["error_count"] += 1
            # Continue anyway - might be able to recover later
        
        while running:
            try:
                # List pods on this node
                pods = list_pods_on_node(node_name)
                
                # Group by priority
                high_priority, low_priority = group_pods_by_priority(pods)
                
                # Update state
                controller_state["high_priority_pods"] = [
                    {"name": p.get("name"), "namespace": p.get("namespace")}
                    for p in high_priority
                ]
                controller_state["low_priority_pods"] = [
                    {"name": p.get("name"), "namespace": p.get("namespace")}
                    for p in low_priority
                ]
                
                # Apply limits to low priority pods
                if device:
                    cgroups_with_limits = apply_limits_to_low_priority_pods(
                        low_priority, device
                    )
                    controller_state["cgroups_with_limits"] = cgroups_with_limits
                else:
                    # Try to rediscover device
                    try:
                        device = discover_block_device_for_shared_volume()
                        logger.info(f"Rediscovered block device {device}")
                    except RuntimeError:
                        pass
                
                controller_state["last_update"] = time.time()
                controller_state["error_count"] = 0
                controller_state["last_error"] = None
                
            except Exception as e:
                logger.error(f"Error in controller loop: {e}", exc_info=True)
                controller_state["error_count"] += 1
                controller_state["last_error"] = str(e)
            
            # Sleep before next iteration
            time.sleep(POLL_INTERVAL)
            
    except KeyboardInterrupt:
        logger.info("Controller interrupted")
    except Exception as e:
        logger.error(f"Fatal error in controller: {e}", exc_info=True)
        sys.exit(1)


@app.route("/health")
def health():
    """Health check endpoint."""
    return jsonify({"status": "healthy"}), 200


@app.route("/status")
def status():
    """Status endpoint showing current controller state."""
    return jsonify({
        "node_name": controller_state["node_name"],
        "high_priority_pods_count": len(controller_state["high_priority_pods"]),
        "low_priority_pods_count": len(controller_state["low_priority_pods"]),
        "high_priority_pods": controller_state["high_priority_pods"],
        "low_priority_pods": controller_state["low_priority_pods"],
        "cgroups_with_limits_count": len(controller_state["cgroups_with_limits"]),
        "cgroups_with_limits": controller_state["cgroups_with_limits"],
        "last_update": controller_state["last_update"],
        "error_count": controller_state["error_count"],
        "last_error": controller_state["last_error"],
        "configuration": {
            "poll_interval": POLL_INTERVAL,
            "shared_mount_path": SHARED_MOUNT_PATH,
            "read_bandwidth_limit": READ_BANDWIDTH_LIMIT,
            "write_bandwidth_limit": WRITE_BANDWIDTH_LIMIT
        }
    }), 200


@app.route("/metrics")
def metrics():
    """
    Prometheus metrics endpoint.
    Returns metrics in Prometheus text format.
    """
    metrics_lines = [
        "# HELP drc_io_high_priority_pods Number of high priority pods detected",
        "# TYPE drc_io_high_priority_pods gauge",
        f"drc_io_high_priority_pods {len(controller_state['high_priority_pods'])}",
        "",
        "# HELP drc_io_low_priority_pods Number of low priority pods detected",
        "# TYPE drc_io_low_priority_pods gauge",
        f"drc_io_low_priority_pods {len(controller_state['low_priority_pods'])}",
        "",
        "# HELP drc_io_cgroups_with_limits Number of cgroups with I/O limits applied",
        "# TYPE drc_io_cgroups_with_limits gauge",
        f"drc_io_cgroups_with_limits {len(controller_state['cgroups_with_limits'])}",
        "",
        "# HELP drc_io_controller_errors_total Total number of controller errors",
        "# TYPE drc_io_controller_errors_total counter",
        f"drc_io_controller_errors_total {controller_state['error_count']}",
        "",
        "# HELP drc_io_last_update_timestamp Timestamp of last successful update",
        "# TYPE drc_io_last_update_timestamp gauge",
        f"drc_io_last_update_timestamp {controller_state['last_update'] or 0}",
    ]
    
    return "\n".join(metrics_lines), 200, {"Content-Type": "text/plain"}


def main():
    """Main entry point."""
    setup_logging()
    logger = logging.getLogger(__name__)
    
    # Register signal handlers
    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)
    
    # Start controller loop in background thread
    controller_thread = Thread(target=controller_loop, daemon=True)
    controller_thread.start()
    
    logger.info(f"Starting metrics server on port {METRICS_PORT}")
    
    # Run Flask app (blocking)
    app.run(host="0.0.0.0", port=METRICS_PORT, threaded=True)


if __name__ == "__main__":
    main()

