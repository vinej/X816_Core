--============================================================================
-- p65c816_flat_wrap.vhd  --  FLAT 24-bit wrapper around the P65C816 core.
--
-- Differences from the X16's p65c816_wrap.vhd (which this is derived from):
--
--   * ADDRESS BUS is the full 24 bits.  The X16 wrapper did
--         addr <= a24_int(15 downto 0)
--     and threw the bank byte away, because the X16 memory map is 16-bit with
--     software bank latches.  Here the bank byte IS the address: the CPU sees
--     one flat 16 MB space and every bus cycle carries {PBR|DBR, A15..A0}.
--
--   * No VPB output.  On the X16, VPB forced the hardware ROM-bank latch to 0
--     during interrupt vector pulls.  There is no bank latch in a flat model,
--     so vector pulls are ordinary bank-$00 reads and need no special casing.
--
--   * RDY_OUT is exposed as `wait_state`.  The X16 left it `open` because its
--     65C02 comparison build stalled WAI with an external wai_shim; the '816
--     needs no shim -- P65C816 gates its own enable internally
--     (EN <= RDY_IN and CE and not WAIExec and not STPExec) and wakes from WAI
--     on NMI/IRQ/ABORT regardless of the I flag, exactly like the real part.
--     NOTE what this signal therefore means: `wait_state` is high whenever the
--     CPU is not advancing FOR ANY REASON -- WAI, STP, *or* an external memory
--     stall on `enable`.  It is a bus-idle indicator (LED, debug, power
--     gating), NOT a "we are in WAI" flag; software polling it through a
--     memory-mapped register can only ever read 0, since the read itself only
--     commits on a cycle where the CPU is advancing.
--
-- Retained verbatim from the X16 wrapper, because each of these was a hard-won
-- fix on real silicon -- do not "simplify" them away:
--
--   * bus_valid = VDA or VPA.  On the '816's internal cycles A_OUT carries
--     in-flight address math (AA+inc etc.), i.e. GHOST addresses.  Undecoded,
--     those hit I/O with read side effects -- VERA's data-port auto-increment
--     and the VIA's interrupt-flag clears both fire on a phantom read.  Every
--     chip select must be qualified with this.
--
--   * the `keep` attribute on the internal address net.  Quartus's fitter note
--     "logic that only feeds a dangling port will be removed" trimmed the
--     upper address cone in the X16 build and corrupted the INDEXED-store
--     address path in silicon only (STA abs,X writes vanished on hardware but
--     were perfect in RTL sim).  Here all 24 bits leave the wrapper so the
--     dangling case cannot arise -- but the anchor stays as insurance against
--     a future consumer that ties part of the bus off.
--
--   * SYNC reconstructed as VPA and VDA.  The 65816 has no SYNC pin; that
--     product term is asserted only on the opcode fetch, which is exactly the
--     65C02 SYNC semantics.
--
--   * WE polarity.  Despite the name, P65C816 drives WE low on writes and high
--     otherwise, which already matches an R_W_N convention -- no inversion.
--
--   * RDY_IN is the stall input and CE is tied high.  Note this is a GLOBAL
--     clock enable on this core: unlike the 65C02, the '816 honours it on
--     WRITE cycles too.  Any memory controller feeding `enable` must keep
--     write cycles flowing (see the ready/we term in flat_sdram.sv).
--
-- NATIVE MODE: the 65816 always resets with E=1 (emulation) and fetches the
-- reset vector from $00FFFC -- that is silicon behaviour and this wrapper does
-- not fake it.  The boot ROM at $00:FF00 does `CLC / XCE / REP #$30` in its
-- first three instructions; `emu_mode` is brought out so the top level can
-- show (or trap) a fall back into emulation mode.
--============================================================================
library IEEE;
use IEEE.std_logic_1164.all;

library work;
use work.P65816_pkg.all;

entity p65c816_flat_wrap is
    port (
        clk        : in  std_logic;
        enable     : in  std_logic;                       -- stall / clock enable
        res_n      : in  std_logic;
        irq_n      : in  std_logic;
        nmi_n      : in  std_logic;
        abort_n    : in  std_logic;
        r_w_n      : out std_logic;
        sync       : out std_logic;                       -- VPA and VDA
        addr       : out std_logic_vector(23 downto 0);   -- FLAT 24-bit bus
        din        : in  std_logic_vector(7 downto 0);
        dout       : out std_logic_vector(7 downto 0);
        pc         : out std_logic_vector(23 downto 0);   -- {PBR, PC}
        emu_mode   : out std_logic;                       -- 1 = emulation, 0 = native
        i_flag     : out std_logic;                       -- current I (IRQ-disable) flag
        wait_state : out std_logic;                       -- RDY_OUT: WAI/STP stalled
        mlb        : out std_logic;                       -- memory lock (RMW), active low
        bus_valid  : out std_logic                        -- VDA or VPA -- qualify all CS
    );
end p65c816_flat_wrap;

architecture rtl of p65c816_flat_wrap is

    signal a24_int  : std_logic_vector(23 downto 0);
    attribute keep : boolean;
    attribute keep of a24_int : signal is true;

    signal we_int   : std_logic;
    signal vpa_int  : std_logic;
    signal vda_int  : std_logic;
    signal sync_int : std_logic;
    signal rdy_out_int : std_logic;
    signal pc_reg   : std_logic_vector(23 downto 0) := (others => '0');

begin

    u_cpu : entity work.P65C816
        port map (
            CLK     => clk,
            RST_N   => res_n,
            CE      => '1',                 -- always clocked; stall via RDY_IN
            RDY_IN  => enable,
            NMI_N   => nmi_n,
            IRQ_N   => irq_n,
            ABORT_N => abort_n,
            D_IN    => din,
            D_OUT   => dout,
            A_OUT   => a24_int,
            WE      => we_int,
            RDY_OUT => rdy_out_int,         -- WAI/STP stall indication
            VPA     => vpa_int,
            VDA     => vda_int,
            MLB     => mlb,
            VPB     => open,                -- no bank latch in a flat model
            E_OUT   => emu_mode,
            I_OUT   => i_flag
        );

    -- Full flat address bus: {bank, offset}.  In native mode the bank byte is
    -- PBR on program fetches and DBR (or the long-addressing bank) on data
    -- cycles -- the core drives the correct one per cycle, so the top level
    -- decodes A_OUT directly and never needs to know which register sourced it.
    addr <= a24_int;

    r_w_n      <= we_int;
    wait_state <= not rdy_out_int;          -- RDY_OUT low = stalled in WAI/STP

    sync_int  <= vpa_int and vda_int;
    sync      <= sync_int;
    bus_valid <= vpa_int or vda_int;

    -- PC reconstruction: latch the opcode-fetch address, gated by `enable` so a
    -- stalled cycle does not re-latch.  During the fetch cycle itself the live
    -- address is forwarded combinationally, so an equality probe on `pc` fires
    -- on the same cycle the instruction is fetched.
    process (clk)
    begin
        if rising_edge(clk) then
            if enable = '1' and sync_int = '1' then
                pc_reg <= a24_int;
            end if;
        end if;
    end process;

    pc <= a24_int when sync_int = '1' else pc_reg;

end rtl;
