# SPDX-FileCopyrightText: (c) 2026 Will
# SPDX-License-Identifier: Apache-2.0
"""
Self-checking cocotb testbench for tt_um_justwillhd_fir.

Every output sample produced by the chip is compared against a bit-accurate
Python golden model (same rounding + saturation as the RTL). The test is
protocol-based (waits for READY / OUT_VALID pins), so the same tests run on
all three architectures and on the gate-level netlist (GL_TEST).

Works with cocotb 1.9.x (Tiny Tapeout template) and cocotb 2.x.
"""
import math
import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, ReadOnly

DEFAULT_NTAPS = 8          # keep in sync with NTAPS in src/project.v (used for GL_TEST)
CLK_NS = 20                # 50 MHz, the Tiny Tapeout default clock

COEF_WR, IN_VALID = 0, 1   # uio_in bit positions
READY, OUT_VALID = 6, 7    # uio_out bit positions


# ----------------------------------------------------------------------------
# helpers that hide cocotb 1.x / 2.x API differences
# ----------------------------------------------------------------------------
def u(val):
    try:
        return val.to_unsigned()      # cocotb 2.x
    except AttributeError:
        return val.integer            # cocotb 1.x


def s8(x):
    return x - 256 if x >= 128 else x


def make_clock(sig):
    try:
        return Clock(sig, CLK_NS, unit="ns")
    except TypeError:
        return Clock(sig, CLK_NS, units="ns")


def ntaps_of(dut):
    if "FIR_NTAPS" in os.environ:
        return int(os.environ["FIR_NTAPS"])
    try:
        return int(dut.user_project.NTAPS.value)
    except Exception:
        return DEFAULT_NTAPS


# ----------------------------------------------------------------------------
# golden model
# ----------------------------------------------------------------------------
def golden(samples, coefs, gain):
    n = len(coefs)
    hist = [0] * n
    shift = 7 - gain
    out = []
    for x in samples:
        hist = [x] + hist[:-1]
        y = sum(c * h for c, h in zip(coefs, hist))
        r = (y + (1 << (shift - 1))) >> shift          # round half up (floor shift)
        out.append(max(-128, min(127, r)))              # saturate
    return out


def lowpass_q17(n, fc):
    """Hamming-windowed sinc low-pass, cutoff fc (cycles/sample), quantised to Q1.7."""
    mid = (n - 1) / 2
    h = []
    for k in range(n):
        t = k - mid
        sinc = 2 * fc if t == 0 else math.sin(2 * math.pi * fc * t) / (math.pi * t)
        w = 0.54 - 0.46 * math.cos(2 * math.pi * k / (n - 1)) if n > 1 else 1.0
        h.append(sinc * w)
    g = sum(h)
    return [max(-128, min(127, round(128 * v / g))) for v in h]


# ----------------------------------------------------------------------------
# bus-functional model of the chip pins
# ----------------------------------------------------------------------------
class FirDriver:
    def __init__(self, dut):
        self.dut = dut
        self.n = ntaps_of(dut)
        self.outputs = []
        self.uio = 0

    async def start(self):
        dut = self.dut
        cocotb.start_soon(make_clock(dut.clk).start())
        dut.ena.value = 1
        dut.ui_in.value = 0
        dut.uio_in.value = 0
        dut.rst_n.value = 0
        await ClockCycles(dut.clk, 10)
        dut.rst_n.value = 1
        await ClockCycles(dut.clk, 2)
        cocotb.start_soon(self._monitor())

    async def _monitor(self):
        while True:
            await RisingEdge(self.dut.clk)
            await ReadOnly()
            if (u(self.dut.uio_out.value) >> OUT_VALID) & 1:
                self.outputs.append(s8(u(self.dut.uo_out.value)))

    def _set_uio(self, bit, val):
        self.uio = (self.uio | (1 << bit)) if val else (self.uio & ~(1 << bit))
        self.dut.uio_in.value = self.uio

    async def set_gain(self, g):
        await RisingEdge(self.dut.clk)
        self.uio = (self.uio & ~0b1100) | ((g & 3) << 2)
        self.dut.uio_in.value = self.uio

    async def _strobe(self, bit):
        self._set_uio(bit, 1)
        await ClockCycles(self.dut.clk, 4)
        self._set_uio(bit, 0)
        await ClockCycles(self.dut.clk, 3)

    async def load_coefs(self, coefs):
        assert len(coefs) == self.n
        for c in reversed(coefs):                      # c[N-1] first, c[0] last
            await RisingEdge(self.dut.clk)
            self.dut.ui_in.value = c & 0xFF
            await self._strobe(COEF_WR)

    async def send(self, x, timeout=200):
        dut = self.dut
        for _ in range(timeout):                       # wait for READY
            await RisingEdge(dut.clk)
            await ReadOnly()
            if (u(dut.uio_out.value) >> READY) & 1:
                break
        await RisingEdge(dut.clk)
        before = len(self.outputs)
        dut.ui_in.value = x & 0xFF
        await self._strobe(IN_VALID)
        for _ in range(timeout):                       # wait for OUT_VALID
            if len(self.outputs) > before:
                return self.outputs[-1]
            await RisingEdge(dut.clk)
        raise AssertionError("timeout waiting for OUT_VALID")

    async def run(self, samples):
        return [await self.send(x) for x in samples]


def check(dut, name, got, exp):
    bad = [(i, g, e) for i, (g, e) in enumerate(zip(got, exp)) if g != e]
    if bad:
        for i, g, e in bad[:10]:
            dut._log.error(f"{name}: sample {i}: got {g}, expected {e}")
    assert not bad and len(got) == len(exp), f"{name}: {len(bad)} mismatches"
    dut._log.info(f"{name}: {len(got)} samples match the golden model")


# ----------------------------------------------------------------------------
# tests
# ----------------------------------------------------------------------------
@cocotb.test()
async def test_reset_default_moving_average(dut):
    """After reset the filter is a moving average (c[k] = 128/N): step response."""
    d = FirDriver(dut)
    await d.start()
    coefs = [128 // d.n] * d.n
    xs = [100] * (d.n + 4) + [0] * (d.n + 2)
    check(dut, "default step", await d.run(xs), golden(xs, coefs, 0))


@cocotb.test()
async def test_impulse_response(dut):
    """An impulse reads the coefficients back out: y[k] ~= c[k]."""
    d = FirDriver(dut)
    await d.start()
    random.seed(1)
    coefs = [random.randint(-128, 127) for _ in range(d.n)]
    await d.load_coefs(coefs)
    xs = [127] + [0] * (d.n + 2)
    got = await d.run(xs)
    check(dut, "impulse", got, golden(xs, coefs, 0))
    dut._log.info(f"coefs   {coefs}")
    dut._log.info(f"impulse {got[:d.n]}")


@cocotb.test()
async def test_random_all_gains(dut):
    """Random coefficients and samples, every gain setting."""
    d = FirDriver(dut)
    await d.start()
    random.seed(2)
    for g in range(4):
        coefs = [random.randint(-128, 127) for _ in range(d.n)]
        await d.load_coefs(coefs)
        await d.set_gain(g)
        # reload the history so golden model and chip start from the same state
        xs = [random.randint(-128, 127) for _ in range(60)]
        warm = [0] * d.n
        await d.run(warm)
        check(dut, f"random gain={g}", await d.run(xs), golden(warm + xs, coefs, g)[d.n:])


@cocotb.test()
async def test_saturation(dut):
    """Full-scale inputs with x8 gain must clip to +127 / -128, never wrap round."""
    d = FirDriver(dut)
    await d.start()
    coefs = [127] * d.n
    await d.load_coefs(coefs)
    await d.set_gain(3)
    xs = [127] * (d.n + 2) + [-128] * (d.n + 2)
    got = await d.run(xs)
    check(dut, "saturation", got, golden(xs, coefs, 3))
    assert max(got) == 127 and min(got) == -128


@cocotb.test()
async def test_lowpass_two_tone(dut):
    """Windowed-sinc low-pass: keep a slow tone, reject a fast one."""
    d = FirDriver(dut)
    await d.start()
    coefs = lowpass_q17(d.n, 0.08)
    await d.load_coefs(coefs)
    f_lo, f_hi = 0.02, 0.40
    xs = [round(60 * math.sin(2 * math.pi * f_lo * i) + 40 * math.sin(2 * math.pi * f_hi * i))
          for i in range(160)]
    got = await d.run(xs)
    check(dut, "two-tone low-pass", got, golden(xs, coefs, 0))
    with open("lowpass_two_tone.csv", "w") as f:
        f.write("n,x,y\n")
        for i, (x, y) in enumerate(zip(xs, got)):
            f.write(f"{i},{x},{y}\n")
    dut._log.info(f"low-pass coefs (Q1.7): {coefs}")
