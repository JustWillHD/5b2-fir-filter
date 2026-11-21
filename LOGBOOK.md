# 5B2 Logbook: Programmable FIR filter on SKY130 (Tiny Tapeout 1x1)

Each entry: aim, what changed, results, what I learned, next step.

Contents: overview table (below) | Exp 0-1 baseline | Exp 2 Yosys sweep | Exp 3 verification |
Exp 4 first failure + fix | Exp 5-6 direct form | Exp 7-10 bit-serial scaling (+ scaling analysis) |
Exp 11 shared multiplier | Exp 12 reproducibility | Exp 13 GAIN synchroniser (planned) | Exp 14 GitHub CI |
Summary of findings | Planned work Entries are ordered by the design story;
each LibreLane entry records its Vulkos run/job ID so every number is traceable, and its outputs
(metrics.json, layout.png, timing screenshot) are saved under `runs/expNN_*/`.

Tile: 161.0 x 111.52 um die, 16,493 um^2 core, 39 rows. Clock 20 ns (50 MHz). Tool: Vulkos (LibreLane, sky130A).

How results are read (applies to every run):
- All numbers are quoted from the run's **Final** tab (`final/metrics.json`), i.e. after routing and sign-off.
  The Vulkos "Timing (STA)" tab can show different slack values (it reports an earlier stage), so it is not quoted.
- "Utilisation" = standard-cell area / core area (`design__instance__utilization`), including tap and buffer cells.
- Setup slack is limited at the slow corner (ss, 100 C, 1.60 V); hold slack at the fast corner (ff, -40 C, 1.95 V).
- Power uses the tool's default switching activity, not a real input signal, so it is a relative comparison only.
- Every run used the default config.json (PL_TARGET_DENSITY_PCT = 60, CLOCK_PERIOD = 20 ns); only NTAPS / ARCH changed.
- Each run folder `runs/expNN_*/` holds `metrics.json`, `layout.png`, `timing.png` (or `error.txt` for failed runs).

AI use (permitted for this module): the v2 RTL, cocotb testbench, Yosys sweep scripts and plots were developed
with AI assistance; all LibreLane runs, results and analysis in this logbook are my own runs.

| Exp | Design | Utilisation | Setup / hold WS | DRC / LVS | Status |
|---|---|---|---|---|---|
| 1 | v1 fixed 4-tap | 23.8 % | +7.83 / +0.11 ns | 0 / 0 | done |
| 5 | ARCH 0 (direct, programmable), N = 2 | 78.3 % | +4.35 / +0.12 ns | 0 / 0 | done |
| 6 | ARCH 0, N = 4 | 154 % (failed) | n/a | n/a | done: GPL-0301, does not fit |
| 7 | ARCH 4 (bit-serial), N = 2 | 51.8 % | +4.43 / +0.11 ns | 0 / 0 | done |
| 8 | ARCH 4, N = 4 | 63.2 % | +4.26 / +0.11 ns | 0 / 0 | done |
| 9 | ARCH 4, N = 6 | 81.6 % | +1.79 / +0.11 ns | 0 / 0 | done |
| 10 | ARCH 4, N = 8 | **87.6 %** | +2.54 / +0.11 ns | 0 / 0 | done: passed (prediction was wrong) |
| 11 | ARCH 2 (serial MAC), N = 4 | 85.3 % | +0.18 / +0.11 ns | 0 / 0 | done: passes with almost no setup margin |
| 12 | ARCH 4, N = 8, rerun of Exp 10 | 87.6 % | +2.54 / +0.11 ns | 0 / 0 | done: identical to Exp 10 |
| 13 | ARCH 4, N = 8, GAIN pins synchronised | [__] | [__] | [__] | to run |
| 14 | GitHub Actions CI (Tiny Tapeout flow), N = 8 | n/a | n/a | n/a | tests pass; gds build stuck on 1 met1 short, cancelled |

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
- Aim: before spending LibreLane runs, find which FIR micro-architecture can fit the most programmable taps.
- Method: one RTL (`src/fir_core.v`) with parameters `ARCH` (0-4) and `NTAPS`; all five architectures compute the
  same function. Synthesised 35 combinations with Yosys + ABC against `sky130_fd_sc_hd__tt_025C_1v80.lib`
  (`synth -flatten; dfflibmap; abc -liberty; stat -liberty`), script in `tools/area_sweep.sh`.
  - ARCH 0: direct form, N multipliers (= v1's structure with programmable coefficients)
  - ARCH 1: transposed form, N multipliers, register between adders
  - ARCH 2: serial MAC, one multiplier, N:1 operand multiplexers
  - ARCH 3: serial MAC with rotating registers (no read multiplexers)
  - ARCH 4: ARCH 3 + bit-serial (Horner) multiplier
- Reference blocks: signed 8x8 multiplier alone = 2,386 um^2 (14 % of the core); 17-bit adder = 470 um^2.

Yosys cell area, um^2 (and % of the 16,493 um^2 core), before place-and-route:

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
  ~3,300 um^2/tap to ~540 um^2/tap (now dominated by 16 bits of storage per tap).
- Decision: ARCH 4 as the main design; confirm the trend with real LibreLane runs of ARCH 0, 2 and 4 (Exp 5-11).
- Throughput cost of ARCH 4: 8N + 2 cycles per sample, about 1 MS/s for N = 6 at 50 MHz, 20x the 48 kHz audio rate.

## Exp 3: Verification of v2 RTL (17 Nov 2026)
- cocotb testbench (`test/test.py`) drives the chip pins and compares every output with a bit-exact Python model.
- Tests: reset default (moving average step), impulse response, random coefficients and samples at all 4 gains,
  saturation, two-tone low-pass.
- Result: 5/5 pass for ARCH 0-4 with N = 8; also N = 5, 6, 12, 16 for several ARCH. Runs on cocotb 1.9.2 and 2.1.
- Lint: `verilator --lint-only` reports 0 warnings for every ARCH setting.
- Mutation check: flipping the sign of the MSB partial product made the impulse and random tests fail,
  so the tests do detect datapath bugs.

## Exp 4: First v2 LibreLane attempt failed at Yosys synth checks (17 Nov 2026 13:05, job 09b6b3eb)
- Error: "32 Yosys check errors found": multiple conflicting drivers for `fir_core.k[31:0]`.
- Cause: one module-level `integer k` was used as the `for`-loop index in several `always` blocks. Simulators accept
  this, but synthesis sees one 32-bit variable written by several processes (32 bits = 32 errors).
- Fix: declare `integer k` locally inside each named `always` block. Yosys `check -assert` now reports 0 problems
  for every ARCH; all cocotb tests still pass.
- Lesson: simulation passing is not enough; run the synthesis checks as part of verification.

## Exp 5: ARCH 0 (direct form, programmable), N = 2 (17 Nov 2026 14:22, job 7e3c1e58)
- Aim: the natural next step from v1: same direct-form structure, coefficients now programmable (real multipliers).

| Metric | Exp 5: ARCH 0, N = 2 | Exp 7: ARCH 4, N = 2 |
|---|---|---|
| Utilisation | **78.3 %** (12,915 um^2) | 51.8 % (8,541 um^2) |
| Flip-flops | 64 | 102 |
| Combinational cells / area | 964 / 9,753 um^2 | 473 / 4,539 um^2 |
| Timing-repair / hold buffers | 120 (1,184 um^2) / 18 | 119 (1,186 um^2) / 67 |
| Clock buffers | 9 (225 um^2) | 27 (320 um^2) |
| Worst setup / hold slack | +4.35 / +0.12 ns | +4.43 / +0.11 ns |
| Max-slew violations (max_ss) | 373 | 86 |
| Route DRC by iteration | 420, 137, 91, 0 | 268, 55, 31, 0 |
| DRC / LVS / antenna | 0 / 0 / 0 | 0 / 0 / 0 |
| Power (metrics.json) | 0.555 mW (int 0.360, sw 0.195) | 0.544 mW (int 0.399, sw 0.146) |
| Throughput | 1 sample per clock (50 MS/s) | 18 clocks per sample (~2.8 MS/s) |

- As predicted by the Yosys sweep (46 % vs 31 % raw): two parallel 8x8 multipliers make the 2-tap direct form
  use 26.5 points more of the tile than the bit-serial version, for the same function.
- The area is combinational (multipliers + adder tree), not storage: only 64 flip-flops, so far fewer hold buffers
  and clock buffers than ARCH 4, but more slew violations (big multiplier nets at the slow corner).
- GPL-0302 placement-density warning appeared but placement completed.
- Power is almost equal: ARCH 0 spends more on switching (wide combinational logic), ARCH 4 more on internal
  flip-flop/clock power. (Power uses the tool's default switching activity, not real filter data.)
- Prediction for Exp 6 (N = 4): Yosys 86 % raw, x ~1.7 -> well over 100 %: should fail to fit.

## Exp 6: ARCH 0, N = 4 (17 Nov 2026 14:29, job 463fe342, run RUN_2026-11-17_14-30-12) - FAILED: DOES NOT FIT
- Aim: scale the programmable direct form to v1's tap count (4). Prediction (Exp 2 + Exp 5): well over 100 %.
- What happened, stage by stage:
  - Lint, synthesis and the Yosys checks all passed (parameters confirmed in the log: NTAPS = 4, ARCH = 0).
  - Synthesis produced 21,607 um^2 of cells (97 flip-flops = only 9.6 % of that; the rest is the four 8x8
    multipliers and the adder tree).
  - Floorplan: "Effective utilization: 1.310" -> the synthesised cells alone are 131 % of the core.
  - After tap/decap insertion and the pin-density adjustment, global placement reported 24,560 um^2 of movable
    cells -> **"[GPL-0301] Utilization 154.283 % exceeds 100%"**, and the flow stopped at stage 24 of 80
    (Global Placement).
- Why: each extra parallel tap adds a full 8x8 multiplier (~2,400 um^2 in isolation) plus adder width and
  registers. Two taps already used 78 % (Exp 5), so doubling the taps cannot fit.
- This is the expected result and the key evidence for the architecture change:
  **with programmable coefficients, the direct form cannot even reach v1's 4 taps in one tile.**
  Raising PL_TARGET_DENSITY_PCT would not help: the problem is total cell area, not packing density.
- Note: Yosys in Exp 2 estimated 14,200 um^2 for this design; LibreLane's synthesis gave 21,607 um^2 (x1.5),
  because it maps to larger-drive (_2) cells. The sweep's ranking was right; its absolute areas are optimistic.
- Saved: `runs/exp06_arch0_n4/error.txt` (full log) and a screenshot of the failure.
- Next: keep the architecture comparison at N = 4 with the methods that share one multiplier
  (Exp 8 ARCH 4, Exp 11 ARCH 2).

## Exp 7: ARCH 4 (bit-serial), N = 2 (17 Nov 2026 13:48, job 439238b4)
| Metric | Value |
|---|---|
| Utilisation | 51.8 % (8,540.7 um^2 std-cell area) |
| Std cells (incl. 225 tap) / sequential | 957 / 102 |
| Combinational / timing-repair / clock buffers | 473 cells 4,539 um^2 / 119 cells 1,186 um^2 / 27 cells 320 um^2 |
| Hold buffers | 67 |
| Worst setup slack | +4.43 ns (max_ss_100C_1v60); reg-to-reg +7.94 ns |
| Worst hold slack | +0.11 ns (min_ff_n40C_1v95) |
| Clock skew (setup / hold) | 0.27 / -0.31 ns |
| Max-slew violations | 86 (max_ss), 75 (nom_ss), 53 (min_ss), 0 at tt/ff |
| Max-fanout violations | 1 |
| Routed wirelength / vias | 15,072 um / 4,898; route DRC by iteration 268, 55, 31, 0 |
| Magic DRC / LVS / antenna / power grid | 0 / 0 / 0 / 0 |
| Worst IR drop | 42 uV |
| Power (metrics.json) | 0.544 mW: internal 0.399, switching 0.146 mW, leakage 18 nW |

- Learned: the smallest bit-serial filter uses about half the tile; most of that is fixed cost (MAC, control,
  output stage, I/O buffering), so the tile should hold several more taps.
- Next: scale up (Exp 8: N = 4, Exp 9: N = 6, Exp 10: N = 8) to find where it stops fitting.

## Exp 8: ARCH 4, N = 4 (17 Nov 2026, job 4121c31e)
- Aim: fill the gap between 2 and 6 taps, and give the bit-serial design at the same tap count where the
  parallel design failed (Exp 6). Prediction: ~67 %.

| Metric | Value |
|---|---|
| Utilisation | **63.2 %** (10,426 um^2) - fits comfortably where ARCH 0 needed 154 % |
| Std cells (incl. tap) / sequential | 1,131 / 137 |
| Combinational / timing-repair / clock buffers | 560 cells 5,201 um^2 / 171 cells 1,677 um^2 / 24 cells 298 um^2 |
| Hold buffers | 106 |
| Worst setup slack | +4.26 ns (max_ss_100C_1v60), and it is a reg-to-reg path (r2r WS = 4.26 ns) |
| Worst hold slack | +0.11 ns (min_ff_n40C_1v95) |
| Clock skew (setup / hold) | 0.27 / -0.32 ns |
| Max-slew violations | 104 (max_ss), 55 (nom_ss), 44 (min_ss), 0 at tt/ff; max-fanout 1 |
| Routed wirelength / vias | 18,603 um / 6,070; route DRC by iteration 319, 90, 60, 5, 0 |
| DRC / LVS / antenna / power grid | 0 / 0 / 0 / 0 |
| Power (metrics.json) | 0.654 mW: internal 0.484, switching 0.169 mW, leakage 18 nW |

- Learned: the same 4-tap programmable filter needs 63 % as bit-serial (ARCH 4) vs 154 % as direct form (ARCH 0):
  a 2.4x area difference for the same function, paid for with 8x more clock cycles per tap.
- Slightly under the 67 % prediction, but see the scaling analysis below: growth is not linear.

## Exp 9: ARCH 4, N = 6 (17 Nov 2026 13:07, job 646b5142) - PASSED SIGN-OFF
| Metric | Value |
|---|---|
| Utilisation | 81.6 % (13,459 um^2 std-cell area) |
| Std cells (incl. tap) / sequential | 1,342 / 172 |
| Nets / vias / wirelength | 1,122 / 8,133 / 32,907 um (5x v1) |
| Worst setup slack | +1.79 ns (max_ss_100C_1v60), TNS 0; reg-to-reg +5.62 ns |
| Worst hold slack | +0.11 ns (min_ff_n40C_1v95) |
| Clock skew (setup / hold) | 0.28 / -0.33 ns |
| Magic DRC / LVS / antenna / power grid | 0 / 0 / 0 / 0 (1 antenna diode inserted) |
| Max-slew violations | 272 (max_ss), 186 (nom_ss), 131 (min_ss), 0 at tt/ff; max-fanout 1 |
| Worst IR drop | 66 uV |
| Power (metrics.json) | 1.21 mW: internal 0.91, switching 0.29 mW, leakage 21 nW |
| Power (Vulkos SS 100C panel) | 0.83 mW: internal 0.63, switching 0.19 mW, leakage 8.2 uW |

Area breakdown of the 13,459 um^2 of standard cells:

| Class | Cells | Area (um^2) | Share |
|---|---|---|---|
| Combinational logic | 626 | 5,912 | 44 % |
| Flip-flops (dfxtp_2) | 172 | 3,659 | 27 % |
| Timing-repair buffers (166 dlygate4sd3 hold buffers + others) | 241 | 2,407 | 18 % |
| Clock tree buffers | 61 | 1,136 | 8 % |
| Tap cells | 225 | 282 | 2 % |

- Critical setup paths (top 8, slack 1.79-1.96 ns) all start at `uio_in[2]` (GAIN[0]) and end at the 8 `dout`
  flip-flops: the gain pins drive the round/shift/saturate logic directly. GAIN is also asynchronous and
  unsynchronised -> metastability risk at `dout`.
- Hold fixing costs 18 % of the area: the rotating registers are shift registers (flop feeds flop directly) and
  clock skew reaches 0.33-0.47 ns, so the resizer inserts delay cells to stop data racing through.
- Internal (flip-flop / clock-pin) power is ~75 % of the total, as expected for a register-heavy design.
- Slew violations grew with density (86 at 52 %, 272 at 82 %): less free space for repair buffers.

### Scaling analysis from Exp 7, 8 and 9 (ARCH 4, N = 2, 4, 6)

| Std-cell area (um^2) | N = 2 | N = 4 | N = 6 | 2 -> 4 | 4 -> 6 |
|---|---|---|---|---|---|
| Flip-flops | 2,170 | 2,914 | 3,659 | +744 | +745 |
| Combinational logic | 4,539 | 5,201 | 5,912 | +662 | +711 |
| Timing-repair buffers (mostly hold) | 1,186 | 1,677 | 2,407 | +491 | +730 |
| Clock tree buffers | 320 (27) | 298 (24) | 1,136 (61) | -22 | **+838** |
| Total std-cell area | 8,541 | 10,426 | 13,459 | +1,885 | **+3,033** |
| Utilisation | 51.8 % | 63.2 % | 81.6 % | +11.4 | **+18.4** |
| Hold buffers | 67 | 106 | 166 | | |
| Power (mW) | 0.544 | 0.654 | 1.21 | | |

- The logic itself grows linearly: every 2 taps add ~745 um^2 of flip-flops (32 bits of storage) and ~690 um^2
  of logic.
- The overheads do not: going from 4 to 6 taps, hold-fix buffers grew by +730 um^2 and the clock tree jumped from
  24 to 61 buffers (+838 um^2). With more flip-flops spread over a fuller die, CTS needs a deeper tree to keep
  skew down, and more flop-to-flop shift paths need hold delay cells. Power follows the clock tree
  (0.65 -> 1.21 mW).
- At N = 4 the worst path is internal (reg-to-reg, +4.26 ns). At N = 6 the worst path moved to the GAIN input pins
  (+1.79 ns), most likely because the denser placement put the output logic further from those pins.
- Revised prediction for N = 8: linear part +1,450 um^2 plus overheads growing at least as fast as 4 -> 6
  (+1,570) -> at least ~16,500 um^2, i.e. about 100 % or more. Expect Exp 10 to fail placement or routing.
- **Correction after Exp 10:** the prediction was wrong. N = 8 routed at 87.6 % with only 29 clock buffers.
  The 61-buffer clock tree at N = 6 was an outlier of that particular placement, not a trend
  (see the updated table in Exp 10).

## Exp 10: ARCH 4, N = 8 (17 Nov 2026, job e390d065) - PASSED SIGN-OFF, prediction wrong
- Aim: push the bit-serial design to 8 taps to find the limit of the tile.
- Prediction (after Exp 8): ~100 % or more, expected to fail. **Actual: it fitted and passed sign-off.**

| Metric | Value |
|---|---|
| Utilisation | **87.6 %** (14,455 um^2) - highest of all runs |
| Std cells (incl. tap) / sequential | 1,457 / 204 |
| Combinational / timing-repair / clock | 697 cells 6,492 um^2 / 286 cells 2,853 um^2 / 29 buffers + 1 inverter 432 um^2 |
| Hold buffers | 197 |
| Worst setup slack | +2.54 ns (max_ss_100C_1v60); reg-to-reg +4.56 ns -> worst path is again an I/O path |
| Worst hold slack | +0.11 ns (min_ff_n40C_1v95) |
| Clock skew (setup / hold) | 0.29 / -0.33 ns |
| Max-slew violations | 341 (max_ss), 255 (nom_ss), 167 (min_ss), 0 at tt/ff |
| Max-fanout violations | **12** (was 1 in every other ARCH 4 run) |
| Placement | GPL-0302 density warning; cells displaced 7.8 um on average, up to 119 um (vs < 1 um at N <= 4) |
| Routing | 40,804 um / 9,282 vias; route DRC by iteration 902, 474, 391, 70, 0 (hardest of all runs, but converged) |
| DRC / LVS / antenna / power grid | 0 / 0 / 0 / 0 (1 antenna diode inserted) |
| Power (metrics.json) | 1.01 mW: internal 0.73, switching 0.28 mW, leakage 21 nW (lower than N = 6) |

Updated ARCH 4 scaling table (std-cell area, um^2):

| | N = 2 | N = 4 | N = 6 | N = 8 |
|---|---|---|---|---|
| Flip-flops | 2,170 | 2,914 | 3,659 | 4,339 |
| Combinational | 4,539 | 5,201 | 5,912 | 6,492 |
| Timing-repair buffers | 1,186 | 1,677 | 2,407 | 2,853 |
| Clock tree (buffers) | 320 (27) | 298 (24) | **1,136 (61)** | 432 (30) |
| Total | 8,541 | 10,426 | 13,459 | 14,455 |
| Total without clock tree | 8,221 | 10,128 | 12,323 | 14,023 |
| Utilisation | 51.8 % | 63.2 % | 81.6 % | 87.6 % |
| Power (mW) | 0.544 | 0.654 | 1.21 | 1.01 |

- Learned: without the clock tree, area grows almost linearly (~+1,700 to +2,200 um^2 per 2 taps). The N = 6 run
  was the outlier: its clock tree came out 2.6x larger than at N = 8. CTS depends on where placement puts the
  flip-flops, so a small change to the design can change the clock tree size a lot, and **power follows it**
  (N = 6 used more power than N = 8).
- Lesson: trends fitted from two or three configurations are unreliable, because placement and CTS respond
  non-linearly to design changes. (Exp 12 shows the flow itself is deterministic: the variation comes from the
  design change, not from randomness in the tools.)
- Cost of the extra taps: much harder placement (large displacement, GPL-0302), the hardest routing, 12
  max-fanout violations and 341 slow-corner slew violations. Timing still met with +2.54 ns.
- Decision: **N = 8 becomes the final configuration** (largest filter that passes DRC / LVS / timing, best use of
  the tile, lower power than N = 6). `project.v` and `test.py` defaults updated to NTAPS = 8; cocotb tests pass.
- Next: clean up the design-rule violations (slew / fanout) and the GAIN input path at N = 8 (see Planned).

## Exp 11: ARCH 2 (serial MAC, array multiplier), N = 4 (17 Nov 2026, job d1b67e48)
- Aim: compare against Exp 8 at the same tap count: one shared 8x8 array multiplier with N:1 operand
  multiplexers (ARCH 2) vs the bit-serial multiplier with rotating registers (ARCH 4).

| Metric | Exp 11: ARCH 2, N = 4 | Exp 8: ARCH 4, N = 4 |
|---|---|---|
| Utilisation | **85.3 %** (14,074 um^2) | **63.2 %** (10,426 um^2) |
| Flip-flops | 118 | 137 |
| Combinational cells / area | 912 / 8,855 um^2 | 560 / 5,201 um^2 |
| Timing-repair / hold buffers | 209 (2,031 um^2) / 120 | 171 (1,677 um^2) / 106 |
| Clock buffers | 27 (320 um^2) | 24 (298 um^2) |
| Worst setup slack | **+0.18 ns** (max_ss, reg-to-reg) | +4.26 ns |
| Worst hold slack | +0.11 ns | +0.11 ns |
| Max-slew violations | 225 (max_ss), 22 (max_tt), 0 at ff | 104 (max_ss), 0 at tt/ff |
| Route DRC by iteration | 266, 73, 54, 0, 1, 0 | 319, 90, 60, 5, 0 |
| DRC / LVS / antenna | 0 / 0 / 0 (4 antenna diodes) | 0 / 0 / 0 |
| Power (metrics.json) | 0.974 mW (int 0.606, **sw 0.368**) | 0.654 mW (int 0.484, sw 0.169) |
| Clocks per sample | N + 2 = 6 | 8N + 2 = 34 |

- Area: the shared array multiplier plus two 4:1 operand muxes cost 3,650 um^2 more logic than the bit-serial
  datapath, even though ARCH 2 has fewer flip-flops. ARCH 2 at 4 taps is almost as large as ARCH 4 at 8 taps.
- Timing: the whole 8x8 multiply and the accumulate happen in one clock cycle, so the critical path is long:
  only +0.18 ns of setup slack at the slow corner. ARCH 2 could not run faster than ~50 MHz at ss; ARCH 4's
  path (one 17-bit add + accumulate) leaves +4.26 ns. First run with slew violations even at the typical corner.
- Power: switching power is 2.2x higher. An array multiplier has many paths of different lengths, so its outputs
  glitch (switch several times per cycle) before settling; that is wasted alpha*C*V^2*f energy.
- Trade-off: ARCH 2 is 5.7x faster per sample (6 vs 34 clocks). For audio (48 kS/s), both are far fast enough,
  so ARCH 4's smaller area, larger timing margin and lower power make it the better choice.
- Yosys predicted a 27 % area gap (8,058 vs 6,331 um^2); after place & route the gap is 35 %.

## Exp 12: Reproducibility check - Exp 10 rerun unchanged (17 Nov 2026, job [ID])
- Aim: check whether LibreLane gives the same result twice for the same input (needed to know whether
  differences between runs come from the design or from the tools).
- Method: reran ARCH 4, N = 8 with identical RTL and config.json.
- Result: every metric identical to Exp 10, to the last digit: 87.6422 % utilisation, setup WS +2.5362 ns,
  hold WS +0.1142 ns, 1,457 cells, 29 clock buffers, 341 slew violations, 1.0103 mW, routed wirelength 40,804 um.
- Learned: the flow is deterministic. Differences between configurations (e.g. the large clock tree at N = 6)
  are caused by the design change itself, which moves placement and therefore CTS and repair.
- Saved: `runs/exp12_arch4_n8_rerun_[ID]/`.

## Exp 13 (optional): synchronise the GAIN pins (planned)
- Problem (Exp 9, 10): the worst setup path starts at the GAIN input pins (`uio_in[3:2]`) and runs straight into
  the round/shift/saturate logic and the `dout` flip-flops. The GAIN pins are also asynchronous, so a change
  close to a clock edge could make `dout` metastable.
- Change: a 2-flip-flop synchroniser on each GAIN pin (4 extra flip-flops), as already used for the strobes.
  RTL in `project_exp13_gain_sync.v`; Verilator lint clean, cocotb tests pass.
- Prediction: worst setup slack moves from the I/O path (+2.54 ns) to the internal reg-to-reg path (~+4.5 ns);
  area +~100 um^2.
- Results: [__].

## Exp 14: GitHub Actions CI on the repository (17 Nov 2026)
- Aim: re-run the tests and the chip build automatically from the GitHub repo, using Tiny Tapeout's own
  workflows, as an independent check of the Vulkos results.
- Workflows: `test` (cocotb RTL simulation), `docs` (datasheet from info.yaml / docs/info.md),
  `gds` (LibreLane hardening, then precheck, gate-level test and viewer).

| Run | Commit | test | docs | gds |
|---|---|---|---|---|
| #2 | 000085e (first v2 upload, from an older zip) | passed | passed | failed after 3 m 31 s |
| #3 | 91ca8ed (final: NTAPS = 8, loop-variable fix) | **passed** (45 s) | **passed** | stuck in detailed routing > 55 min, cancelled |

- #2: the upload contained the old `fir_core.v` (shared loop variable, Exp 4) and NTAPS = 6. The RTL test passed
  but the gds build failed: the same simulation-vs-synthesis lesson as Exp 4 [cause to confirm in the gds #2 log].
- #3: the router reached a single remaining violation (one **met1 short**) and repeated "stubborn tiles"
  iterations without clearing it. Routed wirelength 49,171 um and 10,534 vias, vs 40,804 um / 9,282 vias in
  Vulkos (Exp 10) for the same RTL.
- Config comparison: the repo's `src/config.json` has the same settings as the Vulkos config.json (density 60,
  clock 20 ns, hold margins, margins, PDN pitch, CTS on). The difference is therefore the tool versions used by
  the Tiny Tapeout GitHub action vs Vulkos, which produced a different placement.
- Learned: at 87.6 % utilisation the design has very little routing margin; a different tool version is enough to
  leave one wire unroutable. The RTL itself is verified in both environments.
- Next: either give the router more room (area reduction, e.g. Exp 13 + removing resets from data registers), or
  check the 8-tap result on GitHub with an extra step; if GitHub cannot close at 8 taps, consider 6 taps as the
  tape-out-safe configuration.

##Prediction for next run:
Worst setup slack goes up, from +2.54 ns to roughly +4 to +5 ns, because the worst path is now an internal register-to-register path. At 4 taps, ARCH 4's internal path had +4.26 ns.
Possible surprise: the new worst path could be the dout register → output pin path. If so, that tells us what to look at next.
Area: about +4 flip-flops (roughly +80 to 100 µm²), so utilisation goes up by about 0.5%.
Hold: might need a couple more hold buffers, because the gain_s1 → gain_s2 path is very short.


## Summary of findings (Exp 1-14)
1. Programmable coefficients make multipliers the dominant cost: one 8x8 multiplier is ~14 % of the tile.
2. The direct form (v1's structure) fits only 2 programmable taps (78 %); 4 taps need 154 % (Exp 5, 6).
3. Sharing one multiplier (ARCH 2) fits 4 taps but at 85 % with no timing margin and the highest switching power
   (Exp 11).
4. Bit-serial multiplication with rotating registers (ARCH 4) fits 8 taps at 87.6 % with all sign-off checks
   passing (Exp 7-10): 4x the taps of the direct form in the same silicon.
5. The cost is throughput (8N + 2 clocks per sample, ~0.76 MS/s at N = 8), which is 15x more than audio needs.
6. Place-and-route overheads (hold buffers, clock tree) are 15-20 % of the area and change non-linearly from one
   configuration to the next; the clock tree size also drives power (Exp 9 vs 10). The flow itself is
   deterministic (Exp 12).
7. Remaining issues in the final design: slow-corner slew violations, 12 max-fanout violations, the
   unsynchronised GAIN inputs on the critical path, and thin routing margin (GitHub build, Exp 14).

## Planned
- Synchronise / register the GAIN pins to remove the I/O critical path.
- Remove reset from the sample ring and the `y_full` output register -> area saved [__].
- Find and fix the slow-corner slew violations.
- Gate-level simulation of the final netlist (`make GATES=yes`).
- Power comparison ARCH 2 vs ARCH 4 (rotating registers toggle more).

---

## Appendix A: How each architecture works (worked examples, for reference)

Written 18 Nov 2026 as a study note. All five architectures live in `src/fir_core.v` and are selected at compile time
with the `ARCH` parameter in `src/project.v`. A `generate` block builds **only** the selected one; the others are
not synthesised (as if commented out), which is why the area changes so much between runs.

The FIR filter computes `y = c0*x0 + c1*x1 + ... + c(N-1)*x(N-1)`: each tap multiplies a stored sample by its
coefficient and all the products are added. The architectures differ only in **how many multiplies happen per
clock and how each sample/coefficient pair reaches the multiplier**.

### The common example (4 taps)

| | Tap 0 | Tap 1 | Tap 2 | Tap 3 |
|---|---|---|---|---|
| Sample x (x0 = newest) | 3 | 2 | 5 | 1 |
| Coefficient c | 4 | -2 | 1 | 3 |
| Product c*x | 12 | -4 | 5 | 3 |

Expected answer: 12 - 4 + 5 + 3 = **16**. (Real coefficients are Q1.7, so the output stage also divides by 128,
rounds, applies the gain and saturates to 8 bits; small integers are used here to keep the maths readable.)

---

### ARCH 0: Direct form ("do it all at once")

- Hardware: **N multipliers** (one per tap) + an adder tree, all in one clock.
- Example: all four products are made at the same time and summed.

```
c0*x0 = 12 ┐
c1*x1 = -4 ┼─► adder tree ─► 16      (1 clock)
c2*x2 =  5 │
c3*x3 =  3 ┘
```

- Result: fastest, but every tap costs a full 8x8 multiplier (~2,386 um^2, ~14% of the core each).
  Exp 6: N = 4 needed 154% of the tile and failed.

### ARCH 1: Transposed form ("all at once, but store partial sums")

- Hardware: still **N multipliers**; the new sample is multiplied by every coefficient at once and the products are
  added into a chain of registers `z` that hold partial answers. Samples arrive oldest first: 1, 5, 2, 3.

| Sample in | y = c0*x + z1 | z1 <= c1*x + z2 | z2 <= c2*x + z3 | z3 <= c3*x |
|---|---|---|---|---|
| 1 | 4 + 0 = 4 | -2 | 1 | 3 |
| 5 | 20 - 2 = 18 | -10 + 1 = -9 | 5 + 3 = 8 | 15 |
| 2 | 8 - 9 = -1 | -4 + 8 = 4 | 2 + 15 = 17 | 6 |
| 3 | 12 + 4 = **16** | | | |

- Result: same answer, shorter adder path, but still N multipliers, so just as big (slightly bigger in Exp 2).

### ARCH 2: Serial MAC with selectors ("one multiplier, a pointer picks each tap")

- MAC = multiply-accumulate: one shared multiplier, one 20-bit accumulator `acc`, one tap per clock.
- A counter `idx` drives two N:1 multiplexers (selectors) that pick `coef[idx]` and `x[idx]`.

```verilog
wire signed [15:0] prod = coef[idx] * x[idx];   // the one multiplier, fed by two selectors
acc <= acc + prod_ext;  idx <= idx + 1;         // accumulate, move to next tap
```

| Clock | idx picks | Product | acc |
|---|---|---|---|
| 0 | accept sample, idx = 0, acc = 0 | - | 0 |
| 1 | c0, x0 | 12 | 12 |
| 2 | c1, x1 | -4 | 8 |
| 3 | c2, x2 | 5 | 13 |
| 4 | c3, x3 (last) | 3 | **16** -> y_full |
| 5 | output stage (round, gain, saturate), OUT_VALID | | |

- Clocks per output: **N + 2** (6 for 4 taps).
- Data stays still, the pointer moves.
- Result (Exp 11, N = 4): 85.3% utilisation; setup slack only **+0.18 ns**, because idx -> selector -> full multiplier
  -> adder -> acc must all happen in one 20 ns clock; highest switching power (0.37 mW) because the array
  multiplier glitches.

### ARCH 3: Serial MAC with rotating registers ("one multiplier, the data moves to it")

- Same registers as ARCH 2, but wired as a **ring** (last feeds back to first). The multiplier is hard-wired to the
  **last position**, so the big N:1 selectors are not needed (only one 2:1 "new value or wrap-around" selector per ring).

```verilog
wire signed [7:0] x_top = x[NTAPS-1];   // always read the last position
x[0] <= x[NTAPS-1];                     // wrap-around
for (k = 1; k < NTAPS; k = k + 1) x[k] <= x[k-1];   // everything moves along one
```

| Clock | Samples (last in bold) | Coefficients (last in bold) | Product | acc |
|---|---|---|---|---|
| 1 | 3, 2, 5, **1** | 4, -2, 1, **3** | 3 | 3 |
| 2 | 1, 3, 2, **5** | 3, 4, -2, **1** | 5 | 8 |
| 3 | 5, 1, 3, **2** | 1, 3, 4, **-2** | -4 | 4 |
| 4 | 2, 5, 1, **3** | -2, 1, 3, **4** | 12 | **16** |
| after | 3, 2, 5, 1 | 4, -2, 1, 3 | back to start | |

- Both rings rotate together, so each sample always meets its own coefficient.
- Taps come out in reverse order, but addition order does not matter.
- After N rotations everything is back in place, ready for the next sample.
- Clocks per output: **N + 2** (same as ARCH 2).
- Pointer stays still, data moves.
- Result (Exp 2 Yosys): N = 8 is 10,021 vs 10,702 um^2 for ARCH 2 (~6% smaller). The saving grows with N; at N = 2
  it is slightly worse. Still has the full multiplier, so the same timing/glitch issues as ARCH 2. Its real purpose
  is to enable ARCH 4.

### ARCH 4: Rotating + bit-serial multiplier ("no multiplier: shift-and-add one bit per clock") - FINAL DESIGN

- Same ring as ARCH 3, but the 8x8 multiplier is replaced by **one adder/subtractor**. The product is built one
  coefficient bit per clock, MSB first (Horner's rule):

```verilog
wire term   = c_top[bitc] ? x_top : 0;                      // this bit of c set? use x, else 0
wire p_next = (p <<< 1) + ((bitc == 7) ? -term : term);     // double, then add (subtract on the sign bit)
```

- `p <<< 1` (doubling) is just wiring. Bit 7 is **subtracted** because in two's complement the MSB is worth -128.
- The `*` line in `fir_core.v` (`p_arr`) is only used when ARCH = 3; for ARCH 4 nothing uses it, so Yosys removes it.

Example, first tap in ring order: c = 3 (`00000011`), x = 1

| Bit | Bit value | p = 2p +/- (bit ? x : 0) |
|---|---|---|
| 7 ... 2 | 0 | 0 |
| 1 | 1 | 0 + 1 = 1 |
| 0 | 1 | 2 + 1 = **3** (= 3 * 1) |

Negative check: c = -2 (`11111110`), x = 3

| Bit | Bit value | p |
|---|---|---|
| 7 (-128) | 1 -> subtract | 0 - 3 = -3 |
| 6 ... 1 | 1 | -6 + 3 = -3 each step |
| 0 | 0 | -6 + 0 = **-6** (= -2 * 3) |

- After 8 clocks the tap's product goes into `acc`, both rings rotate, and the next tap starts. The four taps give
  3, 5, -4, 12, so acc = **16**.
- Clocks per output: **8N + 2** (34 for 4 taps, 66 for 8 taps, so about 0.76 MS/s at 50 MHz).
- Result: Exp 2 at N = 8 is 8,636 vs 10,021 um^2 for ARCH 3 (1,385 um^2 saved by swapping the multiplier for one adder).
  Exp 8 at N = 4: 63.2% utilisation, +4.26 ns setup slack, 0.17 mW switching (vs ARCH 2: 85.3%, +0.18 ns, 0.37 mW).
  Exp 10: **N = 8 passed full sign-off at 87.6%**, which is the final design.

---

### Summary table

| ARCH | Multiply hardware | How the tap is chosen | Clocks per output | 4 taps | Area trend |
|---|---|---|---|---|---|
| 0 Direct | N multipliers | Each tap has its own | 1 | 1 | Huge (does not fit N = 4) |
| 1 Transposed | N multipliers | Each tap has its own | 1 | 1 | Huge |
| 2 Serial MAC | 1 multiplier | Counter + N:1 selectors | N + 2 | 6 | Small |
| 3 Rotating | 1 multiplier | Data rotates past a fixed input | N + 2 | 6 | Slightly smaller |
| 4 Bit-serial | 1 adder | Data rotates past a fixed input | 8N + 2 | 34 | Smallest (8 taps fit) |

**Key idea:** each step trades **speed for area**. ARCH 0/1 -> 2 shares the multiplier; 2 -> 3 removes the
selectors; 3 -> 4 removes the multiplier itself. The filter only needs well under 1 MS/s, so the spare clock cycles
are spent on taps instead of hardware.
