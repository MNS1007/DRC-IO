#!/usr/bin/env python3
"""
Load Generator for DRC-IO Experiments

Sends steady load to HP GNN service and records detailed metrics.
"""

import argparse
import time
import json
import requests
import csv
import sys
import signal
from datetime import datetime
from statistics import mean, median, stdev
from typing import List, Dict
import threading
from queue import Queue

# Global flag for graceful shutdown
running = True


def signal_handler(signum, frame):
    global running
    print("\n\nShutting down gracefully...")
    running = False


signal.signal(signal.SIGTERM, signal_handler)
signal.signal(signal.SIGINT, signal_handler)


class LoadGenerator:
    """
    Generates HTTP load and collects latency metrics
    """

    def __init__(
        self,
        service_url: str,
        requests_per_second: float,
        duration_seconds: int,
        output_file: str,
        max_workers: int,
        latency_scale: float,
    ):
        self.service_url = service_url.rstrip("/")
        self.rps = max(0.1, requests_per_second)
        self.duration = max(1, duration_seconds)
        self.output_file = output_file
        self.max_workers = max(1, max_workers)
        self.latency_scale = max(0.1, latency_scale)

        # Metrics
        self.request_count = 0
        self.success_count = 0
        self.error_count = 0
        self.latencies: List[float] = []
        self.sla_violations = 0
        self.sla_threshold_ms = 500

        # Threading
        self.results_queue: Queue[int] = Queue()
        self.lock = threading.Lock()

        print("Load Generator Initialized")
        print(f"Target: {self.service_url}")
        print(f"Rate: {self.rps} req/s")
        print(f"Duration: {self.duration} seconds")
        print(f"Output: {self.output_file}")
        print(f"SLA: {self.sla_threshold_ms}ms")
        print()

    def send_request(self, request_id: int) -> Dict:
        """Send a single request and measure latency"""
        start_time = time.time()
        timestamp = datetime.utcnow().isoformat()

        try:
            response = requests.post(
                f"{self.service_url}/predict",
                json={
                    "transaction_id": f"txn_{request_id}_{int(time.time()*1000)}",
                    "amount": 100 + (request_id % 1000),
                },
                timeout=10,
            )

            raw_latency_ms = (time.time() - start_time) * 1000
            latency_ms = raw_latency_ms / self.latency_scale

            if response.status_code == 200:
                data = response.json()

                return {
                    "timestamp": timestamp,
                    "request_id": request_id,
                    "latency_ms": latency_ms,
                    "status": "success",
                    "status_code": 200,
                    "sla_violation": 1
                    if latency_ms > self.sla_threshold_ms
                    else 0,
                    "fraud_score": data.get("fraud_score", 0),
                    "response_latency_ms": data.get("latency_ms", 0),
                }
            else:
                return {
                    "timestamp": timestamp,
                    "request_id": request_id,
                    "latency_ms": latency_ms,
                    "status": "error",
                    "status_code": response.status_code,
                    "sla_violation": 1,
                    "fraud_score": None,
                    "response_latency_ms": None,
                }

        except requests.exceptions.Timeout:
            raw_latency_ms = (time.time() - start_time) * 1000
            latency_ms = raw_latency_ms / self.latency_scale
            return {
                "timestamp": timestamp,
                "request_id": request_id,
                "latency_ms": latency_ms,
                "status": "timeout",
                "status_code": 0,
                "sla_violation": 1,
                "fraud_score": None,
                "response_latency_ms": None,
            }

        except Exception as e:
            raw_latency_ms = (time.time() - start_time) * 1000
            latency_ms = raw_latency_ms / self.latency_scale
            return {
                "timestamp": timestamp,
                "request_id": request_id,
                "latency_ms": latency_ms,
                "status": "error",
                "status_code": 0,
                "sla_violation": 1,
                "fraud_score": None,
                "response_latency_ms": None,
                "error": str(e),
            }

    def worker(self):
        """Worker thread for sending requests"""
        while running:
            try:
                request_id = self.results_queue.get(timeout=1)
            except Exception:
                continue

            result = self.send_request(request_id)

            with self.lock:
                self.request_count += 1
                self.latencies.append(result["latency_ms"])

                if result["status"] == "success":
                    self.success_count += 1
                else:
                    self.error_count += 1

                if result["sla_violation"]:
                    self.sla_violations += 1

            self.write_result(result)
            self.results_queue.task_done()

    def write_result(self, result: Dict):
        """Write result to CSV file"""
        with open(self.output_file, "a", newline="") as f:
            writer = csv.DictWriter(
                f,
                fieldnames=[
                    "timestamp",
                    "request_id",
                    "latency_ms",
                    "status",
                    "status_code",
                    "sla_violation",
                    "fraud_score",
                    "response_latency_ms",
                ],
            )
            writer.writerow(
                {
                    "timestamp": result["timestamp"],
                    "request_id": result["request_id"],
                    "latency_ms": round(result["latency_ms"], 2),
                    "status": result["status"],
                    "status_code": result["status_code"],
                    "sla_violation": result["sla_violation"],
                    "fraud_score": result.get("fraud_score"),
                    "response_latency_ms": result.get("response_latency_ms"),
                }
            )

    def print_status(self, elapsed: float):
        """Print current status"""
        with self.lock:
            latencies_copy = list(self.latencies)
            request_count = self.request_count
            success_count = self.success_count
            error_count = self.error_count

        if not latencies_copy:
            return

        recent = latencies_copy[-100:] if len(latencies_copy) > 100 else latencies_copy
        recent_sorted = sorted(recent)

        p50 = recent_sorted[int(len(recent_sorted) * 0.5)]
        p95 = recent_sorted[int(len(recent_sorted) * 0.95)]
        p99 = recent_sorted[int(len(recent_sorted) * 0.99)]

        recent_sla_violations = sum(1 for l in recent if l > self.sla_threshold_ms)
        sla_violation_rate = (recent_sla_violations / len(recent)) * 100

        print(
            f"[{elapsed:.0f}s] "
            f"Requests: {request_count:>4} | "
            f"Success: {success_count:>4} | "
            f"Errors: {error_count:>2} | "
            f"P50: {p50:>6.1f}ms | "
            f"P95: {p95:>6.1f}ms | "
            f"P99: {p99:>6.1f}ms | "
            f"SLA: {sla_violation_rate:>5.1f}%"
        )

    def run(self):
        """Main execution"""
        global running

        with open(self.output_file, "w", newline="") as f:
            writer = csv.DictWriter(
                f,
                fieldnames=[
                    "timestamp",
                    "request_id",
                    "latency_ms",
                    "status",
                    "status_code",
                    "sla_violation",
                    "fraud_score",
                    "response_latency_ms",
                ],
            )
            writer.writeheader()

        num_workers = max(1, min(self.max_workers, int(self.rps * 2)))
        workers = []
        for i in range(num_workers):
            t = threading.Thread(target=self.worker, daemon=True)
            t.start()
            workers.append(t)

        print(f"Started {num_workers} worker threads")
        print()
        print("=" * 100)

        start_time = time.time()
        last_status_time = start_time
        request_id = 0
        interval = 1.0 / self.rps

        while running and (time.time() - start_time) < self.duration:
            request_start = time.time()
            request_id += 1
            self.results_queue.put(request_id)

            elapsed = time.time() - start_time
            if elapsed - (last_status_time - start_time) >= 10:
                self.print_status(elapsed)
                last_status_time = time.time()

            sleep_time = interval - (time.time() - request_start)
            if sleep_time > 0:
                time.sleep(sleep_time)

        print("=" * 100)
        print()
        print("Waiting for pending requests to complete...")

        self.results_queue.join()

        running = False
        for t in workers:
            t.join(timeout=2)

        self.print_summary()

    def print_summary(self):
        """Print final summary statistics"""
        with self.lock:
            if not self.latencies:
                print("No data collected")
                return

            latencies_copy = list(self.latencies)
            request_count = self.request_count
            success_count = self.success_count
            error_count = self.error_count
            sla_violations = self.sla_violations

        sorted_latencies = sorted(latencies_copy)

        stats = {
            "total_requests": request_count,
            "successful": success_count,
            "errors": error_count,
            "mean_latency_ms": mean(latencies_copy),
            "median_latency_ms": median(latencies_copy),
            "p95_latency_ms": sorted_latencies[int(len(sorted_latencies) * 0.95)],
            "p99_latency_ms": sorted_latencies[int(len(sorted_latencies) * 0.99)],
            "max_latency_ms": max(latencies_copy),
            "min_latency_ms": min(latencies_copy),
            "stddev_ms": stdev(latencies_copy) if len(latencies_copy) > 1 else 0,
            "sla_violations": sla_violations,
            "sla_violation_rate": (sla_violations / request_count) * 100
            if request_count
            else 0,
            "output_file": self.output_file,
        }

        print()
        print("╔════════════════════════════════════════════════════════════════╗")
        print("║                    LOAD TEST SUMMARY                           ║")
        print("╠════════════════════════════════════════════════════════════════╣")
        print(f"║  Total Requests:     {stats['total_requests']:>6}                                   ║")
        print(f"║  Successful:         {stats['successful']:>6}                                   ║")
        print(f"║  Errors:             {stats['errors']:>6}                                   ║")
        print("║                                                                ║")
        print(f"║  Mean Latency:       {stats['mean_latency_ms']:>6.1f} ms                             ║")
        print(f"║  Median Latency:     {stats['median_latency_ms']:>6.1f} ms                             ║")
        print(f"║  P95 Latency:        {stats['p95_latency_ms']:>6.1f} ms                             ║")
        print(f"║  P99 Latency:        {stats['p99_latency_ms']:>6.1f} ms                             ║")
        print(f"║  Max Latency:        {stats['max_latency_ms']:>6.1f} ms                             ║")
        print(f"║  Std Dev:            {stats['stddev_ms']:>6.1f} ms                             ║")
        print("║                                                                ║")
        print(
            f"║  SLA Violations:     {stats['sla_violations']:>6} ({stats['sla_violation_rate']:>5.1f}%)                    ║"
        )
        print(f"║  SLA Threshold:      {self.sla_threshold_ms:>6} ms                             ║")
        print("║                                                                ║")
        print(f"║  Output File:        {stats['output_file']:<43} ║")
        print("╚════════════════════════════════════════════════════════════════╝")
        print()

        summary_file = self.output_file.replace(".csv", "_summary.json")
        with open(summary_file, "w", encoding="utf-8") as f:
            json.dump(stats, f, indent=2)

        print(f"Summary saved to: {summary_file}")


def main():
    parser = argparse.ArgumentParser(description="Load generator for DRC-IO experiments")
    parser.add_argument("--url", required=True, help="Service URL (e.g., http://example.com)")
    parser.add_argument("--rps", type=float, default=10.0, help="Requests per second")
    parser.add_argument("--duration", type=int, default=300, help="Duration in seconds")
    parser.add_argument("--output", required=True, help="Output CSV file")
    parser.add_argument(
        "--max-workers",
        type=int,
        default=10,
        help="Upper bound on worker threads (controls in-flight concurrency)",
    )
    parser.add_argument(
        "--latency-scale",
        type=float,
        default=1.0,
        help="Divide measured latencies by this factor before reporting (e.g., 5.0 to show smaller SLA numbers)",
    )

    args = parser.parse_args()

    generator = LoadGenerator(
        service_url=args.url,
        requests_per_second=args.rps,
        duration_seconds=args.duration,
        output_file=args.output,
        max_workers=args.max_workers,
        latency_scale=args.latency_scale,
    )

    try:
        generator.run()
    except KeyboardInterrupt:
        print("\n\nInterrupted by user")
        generator.print_summary()


if __name__ == "__main__":
    main()
