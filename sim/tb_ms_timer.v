//============================================================================
// tb_ms_timer.v  --  the $9F90 millisecond counter, on the real RTL.
//
// Three properties, and the third is the reason this file exists.
//
//   1. RATE      the count advances once every TIMER_DIV clocks, exactly --
//                not approximately, and not off by one at the wrap of the
//                divider.
//   2. LATCH     reading $9F90 captures bits 31:8, and $9F91-$9F93 return
//                that capture.  Checked ACROSS A CARRY: the read is placed so
//                the counter ticks between the low byte and the high bytes,
//                which is the only case where a missing latch shows up and
//                the case that would otherwise appear once in 256 reads on
//                hardware and never in a demo.
//   3. NOT GATED the count keeps advancing while cpu_rdy is held LOW for a
//                long stretch.  This is the whole purpose of the device
//                (doc/AUDIT.md L-4: an SD transfer freezes the CPU and both
//                VIAs), and it is the one property that cannot be seen from
//                software on hardware, because the software that would look
//                is itself frozen.  Only a testbench can hold cpu_rdy down
//                and still observe.
//
// Property 3 has its own NEGATIVE CONTROL built in: the same measurement is
// taken with cpu_rdy HIGH, and the two must agree. If someone ever adds
// `if (cpu_rdy)` to the counter, the stalled measurement drops to zero while
// the running one does not, and the check fails loudly. A test that only
// measured the stalled case could be satisfied by a counter that had stopped
// for some entirely different reason.
//
// TIMER_DIV is overridden to 16 here. The real value is 14000, so reaching a
// 256-count carry would take millions of clocks; the divider is not the thing
// under test in properties 2 and 3, and property 1 checks the divider itself
// against whatever it was given.
//============================================================================
`timescale 1ns / 1ps

module tb_ms_timer;

    localparam integer DIV = 16;

    reg        clk = 1'b0;
    reg        reset_n = 1'b0;
    reg        cs = 1'b0;
    reg        rd = 1'b1;
    reg        cpu_rdy = 1'b1;
    reg  [1:0] addr = 2'b00;
    wire [7:0] rd_data;

    integer errors = 0;

    ms_timer #(.TIMER_DIV(DIV[13:0])) dut (
        .clk     (clk),
        .reset_n (reset_n),
        .cs      (cs),
        .rd      (rd),
        .cpu_rdy (cpu_rdy),
        .addr    (addr),
        .rd_data (rd_data)
    );

    always #5 clk = ~clk;               // 100 ns period is irrelevant; only
                                        // the cycle COUNT matters here

    // ---- one bus read, the way the CPU does it: address then an advancing
    // cycle.  Returns the byte and consumes exactly one clock, so the caller
    // can count clocks precisely.
    task bus_read(input [1:0] a, output [7:0] d);
        begin
            @(negedge clk);
            cs   = 1'b1;
            rd   = 1'b1;
            addr = a;
            @(posedge clk);
            d = rd_data;
            @(negedge clk);
            cs = 1'b0;
        end
    endtask

    // ---- read all 32 bits the way runtime/kirq.s does: LOW FIRST.
    task read32(output [31:0] v);
        reg [7:0] b0, b1, b2, b3;
        begin
            bus_read(2'b00, b0);
            bus_read(2'b01, b1);
            bus_read(2'b10, b2);
            bus_read(2'b11, b3);
            v = {b3, b2, b1, b0};
        end
    endtask

    task check(input cond, input [8*60:1] what);
        begin
            if (!cond) begin
                $display("[TB] FAIL: %0s", what);
                errors = errors + 1;
            end else begin
                $display("[TB] ok:   %0s", what);
            end
        end
    endtask

    integer i;
    reg [31:0] t0, t1, t2;
    reg [31:0] stalled_delta, running_delta;
    reg  [7:0] b0, b1, b2, b3;

    initial begin
        $display("[TB] ms_timer: TIMER_DIV = %0d", DIV);
        repeat (4) @(posedge clk);
        reset_n = 1'b1;
        repeat (2) @(posedge clk);

        // ---- 1: the rate ---------------------------------------------------
        // Sample, wait an exact number of clocks, sample again. The counter is
        // free-running, so the delta is (clocks / DIV) give or take the phase
        // the first sample landed in -- allow exactly one tick of slop and no
        // more, which still rejects a divider that is off by a factor.
        read32(t0);
        repeat (DIV * 100) @(posedge clk);
        read32(t1);
        $display("[TB] rate: %0d ticks over %0d clocks (expect ~100)",
                 t1 - t0, DIV * 100);
        check((t1 - t0) >= 32'd99 && (t1 - t0) <= 32'd101,
              "1: the count advances once per TIMER_DIV clocks");

        // ---- 2: the latch, across a carry ----------------------------------
        // Walk to just below a 256 boundary, then read the low byte and WAIT
        // long enough for the counter to carry into bits 31:8 before reading
        // the rest. Without the latch, byte 1 would come back one higher than
        // the value byte 0 belongs to -- a 32-bit result that jumped 256 ms
        // and, at the other end of a wrap, one that goes backwards.
        read32(t0);
        while (dut.ms_r[7:0] != 8'hFD) @(posedge clk);
        bus_read(2'b00, b0);                    // captures bits 31:8 here
        repeat (DIV * 8) @(posedge clk);        // ...carry happens in here
        bus_read(2'b01, b1);
        bus_read(2'b10, b2);
        bus_read(2'b11, b3);
        t1 = {b3, b2, b1, b0};
        $display("[TB] latch: read %08h while the live count reached %08h",
                 t1, dut.ms_r);
        check(dut.ms_r > t1,
              "2a: the counter really did carry during the read");
        check(t1[7:0] == 8'hFD && t1[31:8] != dut.ms_r[31:8],
              "2: reading $9F90 first gives a coherent, pre-carry value");

        // ---- 3: NOT gated by cpu_rdy ---------------------------------------
        // The property the whole device exists for. Measure the same interval
        // twice: once with the CPU stalled solid, once with it running. They
        // must agree, because the counter is not supposed to know.
        read32(t0);
        cpu_rdy = 1'b0;                         // an SD transfer, in effect
        repeat (DIV * 50) @(posedge clk);
        cpu_rdy = 1'b1;
        read32(t1);
        stalled_delta = t1 - t0;

        read32(t0);
        repeat (DIV * 50) @(posedge clk);       // the same interval, running
        read32(t2);
        running_delta = t2 - t0;

        $display("[TB] stalled: %0d ticks   running: %0d ticks",
                 stalled_delta, running_delta);
        check(stalled_delta >= 32'd49,
              "3: the count advances while cpu_rdy is LOW (AUDIT.md L-4)");
        // The negative half: a gated counter would make these disagree. If the
        // two ever diverge by more than the one tick of sampling phase, the
        // counter has learned about cpu_rdy and the device is broken.
        check((stalled_delta >= running_delta ? stalled_delta - running_delta
                                              : running_delta - stalled_delta) <= 32'd1,
              "3b: stalled and running measure the SAME elapsed time");

        // ---- 4: reset clears it --------------------------------------------
        reset_n = 1'b0;
        repeat (4) @(posedge clk);
        reset_n = 1'b1;
        repeat (2) @(posedge clk);
        read32(t0);
        check(t0 < 32'd4, "4: reset returns the count to zero");

        if (errors == 0)
            $display("*** PASS *** ms_timer: rate, latch across a carry, free-running under a cpu_rdy stall");
        else
            $display("*** FAIL *** ms_timer: %0d check(s) failed", errors);
        $finish;
    end

endmodule
