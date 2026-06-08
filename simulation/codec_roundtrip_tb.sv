// See LICENSE file for copyright and license details
//
// End-to-end codec wrapper testbench.
//
// Exercises all four wrapper modules (decoder_linear, decoder_logarithmic,
// encoder_linear, encoder_logarithmic) plus the predecoder OUTPUT_EXPONENT=1
// path that the linear decoder selects -- none of which the per-module gates
// drive directly.
//
// References (one expected pair per takum, read from +VEC):
//   * logarithmic chain  -- a true inverse pair, so expected == input takum.
//   * linear chain       -- compared against the faithful oracle composition
//     (tools/takum_oracle.py codec_lin_expected).  This pair is the identity
//     for negative inputs only: the predecoder emits exponent e=-c-1 while
//     encoder_linear re-inverts only for sign=1, an upstream-VHDL property the
//     faithful SV reproduces.  The gate therefore checks faithful reproduction,
//     not identity, on the linear path.
//
// Compile per width with  iverilog -g2012 -P codec_roundtrip_tb.N=8 ...
// and pass the vector file with  +VEC=<path>.

`timescale 1ns / 1ps

module codec_roundtrip_tb #(
    parameter int N = 16
);

    logic [N-1:0] takum;

    // logarithmic chain
    logic                  log_sign;
    logic [N+3:0]          log_blv;
    logic [$clog2(N-4)-1:0] log_prec;
    logic                  log_zero, log_nar;
    logic [N-1:0]          takum_log;

    // linear chain
    logic                  lin_sign;
    logic signed [8:0]     lin_exp;
    logic [N-6:0]          lin_frac;
    logic [$clog2(N-4)-1:0] lin_prec;
    logic                  lin_zero, lin_nar;
    logic [N-1:0]          takum_lin;

    decoder_logarithmic #(.N(N)) dlog (
        .takum(takum), .sign_bit(log_sign),
        .barred_logarithmic_value(log_blv), .precision(log_prec),
        .is_zero(log_zero), .is_nar(log_nar));

    encoder_logarithmic #(.N(N)) elog (
        .sign_bit(log_sign), .barred_logarithmic_value(log_blv),
        .is_zero(log_zero), .is_nar(log_nar), .takum(takum_log));

    decoder_linear #(.N(N)) dlin (
        .takum(takum), .sign_bit(lin_sign), .exponent(lin_exp),
        .fraction_bits(lin_frac), .precision(lin_prec),
        .is_zero(lin_zero), .is_nar(lin_nar));

    encoder_linear #(.N(N)) elin (
        .sign_bit(lin_sign), .exponent(lin_exp), .fraction_bits(lin_frac),
        .is_zero(lin_zero), .is_nar(lin_nar), .takum(takum_lin));

    integer i, fd, code, errors, count;
    string  vecfile;
    logic [N-1:0] exp_log, exp_lin;

    initial begin
        errors = 0;
        count  = 0;
        if (!$value$plusargs("VEC=%s", vecfile)) begin
            $display("FATAL: no +VEC=<file> given");
            $fatal;
        end
        fd = $fopen(vecfile, "r");
        if (fd == 0) begin
            $display("FATAL: cannot open %s", vecfile);
            $fatal;
        end

        for (i = 0; i < (1 << N); i = i + 1) begin
            code = $fscanf(fd, "%b %b\n", exp_log, exp_lin);
            if (code != 2) begin
                $display("FATAL: vector underrun at i=%0d", i);
                $fatal;
            end
            takum = i[N-1:0];
            #1;
            count = count + 1;
            if (takum_log !== exp_log) begin           // expected == input (true inverse)
                errors = errors + 1;
                if (errors <= 10)
                    $display("MISMATCH log takum=%b out=%b exp=%b", takum, takum_log, exp_log);
            end
            if (takum_lin !== exp_lin) begin           // expected == faithful oracle
                errors = errors + 1;
                if (errors <= 10)
                    $display("MISMATCH lin takum=%b out=%b exp=%b", takum, takum_lin, exp_lin);
            end
        end
        $fclose(fd);

        if (errors == 0)
            $display("PASS: codec wrappers N=%0d, %0d values (log+lin), 0 mismatches.", N, count);
        else
            $display("FAIL: codec wrappers N=%0d, %0d values, %0d mismatches.", N, count, errors);
    end

endmodule
