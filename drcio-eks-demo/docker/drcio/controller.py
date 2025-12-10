#!/usr/bin/env python3
"""
DRC-IO Controller: Dynamic Resource Controller for I/O

This daemon protects latency-critical services by continuously monitoring
their SLA metrics and dynamically adjusting the Linux cgroup io.weight
values of co-located low-priority batch workloads.
"""

import glob
import logging
import os
import signal
import sys
import time
from datetime import datetime, timezone
from typing import Dict, List, Optional, Tuple

import requests
from kubernetes import client, config
from prometheus_client import Counter, Gauge, Histogram, start_http_server

# -----------------------------------------------------------------------------
# Logging setup
# -----------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger("drcio")

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
PROMETHEUS_URL = os.getenv(
    "PROMETHEUS_URL",
    "http://prometheus-kube-prometheus-prometheus.monitoring:9090",
)
SLA_THRESHOLD_MS = float(os.getenv("SLA_THRESHOLD_MS", "500"))
CONTROL_LOOP_INTERVAL = int(os.getenv("CONTROL_LOOP_INTERVAL", "5"))
K8S_NAMESPACE = os.getenv("K8S_NAMESPACE", "fraud-detection")
METRICS_PORT = int(os.getenv("METRICS_PORT", "8080"))
MIN_IO_WEIGHT = max(1, int(os.getenv("MIN_IO_WEIGHT", "100")))
MAX_IO_WEIGHT = min(1000, int(os.getenv("MAX_IO_WEIGHT", "1000")))
ADJUSTMENT_COOLDOWN = int(os.getenv("ADJUSTMENT_COOLDOWN", "10"))

CGROUP_ROOT = "/sys/fs/cgroup"
CGROUP_PATTERNS = [
    "kubepods.slice/kubepods-burstable.slice/kubepods-burstable-pod{uid}.slice",
    "kubepods.slice/kubepods-besteffort.slice/kubepods-besteffort-pod{uid}.slice",
    "kubepods/kubepods-burstable.slice/kubepods-burstable-pod{uid}.slice",
    "kubepods/pod{uid}",
]

# -----------------------------------------------------------------------------
# Prometheus metrics exposed by the controller itself
# -----------------------------------------------------------------------------
drcio_hp_weight = Gauge("drcio_hp_weight", "Current I/O weight for HP pods")
drcio_lp_weight = Gauge("drcio_lp_weight", "Current I/O weight for LP pods")
drcio_hp_latency_ms = Gauge(
    "drcio_hp_latency_ms", "Current HP service P95 latency in ms"
)
drcio_adjustments_total = Counter(
    "drcio_adjustments_total", "Total number of I/O weight adjustments"
)
drcio_errors_total = Counter(
    "drcio_errors_total", "Total number of errors encountered", ["error_type"]
)
drcio_pod_count = Gauge(
    "drcio_pod_count",
    "Number of pods under DRC-IO management",
    ["priority"],
)
drcio_last_adjustment_ts = Gauge(
    "drcio_last_adjustment_timestamp",
    "Unix epoch timestamp of the last successful adjustment",
)
drcio_control_loop_duration = Histogram(
    "drcio_control_loop_duration_seconds",
    "Duration of a single DRC-IO control loop iteration",
    buckets=(
        0.05,
        0.1,
        0.2,
        0.3,
        0.5,
        0.75,
        1.0,
        1.5,
        2.0,
        3.0,
        5.0,
    ),
)

# -----------------------------------------------------------------------------
# Graceful shutdown handling
# -----------------------------------------------------------------------------
running = True


def signal_handler(signum, _frame):
    global running
    logger.info("Received signal %s, shutting down gracefully...", signum)
    running = False


signal.signal(signal.SIGTERM, signal_handler)
signal.signal(signal.SIGINT, signal_handler)


class DRCIOController:
    """Dynamic Resource Controller implementation."""

    def __init__(self):
        self.namespace = K8S_NAMESPACE
        self.sla_threshold_ms = SLA_THRESHOLD_MS
        self.prometheus_url = PROMETHEUS_URL.rstrip("/")
        self.hp_weight = 500
        self.lp_weight = 500
        self.adjustment_count = 0
        self.last_adjustment_time: Optional[float] = None
        self.http = requests.Session()
        self.http.headers.update({"User-Agent": "drcio-controller/1.0"})

        self._load_kube_client()

        logger.info("DRC-IO Controller initialized")
        logger.info("Namespace: %s", self.namespace)
        logger.info("Prometheus: %s", self.prometheus_url)
        logger.info("SLA Threshold: %.0f ms", self.sla_threshold_ms)
        logger.info("I/O weight bounds: %s - %s", MIN_IO_WEIGHT, MAX_IO_WEIGHT)
        logger.info("Control loop interval: %ss", CONTROL_LOOP_INTERVAL)

    def _load_kube_client(self):
        """Load Kubernetes config (in cluster first, fall back to kubeconfig)."""
        try:
            config.load_incluster_config()
            logger.info("Loaded in-cluster Kubernetes config")
        except Exception:
            config.load_kube_config()
            logger.info("Loaded local kubeconfig")
        self.k8s_api = client.CoreV1Api()

    # ------------------------------------------------------------------ Pod discovery
    def discover_pods(self) -> Tuple[List[Dict], List[Dict]]:
        """Discover HP and LP pods in the managed namespace."""
        try:
            pods = self.k8s_api.list_namespaced_pod(self.namespace, watch=False)
        except Exception as exc:
            logger.error("Error discovering pods: %s", exc, exc_info=True)
            drcio_errors_total.labels(error_type="pod_discovery").inc()
            return [], []

        hp_pods: List[Dict] = []
        lp_pods: List[Dict] = []

        for pod in pods.items:
            if pod.status.phase != "Running":
                continue

            labels = pod.metadata.labels or {}
            group_id = labels.get("group-id")
            pod_info = {
                "name": pod.metadata.name,
                "uid": pod.metadata.uid,
                "node": pod.spec.node_name,
                "namespace": pod.metadata.namespace,
                "labels": labels,
            }

            if group_id == "hp":
                hp_pods.append(pod_info)
            elif group_id == "lp":
                lp_pods.append(pod_info)

        drcio_pod_count.labels("hp").set(len(hp_pods))
        drcio_pod_count.labels("lp").set(len(lp_pods))
        logger.debug("Discovered %d HP pods and %d LP pods", len(hp_pods), len(lp_pods))
        return hp_pods, lp_pods

    # ------------------------------------------------------------------ Metrics ingestion
    def get_hp_latency(self) -> Optional[float]:
        """Return HP service P95 latency (ms) from Prometheus."""
        query = (
            "histogram_quantile(0.95, "
            "sum(rate(http_request_duration_seconds_bucket{"
            f'namespace="{self.namespace}",group_id="hp"'
            "}[1m])) by (le))"
        )
        try:
            response = self.http.get(
                f"{self.prometheus_url}/api/v1/query",
                params={"query": query},
                timeout=5,
            )
            response.raise_for_status()
        except requests.RequestException as exc:
            logger.error("Error querying Prometheus: %s", exc)
            drcio_errors_total.labels(error_type="prometheus_query").inc()
            return None

        result = response.json()
        if result.get("status") != "success":
            logger.warning("Prometheus query unsuccessful: %s", result)
            return None

        data = result.get("data", {}).get("result")
        if not data:
            logger.debug("Prometheus returned no latency samples")
            return None

        try:
            latency_seconds = float(data[0]["value"][1])
        except (KeyError, ValueError, TypeError) as exc:
            logger.error("Unable to parse Prometheus latency response: %s", exc)
            drcio_errors_total.labels(error_type="prometheus_parse").inc()
            return None

        latency_ms = latency_seconds * 1000
        drcio_hp_latency_ms.set(latency_ms)
        return latency_ms

    # ------------------------------------------------------------------ I/O scheduling logic
    def calculate_weights(self, current_latency_ms: float) -> Tuple[int, int]:
        """
        Decide new HP/LP weights. The further away from SLA, the more aggressive
        the prioritization of HP workloads. Returns (hp_weight, lp_weight).
        """
        threshold = self.sla_threshold_ms

        if current_latency_ms > threshold * 1.3:
            weights = (900, 100)
        elif current_latency_ms > threshold * 1.1:
            weights = (800, 200)
        elif current_latency_ms > threshold:
            weights = (750, 250)
        elif current_latency_ms > threshold * 0.8:
            weights = (700, 300)
        elif current_latency_ms > threshold * 0.6:
            weights = (600, 400)
        else:
            weights = (500, 500)

        return tuple(self._clamp_weight(w) for w in weights)  # type: ignore

    @staticmethod
    def _clamp_weight(weight: int) -> int:
        return max(MIN_IO_WEIGHT, min(MAX_IO_WEIGHT, weight))

    # ------------------------------------------------------------------ cgroup helpers
    def get_cgroup_path(self, pod_info: Dict) -> Optional[str]:
        """Locate the pod's cgroup directory."""
        pod_uid = pod_info["uid"]
        sanitized_uid = pod_uid.replace("-", "_")

        for pattern in CGROUP_PATTERNS:
            candidate = os.path.join(CGROUP_ROOT, pattern.format(uid=sanitized_uid))
            if os.path.isdir(candidate):
                return candidate

        # Fallback to slower glob search
        try:
            matches = glob.glob(
                os.path.join(CGROUP_ROOT, f"**/*pod{sanitized_uid}*"), recursive=True
            )
            for match in matches:
                if os.path.isdir(match):
                    return match
        except OSError as exc:
            logger.debug("Error during cgroup glob search: %s", exc)

        logger.warning("Could not locate cgroup for pod %s (%s)", pod_info["name"], pod_uid)
        return None

    def apply_io_weight(self, pod_info: Dict, weight: int) -> bool:
        """
        Apply io.weight to every container folder found for the pod.
        Returns True if at least one container was updated.
        """
        cgroup_path = self.get_cgroup_path(pod_info)
        if not cgroup_path:
            return False

        targets = []
        direct_weight = os.path.join(cgroup_path, "io.weight")
        if os.path.isfile(direct_weight):
            targets.append(direct_weight)

        for entry in glob.glob(os.path.join(cgroup_path, "*")):
            candidate = os.path.join(entry, "io.weight")
            if os.path.isfile(candidate):
                targets.append(candidate)

        if not targets:
            logger.warning("No io.weight files found under %s", cgroup_path)
            return False

        success = False
        for target in targets:
            try:
                with open(target, "w", encoding="utf-8") as handle:
                    handle.write(f"default {weight}\n")
                logger.debug("Set io.weight=%s for %s", weight, target)
                success = True
            except PermissionError:
                logger.error("Permission denied writing %s", target)
                drcio_errors_total.labels(error_type="permission_denied").inc()
            except OSError as exc:
                logger.error("Failed writing %s: %s", target, exc)
                drcio_errors_total.labels(error_type="io_weight_write").inc()

        return success

    # ------------------------------------------------------------------ Control loop
    def control_loop_iteration(self):
        """Execute a single control loop iteration."""
        start = time.time()
        try:
            hp_pods, lp_pods = self.discover_pods()
            if not hp_pods:
                logger.debug("No HP pods discovered; skipping iteration")
                return

            latency = self.get_hp_latency()
            if latency is None:
                logger.debug("Latency metrics unavailable; skipping adjustment check")
                return

            new_hp_weight, new_lp_weight = self.calculate_weights(latency)
            if (
                new_hp_weight == self.hp_weight
                and new_lp_weight == self.lp_weight
            ):
                logger.debug(
                    "Latency %.1f ms within tolerance; keeping weights HP=%d LP=%d",
                    latency,
                    self.hp_weight,
                    self.lp_weight,
                )
                return

            if self.last_adjustment_time:
                elapsed = time.time() - self.last_adjustment_time
                if elapsed < ADJUSTMENT_COOLDOWN:
                    logger.debug(
                        "Last adjustment %.1fs ago; waiting for cooldown (target %ss)",
                        elapsed,
                        ADJUSTMENT_COOLDOWN,
                    )
                    return

            self._apply_new_weights(hp_pods, lp_pods, new_hp_weight, new_lp_weight, latency)
        finally:
            drcio_control_loop_duration.observe(time.time() - start)

    def _apply_new_weights(
        self,
        hp_pods: List[Dict],
        lp_pods: List[Dict],
        new_hp_weight: int,
        new_lp_weight: int,
        latency: float,
    ):
        """Apply computed weights and emit structured logs/metrics."""
        logger.info("╔════════════════════════════════════════════════════════╗")
        logger.info("║              DRC-IO ADJUSTMENT TRIGGERED               ║")
        logger.info("╠════════════════════════════════════════════════════════╣")
        logger.info(
            "║  HP Latency: %8.1f ms (SLA: %.0f ms)                       ║",
            latency,
            self.sla_threshold_ms,
        )
        logger.info(
            "║  Old weights: HP=%4d  LP=%4d                               ║",
            self.hp_weight,
            self.lp_weight,
        )
        logger.info(
            "║  New weights: HP=%4d  LP=%4d                               ║",
            new_hp_weight,
            new_lp_weight,
        )

        hp_success = sum(1 for pod in hp_pods if self.apply_io_weight(pod, new_hp_weight))
        lp_success = sum(1 for pod in lp_pods if self.apply_io_weight(pod, new_lp_weight))

        logger.info(
            "║  Applied to:   %2d/%2d HP pods | %2d/%2d LP pods             ║",
            hp_success,
            len(hp_pods),
            lp_success,
            len(lp_pods),
        )
        logger.info("╚════════════════════════════════════════════════════════╝")

        self.hp_weight = new_hp_weight
        self.lp_weight = new_lp_weight
        self.adjustment_count += 1
        self.last_adjustment_time = time.time()
        drcio_hp_weight.set(new_hp_weight)
        drcio_lp_weight.set(new_lp_weight)
        drcio_adjustments_total.inc()
        drcio_last_adjustment_ts.set(self.last_adjustment_time)

    def run(self):
        """Main controller loop."""
        logger.info("╔════════════════════════════════════════════════════════╗")
        logger.info("║            DRC-IO CONTROLLER STARTING                  ║")
        logger.info("╚════════════════════════════════════════════════════════╝")
        iteration = 0

        while running:
            iteration += 1
            try:
                self.control_loop_iteration()
                if iteration % 10 == 0:
                    logger.info(
                        "Status: %d adjustments | current weights HP=%d, LP=%d",
                        self.adjustment_count,
                        self.hp_weight,
                        self.lp_weight,
                    )
            except Exception as exc:
                logger.error("Unexpected error in control loop: %s", exc, exc_info=True)
                drcio_errors_total.labels(error_type="control_loop").inc()
            finally:
                time.sleep(CONTROL_LOOP_INTERVAL)

        logger.info("DRC-IO Controller shutting down. Total adjustments: %d", self.adjustment_count)


def main():
    """Entrypoint."""
    start_http_server(METRICS_PORT)
    logger.info("Prometheus metrics server started on port %d", METRICS_PORT)
    controller = DRCIOController()
    controller.run()


if __name__ == "__main__":
    main()
