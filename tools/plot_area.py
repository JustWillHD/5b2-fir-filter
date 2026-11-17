import csv, matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 12, "axes.edgecolor": "#bdbcb7",
                     "axes.labelcolor": "#52514e", "xtick.color": "#52514e", "ytick.color": "#52514e"})
CORE = 16493.3
rows = list(csv.DictReader(open("/home/claude/sweep/sweep.csv")))
names = {0: "0  Direct form (parallel)", 1: "1  Transposed (parallel)", 2: "2  Serial MAC",
         3: "3  Serial, rotating regs", 4: "4  Serial, bit-serial multiplier"}
cols = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#6250d6"]
fig, ax = plt.subplots(figsize=(11, 5.6), dpi=160)
fig.patch.set_facecolor("#fcfcfb"); ax.set_facecolor("#fcfcfb")
for a in range(5):
    pts = sorted((int(r["ntaps"]), float(r["area"]) / CORE * 100) for r in rows if int(r["arch"]) == a)
    xs, ys = zip(*pts)
    ax.plot(xs, ys, color=cols[a], lw=2, marker="o", ms=7, mec="#fcfcfb", mew=2, label=names[a])
ax.axhline(100, color="#0b0b0b", lw=1, ls="--")
ax.text(16.3, 102, "entire core area (16,493 µm²)", va="bottom", ha="right", color="#0b0b0b", fontsize=10)
ax.axhline(48, color="#52514e", lw=1, ls=":")
ax.text(16.3, 45, "≈75% placed utilisation after LibreLane\n(×1.48 + tap/IO cells, calibrated on your v1 run)",
        va="top", ha="right", color="#52514e", fontsize=9.5)
ax.set_ylim(0, 200); ax.set_xticks([2, 4, 6, 8, 10, 12, 16])
ax.set_xlabel("Number of taps (N)"); ax.set_ylabel("Synthesised cell area, % of tile core")
ax.set_title("Area vs taps: only the time-multiplexed architectures fit useful filters", loc="left", fontsize=14, color="#0b0b0b")
ax.grid(axis="y", color="#e7e6e2", lw=0.8)
for s in ("top", "right"): ax.spines[s].set_visible(False)
ax.legend(frameon=False, loc="upper right", bbox_to_anchor=(1.0, 0.95), fontsize=10.5, title="ARCH",
          title_fontsize=10, alignment="left")
fig.text(0.99, 0.01, "Yosys + ABC, sky130_fd_sc_hd tt_025C_1v80. Parallel forms continue off-chart (N=16: 334% / 364%).",
         ha="right", fontsize=8.5, color="#52514e")
fig.tight_layout(rect=(0, 0.03, 1, 1)); fig.savefig("area_vs_taps.png", facecolor=fig.get_facecolor())
