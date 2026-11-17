# 5B2 Logbook: Programmable FIR filter on SKY130 (Tiny Tapeout 1x1)

Each entry: aim, what I changed, results, what I learned, next step. Every LibreLane run is tagged in git
(`run-XX`) so its RTL and config can be reproduced. Tile: 161.0 x 111.52 um die, 16,493 um^2 core.

---

## Exp 0: Tool check (template design), Oct 2026
- Aim: confirm the Vulkos / LibreLane flow runs end to end before writing my own RTL.
- Result: [fill in: utilisation, cells, DRC/LVS of the unmodified template].

## Exp 1: v1, 4-tap fixed FIR (moving average / difference), late Oct 2026
- RTL: 3-register delay line, unsigned adds, fixed coefficients chosen by `uio_in[0]`, divide by 4 with a bit slice.
- LibreLane results (final/metrics.json):

| Metric | Value |
|---|---|
| Std-cell area / utilisation | 3,927.5 um^2 / 23.8 % |
| Logic cells | 354 (32 DFF, 267 comb, 7 inv, 43 timing-repair buffers, 5 clock buffers) |
| Tap / fill cells | 225 / 3,530 |
| Hold buffers inserted | 19 |
| Worst setup slack | +7.83 ns (max_ss_100C_1v60) |
| Worst hold slack | +0.11 ns (min_ff_n40C_1v95) |
| Worst clock skew (setup) | 0.28 ns (max_ss_100C_1v60) |
| Max-slew violations | 33 (max_ss), 22 (nom_ss), 0 at tt/ff |
| Routed wirelength / vias | 6,582 um / 2,229 |
| Detailed-route DRC by iteration | 62, 3, 8, 1, 1, 0 |
| Magic DRC / LVS / antenna | 0 / 0 / 0 |
| Power | reported as 0: power analysis not produced in this run |

- Learned: setup is limited at the slow corner, hold at the fast corner; the resizer fixed hold with 19 buffers.
  76 % of the tile is empty, coefficients are fixed, and there is no testbench.
- Next: make coefficients programmable and signed, verify against a golden model, fill the tile.

## Exp 2: Architecture / area sweep with Yosys (17 Nov 2026)
- Aim: find which FIR micro-architecture can fit the most programmable taps in one tile, before spending
  LibreLane runs.
- Method: one RTL (`src/fir_core.v`) with parameters `ARCH` (0-4) and `NTAPS`; all five architectures compute the
  same function. Synthesised 35 combinations with Yosys + ABC against `sky130_fd_sc_hd__tt_025C_1v80.lib`
  (`synth -flatten; dfflibmap; abc -liberty; stat -liberty`).
- Calibration: v1 synthesised to 2,177 um^2 in the same script, but placed-and-routed logic was 3,218 um^2
  (excluding 281.5 um^2 tap cells and 428 um^2 I/O buffers), a factor of about 1.48.
- Reference blocks: signed 8x8 multiplier alone = 2,386 um^2 (14 % of the core); 17-bit adder = 470 um^2.

Yosys cell area, um^2 (and % of the 16,493 um^2 core):

| N | ARCH 0 direct | ARCH 1 transposed | ARCH 2 serial | ARCH 3 rotating | ARCH 4 bit-serial |
|---|---|---|---|---|---|
| 2 | 7,617 (46%) | 7,331 (44%) | 6,319 (38%) | 6,400 (39%) | 5,086 (31%) |
| 4 | 14,200 (86%) | 14,521 (88%) | 8,058 (49%) | 7,700 (47%) | 6,331 (38%) |
| 6 | 21,068 (128%) | 22,142 (134%) | 9,434 (57%) | 9,065 (55%) | 7,621 (46%) |
| 8 | 27,792 (169%) | 29,397 (178%) | 10,702 (65%) | 10,021 (61%) | 8,636 (52%) |
| 10 | 34,738 (211%) | 37,325 (226%) | 11,905 (72%) | 11,276 (68%) | 9,792 (59%) |
| 12 | 41,225 (250%) | 44,963 (273%) | 13,160 (80%) | 12,367 (75%) | 10,852 (66%) |
| 16 | 55,117 (334%) | 60,078 (364%) | 15,594 (95%) | 14,406 (87%) | 12,936 (78%) |

- Learned: fully parallel forms cannot fit more than 2-4 taps. Time-multiplexing one MAC changes the slope from
  ~3,300 um^2/tap to ~540 um^2/tap (now dominated by 16 bits of storage per tap). Flip-flops are about half of
  the bit-serial design's area.
- Prediction with the 1.48 factor: ARCH 4, N = 6 -> ~73 % utilisation; N = 8 -> ~82 % (may not route).
- Decision: ARCH 4 (bit-serial, rotating registers), start at N = 6, then try N = 8.
- Throughput cost: 8N + 2 cycles per sample, about 1 MS/s for N = 6 at 50 MHz, still 20x the 48 kHz audio rate.

## Exp 3: Verification of v2 (17 Nov 2026)
- cocotb testbench (`test/test.py`) drives the chip pins and compares every output with a bit-exact Python model.
- Tests: reset default (moving average step), impulse response, random coefficients and samples at all 4 gains,
  saturation, two-tone low-pass.
- Result: 5/5 pass for ARCH 0-4 with N = 8; also N = 5 (ARCH 2, 4), 6 (ARCH 4), 12 (ARCH 1, 3), 16 (ARCH 4).
  Runs on cocotb 1.9.2 and 2.1.
- Lint: `verilator --lint-only` reports 0 warnings for every ARCH setting.
- Mutation check: flipping the sign of the MSB partial product made the impulse and random tests fail,
  so the tests do detect datapath bugs.

## Exp 4: v2 LibreLane run, ARCH 4, N = 6 ([date])
- Results: utilisation [__], logic cells [__], DFF [__], setup / hold WS [__ / __], skew [__], slew violations [__],
  DRC / LVS / antenna [__], power [__].
- Compare with the 1.48 prediction (73 %): [__].

## Exp 5: v2 LibreLane run, ARCH 4, N = 8 ([date])
- Results: [__]. Did it route? [__].

## Planned
- Exp 6: remove reset from the sample ring (data flops become plain DFFs) -> area saved [__].
- Exp 7: remove the `y_full` output pipeline register -> area saved, timing cost [__].
- Exp 8: gate-level simulation of the final netlist (`make GATES=yes`).
- Exp 9: power with switching activity; compare ARCH 2 vs ARCH 4 power (rotating registers toggle more).
- Exp 10: slew violations at the ss corner: where they are and how to remove them.
