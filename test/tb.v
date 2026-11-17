`default_nettype none
`timescale 1ns / 1ps

/* Testbench top: instantiates the Tiny Tapeout module and exposes its pins
   to cocotb (test.py drives / checks everything). */
module tb ();

  initial begin
    $dumpfile("tb.vcd");
    $dumpvars(0, tb);
    #1;
  end

  reg clk;
  reg rst_n;
  reg ena;
  reg [7:0] ui_in;
  reg [7:0] uio_in;
  wire [7:0] uo_out;
  wire [7:0] uio_out;
  wire [7:0] uio_oe;
`ifdef GL_TEST
  wire VPWR = 1'b1;
  wire VGND = 1'b0;
`endif

`ifdef GL_TEST
  tt_um_justwillhd_fir user_project (
      .VPWR(VPWR),
      .VGND(VGND),
`elsif TB_NTAPS
  // parameter sweep in RTL simulation: make TB_NTAPS=.. TB_ARCH=..
  tt_um_justwillhd_fir #(.NTAPS(`TB_NTAPS), .ARCH(`TB_ARCH)) user_project (
`else
  tt_um_justwillhd_fir user_project (
`endif
      .ui_in  (ui_in),
      .uo_out (uo_out),
      .uio_in (uio_in),
      .uio_out(uio_out),
      .uio_oe (uio_oe),
      .ena    (ena),
      .clk    (clk),
      .rst_n  (rst_n)
  );

endmodule
