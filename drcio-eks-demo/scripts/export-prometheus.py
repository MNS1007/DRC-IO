#!/usr/bin/env python3
"""
Export Prometheus metrics for DRC-IO experiments
"""

import argparse
import requests
import json
import time
from datetime import datetime


class PrometheusExporter:
    """Export metrics from Prometheus"""

    def __init__(self, prometheus_url: str = "http://localhost:9090"):
        self.url = prometheus_url.rstrip("/")

    def query_range(self, query, start_time, end_time, step="5s"):
        """Query Prometheus range data"""
        try:
            response = requests.get(
                f"{self.url}/api/v1/query_range",
                params={
                    "query": query,
                    "start": start_time,
                    "end": end_time,
                    "step": step,
                },
                timeout=30,
            )

            if response.status_code != 200:
                print(f"Warning: Query failed: {query}")
                return None

            data = response.json()

            if data.get("status") != "success":
                print(f"Warning: Query unsuccessful: {query}")
                return None

            return data.get("data", {}).get("result", [])

        except Exception as e:
            print(f"Error querying Prometheus: {e}")
            return None

    def query_instant(self, query):
        """Query Prometheus instant data"""
        try:
            response = requests.get(
                f"{self.url}/api/v1/query",
                params={"query": query},
                timeout=10,
            )
            if response.status_code != 200:
                return None
            data = response.json()
            result = data.get("data", {}).get("result")
            if data.get("status") != "success" or not result:
                return None
            return float(result[0]["value"][1])
        except Exception:
            return None

    def export_experiment_metrics(self, duration_seconds, output_file):
        """Export all relevant metrics for an experiment"""

        end_time = time.time()
        start_time = end_time - duration_seconds

        print(f"Exporting metrics from last {duration_seconds}s...")
        print(
            f"Time range: {datetime.fromtimestamp(start_time)} to {datetime.fromtimestamp(end_time)}"
        )
        print()

        metrics = {}

        print("Querying HP service latency...")
        metrics["hp_p50_latency"] = self.query_range(
            """
histogram_quantile(0.50,
    sum(rate(http_request_duration_seconds_bucket{
        namespace="fraud-detection",
        group_id="hp"
    }[1m])) by (le)
)
""",
            start_time,
            end_time,
        )
        metrics["hp_p95_latency"] = self.query_range(
            """
histogram_quantile(0.95,
    sum(rate(http_request_duration_seconds_bucket{
        namespace="fraud-detection",
        group_id="hp"
    }[1m])) by (le)
)
""",
            start_time,
            end_time,
        )
        metrics["hp_p99_latency"] = self.query_range(
            """
histogram_quantile(0.99,
    sum(rate(http_request_duration_seconds_bucket{
        namespace="fraud-detection",
        group_id="hp"
    }[1m])) by (le)
)
""",
            start_time,
            end_time,
        )

        print("Querying request rate...")
        metrics["request_rate"] = self.query_range(
            """
sum(rate(http_requests_total{
    namespace="fraud-detection"
}[1m]))
""",
            start_time,
            end_time,
        )

        print("Querying SLA violations...")
        metrics["sla_violation_rate"] = self.query_range(
            """
sum(rate(sla_violations_total{
    namespace="fraud-detection"
}[1m])) /
sum(rate(http_requests_total{
    namespace="fraud-detection"
}[1m])) * 100
""",
            start_time,
            end_time,
        )

        print("Querying DRC-IO metrics...")
        metrics["drcio_hp_weight"] = self.query_range(
            'drcio_hp_weight{namespace="fraud-detection"}', start_time, end_time
        )
        metrics["drcio_lp_weight"] = self.query_range(
            'drcio_lp_weight{namespace="fraud-detection"}', start_time, end_time
        )
        metrics["drcio_adjustments"] = self.query_range(
            'drcio_adjustments_total{namespace="fraud-detection"}', start_time, end_time
        )

        print("Querying resource metrics...")
        metrics["cpu_usage"] = self.query_range(
            """
sum(rate(container_cpu_usage_seconds_total{
    namespace="fraud-detection"
}[1m])) by (pod)
""",
            start_time,
            end_time,
        )
        metrics["memory_usage"] = self.query_range(
            """
sum(container_memory_working_set_bytes{
    namespace="fraud-detection"
}) by (pod)
""",
            start_time,
            end_time,
        )

        print("Calculating summary statistics...")
        summary = {}
        p95_avg = self.query_instant(
            f"""
avg_over_time(
    (histogram_quantile(0.95,
        sum(rate(http_request_duration_seconds_bucket{{
            namespace="fraud-detection"
        }}[1m])) by (le)
    ))[{duration_seconds}s:])
"""
        )
        if p95_avg is not None:
            summary["avg_p95_latency_ms"] = p95_avg * 1000

        total_requests = self.query_instant(
            f"""
sum(increase(http_requests_total{{
    namespace="fraud-detection"
}}[{duration_seconds}s]))
"""
        )
        if total_requests is not None:
            summary["total_requests"] = int(total_requests)

        total_violations = self.query_instant(
            f"""
sum(increase(sla_violations_total{{
    namespace="fraud-detection"
}}[{duration_seconds}s]))
"""
        )
        if total_violations is not None:
            summary["total_sla_violations"] = int(total_violations)
            if total_requests:
                summary["sla_violation_rate"] = (
                    total_violations / total_requests * 100
                )

        total_adjustments = self.query_instant(
            f"""
sum(increase(drcio_adjustments_total{{
    namespace="fraud-detection"
}}[{duration_seconds}s]))
"""
        )
        if total_adjustments is not None:
            summary["total_drcio_adjustments"] = int(total_adjustments)

        metrics["summary"] = summary

        print(f"Saving metrics to {output_file}...")
        output = {
            "timestamp": datetime.utcnow().isoformat(),
            "duration_seconds": duration_seconds,
            "start_time": datetime.fromtimestamp(start_time).isoformat(),
            "end_time": datetime.fromtimestamp(end_time).isoformat(),
            "metrics": metrics,
        }

        with open(output_file, "w", encoding="utf-8") as f:
            json.dump(output, f, indent=2)

        print("✓ Metrics exported\n")

        if summary:
            print("Summary Statistics:")
            print(f"  Total Requests: {summary.get('total_requests', 'N/A')}")
            avg_p95 = summary.get("avg_p95_latency_ms")
            print(
                f"  Avg P95 Latency: {avg_p95:.1f} ms"
                if avg_p95 is not None
                else "  Avg P95 Latency: N/A"
            )
            print(
                f"  SLA Violations: {summary.get('total_sla_violations', 'N/A')} "
                f"({summary.get('sla_violation_rate', 0):.1f}%)"
            )
            print(
                f"  DRC-IO Adjustments: {summary.get('total_drcio_adjustments', 'N/A')}"
            )
            print()


def main():
    parser = argparse.ArgumentParser(description="Export Prometheus metrics")
    parser.add_argument(
        "--prometheus-url",
        default="http://localhost:9090",
        help="Prometheus URL",
    )
    parser.add_argument(
        "--duration", type=int, required=True, help="Duration in seconds to export"
    )
    parser.add_argument(
        "--output",
        required=True,
        help="Output JSON file",
    )

    args = parser.parse_args()

    exporter = PrometheusExporter(args.prometheus_url)
    exporter.export_experiment_metrics(args.duration, args.output)


if __name__ == "__main__":
    main()
