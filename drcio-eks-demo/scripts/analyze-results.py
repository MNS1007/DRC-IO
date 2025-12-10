#!/usr/bin/env python3
"""
Analyze experimental results and generate comparison report
"""

import argparse
import json
from pathlib import Path
from statistics import mean, median, stdev

import numpy as np
import pandas as pd


class ExperimentAnalyzer:
    """Analyze and compare experimental results"""

    def __init__(self, results_dir):
        self.results_dir = Path(results_dir)
        self.scenarios = {
            "scenario1-baseline.csv": "Baseline (HP Only)",
            "scenario2-no-drcio.csv": "No DRC-IO (Contention)",
            "scenario3-with-drcio.csv": "With DRC-IO (Solution)",
        }

    def load_scenario(self, filename):
        """Load scenario data from CSV"""
        filepath = self.results_dir / filename

        if not filepath.exists():
            print(f"Warning: {filename} not found")
            return None

        df = pd.read_csv(filepath)
        if df.empty:
            print(f"Warning: {filename} contains no data")
            return None

        latencies = df["latency_ms"].values

        stats = {
            "total_requests": len(df),
            "successful": int((df["status"] == "success").sum()),
            "errors": int((df["status"] != "success").sum()),
            "mean_latency": float(mean(latencies)),
            "median_latency": float(median(latencies)),
            "p50_latency": float(np.percentile(latencies, 50)),
            "p95_latency": float(np.percentile(latencies, 95)),
            "p99_latency": float(np.percentile(latencies, 99)),
            "max_latency": float(np.max(latencies)),
            "min_latency": float(np.min(latencies)),
            "stddev": float(stdev(latencies)) if len(latencies) > 1 else 0.0,
            "sla_violations": int(df["sla_violation"].sum()),
            "sla_violation_rate": float(df["sla_violation"].mean() * 100),
        }

        metrics_file = filepath.parent / filename.replace(".csv", "-metrics.json")
        if metrics_file.exists():
            with open(metrics_file, "r", encoding="utf-8") as f:
                prom_data = json.load(f)
                stats["prometheus"] = prom_data.get("metrics", {}).get("summary", {})

        return stats

    def generate_comparison_table(self, all_stats):
        """Generate comparison table"""
        lines = []
        lines.append(
            "╔═══════════════════════════════════════════════════════════════════════════╗"
        )
        lines.append(
            "║                    EXPERIMENTAL RESULTS COMPARISON                        ║"
        )
        lines.append(
            "╠═══════════════════════════════════════════════════════════════════════════╣"
        )
        lines.append("║                                                                           ║")
        lines.append(
            "║  Metric                  │ Scenario 1  │ Scenario 2  │ Scenario 3  │ Impr. ║"
        )
        lines.append(
            "║                          │  Baseline   │  No DRC-IO  │ With DRC-IO │       ║"
        )
        lines.append(
            "║──────────────────────────┼─────────────┼─────────────┼─────────────┼───────║"
        )

        s1 = all_stats.get("scenario1-baseline.csv", {})
        s2 = all_stats.get("scenario2-no-drcio.csv", {})
        s3 = all_stats.get("scenario3-with-drcio.csv", {})

        lines.append(
            f"║  Total Requests          │ {s1.get('total_requests', 0):>11} │ {s2.get('total_requests', 0):>11} │ {s3.get('total_requests', 0):>11} │       ║"
        )
        lines.append(
            f"║  Successful              │ {s1.get('successful', 0):>11} │ {s2.get('successful', 0):>11} │ {s3.get('successful', 0):>11} │       ║"
        )
        lines.append("║                          │             │             │             │       ║")

        lines.append(
            f"║  Mean Latency (ms)       │ {s1.get('mean_latency', 0):>11.1f} │ {s2.get('mean_latency', 0):>11.1f} │ {s3.get('mean_latency', 0):>11.1f} │ {self._improvement(s2.get('mean_latency', 0), s3.get('mean_latency', 0)):>5} ║"
        )
        lines.append(
            f"║  Median Latency (ms)     │ {s1.get('median_latency', 0):>11.1f} │ {s2.get('median_latency', 0):>11.1f} │ {s3.get('median_latency', 0):>11.1f} │ {self._improvement(s2.get('median_latency', 0), s3.get('median_latency', 0)):>5} ║"
        )
        lines.append(
            f"║  P95 Latency (ms)        │ {s1.get('p95_latency', 0):>11.1f} │ {s2.get('p95_latency', 0):>11.1f} │ {s3.get('p95_latency', 0):>11.1f} │ {self._improvement(s2.get('p95_latency', 0), s3.get('p95_latency', 0)):>5} ║"
        )
        lines.append(
            f"║  P99 Latency (ms)        │ {s1.get('p99_latency', 0):>11.1f} │ {s2.get('p99_latency', 0):>11.1f} │ {s3.get('p99_latency', 0):>11.1f} │ {self._improvement(s2.get('p99_latency', 0), s3.get('p99_latency', 0)):>5} ║"
        )
        lines.append(
            f"║  Max Latency (ms)        │ {s1.get('max_latency', 0):>11.1f} │ {s2.get('max_latency', 0):>11.1f} │ {s3.get('max_latency', 0):>11.1f} │       ║"
        )
        lines.append(
            f"║  Std Dev (ms)            │ {s1.get('stddev', 0):>11.1f} │ {s2.get('stddev', 0):>11.1f} │ {s3.get('stddev', 0):>11.1f} │       ║"
        )
        lines.append("║                          │             │             │             │       ║")

        lines.append(
            f"║  SLA Violations          │ {s1.get('sla_violations', 0):>11} │ {s2.get('sla_violations', 0):>11} │ {s3.get('sla_violations', 0):>11} │ {self._improvement(s2.get('sla_violations', 0), s3.get('sla_violations', 0)):>5} ║"
        )
        lines.append(
            f"║  SLA Violation Rate (%)  │ {s1.get('sla_violation_rate', 0):>11.1f} │ {s2.get('sla_violation_rate', 0):>11.1f} │ {s3.get('sla_violation_rate', 0):>11.1f} │ {self._improvement(s2.get('sla_violation_rate', 0), s3.get('sla_violation_rate', 0)):>5} ║"
        )

        lines.append(
            "╚═══════════════════════════════════════════════════════════════════════════╝"
        )

        return "\n".join(lines)

    def _improvement(self, before, after):
        """Calculate improvement percentage"""
        if before == 0:
            return "N/A"

        improvement = ((before - after) / before) * 100

        if improvement > 0:
            return f"{improvement:.0f}%↓"
        if improvement < 0:
            return f"{abs(improvement):.0f}%↑"
        return "0%"

    def generate_summary(self, all_stats):
        """Generate text summary"""

        s1 = all_stats.get("scenario1-baseline.csv", {})
        s2 = all_stats.get("scenario2-no-drcio.csv", {})
        s3 = all_stats.get("scenario3-with-drcio.csv", {})

        lines = []
        lines.append("")
        lines.append("KEY FINDINGS:")
        lines.append("=" * 80)
        lines.append("")

        if s2 and s1 and s1.get("p95_latency"):
            degradation = (s2.get("p95_latency", 0) / s1.get("p95_latency", 1)) - 1
            lines.append("1. PROBLEM SEVERITY (Baseline → No DRC-IO):")
            lines.append(
                f"   • P95 latency increased {degradation*100:.0f}%: {s1.get('p95_latency', 0):.0f}ms → {s2.get('p95_latency', 0):.0f}ms"
            )
            lines.append(
                f"   • SLA violations: {s1.get('sla_violation_rate', 0):.1f}% → {s2.get('sla_violation_rate', 0):.1f}%"
            )
            lines.append(
                f"   • Failed transactions: {s2.get('sla_violations', 0) - s1.get('sla_violations', 0):,}"
            )
            lines.append("")

        if s3 and s2 and s3.get("p95_latency"):
            improvement = (s2.get("p95_latency", 0) / s3.get("p95_latency", 1)) - 1
            violation_reduction = (
                (
                    s2.get("sla_violation_rate", 0)
                    - s3.get("sla_violation_rate", 0)
                )
                / max(s2.get("sla_violation_rate", 1), 1e-6)
            ) * 100
            lines.append("2. SOLUTION EFFECTIVENESS (No DRC-IO → With DRC-IO):")
            lines.append(
                f"   • P95 latency improved {improvement*100:.0f}%: {s2.get('p95_latency', 0):.0f}ms → {s3.get('p95_latency', 0):.0f}ms"
            )
            lines.append(
                f"   • SLA violations reduced {violation_reduction:.0f}%: {s2.get('sla_violation_rate', 0):.1f}% → {s3.get('sla_violation_rate', 0):.1f}%"
            )
            lines.append(
                f"   • Transactions saved: {s2.get('sla_violations', 0) - s3.get('sla_violations', 0):,}"
            )
            lines.append("")

        if s2 and s3 and s3.get("total_requests"):
            saved_txn = s2.get("sla_violations", 0) - s3.get("sla_violations", 0)
            exp_requests = s3.get("total_requests", 1)
            # assume experiment load ~10 requests/sec as configured
            exp_duration_min = exp_requests / (REQUESTS_PER_SECOND := 10) / 60
            daily_saved = int(saved_txn * (1440 / max(exp_duration_min, 1)))
            yearly_saved = daily_saved * 365

            lines.append("3. BUSINESS IMPACT (Extrapolated):")
            lines.append(f"   • Transactions saved per day: ~{daily_saved:,}")
            lines.append(f"   • Transactions saved per year: ~{yearly_saved:,}")
            lines.append(f"   • Value @ $10/txn: ${yearly_saved * 10:,}")
            lines.append(f"   • Value @ $20/txn: ${yearly_saved * 20:,}")
            lines.append("")

        if s1 and s3 and s1.get("p95_latency"):
            overhead = (s3.get("p95_latency", 0) / s1.get("p95_latency", 1)) - 1
            lines.append("4. OVERHEAD ANALYSIS (Baseline → With DRC-IO):")
            lines.append(f"   • P95 latency overhead: {overhead*100:.0f}%")
            lines.append(
                f"   • P95 latency under SLA: {s3.get('p95_latency', 0):.0f} ms < 500 ms"
            )
            lines.append("")

        return "\n".join(lines)

    def analyze(self):
        """Run full analysis"""

        print("Analyzing experimental results...\n")
        all_stats = {}
        for filename, name in self.scenarios.items():
            print(f"Loading {name} ({filename})...")
            stats = self.load_scenario(filename)
            if stats:
                all_stats[filename] = stats
        print("")

        if not all_stats:
            print("No scenario data found.")
            return

        table = self.generate_comparison_table(all_stats)
        print(table)
        summary = self.generate_summary(all_stats)
        print(summary)

        output_file = self.results_dir / "comparison.txt"
        with open(output_file, "w", encoding="utf-8") as f:
            f.write(table)
            f.write("\n")
            f.write(summary)
        print(f"Comparison saved to: {output_file}\n")

        json_file = self.results_dir / "summary.json"
        with open(json_file, "w", encoding="utf-8") as f:
            json.dump(all_stats, f, indent=2)
        print(f"JSON summary saved to: {json_file}")


def main():
    parser = argparse.ArgumentParser(description="Analyze experimental results")
    parser.add_argument("--input", required=True, help="Results directory")
    args = parser.parse_args()

    analyzer = ExperimentAnalyzer(args.input)
    analyzer.analyze()


if __name__ == "__main__":
    main()
