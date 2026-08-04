# ============================================================================
# x816.sdc -- X816 core timing constraints (applied ON TOP of sys/sys_top.sdc).
#
# sys_top.sdc cuts the whole core PLL group from the HDMI/audio/system clocks,
# but its `*[*]` wildcard lumps all FOUR core outputs into a single group, so
# they end up analyzed as synchronous to each other:
#
#   outclk_0  general[0]   25.0 MHz  pix_clk    (VERA VGA, IKAOPM, audio mix)
#   outclk_1  general[1]   14.0 MHz  cpu_clk    (CPU, VIA, SMC -- see TURBO
#                                                in x816.sv; CPU speed is a
#                                                clock-ENABLE, never a clock
#                                                switch, so one constraint
#                                                covers both speeds)
#   outclk_2  general[2]    8.0 MHz  clk8_spare (the pre-turbo CPU clock,
#                                                generated but unused)
#   outclk_3  general[3]  100.0 MHz  sdram_clk  (SDRAM controller, hps_io)
#
# Every crossing between them is handled in HARDWARE:
#   cpu_clk <-> pix_clk    the VERA _q1/_q2/_q3 bus pipeline, the YM2151
#                          req/ack toggle handshake, per-domain reset syncs
#   cpu_clk <-> sdram_clk  flat_sdram's req/ack toggle handshake and
#                          bank0_ram's loader handshake
# so the four domains are genuinely asynchronous.  Declare them so; without
# this the CPU domain shows large negative slack on phantom cross paths.
# ============================================================================
set_clock_groups -asynchronous \
    -group [get_clocks {*|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    -group [get_clocks {*|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    -group [get_clocks {*|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    -group [get_clocks {*|pll|pll_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk}]
