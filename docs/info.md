<!---
This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.
-->

## How it works

A programmable N-tap FIR filter, `y[n] = sum c[k]·x[n-k]`, with signed 8-bit samples and signed 8-bit Q1.7
coefficients (`c/128`). To fit a useful number of taps into one tile, the datapath is time-multiplexed:

* The sample history and the coefficients sit in two rings of registers that rotate together past a single
  read point, so no N:1 multiplexers are needed.
* The multiply is done bit-serially with Horner's rule over the coefficient bits (`p <- 2p ± x·c[b]`, MSB first,
  MSB weight −128), so the 8×8 multiplier becomes one 17-bit adder. Each tap takes 8 clock cycles.
* The sum is rounded, scaled by the gain setting (×1/×2/×4/×8) and saturated to signed 8 bits.

After reset the coefficients default to a moving average, so the chip low-pass filters straight away.

The RTL also contains four other architectures (direct form, transposed form, serial MAC, rotating serial MAC),
selected with the `ARCH` parameter, used for the area/throughput comparison in the logbook.

## How to test

1. Reset. The filter is now a moving average.
2. Optional, load coefficients: for k = N−1 down to 0, put `c[k]` on `ui_in` and give a rising edge on `uio[0]`.
3. Set the gain on `uio[3:2]` (00 = unity for Q1.7 coefficients).
4. Wait for `READY` (`uio[6]`) high, put a sample on `ui_in`, give a rising edge on `uio[1]`.
5. When `OUT_VALID` (`uio[7]`) pulses, `uo_out` holds the new signed output.

Maximum sample rate is about fclk / (8N + 5): about 0.7 MS/s for N = 8 at 50 MHz.

## External hardware

None required. An ADC on `ui_in` and a DAC on `uo_out` turn it into a real-time audio or sensor filter.
