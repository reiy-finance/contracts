#!/usr/bin/env python3
import argparse
import json
import math
from collections import defaultdict
from pathlib import Path

import matplotlib.pyplot as plt
from matplotlib.backends.backend_pdf import PdfPages
from matplotlib.ticker import FuncFormatter, MaxNLocator


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("run_json")
    parser.add_argument("--out-dir", default=None)
    args = parser.parse_args()

    run_path = Path(args.run_json)
    run = json.loads(run_path.read_text())
    out_dir = Path(args.out_dir) if args.out_dir else run_path.parent / "figures"
    out_dir.mkdir(parents=True, exist_ok=True)

    records = run.get("records", [])
    by_op = defaultdict(list)
    for record in records:
        by_op[record.get("op", "unknown")].append(record)

    write_latency_pdf(out_dir / "latency.pdf", run, records)
    write_gas_pdf(out_dir / "gas.pdf", run, records)
    write_summary_pdf(out_dir / "summary.pdf", run, by_op)
    settlement_records = [record for record in records if record.get("op") == "settle_solution"]
    if settlement_records:
        write_settlement_batches_pdf(out_dir / "settlement_batches.pdf", run, settlement_records)
    print(f"figures: {out_dir}")


def write_latency_pdf(path, run, records):
    with PdfPages(path) as pdf:
        write_overview_page(pdf, run, records, "latencyMs", "latency", "latency (ms)", format_ms)
        for op, rows in grouped_records(records):
            if values_for(rows, "latencyMs"):
                write_detail_page(pdf, run, op, rows, "latencyMs", "latency (ms)", format_ms)


def write_gas_pdf(path, run, records):
    with PdfPages(path) as pdf:
        write_overview_page(pdf, run, records, "gasMist", "gas", "gas (MIST)", format_compact)
        for op, rows in grouped_records(records):
            if values_for(rows, "gasMist"):
                write_detail_page(pdf, run, op, rows, "gasMist", "gas (MIST)", format_compact)


def write_overview_page(pdf, run, records, field, label, ylabel, formatter):
    fig, ax = plt.subplots(figsize=(12.5, 6.2))
    for op, xs, ys in grouped_series(records, field):
        ax.plot(xs, ys, marker="o", linewidth=1.2, markersize=2.8, label=op)
    ax.set_title(f"{run['runId']} {label} overview")
    ax.set_xlabel("global transaction index")
    ax.set_ylabel(ylabel)
    style_axis(ax, formatter)
    ax.legend(loc="best", fontsize=8)
    fig.tight_layout()
    pdf.savefig(fig)
    plt.close(fig)


def write_detail_page(pdf, run, op, rows, field, ylabel, formatter):
    values = values_for(rows, field)
    xs = list(range(1, len(values) + 1))
    fig, ax = plt.subplots(figsize=(12.5, 6.4))
    ax.plot(xs, values, marker="o", linewidth=1.4, markersize=3.2, color="#2563eb")
    ax.set_title(f"{run['runId']} {op} {field}")
    ax.set_xlabel(f"{op} local index")
    ax.set_ylabel(ylabel)
    style_axis(ax, formatter)
    fit_y_axis(ax, values)
    annotate_points(ax, xs, values, formatter)
    add_stats_box(ax, values, formatter)
    fig.tight_layout(rect=(0, 0, 0.82, 1))
    pdf.savefig(fig)
    plt.close(fig)


def write_summary_pdf(path, run, by_op):
    labels = list(by_op.keys())
    if not labels:
        labels = ["empty"]
        by_op["empty"] = []

    latency_avg = [avg([num(r.get("latencyMs")) for r in by_op[label]]) for label in labels]
    latency_p90 = [percentile([num(r.get("latencyMs")) for r in by_op[label]], 0.9) for label in labels]
    gas_avg = [avg([record_value(r, "gasMist") for r in by_op[label]]) for label in labels]
    success = [sum(1 for r in by_op[label] if r.get("status") == "success") for label in labels]
    failed = [sum(1 for r in by_op[label] if r.get("status") != "success") for label in labels]

    with PdfPages(path) as pdf:
        fig, axes = plt.subplots(2, 2, figsize=(11, 8))
        x = range(len(labels))

        axes[0][0].bar(x, latency_avg, color="#2563eb")
        axes[0][0].set_title("avg latency")
        axes[0][0].set_ylabel("ms")

        axes[0][1].bar(x, latency_p90, color="#7c3aed")
        axes[0][1].set_title("p90 latency")
        axes[0][1].set_ylabel("ms")

        axes[1][0].bar(x, gas_avg, color="#059669")
        axes[1][0].set_title("avg gas")
        axes[1][0].set_ylabel("MIST")

        axes[1][1].bar(x, success, color="#16a34a", label="success")
        axes[1][1].bar(x, failed, bottom=success, color="#dc2626", label="failed")
        axes[1][1].set_title("tx count")
        axes[1][1].legend(fontsize=8)

        for ax in axes.flatten():
            ax.set_xticks(list(x))
            ax.set_xticklabels(labels, rotation=30, ha="right")
            ax.yaxis.set_major_formatter(FuncFormatter(lambda value, _: format_compact(value)))
            ax.yaxis.set_major_locator(MaxNLocator(nbins=7))
            ax.grid(True, axis="y", alpha=0.25)

        fig.suptitle(run["runId"])
        fig.tight_layout()
        pdf.savefig(fig)
        plt.close(fig)

        write_summary_table_page(pdf, run, by_op)


def write_settlement_batches_pdf(path, run, records):
    xs = list(range(1, len(records) + 1))
    batch_sizes = [num(record.get("intentCount")) or 0 for record in records]
    latencies = [num(record.get("latencyMs")) or 0 for record in records]
    gas = [record_value(record, "gasMist") or 0 for record in records]
    gas_per_intent = [g / b if b else 0 for g, b in zip(gas, batch_sizes)]
    protocol_fee = [num(record.get("estimatedProtocolFeeMist")) or 0 for record in records]
    solver_fee = [num(record.get("estimatedSolverFeeMist")) or 0 for record in records]
    protocol_fee_per_intent = [g / b if b else 0 for g, b in zip(protocol_fee, batch_sizes)]
    solver_fee_per_intent = [g / b if b else 0 for g, b in zip(solver_fee, batch_sizes)]

    with PdfPages(path) as pdf:
        fig, axes = plt.subplots(3, 2, figsize=(11.5, 10.2))

        axes[0][0].bar(xs, batch_sizes, color="#475569")
        axes[0][0].set_title("intents per settlement tx")
        axes[0][0].set_ylabel("intents")

        axes[0][1].plot(xs, latencies, marker="o", linewidth=1.2, markersize=3, color="#2563eb")
        axes[0][1].set_title("settlement latency")
        axes[0][1].set_ylabel("ms")

        axes[1][0].plot(xs, gas, marker="o", linewidth=1.2, markersize=3, color="#059669")
        axes[1][0].set_title("settlement gas")
        axes[1][0].set_ylabel("MIST")

        axes[1][1].plot(xs, gas_per_intent, marker="o", linewidth=1.2, markersize=3, color="#d97706")
        axes[1][1].set_title("settlement gas per intent")
        axes[1][1].set_ylabel("MIST / intent")

        axes[2][0].plot(xs, protocol_fee_per_intent, marker="o", linewidth=1.2, markersize=3, color="#0f766e")
        axes[2][0].set_title("protocol fee per intent")
        axes[2][0].set_ylabel("MIST / intent")

        axes[2][1].plot(xs, solver_fee_per_intent, marker="o", linewidth=1.2, markersize=3, color="#7c3aed")
        axes[2][1].set_title("solver fee share per intent")
        axes[2][1].set_ylabel("MIST / intent")

        for ax in axes.flatten():
            ax.set_xlabel("settlement batch index")
            ax.xaxis.set_major_locator(MaxNLocator(integer=True, nbins=10))
            ax.yaxis.set_major_locator(MaxNLocator(nbins=9))
            ax.grid(True, alpha=0.25)

        axes[0][0].yaxis.set_major_formatter(FuncFormatter(lambda value, _: format_compact(value)))
        axes[0][1].yaxis.set_major_formatter(FuncFormatter(lambda value, _: format_ms(value)))
        axes[1][0].yaxis.set_major_formatter(FuncFormatter(lambda value, _: format_compact(value)))
        axes[1][1].yaxis.set_major_formatter(FuncFormatter(lambda value, _: format_compact(value)))
        axes[2][0].yaxis.set_major_formatter(FuncFormatter(lambda value, _: format_compact(value)))
        axes[2][1].yaxis.set_major_formatter(FuncFormatter(lambda value, _: format_compact(value)))

        for ax, ys, fmt in [
            (axes[0][0], batch_sizes, format_compact),
            (axes[0][1], latencies, format_ms),
            (axes[1][0], gas, format_compact),
            (axes[1][1], gas_per_intent, format_compact),
            (axes[2][0], protocol_fee_per_intent, format_compact),
            (axes[2][1], solver_fee_per_intent, format_compact),
        ]:
            fit_y_axis(ax, ys)
            annotate_points(ax, xs, ys, fmt, dense_limit=12)

        fig.suptitle(f"{run['runId']} settlement batches")
        fig.tight_layout()
        pdf.savefig(fig)
        plt.close(fig)

        write_settlement_table_page(
            pdf,
            run,
            records,
            batch_sizes,
            latencies,
            gas,
            gas_per_intent,
            protocol_fee_per_intent,
            solver_fee_per_intent,
        )


def grouped_series(records, field):
    pos = 1
    grouped = defaultdict(lambda: ([], []))
    for record in records:
        value = record_value(record, field)
        if value is None:
            pos += 1
            continue
        xs, ys = grouped[record.get("op", "unknown")]
        xs.append(pos)
        ys.append(value)
        pos += 1
    return [(op, xs, ys) for op, (xs, ys) in grouped.items()]


def grouped_records(records):
    grouped = defaultdict(list)
    for record in records:
        grouped[record.get("op", "unknown")].append(record)
    return list(grouped.items())


def values_for(records, field):
    return [value for value in [record_value(record, field) for record in records] if value is not None]


def style_axis(ax, formatter):
    ax.yaxis.set_major_formatter(FuncFormatter(lambda value, _: formatter(value)))
    ax.yaxis.set_major_locator(MaxNLocator(nbins=8))
    ax.xaxis.set_major_locator(MaxNLocator(integer=True, nbins=14))
    ax.grid(True, which="major", alpha=0.28)
    ax.grid(True, which="minor", alpha=0.12)
    ax.minorticks_on()


def fit_y_axis(ax, values):
    values = [v for v in values if v is not None]
    if not values:
        return
    low = min(values)
    high = max(values)
    if low == high:
        pad = max(abs(low) * 0.1, 1)
    else:
        pad = (high - low) * 0.12
    floor = 0 if low >= 0 else low - pad
    ax.set_ylim(floor, high + pad)


def annotate_points(ax, xs, ys, formatter, dense_limit=20):
    if not ys:
        return
    if len(ys) <= dense_limit:
        for x, y in zip(xs, ys):
            ax.annotate(
                formatter(y),
                (x, y),
                textcoords="offset points",
                xytext=(0, 7),
                ha="center",
                fontsize=7,
            )
        return

    extremes = {ys.index(min(ys)), ys.index(max(ys))}
    for idx in sorted(extremes):
        ax.annotate(
            formatter(ys[idx]),
            (xs[idx], ys[idx]),
            textcoords="offset points",
            xytext=(0, 8),
            ha="center",
            fontsize=8,
            fontweight="bold",
        )


def add_stats_box(ax, values, formatter):
    values = sorted(v for v in values if v is not None)
    if not values:
        return
    rows = [
        ("count", str(len(values))),
        ("min", formatter(values[0])),
        ("avg", formatter(avg(values))),
        ("p50", formatter(percentile(values, 0.5))),
        ("p90", formatter(percentile(values, 0.9))),
        ("p99", formatter(percentile(values, 0.99))),
        ("max", formatter(values[-1])),
    ]
    text = "\n".join(f"{name}: {value}" for name, value in rows)
    ax.text(
        1.02,
        0.98,
        text,
        transform=ax.transAxes,
        va="top",
        ha="left",
        fontsize=9,
        bbox={"boxstyle": "round,pad=0.35", "facecolor": "white", "edgecolor": "#cbd5e1", "alpha": 0.95},
    )


def write_summary_table_page(pdf, run, by_op):
    labels = list(by_op.keys())
    rows = []
    for label in labels:
        records = by_op[label]
        latencies = values_for(records, "latencyMs")
        gas = values_for(records, "gasMist")
        rows.append([
            label,
            str(len(records)),
            str(sum(1 for r in records if r.get("status") == "success")),
            str(sum(1 for r in records if r.get("status") != "success")),
            format_ms(avg(latencies)),
            format_ms(percentile(latencies, 0.9)),
            format_compact(avg(gas)),
            format_compact(percentile(gas, 0.9)),
        ])

    fig, ax = plt.subplots(figsize=(12.5, 7.2))
    ax.axis("off")
    ax.set_title(f"{run['runId']} operation summary table", pad=18)
    table = ax.table(
        cellText=rows,
        colLabels=["op", "tx", "ok", "fail", "lat avg", "lat p90", "gas avg", "gas p90"],
        cellLoc="right",
        colLoc="right",
        loc="center",
    )
    table.auto_set_font_size(False)
    table.set_fontsize(8)
    table.scale(1, 1.35)
    pdf.savefig(fig)
    plt.close(fig)


def write_settlement_table_page(
    pdf,
    run,
    records,
    batch_sizes,
    latencies,
    gas,
    gas_per_intent,
    protocol_fee_per_intent,
    solver_fee_per_intent,
):
    rows = []
    for idx, record in enumerate(records):
        rows.append([
            str(idx + 1),
            str(int(batch_sizes[idx])),
            format_ms(latencies[idx]),
            format_compact(gas[idx]),
            format_compact(gas_per_intent[idx]),
            format_compact(protocol_fee_per_intent[idx]),
            format_compact(solver_fee_per_intent[idx]),
            str(record.get("solutionId", "")),
            str(record.get("status", "")),
        ])

    fig, ax = plt.subplots(figsize=(12.5, 7.2))
    ax.axis("off")
    ax.set_title(f"{run['runId']} settlement batch detail table", pad=18)
    table = ax.table(
        cellText=rows,
        colLabels=["batch", "intents", "latency", "gas", "gas / intent", "protocol fee / intent", "solver fee / intent", "solution", "status"],
        cellLoc="right",
        colLoc="right",
        loc="center",
    )
    table.auto_set_font_size(False)
    table.set_fontsize(8)
    table.scale(1, 1.25)
    pdf.savefig(fig)
    plt.close(fig)


def num(value):
    if value is None:
        return None
    try:
        value = float(value)
    except Exception:
        return None
    return value if math.isfinite(value) else None


def record_value(record, field):
    value = num(record.get(field))
    if value is not None or field != "gasMist":
        return value
    parts = [record.get("computationCost"), record.get("storageCost"), record.get("storageRebate")]
    if all(part is None for part in parts):
        return None
    return (num(parts[0]) or 0) + (num(parts[1]) or 0) - (num(parts[2]) or 0)


def avg(values):
    values = [v for v in values if v is not None]
    return sum(values) / len(values) if values else 0


def percentile(values, p):
    values = sorted(v for v in values if v is not None)
    if not values:
        return 0
    return values[min(len(values) - 1, math.ceil(len(values) * p) - 1)]


def format_ms(value):
    value = num(value) or 0
    return f"{value:,.0f}ms"


def format_compact(value):
    value = num(value) or 0
    sign = "-" if value < 0 else ""
    value = abs(value)
    if value >= 1_000_000_000:
        return f"{sign}{value / 1_000_000_000:.2f}B"
    if value >= 1_000_000:
        return f"{sign}{value / 1_000_000:.2f}M"
    if value >= 1_000:
        return f"{sign}{value / 1_000:.1f}K"
    if value == int(value):
        return f"{sign}{int(value)}"
    return f"{sign}{value:.2f}"


if __name__ == "__main__":
    main()
