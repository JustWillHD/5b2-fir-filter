/*
 * fir_core.v  --  Programmable N-tap signed FIR filter
 * 5B2 Integrated Electronic Devices coursework (SKY130 / Tiny Tapeout 1x1 tile)
 *
 *   y[n] = sum_{k=0}^{NTAPS-1} c[k] * x[n-k]
 *
 *   x : signed 8-bit samples (two's complement)
 *   c : signed 8-bit coefficients in Q1.7 format (c_real = c / 128)
 *
 * Three micro-architectures, selected by the ARCH parameter, compute the SAME
 * function so their power / performance / area can be compared like-for-like:
 *
 *   ARCH = 0  Direct form, fully parallel : NTAPS multipliers + adder tree,
 *             one output per sample, long combinational critical path.
 *   ARCH = 1  Transposed form, fully parallel : NTAPS multipliers, a register
 *             between every adder -> critical path = 1 multiply + 1 add,
 *             independent of NTAPS. Costs wide (AW-bit) pipeline registers.
 *   ARCH = 2  Serial MAC (time-multiplexed) : ONE multiplier + accumulator
 *             reused NTAPS times per sample, operands picked by N:1 muxes.
 *             Throughput drops to ~fclk / (NTAPS + 2) samples per second.
 *   ARCH = 3  Serial MAC with ROTATING registers : no N:1 read muxes; the data
 *             and coefficient chains rotate past one fixed read point.
 *             Less area, more flip-flop toggling (dynamic power).
 *   ARCH = 4  ARCH 3 + BIT-SERIAL multiplier (Horner's rule, 1 coefficient bit
 *             per cycle): the 8x8 array multiplier becomes one small adder.
 *             Smallest area; ~8*NTAPS cycles per sample.
 *
 * Output stage (shared): round-half-up, arithmetic shift by (7 - gain_sel),
 * then saturate to signed 8 bits. gain_sel = 0 -> unity gain for Q1.7
 * coefficients, 1 -> x2, 2 -> x4, 3 -> x8.
 *
 * Coefficient loading: each coef_wr strobe shifts din into c[0] and moves
 * c[k] -> c[k+1]. Load c[NTAPS-1] first and c[0] last.
 * After reset the coefficients default to a moving average (c[k] = 128/NTAPS),
 * so the chip is a working low-pass filter without any configuration.
 */
`default_nettype none

module fir_core #(
    parameter integer NTAPS = 8,
    parameter integer ARCH  = 4,
    parameter integer DW    = 8,           // sample width
    parameter integer CW    = 8            // coefficient width
) (
    input  wire                 clk,
    input  wire                 rst_n,     // synchronous, active low
    input  wire                 coef_wr,   // 1-cycle strobe: shift din into coefficient chain
    input  wire                 in_valid,  // 1-cycle strobe: din is a new sample
    input  wire [1:0]           gain_sel,
    input  wire signed [DW-1:0] din,
    output reg  signed [7:0]    dout,
    output reg                  out_valid, // 1-cycle pulse when dout updates
    output wire                 ready      // 1 = a new sample can be accepted
);

    localparam integer PW = DW + CW;                 // product width
    localparam integer AW = PW + $clog2(NTAPS) + 1;  // accumulator width (+1 guard bit for rounding)
    localparam integer IW = (NTAPS > 1) ? $clog2(NTAPS) : 1;
    localparam integer C_DEF_I = 128 / NTAPS;
    localparam signed [CW-1:0] C_DEFAULT = C_DEF_I[CW-1:0];
    localparam integer LAST_I = NTAPS - 1;

    integer k;

    // ------------------------------------------------------------------
    // Coefficient register chain (shared by all architectures)
    // ------------------------------------------------------------------
    reg signed [CW-1:0] coef [0:NTAPS-1];
    wire coef_rot;                       // serial archs 3/4 rotate the chain while computing
    wire coef_shift = coef_wr & ready;   // loading is ignored while a sample is being computed

    always @(posedge clk) begin
        if (!rst_n) begin
            for (k = 0; k < NTAPS; k = k + 1) coef[k] <= C_DEFAULT;
        end else if (coef_shift | coef_rot) begin
            coef[0] <= coef_shift ? din : coef[NTAPS-1];
            for (k = 1; k < NTAPS; k = k + 1) coef[k] <= coef[k-1];
        end
    end

    // ------------------------------------------------------------------
    // Datapath: produces y_full (full precision) and y_valid (1-cycle pulse)
    // ------------------------------------------------------------------
    reg signed [AW-1:0] y_full;
    reg                 y_valid;
    wire                accept;

    generate
    if (ARCH == 0) begin : g_direct
        // ---------------- Direct form, fully parallel ----------------
        reg signed [DW-1:0] x [0:NTAPS-1];       // tapped delay line
        reg                 v1;
        reg signed [AW-1:0] sum;
        assign accept = in_valid;
        assign ready  = 1'b1;
        assign coef_rot = 1'b0;

        always @* begin
            sum = {AW{1'b0}};
            for (k = 0; k < NTAPS; k = k + 1)
                sum = sum + coef[k] * x[k];       // NTAPS multipliers + adder tree
        end

        always @(posedge clk) begin
            if (!rst_n) begin
                for (k = 0; k < NTAPS; k = k + 1) x[k] <= {DW{1'b0}};
                v1 <= 1'b0; y_valid <= 1'b0; y_full <= {AW{1'b0}};
            end else begin
                v1      <= accept;
                y_valid <= v1;
                if (accept) begin
                    x[0] <= din;
                    for (k = 1; k < NTAPS; k = k + 1) x[k] <= x[k-1];
                end
                if (v1) y_full <= sum;
            end
        end

    end else if (ARCH == 1) begin : g_transposed
        // ---------------- Transposed form, fully parallel ----------------
        // y[n] = c0*x[n] + z0 ;  z_k <= c_{k+1}*x[n] + z_{k+1} ;  z_{N-2} <= c_{N-1}*x[n]
        reg signed [AW-1:0] z [0:NTAPS-2];        // NTAPS-1 partial-sum registers
        assign accept = in_valid;
        assign ready  = 1'b1;
        assign coef_rot = 1'b0;

        always @(posedge clk) begin
            if (!rst_n) begin
                for (k = 0; k < NTAPS - 1; k = k + 1) z[k] <= {AW{1'b0}};
                y_valid <= 1'b0; y_full <= {AW{1'b0}};
            end else begin
                y_valid <= accept;
                if (accept) begin
                    y_full <= coef[0] * din + z[0];
                    for (k = 0; k < NTAPS - 2; k = k + 1)
                        z[k] <= coef[k+1] * din + z[k+1];
                    z[NTAPS-2] <= coef[NTAPS-1] * din;
                end
            end
        end

    end else if (ARCH == 2) begin : g_serial
        // ---------------- Serial MAC (time-multiplexed) ----------------
        reg signed [DW-1:0] x [0:NTAPS-1];
        reg                 busy;
        reg        [IW-1:0] idx;
        reg signed [AW-1:0] acc;
        wire signed [PW-1:0] prod = coef[idx] * x[idx];   // the single shared multiplier
        wire signed [AW-1:0] prod_ext = $signed({{(AW-PW){prod[PW-1]}}, prod});
        localparam [IW-1:0] ILAST = LAST_I[IW-1:0];
        assign ready  = ~busy;
        assign accept = in_valid & ~busy;
        assign coef_rot = 1'b0;

        always @(posedge clk) begin
            if (!rst_n) begin
                for (k = 0; k < NTAPS; k = k + 1) x[k] <= {DW{1'b0}};
                busy <= 1'b0; idx <= {IW{1'b0}}; acc <= {AW{1'b0}};
                y_valid <= 1'b0; y_full <= {AW{1'b0}};
            end else begin
                y_valid <= 1'b0;
                if (accept) begin
                    x[0] <= din;
                    for (k = 1; k < NTAPS; k = k + 1) x[k] <= x[k-1];
                    busy <= 1'b1;
                    idx  <= {IW{1'b0}};
                    acc  <= {AW{1'b0}};
                end else if (busy) begin
                    if (idx == ILAST) begin
                        busy    <= 1'b0;
                        y_full  <= acc + prod_ext;
                        y_valid <= 1'b1;
                    end else begin
                        acc <= acc + prod_ext;
                        idx <= idx + 1'b1;
                    end
                end
            end
        end
    end else begin : g_rotate
        // ------- Serial MAC with ROTATING registers (ARCH 3) and optionally a
        // ------- BIT-SERIAL multiplier (ARCH 4).
        // Instead of an N:1 read multiplexer, the data and coefficient chains
        // rotate together, so the MAC always reads position NTAPS-1. After NTAPS
        // rotations both chains are back where they started.
        // ARCH 4 replaces the 8x8 array multiplier with Horner's rule over the
        // coefficient bits (MSB first, MSB has weight -2^7):
        //     p <- 2p +/- (c[b] ? x : 0)      8 cycles per tap, one small adder.
        localparam BITSERIAL = (ARCH == 4);
        localparam integer BW = $clog2(CW);
        localparam integer BMAX_I = CW - 1;
        localparam [BW-1:0] BMAX = BMAX_I[BW-1:0];
        localparam [IW-1:0] TLAST = LAST_I[IW-1:0];
        reg signed [DW-1:0] x [0:NTAPS-1];
        reg                 busy;
        reg        [IW-1:0] tap;
        reg        [BW-1:0] bitc;
        reg signed [AW-1:0] acc;
        reg signed [PW:0]   p;
        wire signed [DW-1:0] x_top = x[NTAPS-1];
        wire signed [CW-1:0] c_top = coef[NTAPS-1];
        wire last_bit = BITSERIAL ? (bitc == 0) : 1'b1;
        wire rot      = busy & last_bit;
        assign coef_rot = rot;
        assign ready    = ~busy;
        assign accept   = in_valid & ~busy;

        // product for this tap
        wire signed [PW:0]   term   = c_top[bitc] ? {{(PW+1-DW){x_top[DW-1]}}, x_top} : {(PW+1){1'b0}};
        wire signed [PW:0]   p_next = (p <<< 1) + ((bitc == BMAX) ? -term : term);
        wire signed [PW-1:0] p_arr  = c_top * x_top;
        wire signed [AW-1:0] p_ext  = BITSERIAL ? $signed({{(AW-PW-1){p_next[PW]}}, p_next})
                                             : $signed({{(AW-PW){p_arr[PW-1]}}, p_arr});
        wire signed [AW-1:0] acc_next = acc + p_ext;

        always @(posedge clk) begin
            if (!rst_n) begin
                for (k = 0; k < NTAPS; k = k + 1) x[k] <= {DW{1'b0}};
                busy <= 1'b0; tap <= {IW{1'b0}}; bitc <= BMAX; acc <= {AW{1'b0}};
                p <= {(PW+1){1'b0}}; y_valid <= 1'b0; y_full <= {AW{1'b0}};
            end else begin
                y_valid <= 1'b0;
                if (accept) begin                    // shift a new sample in
                    x[0] <= din;
                    for (k = 1; k < NTAPS; k = k + 1) x[k] <= x[k-1];
                    busy <= 1'b1; tap <= {IW{1'b0}}; bitc <= BMAX;
                    acc  <= {AW{1'b0}}; p <= {(PW+1){1'b0}};
                end else if (busy) begin
                    if (!last_bit) begin             // ARCH 4: next coefficient bit
                        p    <= p_next;
                        bitc <= bitc - 1'b1;
                    end else begin                   // tap finished: accumulate + rotate
                        x[0] <= x[NTAPS-1];
                        for (k = 1; k < NTAPS; k = k + 1) x[k] <= x[k-1];
                        p    <= {(PW+1){1'b0}};
                        bitc <= BMAX;
                        if (tap == TLAST) begin
                            busy    <= 1'b0;
                            y_full  <= acc_next;
                            y_valid <= 1'b1;
                        end else begin
                            acc <= acc_next;
                            tap <= tap + 1'b1;
                        end
                    end
                end
            end
        end
    end
    endgenerate

    // ------------------------------------------------------------------
    // Output stage: round, scale, saturate (registered)
    // ------------------------------------------------------------------
    wire [2:0]          shamt   = 3'd7 - {1'b0, gain_sel};
    wire signed [AW-1:0] half   = $signed({{(AW-1){1'b0}}, 1'b1}) <<< (shamt - 3'd1);
    wire signed [AW-1:0] y_sh   = (y_full + half) >>> shamt;
    wire signed [7:0]    y_sat  = (y_sh >  127) ?  8'sd127 :
                                  (y_sh < -128) ? -8'sd128 : y_sh[7:0];

    always @(posedge clk) begin
        if (!rst_n) begin
            dout      <= 8'sd0;
            out_valid <= 1'b0;
        end else begin
            out_valid <= y_valid;
            if (y_valid) dout <= y_sat;
        end
    end

endmodule
