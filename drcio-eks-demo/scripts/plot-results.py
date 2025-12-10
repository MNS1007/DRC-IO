#!/usr/bin/env python3
"""
Generate publication-quality plots for DRC-IO experiments
"""

import argparse
import json
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
import seaborn as sns

plt.style.use("seaborn-v0_8-darkgrid")
sns.set_palette("husl")
plt.rcParams["figure.figsize"] = (12, 8)
plt.rcParams["font.size"] = 12
plt.rcParams["axes.labelsize"] = 14
plt.rcParams["axes.titlesize"] = 16
plt.rcParams["xtick.labelsize"] = 12
plt.rcParams["ytick.labelsize"] = 12
plt.rcParams["legend.fontsize"] = 12
plt.rcParams["figure.titlesize"] = 18


class ResultsPlotter:
    """Generate plots from experimental results"""

    def __init__(self, results_dir):
        self.results_dir = Path(results_dir)
        self.scenarios = {
            "scenario1-baseline.csv": {
                "name": "Baseline (HP Only)",
                "color": "#2ecc71",
                "label": "Scenario 1: Baseline",
            },
            "scenario2-no-drcio.csv": {
                "name": "No DRC-IO",
                "color": "#e74c3c",
                "label": "Scenario 2: No DRC-IO",
            },
            "scenario3-with-drcio.csv": {
                "name": "With DRC-IO",
                "color": "#3498db",
                "label": "Scenario 3: With DRC-IO",
            },
        }

    def load_data(self):
        """Load all scenario data"""
        data = {}
        for filename, info in self.scenarios.items():
            filepath = self.results_dir / filename
            if filepath.exists():
                df = pd.read_csv(filepath)
                data[filename] = {
                    "df": df,
                    "name": info["name"],
                    "color": info["color"],
                    "label": info["label"],
                }
                print(f"✓ Loaded {info['name']}: {len(df)} requests")
            else:
                print(f"✗ Not found: {filename}")
        return data

    def plot_cdf(self, data):
        """Plot CDF of latencies"""
        fig, ax = plt.subplots(figsize=(12, 8))
        for filename in self.scenarios.keys():
            if filename not in data:
                continue
            scenario = data[filename]
            latencies = np.sort(scenario["df"]["latency_ms"].values)
            if not len(latencies):
                continue
            cdf = np.arange(1, len(latencies) + 1) / len(latencies)
            ax.plot(
                latencies,
                cdf,
                label=scenario["label"],
                color=scenario["color"],
                linewidth=2.5,
                alpha=0.9,
            )
        ax.axvline(
            x=500,
            color="red",
            linestyle="--",
            linewidth=2,
            label="SLA Threshold (500ms)",
            alpha=0.7,
        )
        ax.set_xlabel("Latency (ms)", fontweight="bold")
        ax.set_ylabel("CDF", fontweight="bold")
        ax.set_title(
            "Latency Cumulative Distribution Function\nAcross Experimental Scenarios",
            fontweight="bold",
            pad=20,
        )
        ax.legend(loc="lower right", framealpha=0.95)
        ax.grid(True, alpha=0.3)
        ax.set_xlim(0, max(2000, ax.get_xlim()[1]))
        ax.set_ylim(0, 1.05)
        plt.tight_layout()
        output_file = self.results_dir / "plot_cdf.png"
        plt.savefig(output_file, dpi=300, bbox_inches="tight")
        print(f"✓ Saved: {output_file}")
        plt.close()

    def plot_latency_percentiles(self, data):
        """P95 latency bar chart"""
        fig, ax = plt.subplots(figsize=(10, 8))
        scenarios = []
        p95_values = []
        colors = []
        for filename in self.scenarios.keys():
            if filename not in data:
                continue
            scenario = data[filename]
            latencies = scenario["df"]["latency_ms"].values
            if not len(latencies):
                continue
            scenarios.append(scenario["name"])
            p95_values.append(np.percentile(latencies, 95))
            colors.append(scenario["color"])
        bars = ax.bar(
            scenarios, p95_values, color=colors, alpha=0.8, edgecolor="black", linewidth=1.5
        )
        ax.axhline(
            y=500,
            color="red",
            linestyle="--",
            linewidth=2,
            label="SLA (500ms)",
            alpha=0.7,
        )
        for bar, value in zip(bars, p95_values):
            height = bar.get_height()
            ax.text(
                bar.get_x() + bar.get_width() / 2.0,
                height,
                f"{value:.0f}ms",
                ha="center",
                va="bottom",
                fontsize=14,
                fontweight="bold",
            )
        ax.set_ylabel("P95 Latency (ms)", fontweight="bold")
        ax.set_title(
            "High-Priority GNN Service P95 Latency\nby Experimental Scenario",
            fontweight="bold",
            pad=20,
        )
        ax.legend(loc="upper left", framealpha=0.95)
        ax.grid(True, axis="y", alpha=0.3)
        plt.tight_layout()
        output_file = self.results_dir / "plot_p95_latency.png"
        plt.savefig(output_file, dpi=300, bbox_inches="tight")
        print(f"✓ Saved: {output_file}")
        plt.close()

    def plot_sla_violations(self, data):
        """Plot SLA violation rates"""
        fig, ax = plt.subplots(figsize=(10, 8))
        scenarios = []
        violation_rates = []
        colors = []
        for filename in self.scenarios.keys():
            if filename not in data:
                continue
            scenario = data[filename]
            df = scenario["df"]
            if df.empty:
                continue
            violation_rate = (df["sla_violation"].sum() / len(df)) * 100
            scenarios.append(scenario["name"])
            violation_rates.append(violation_rate)
            colors.append(scenario["color"])
        bars = ax.bar(
            scenarios,
            violation_rates,
            color=colors,
            alpha=0.8,
            edgecolor="black",
            linewidth=1.5,
        )
        for bar, value in zip(bars, violation_rates):
            height = bar.get_height()
            ax.text(
                bar.get_x() + bar.get_width() / 2.0,
                height,
                f"{value:.1f}%",
                ha="center",
                va="bottom",
                fontsize=14,
                fontweight="bold",
            )
        ax.set_ylabel("SLA Violation Rate (%)", fontweight="bold")
        ax.set_title(
            "SLA Violation Rate (>500ms)\nby Experimental Scenario",
            fontweight="bold",
            pad=20,
        )
        ax.grid(True, axis="y", alpha=0.3)
        ax.set_ylim(0, max(violation_rates + [0]) * 1.2 if violation_rates else 1)
        plt.tight_layout()
        output_file = self.results_dir / "plot_sla_violations.png"
        plt.savefig(output_file, dpi=300, bbox_inches="tight")
        print(f"✓ Saved: {output_file}")
        plt.close()

    def plot_latency_boxplot(self, data):
        """Latency distribution boxplot"""
        fig, ax = plt.subplots(figsize=(10, 8))
        plot_data = []
        labels = []
        colors_list = []
        for filename in self.scenarios.keys():
            if filename not in data:
                continue
            scenario = data[filename]
            latencies = scenario["df"]["latency_ms"].values
            if not len(latencies):
                continue
            plot_data.append(latencies)
            labels.append(scenario["name"])
            colors_list.append(scenario["color"])
        if not plot_data:
            print("⚠ No latency data for boxplot")
            return
        bp = ax.boxplot(
            plot_data,
            labels=labels,
            patch_artist=True,
            showmeans=True,
            meanline=True,
            widths=0.6,
        )
        for patch, color in zip(bp["boxes"], colors_list):
            patch.set_facecolor(color)
            patch.set_alpha(0.7)
        ax.axhline(
            y=500,
            color="red",
            linestyle="--",
            linewidth=2,
            label="SLA (500ms)",
            alpha=0.7,
        )
        ax.set_ylabel("Latency (ms)", fontweight="bold")
        ax.set_title(
            "Latency Distribution Comparison\n(Boxplot with Mean and Outliers)",
            fontweight="bold",
            pad=20,
        )
        ax.legend(loc="upper left", framealpha=0.95)
        ax.grid(True, axis="y", alpha=0.3)
        plt.tight_layout()
        output_file = self.results_dir / "plot_boxplot.png"
        plt.savefig(output_file, dpi=300, bbox_inches="tight")
        print(f"✓ Saved: {output_file}")
        plt.close()

    def plot_latency_over_time(self, data):
        """Latency timeseries for each scenario"""
        fig, axes = plt.subplots(3, 1, figsize=(14, 12), sharex=True)
        for idx, filename in enumerate(self.scenarios.keys()):
            if filename not in data:
                axes[idx].axis("off")
                continue
            scenario = data[filename]
            df = scenario["df"].copy()
            if df.empty:
                axes[idx].axis("off")
                continue
            df["timestamp"] = pd.to_datetime(df["timestamp"])
            df["seconds"] = (df["timestamp"] - df["timestamp"].min()).dt.total_seconds()
            axes[idx].scatter(
                df["seconds"],
                df["latency_ms"],
                alpha=0.3,
                s=10,
                color=scenario["color"],
            )
            window = min(50, max(5, len(df) // 20))
            if window > 1:
                df["rolling_mean"] = df["latency_ms"].rolling(window=window, center=True).mean()
                axes[idx].plot(
                    df["seconds"],
                    df["rolling_mean"],
                    color="black",
                    linewidth=2,
                    label=f"Rolling Mean ({window} req)",
                )
            axes[idx].axhline(
                y=500,
                color="red",
                linestyle="--",
                linewidth=2,
                alpha=0.7,
                label="SLA (500ms)",
            )
            axes[idx].set_ylabel("Latency (ms)", fontweight="bold")
            axes[idx].set_title(scenario["label"], fontweight="bold")
            axes[idx].legend(loc="upper right", framealpha=0.95)
            axes[idx].grid(True, alpha=0.3)
            axes[idx].set_ylim(0, max(2000, df["latency_ms"].max() * 1.1))
        axes[2].set_xlabel("Time (seconds)", fontweight="bold")
        fig.suptitle("Latency Over Time - All Scenarios", fontsize=18, fontweight="bold")
        plt.tight_layout()
        output_file = self.results_dir / "plot_latency_timeseries.png"
        plt.savefig(output_file, dpi=300, bbox_inches="tight")
        print(f"✓ Saved: {output_file}")
        plt.close()

    def plot_comparison_table(self, data):
        """Visual summary table"""
        stats = []
        for filename in self.scenarios.keys():
            if filename not in data:
                continue
            scenario = data[filename]
            df = scenario["df"]
            latencies = df["latency_ms"].values
            if not len(latencies):
                continue
            stats.append(
                {
                    "Scenario": scenario["name"],
                    "Mean (ms)": f"{np.mean(latencies):.1f}",
                    "P95 (ms)": f"{np.percentile(latencies, 95):.1f}",
                    "P99 (ms)": f"{np.percentile(latencies, 99):.1f}",
                    "SLA Viol. (%)": f"{(df['sla_violation'].sum() / len(df)) * 100:.1f}",
                    "Requests": f"{len(df)}",
                }
            )
        if not stats:
            print("⚠ No stats for summary table")
            return
        fig, ax = plt.subplots(figsize=(12, 4))
        ax.axis("tight")
        ax.axis("off")
        headers = list(stats[0].keys())
        table_data = [headers] + [list(row.values()) for row in stats]
        table = ax.table(
            cellText=table_data,
            cellLoc="center",
            loc="center",
            colWidths=[0.25, 0.15, 0.15, 0.15, 0.15, 0.15],
        )
        table.auto_set_font_size(False)
        table.set_fontsize(12)
        table.scale(1, 2)
        for i in range(len(headers)):
            table[(0, i)].set_facecolor("#3498db")
            table[(0, i)].set_text_props(weight="bold", color="white")
        colors = ["#2ecc71", "#e74c3c", "#3498db"]
        for i in range(1, len(table_data)):
            for j in range(len(headers)):
                if j == 0:
                    table[(i, j)].set_facecolor(colors[i - 1])
                    table[(i, j)].set_text_props(weight="bold", color="white")
                else:
                    table[(i, j)].set_facecolor("#ecf0f1")
        plt.title("Experimental Results Summary Table", fontsize=16, fontweight="bold", pad=20)
        plt.tight_layout()
        output_file = self.results_dir / "plot_summary_table.png"
        plt.savefig(output_file, dpi=300, bbox_inches="tight")
        print(f"✓ Saved: {output_file}")
        plt.close()

    def plot_drcio_weights(self, data):
        """Plot io.weight adjustments from Prometheus export"""
        metrics_file = self.results_dir / "scenario3-with-drcio-metrics.json"
        if not metrics_file.exists():
            print("⚠ No DRC-IO metrics found, skipping weight plot")
            return
        with open(metrics_file, "r", encoding="utf-8") as f:
            metrics = json.load(f)
        hp_entries = metrics.get("metrics", {}).get("drcio_hp_weight", [])
        lp_entries = metrics.get("metrics", {}).get("drcio_lp_weight", [])
        hp_times, hp_values = [], []
        for entry in hp_entries:
            for ts, value in entry.get("values", []):
                hp_times.append(float(ts))
                hp_values.append(float(value))
        lp_times, lp_values = [], []
        for entry in lp_entries:
            for ts, value in entry.get("values", []):
                lp_times.append(float(ts))
                lp_values.append(float(value))
        if not hp_times or not lp_times:
            print("⚠ DRC-IO weight data missing, skipping weight plot")
            return
        min_ts = min(min(hp_times), min(lp_times))
        hp_seconds = [ts - min_ts for ts in hp_times]
        lp_seconds = [ts - min_ts for ts in lp_times]
        fig, ax = plt.subplots(figsize=(12, 6))
        ax.plot(hp_seconds, hp_values, label="HP io.weight", color="#3498db", linewidth=2.5, marker="o", markersize=4)
        ax.plot(lp_seconds, lp_values, label="LP io.weight", color="#e74c3c", linewidth=2.5, marker="s", markersize=4)
        ax.set_xlabel("Time (seconds)", fontweight="bold")
        ax.set_ylabel("I/O Weight", fontweight="bold")
        ax.set_title("DRC-IO Dynamic Weight Adjustments\n(Scenario 3: With DRC-IO)", fontweight="bold", pad=20)
        ax.legend(loc="best", framealpha=0.95)
        ax.grid(True, alpha=0.3)
        ax.set_ylim(0, 1000)
        plt.tight_layout()
        output_file = self.results_dir / "plot_drcio_weights.png"
        plt.savefig(output_file, dpi=300, bbox_inches="tight")
        print(f"✓ Saved: {output_file}")
        plt.close()

    def generate_all_plots(self):
        """Generate every plot for the experiment results"""
        print("╔════════════════════════════════════════════════════════╗")
        print("║          Generating Experimental Plots                ║")
        print("╚════════════════════════════════════════════════════════╝")
        print()
        print("Loading data...")
        data = self.load_data()
        print()
        if not data:
            print("No data to plot.")
            return
        print("Generating plots...\n")
        self.plot_cdf(data)
        self.plot_latency_percentiles(data)
        self.plot_sla_violations(data)
        self.plot_latency_boxplot(data)
        self.plot_latency_over_time(data)
        self.plot_comparison_table(data)
        self.plot_drcio_weights(data)
        print()
        print("╔════════════════════════════════════════════════════════╗")
        print("║              ✅ All Plots Generated!                  ║")
        print("╚════════════════════════════════════════════════════════╝")
        print()
        print(f"Plots saved to: {self.results_dir}")
        print()
        print("Generated plots:")
        print("  • plot_cdf.png")
        print("  • plot_p95_latency.png")
        print("  • plot_sla_violations.png")
        print("  • plot_boxplot.png")
        print("  • plot_latency_timeseries.png")
        print("  • plot_summary_table.png")
        print("  • plot_drcio_weights.png")
        print()


def main():
    parser = argparse.ArgumentParser(description="Generate plots from experimental results")
    parser.add_argument("--input", required=True, help="Results directory")
    args = parser.parse_args()
    plotter = ResultsPlotter(args.input)
    plotter.generate_all_plots()


if __name__ == "__main__":
    main()
