/*
 * Copyright (c) 2026 Will
 * SPDX-License-Identifier: Apache-2.0
 *
 * Tiny Tapeout wrapper for the programmable FIR filter (fir_core.v).
 *
 * Pin map
 *   ui_in[7:0]   din      : signed 8-bit sample, or coefficient while loading
 *   uo_out[7:0]  dout     : signed 8-bit filtered output y[n]
 *   uio_in[0]    COEF_WR  : rising edge -> shift ui_in into the coefficient chain
 *   uio_in[1]    IN_VALID : rising edge -> ui_in is a new sample x[n]
 *   uio_in[3:2]  GAIN     : output gain 1x / 2x / 4x / 8x
 *   uio_out[6]   READY    : 1 = filter can accept a new sample
 *   uio_out[7]   OUT_VALID: 1-cycle pulse when uo_out updates
 *
 * The two strobe pins come from off-chip and are asynchronous to clk, so each
 * goes through a 2-flip-flop synchroniser (metastability protection) followed
 * by a rising-edge detector that turns it into a single-cycle strobe.
 */
`default_nettype none

module tt_um_justwillhd_fir #(
    parameter integer NTAPS = 6,   // chosen from the area sweep (see LOGBOOK.md); try 8 next
    parameter integer ARCH  = 4    // 0 direct, 1 transposed, 2 serial MAC, 3 rotating serial, 4 rotating bit-serial
) (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

    // ---------------- strobe synchronisers + edge detect ----------------
    reg [2:0] wr_sync, vld_sync;   // [0],[1] = synchroniser, [2] = previous value
    always @(posedge clk) begin
        if (!rst_n) begin
            wr_sync  <= 3'b000;
            vld_sync <= 3'b000;
        end else begin
            wr_sync  <= {wr_sync[1:0],  uio_in[0]};
            vld_sync <= {vld_sync[1:0], uio_in[1]};
        end
    end
    wire coef_wr  = wr_sync[1]  & ~wr_sync[2];
    wire in_valid = vld_sync[1] & ~vld_sync[2];

    // ---------------- filter core ----------------
    wire signed [7:0] dout;
    wire              out_valid, ready;

    fir_core #(.NTAPS(NTAPS), .ARCH(ARCH)) u_fir (
        .clk      (clk),
        .rst_n    (rst_n),
        .coef_wr  (coef_wr),
        .in_valid (in_valid),
        .gain_sel (uio_in[3:2]),
        .din      (ui_in),
        .dout     (dout),
        .out_valid(out_valid),
        .ready    (ready)
    );

    assign uo_out  = dout;
    assign uio_out = {out_valid, ready, 6'b000000};
    assign uio_oe  = 8'b1100_0000;

    // List all unused inputs to prevent warnings
    wire _unused = &{ena, uio_in[7:4], 1'b0};

endmodule
