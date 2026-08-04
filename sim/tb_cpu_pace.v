//============================================================================
// tb_cpu_pace.v  --  the SYSCTL[2] TURBO pacer, on the real RTL.
//
// Four properties, and the first is the reason the module exists at all
// (rtl/cpu_pace.sv: "turbo=0 advances EXACTLY 4 of every 7 cycles, not
// roughly" -- the property a screen cannot show).
//
//   1. RATE        with turbo=0, adv_en is high exactly 4 times in every
//                  7-cycle window, measured over many windows AND over every
//                  7-cycle-aligned sub-window, so a pattern that averaged
//                  right but burst wrong would still fail.
//   2. TURBO       with turbo=1, adv_en is high EVERY cycle.
//   3. GAPS        with turbo=0, adv_en is never low for more than 1 cycle
//                  in a row -- the worst-case stall the pacer may add to any
//                  bus cycle, which is what bounds how long a peripheral sees
//                  a held bus state and how late an IRQ can be sampled.
//                  (4/7 is denser than the old 16/25: the pattern alternates
//                  stall/advance and never stalls twice running.)
//   4. SWITCH      flipping turbo mid-run takes effect within 2 cycles, both
//                  directions, and re-enters the paced pattern cleanly (the
//                  next 7-cycle window still counts 4).
//
// The NEGATIVE CONTROL for property 1 is built in: the same counter is run
// with turbo=1 and must read 7/7, so a measurement loop that had stopped
// counting (or a pacer output stuck high) cannot satisfy both readings.
//============================================================================
`timescale 1ns / 1ps

module tb_cpu_pace;

    reg  clk = 1'b0;
    reg  reset_n = 1'b0;
    reg  turbo = 1'b0;
    wire adv_en;

    integer errors = 0;

    cpu_pace dut (
        .clk     (clk),
        .reset_n (reset_n),
        .turbo   (turbo),
        .adv_en  (adv_en)
    );

    always #35.7 clk = ~clk;            // ~14 MHz; only cycle COUNTS matter

    // count adv_en highs over n cycles
    task count_adv(input integer n, output integer c);
        integer k;
        begin
            c = 0;
            for (k = 0; k < n; k = k + 1) begin
                @(posedge clk);
                if (adv_en) c = c + 1;
            end
        end
    endtask

    integer c, w, worst_gap, gap;
    integer total;

    initial begin
        repeat (4) @(posedge clk);
        reset_n = 1'b1;
        @(posedge clk);

        // ---- 1. RATE: every aligned 7-cycle window carries exactly 4 ------
        // Skip one full window first so the post-reset phase (adv_en held
        // high through reset) has flushed and windows align to the pattern.
        count_adv(7, c);
        total = 0;
        for (w = 0; w < 100; w = w + 1) begin
            count_adv(7, c);
            total = total + c;
            if (c !== 4) begin
                errors = errors + 1;
                $display("[TB] FAIL: paced window %0d carried %0d advances, want 4", w, c);
            end
        end
        $display("[TB] paced: %0d advances in 700 cycles (want 400)", total);
        if (total !== 400) errors = errors + 1;

        // ---- 3. GAPS: never more than 1 consecutive stall -----------------
        worst_gap = 0; gap = 0;
        for (w = 0; w < 500; w = w + 1) begin
            @(posedge clk);
            if (adv_en) gap = 0;
            else begin
                gap = gap + 1;
                if (gap > worst_gap) worst_gap = gap;
            end
        end
        $display("[TB] paced: worst consecutive stall = %0d cycles (want <= 1)", worst_gap);
        if (worst_gap > 1) begin
            errors = errors + 1;
            $display("[TB] FAIL: pacer starves the CPU for %0d cycles", worst_gap);
        end

        // ---- 2. TURBO: every cycle -- the negative control for 1 ----------
        turbo = 1'b1;
        @(posedge clk); @(posedge clk);      // property 4: <= 2 cycles to take
        count_adv(7, c);
        $display("[TB] turbo: %0d advances in 7 cycles (want 7)", c);
        if (c !== 7) begin
            errors = errors + 1;
            $display("[TB] FAIL: turbo mode gated the CPU");
        end

        // ---- 4. SWITCH back: paced pattern re-enters cleanly --------------
        turbo = 1'b0;
        @(posedge clk); @(posedge clk);
        count_adv(7, c);
        if (c !== 4) begin
            errors = errors + 1;
            $display("[TB] FAIL: first window after turbo->paced carried %0d, want 4", c);
        end else
            $display("[TB] turbo->paced: first window back carries 4/7, clean re-entry");

        if (errors == 0) begin
            $display("[TB] 1: exactly 4 advances per 7-cycle window, every window");
            $display("[TB] 2: turbo advances every cycle (negative control)");
            $display("[TB] 3: pacer never stalls more than 1 cycle in a row");
            $display("[TB] 4: mode switches take effect within 2 cycles, both ways");
            $display("*** PASS ***");
        end else begin
            $display("*** FAIL: %0d error(s) ***", errors);
        end
        $finish;
    end

endmodule
