#!/usr/bin/env python3
# ============================================================================
# contract.py -- the single source for the X816 core<->ROM<->emulator contract.
#
#   python tools/contract.py --write     regenerate every generated file
#   python tools/contract.py --check     fail if anything has drifted (CI)
#   python tools/contract.py --selftest  prove --check can actually fail
#   python tools/contract.py --list      print the table
#
# WHY THIS EXISTS
# ---------------
# doc/AUDIT.md "Contract duplication" counted the agreements that are encoded
# by repetition rather than by a shared source: KERN_TABLE in three files, the
# call numbers duplicated POSITIONALLY between kernel.h and kerntab.s, the load
# base in six-plus files across three repositories, EXEC_STAGE in three. None
# of these has ever been wrong -- they are maintained by someone remembering,
# which is a method that works until it does not, and whose failure mode is a
# program that links cleanly and jumps into noise.
#
# THE TWO HALVES, AND WHY BOTH
# ----------------------------
# A generator alone is not enough. A generated header that nothing includes
# proves nothing: it can agree with itself forever while the real definitions
# drift underneath it. So this file does two different jobs.
#
#   GENERATE  the files that consumers actually #include. Deleting a constant
#             from the table breaks the build of everything that used it.
#
#   VERIFY    the sites that legitimately keep their own literal -- Verilog
#             localparams, ca65 equates, ln65816 linker scripts, the card
#             builder. Those cannot include a C header, so --check reads them
#             and compares. A site whose PATTERN NO LONGER MATCHES is a
#             failure, not a pass: that is the whole difference between a
#             check and a decoration.
#
# --selftest is the negative control. It perturbs each constant in memory and
# asserts the corresponding site check goes red. A verifier that has never
# been seen to fail is a verifier nobody should trust -- doc/AUDIT.md has two
# findings that survived precisely because the test that covered them was
# never written, and one that survived because the test that "covered" it
# looked at a different path.
#
# WHAT IS DELIBERATELY NOT GENERATED
# ----------------------------------
# rtl/*.sv and boot/*.s (other than boot.s's own include) keep hand-written
# literals under VERIFY, not GENERATE, because changing RTL means a Quartus
# round and hardware. boot/boot.s IS wired to the generated ca65 include --
# that one is provable without hardware, because build.sh regenerates boot.hex
# and the bytes come out identical, so the shipped bitstream stays valid.
# ============================================================================

import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CORE = os.path.dirname(HERE)
PROJECTS = os.path.dirname(CORE)
CALYPSI = os.environ.get("CALYPSI_REPO", os.path.join(PROJECTS, "X816_Calypsi"))
EMU = os.environ.get("EMU_REPO", os.path.join(PROJECTS, "X816_Emulator"))


# ============================================================================
# The table
# ============================================================================
class Const:
    """One contract constant.

    width is how many hex digits the emitters pad to, which is not cosmetic:
    $01:0000 written as 0x10000 has been misread as bank $10 before.
    """

    def __init__(self, name, value, width=6, note="", kind="int", base=16):
        self.name = name
        self.value = value
        self.width = width
        self.note = note
        self.kind = kind            # "int" | "str"
        self.base = base            # 10 for counts and codes, 16 for addresses

    def c_literal(self):
        if self.kind == "str":
            return '"%s"' % self.value
        if self.kind == "char":
            return "'%s'" % chr(self.value)
        if self.base == 10:
            return "%d" % self.value
        # UL on anything that is a 24-bit ADDRESS, not merely on what does not
        # fit: the runtime is a 16-bit-int target, so 0x010000 without the
        # suffix is 0, and $00:FE00 cast to a __far pointer needs the width
        # even though the value itself would fit. Width is the tell -- six hex
        # digits means a flat address.
        suffix = "UL" if (self.width >= 5 or self.value > 0xFFFF) else "u"
        return "0x%0*X%s" % (self.width, self.value, suffix)

    def asm_literal(self):
        # Calypsi's assembler takes C-style expressions but not C's integer
        # suffixes.
        if self.base == 10:
            return "%d" % self.value
        return "0x%0*x" % (self.width, self.value)

    def ca65_literal(self):
        if self.base == 10:
            return "%d" % self.value
        return "$%0*X" % (self.width, self.value)

    def display(self):
        if self.kind == "str":
            return self.value
        if self.kind == "char":
            return "'%s'" % chr(self.value)
        if self.base == 10:
            return "%d" % self.value
        return "0x%0*X" % (self.width, self.value)


GROUPS = []


def group(title, blurb, consts):
    GROUPS.append((title, blurb, consts))
    return consts


# ---- image and load contract ------------------------------------------------
group(
    "Image and load contract",
    """Where the HPS loader drops an image, what marks it as one, and where
control is handed to it. boot/boot.s, x816.sv's download path, exec.s and
every linker script have to agree on all of it or a load lands on the zero
page and the machine dies before it prints anything.""",
    [
        Const("X816_PROG_BASE", 0x010000, 6,
              "loadable program image: OSD 'Load Image' and boot1.rom"),
        Const("X816_PROG_ENTRY", 0x010004, 6,
              "PROG_BASE + 4 -- the jmp in the image's own header"),
        Const("X816_FW_BASE", 0xF00000, 6,
              "resident kernel firmware image, boot2.rom (doc/KERNEL.md 3)"),
        Const("X816_FW_ENTRY", 0xF00004, 6, "FW_BASE + 4"),
        Const("X816_FW_FIRST_BANK", 0xF0, 2,
              "banks $F0-$FF are the firmware region, write-protected"),
        Const("X816_MAGIC", "X816", 0,
              "the four bytes at either base that say 'this is an image'",
              kind="str"),
        # And the same four as separate characters. Not redundancy: a
        # 65816 assembler cannot compare a string, and on the C side the
        # runtime is a LARGE-CODE model, so indexing the string literal puts
        # it in far memory and `X816_MAGIC[0]` becomes a link error rather
        # than a byte. Both consumers need the bytes one at a time.
        Const("X816_MAGIC_0", ord("X"), 2, "", kind="char"),
        Const("X816_MAGIC_1", ord("8"), 2, "", kind="char"),
        Const("X816_MAGIC_2", ord("1"), 2, "", kind="char"),
        Const("X816_MAGIC_3", ord("6"), 2, "", kind="char"),
        Const("X816_MAGIC_LE32", 0x36313858, 8,
              "the same four bytes as one little-endian 32-bit read"),
        Const("X816_IOCTL_PROG", 0x0040, 4,
              "MiSTer ioctl_index for boot1.rom (a program image)"),
        Const("X816_IOCTL_FW", 0x0080, 4,
              "MiSTer ioctl_index for boot2.rom (the kernel firmware)"),
        Const("X816_IOCTL_OSD_SLOT", 0x01, 2,
              "ioctl_index[5:0] for an OSD file pick"),
        Const("X816_EXEC_STAGE", 0x100000, 6,
              "where `run` parks an image before relocating it over PROG_BASE"),
        Const("X816_EXEC_MAX", 0xFF00, 4,
              "largest image exec.s's single-pass copy can move (X is 16 bits)"),
    ])

# ---- kernel ABI -------------------------------------------------------------
group(
    "Kernel ABI -- table, context and error codes",
    """doc/KERNEL.md sections 3-5. The table address is fixed forever; the
kernel's bank-0 claim is carved out of every program's linker map so a
program object cannot land on the kernel's direct page.""",
    [
        Const("KERN_TABLE", 0x00FE00, 6, "64 entries of `jmp long:`, one page"),
        Const("KERN_ENTRIES", 64, 2, "entries in the table", base=10),
        Const("KERN_ENTRY_SIZE", 4, 1, "bytes per entry -- a jmp long:", base=10),
        Const("KERN_TABLE_END", 0x00FEFF, 6, "last byte of the table page"),
        Const("KERN_DP", 0x2000, 4,
              "the kernel's direct page; KENTER switches D here"),
        Const("KERN_STATE", 0x2000, 4,
              "start of the kernel's bank-0 claim (KERNEL.md 3.1)"),
        Const("KERN_STATE_END", 0x2FFF, 4, "last byte of the claim"),
    ])

# ---- the kernel heap --------------------------------------------------------
group(
    "MEM_ALLOC arena",
    """The flat SDRAM the kernel hands out, doc/KERNEL.md 5.5. It starts at
bank $20 because everything below is already claimed by somebody: bank $00 is
BRAM, $01-$0F is the program image (x816-lib.scm's Code region), and
$10-$1F is FarRAM and the EXEC staging area. It stops below $F0 because that
is the write-protected firmware. Nothing here is a preference -- if the
linker maps and this arena ever disagreed, a program's own `far` data and a
kernel allocation would be the same bytes, which is silent.""",
    [
        Const("X816_HEAP_TABLE", 0x200000, 6,
              "one page of kernel bookkeeping, never handed out"),
        Const("X816_HEAP_BASE", 0x200100, 6, "first byte MEM_ALLOC may return"),
        Const("X816_HEAP_END", 0xEFFFFF, 6, "last byte of the arena, inclusive"),
        Const("X816_HEAP_GRAIN", 0x100, 3,
              "allocations are rounded up, and start, on a page"),
        Const("X816_HEAP_BLOCKS", 32, 2,
              "live allocations at once -- a fixed table, not a free list",
              base=10),
    ])

group(
    "Kernel error codes",
    """Returned in C with carry SET. Zero is never an error, so a caller that
only checks carry and a caller that checks the code agree.""",
    [
        Const("KERR_NOSYS", 1, 1, "call number not implemented in this build",
              base=10),
        Const("KERR_NOTFOUND", 2, 1, "", base=10),
        Const("KERR_NOSPACE", 3, 1, "", base=10),
        Const("KERR_BADARG", 4, 1, "", base=10),
        Const("KERR_IO", 5, 1, "", base=10),
        Const("KERR_EXISTS", 6, 1, "", base=10),
        Const("KERR_NOTEMPTY", 7, 1, "", base=10),
    ])

# ---- the I/O page -----------------------------------------------------------
group(
    "I/O page, bank $00 page $9F",
    """Deliberately the same layout as the Commander X16 for $9F00-$9F7F so
X16 register offsets port over unchanged; $9F80-$9F8F is X816's own.""",
    [
        Const("X816_IO_PAGE", 0x9F00, 4, "bank $00 only"),
        Const("X816_VIA1", 0x9F00, 4, ""),
        Const("X816_VIA2", 0x9F10, 4, ""),
        Const("X816_VERA", 0x9F20, 4, "$9F20-$9F3F"),
        Const("X816_YM", 0x9F40, 4, ""),
        Const("X816_SYSCTL", 0x9F80, 4, "bit 0 boot overlay, bit 1 E flag (r/o)"),
        Const("X816_SYSCTL_LAST", 0x9F8F, 4, "end of the SYSCTL decode"),
        Const("X816_SYSCTL_OVERLAY", 0x01, 2, "bit 0: boot ROM overlay enable"),
        Const("X816_SYSCTL_EMU", 0x02, 2, "bit 1: CPU E flag, read-only"),
        # The SD block device. CMD and STATUS are separate addresses on
        # purpose and $9F8B must stay unmapped -- rtl/sd_block.sv says why at
        # length, and doc/AUDIT.md M-3 is what happens when a doc disagrees.
        Const("X816_SD_LBA", 0x9F81, 4, "$9F81-$9F84 block number, LE"),
        Const("X816_SD_MEM", 0x9F85, 4, "$9F85-$9F87 DMA address, LE (READ only)"),
        Const("X816_SD_COUNT", 0x9F88, 4, "blocks to transfer, 1-255"),
        Const("X816_SD_CMD", 0x9F89, 4, "WRITE ONLY. 1 READ 2 WRITE 3 READBUF 4 RESET"),
        Const("X816_SD_STATUS", 0x9F8A, 4, "READ ONLY. b0 busy, b1 error, b7 present"),
        Const("X816_SD_GAP", 0x9F8B, 4, "MUST STAY UNMAPPED -- see sd_block.sv"),
        Const("X816_SD_DATA", 0x9F8C, 4, "block-buffer window, auto-incrementing"),
        Const("X816_KBD_COUNT", 0x9F8D, 4, "keyboard diagnostic counters, $9F8D-$9F8F"),
        # The free-running millisecond timer. NOT in the $9F8x block: that
        # block is full ($9F8D-$9F8F took the last three), so this opens the
        # $9F9x nibble. It is deliberately below the emulator's debug device
        # at $9FB0, which is emulator-only and must stay reachable.
        Const("X816_TIMER", 0x9F90, 4, "$9F90-$9F93 free-running ms counter, LE"),
        Const("X816_TIMER_LAST", 0x9F93, 4, "reading $9F90 latches bits 31:8"),
        Const("X816_TIMER_DIV", 8000, 4,
              "cpu_clk cycles per tick: 8.000 MHz / 8000 = 1 kHz exactly",
              base=10),
        Const("X816_TIMER_HZ", 1000, 4, "so the unit is a millisecond", base=10),
        Const("X816_BOOT_BASE", 0xFF00, 4, "boot ROM read overlay, bank $00"),
        Const("X816_BOOT_SIZE", 0x100, 3, "and it is exactly one page"),
    ])

# ---- the pieces of the I/O page the interrupt dispatcher touches -------------
group(
    "Interrupt hardware",
    """VERA's interrupt registers and the VIA's, by the offsets the stock X16
uses -- the I/O page is byte-for-byte the X16's for $9F00-$9F7F, so these are
inherited rather than chosen. The kernel's dispatcher (runtime/kirq.s) is the
one thing that has to know all of them at once, because it is the only code
that sees an interrupt before anybody has said which device caused it.""",
    [
        Const("X816_VERA_IEN", 0x9F26, 4, "VERA interrupt enable"),
        Const("X816_VERA_ISR", 0x9F27, 4, "VERA interrupt status; write 1 to clear"),
        Const("X816_VERA_IRQ_VSYNC", 0x01, 2, "", base=10),
        Const("X816_VERA_IRQ_LINE", 0x02, 2, "", base=10),
        Const("X816_VERA_IRQ_SPRCOL", 0x04, 2, "", base=10),
        # AFLOW is the one that cannot be acknowledged by writing ISR: it
        # clears only when something refills the audio FIFO. See kirq.s.
        Const("X816_VERA_IRQ_AFLOW", 0x08, 2, "clears by REFILLING, not by ack", base=10),
        Const("X816_VIA_IFR", 0x0D, 2, "offset within a VIA: interrupt flags", base=10),
        Const("X816_VIA_IER", 0x0E, 2, "offset within a VIA: interrupt enable", base=10),
        Const("X816_YM_TIMER_REG", 0x14, 2, "YM2151 register holding its IRQ resets", base=10),
    ])

# ---- the 65816 vectors ------------------------------------------------------
group(
    "65816 native vectors",
    """Hardware addresses, not ours to place, and SIXTEEN bits wide -- which
is the constraint that shapes doc/KERNEL.md section 5.6: the CPU jumps into
bank $00 for every interrupt, so the kernel's first-level handler cannot live
in the firmware region with the rest of the kernel. kirq_install stamps a
four-byte `jmp long:` trampoline into bank $00 for each of these and points
the vector at it. ABORT is listed because it must keep trapping: x816.sv ties
abort_n high, so there is no ABORT source and nothing should install one.""",
    [
        Const("X816_VEC_COP", 0x00FFE4, 6, ""),
        Const("X816_VEC_BRK", 0x00FFE6, 6, ""),
        Const("X816_VEC_ABORT", 0x00FFE8, 6, "no source; stays trapping"),
        Const("X816_VEC_NMI", 0x00FFEA, 6, ""),
        Const("X816_VEC_IRQ", 0x00FFEE, 6, ""),
    ])

# ---- the kernel's interrupt vector table ------------------------------------
group(
    "Interrupt vector slots",
    """IRQ_SET's index space (doc/KERNEL.md section 5.6). One slot per SOURCE
rather than one per CPU vector, because the CPU has a single IRQ vector and
seven things behind it: deciding which fired is the dispatcher's job, and a
program that wants the raster split should not have to also service the
audio FIFO to get it. Slot numbers are ABI -- appending is fine, renumbering
is not.""",
    [
        Const("KIRQ_VSYNC", 0, 1, "VERA vertical blank", base=10),
        Const("KIRQ_LINE", 1, 1, "VERA raster line compare", base=10),
        Const("KIRQ_SPRCOL", 2, 1, "VERA sprite collision", base=10),
        Const("KIRQ_AFLOW", 3, 1, "VERA audio FIFO low", base=10),
        Const("KIRQ_VIA1", 4, 1, "VIA #1 -- timers, SNES pads, I2C to the SMC", base=10),
        Const("KIRQ_VIA2", 5, 1, "VIA #2 -- user port", base=10),
        Const("KIRQ_YM", 6, 1, "YM2151 timer", base=10),
        Const("KIRQ_SPURIOUS", 7, 1, "an IRQ that no enabled source claimed", base=10),
        Const("KIRQ_NMI", 8, 1, "SMC NMI request -- edge, nothing to acknowledge", base=10),
        Const("KIRQ_BRK", 9, 1, "BRK", base=10),
        Const("KIRQ_COP", 10, 1, "COP", base=10),
        Const("KIRQ_SLOTS", 11, 2, "slots in the table", base=10),
        Const("KIRQ_SLOT_SIZE", 4, 1,
              "bytes per slot: a 24-bit handler in a power-of-two stride, so "
              "the index scales with two shifts and not a multiply", base=10),
        Const("KIRQ_TRAMPOLINE_SIZE", 4, 1, "`jmp long:` -- opcode plus 24 bits", base=10),
    ])

# ---- paths ------------------------------------------------------------------
group(
    "Card layout",
    """The demo card built by tools/mksdcard.py, and the one path that is
compiled into a binary: goshell reloads the shell by name.""",
    [
        Const("X816_DEMO_DIR", "/DEMO", 0, "", kind="str"),
        Const("X816_SHELL_PATH", "/DEMO/SHELL.BIN", 0,
              "goshell.c reloads this on ESC", kind="str"),
    ])


# ============================================================================
# The kernel call table.
#
# THIS is the duplication that mattered most: kernel.h gave each call a
# number, and kerntab.s gave each call a POSITION, and nothing checked that
# entry 21 in one was entry 21 in the other. Renumbering by accident is an ABI
# break that produces no diagnostic anywhere -- the program jumps to a real,
# working, wrong routine.
#
# Fields: number, ABI name (None = an unnamed reserved slot), thunk label,
# and the comment that appears in kernel.h. A named slot whose thunk is
# k_nosys is reserved-and-numbered: the number is promised, the code is not
# written yet. That distinction is the reason the numbering leaves gaps.
# ============================================================================
NOSYS = "k_nosys"

CALLS = [
    (0,  "K_CON_PUTC",    "k_con_putc",    "C = character"),
    (1,  "K_CON_PUTS",    "k_con_puts",    "C:X = 24-bit pointer to a NUL-terminated str"),
    (2,  "K_CON_GETC",    "k_con_getc",    "-> C = character, blocking"),
    (3,  "K_CON_GETKEY",  "k_con_getkey",  "-> C = character, or 0 if none"),
    (4,  "K_CON_CLS",     "k_con_cls",     ""),
    (5,  "K_CON_GOTOXY",  "k_con_gotoxy",  "C = column, X = row"),
    (6,  "K_CON_GETXY",   "k_con_getxy",   "-> C = column, X = row"),
    (7,  "K_CON_PUTRAW",  "k_con_putraw",  "C = column, X = row, Y = glyph code"),
    (16, "K_FS_OPEN",     "k_fs_open",     ""),
    (17, "K_FS_CLOSE",    "k_fs_close",    ""),
    (18, "K_FS_READ",     "k_fs_read",     ""),
    (19, "K_FS_WRITE",    "k_fs_write",    ""),
    (20, "K_FS_SEEK",     "k_fs_seek",     ""),
    (21, "K_FS_SIZE",     "k_fs_size",     ""),
    (22, "K_FS_DELETE",   "k_fs_delete",   ""),
    (23, "K_FS_RENAME",   "k_fs_rename",   ""),
    (24, "K_DIR_OPEN",    "k_dir_open",    ""),
    (25, "K_DIR_NEXT",    "k_dir_next",    ""),
    (26, "K_DIR_CLOSE",   "k_dir_close",   ""),
    (27, "K_FS_CHDIR",    "k_fs_chdir",    ""),
    (28, "K_FS_GETCWD",   "k_fs_getcwd",   ""),
    (29, "K_FS_MKDIR",    "k_fs_mkdir",    ""),
    (30, "K_FS_RMDIR",    "k_fs_rmdir",    ""),
    (32, "K_EXEC",        "k_exec",        "C:X = path; does not return on success"),
    (33, "K_EXIT",        "k_exit",        "C = status; does not return"),
    (40, "K_MEM_ALLOC",   "k_mem_alloc",   "C:X = 32-bit size -> C:X = address"),
    (41, "K_MEM_FREE",    "k_mem_free",    "C:X = address"),
    (48, "K_SYS_VERSION", "k_sys_version", "-> C = (major << 8) | minor"),
    (49, "K_IRQ_SET",     "k_irq_set",     "C = KIRQ_ slot, X:Y = handler -> C:X = previous"),
    (50, "K_TIME_GET",    "k_time_get",    "-> C = ms low 16, X = ms high 16"),
    (51, "K_TIME_SET",    "k_time_set",    "C = ms low 16, X = ms high 16"),
    (52, "K_IRQ_FRAMES",  "k_irq_frames",  "-> C = VSYNC frames, 16-bit, wraps"),
]

CALL_GROUPS = [
    (0,  15, "console"),
    (16, 31, "filesystem"),
    (32, 39, "programs"),
    (40, 47, "memory"),
    (48, 63, "system"),
]


def call_by_number():
    by_n = {}
    for n, name, thunk, note in CALLS:
        if n in by_n:
            raise SystemExit("contract: call number %d defined twice" % n)
        by_n[n] = (name, thunk, note)
    kern_entries = const("KERN_ENTRIES").value
    for n, (name, thunk, note) in by_n.items():
        if not 0 <= n < kern_entries:
            raise SystemExit("contract: call %s is number %d, outside the table"
                             % (name, n))
    return by_n


def const(name):
    for _t, _b, consts in GROUPS:
        for c in consts:
            if c.name == name:
                return c
    # Call numbers are constants too, they just live in CALLS because their
    # ORDER is the other half of what that table produces.
    for num, cname, _thunk, note in CALLS:
        if cname == name:
            return Const(name, num, 2, note, base=10)
    raise SystemExit("contract: no such constant: %s" % name)


def all_consts():
    for _t, _b, consts in GROUPS:
        for c in consts:
            yield c


# ============================================================================
# Emitters
# ============================================================================
BANNER = "GENERATED BY tools/contract.py -- DO NOT EDIT"


def _wrap(text, width, lead):
    out, line = [], lead
    for word in text.split():
        if len(line) + 1 + len(word) > width and line != lead:
            out.append(line)
            line = lead
        line += ("" if line == lead else " ") + word
    out.append(line)
    return out


def emit_c(guard, origin):
    L = []
    A = L.append
    A("/* ==========================================================================")
    A(" * %s -- the X816 contract constants." % os.path.basename(origin))
    A(" *")
    A(" * %s." % BANNER)
    A(" * Edit X816_core/tools/contract.py and run:  python tools/contract.py --write")
    A(" *")
    A(" * This file is one half of the contract mechanism. The other half is")
    A(" * `contract.py --check`, which reads the sites that keep their own literal")
    A(" * -- x816.sv, the linker scripts, mksdcard.py -- and fails if any of them")
    A(" * has drifted from the table these constants came from.")
    A(" * ========================================================================== */")
    A("")
    A("#ifndef %s" % guard)
    A("#define %s" % guard)
    A("")
    for title, blurb, consts in GROUPS:
        A("/* ---- %s %s */" % (title, "-" * max(3, 68 - len(title))))
        for line in _wrap(" ".join(blurb.split()), 76, " "):
            A("/*%s */" % line if False else "/*%s */" % line)
        A("")
        width = max(len(c.name) for c in consts)
        for c in consts:
            line = "#define %-*s %s" % (width, c.name, c.c_literal())
            if c.note:
                line = "%-*s /* %s */" % (max(len(line), 44), line, c.note)
            A(line)
        A("")

    A("/* ---- kernel call numbers %s */" % ("-" * 43))
    A("/* The numbering leaves gaps between groups on purpose: adding FS_TRUNCATE  */")
    A("/* later must not renumber MEM_ALLOC, because a renumber breaks every       */")
    A("/* program already built. kerntab.s's table is generated from the same      */")
    A("/* rows, so a number here and a position there cannot disagree.             */")
    A("")
    by_n = call_by_number()
    width = max(len(name) for _n, name, _t, _c in CALLS if name)
    for lo, hi, gname in CALL_GROUPS:
        rows = [(n, by_n[n]) for n in range(lo, hi + 1)
                if n in by_n and by_n[n][0]]
        if not rows:
            continue
        A("/* %s, %d-%d */" % (gname, lo, hi))
        for n, (name, thunk, note) in rows:
            line = "#define %-*s %2d" % (width, name, n)
            tail = note
            if thunk == NOSYS and not note:
                tail = "reserved, not implemented"
            if tail:
                line = "%-*s /* %s */" % (max(len(line), 40), line, tail)
            A(line)
        A("")

    A("#endif /* %s */" % guard)
    A("")
    return "\n".join(L)


def emit_calypsi_asm():
    L = []
    A = L.append
    A("; ============================================================================")
    A("; x816_contract.inc -- the X816 contract constants, for as65816.")
    A(";")
    A("; %s." % BANNER)
    A("; Edit X816_core/tools/contract.py and run:  python tools/contract.py --write")
    A(";")
    A("; The Calypsi assembler runs the C preprocessor, so this is #included, not")
    A("; .included, and the expressions are C-style. Every symbol here is a .equ:")
    A("; defining one of these names again in the including file is a duplicate")
    A("; symbol error, which is the point -- a second definition is exactly the")
    A("; drift this file exists to stop.")
    A("; ============================================================================")
    A("")
    A("#ifndef X816_CONTRACT_INC")
    A("#define X816_CONTRACT_INC")
    A("")
    for title, blurb, consts in GROUPS:
        A("; ---- %s %s" % (title, "-" * max(3, 68 - len(title))))
        for line in _wrap(" ".join(blurb.split()), 76, ""):
            A("; %s" % line)
        width = max(len(c.name) for c in consts)
        for c in consts:
            if c.kind == "str":
                continue        # no string equates in an assembler symbol table
            line = "%-*s .equ    %s" % (width + 1, c.name + ":", c.asm_literal())
            if c.note:
                line = "%-*s ; %s" % (max(len(line), 46), line, c.note)
            A(line)
        A("")

    A("; ---- kernel call numbers %s" % ("-" * 44))
    by_n = call_by_number()
    width = max(len(name) for _n, name, _t, _c in CALLS if name)
    for n in sorted(by_n):
        name, thunk, note = by_n[n]
        if not name:
            continue
        A("%-*s .equ    %d" % (width + 1, name + ":", n))
    A("")
    A("#endif /* X816_CONTRACT_INC */")
    A("")
    return "\n".join(L)


def emit_kerntab_inc():
    """The 64-entry prototype table body, #included by kerntab.s.

    The positional duplication doc/AUDIT.md named lived exactly here: this is
    the list whose ORDER is the ABI, facing a header whose NUMBERS are the
    same ABI. Now they are the same rows.
    """
    L = []
    A = L.append
    A("; ============================================================================")
    A("; x816_kerntab.inc -- the body of kern_proto: 64 entries of `jmp long:`.")
    A(";")
    A("; %s." % BANNER)
    A("; Edit X816_core/tools/contract.py and run:  python tools/contract.py --write")
    A(";")
    A("; ORDER IS THE ABI. This file and the K_* numbers in x816_contract.h are")
    A("; generated from one table, so entry n here and K_xxx = n there cannot")
    A("; disagree -- which they could, silently, when these were two hand-kept")
    A("; lists (doc/AUDIT.md, contract duplication).")
    A(";")
    A("; Slots with no implementation point at k_nosys and return carry set with")
    A("; KERR_NOSYS. Every one of the 64 is filled: a caller gets a clean error")
    A("; instead of a jump into whatever bank $00 happened to contain.")
    A("; ============================================================================")
    by_n = call_by_number()
    for n in range(const("KERN_ENTRIES").value):
        name, thunk, _note = by_n.get(n, (None, NOSYS, ""))
        comment = "%2d" % n
        if name:
            comment += " " + name
            if thunk == NOSYS:
                comment += " (reserved)"
        A("              jmp     long:%-18s ; %s" % (thunk, comment))
    A("")
    return "\n".join(L)


def emit_ca65():
    L = []
    A = L.append
    A("; ============================================================================")
    A("; x816_contract.inc -- the X816 contract constants, for ca65.")
    A(";")
    A("; %s." % BANNER)
    A("; Edit X816_core/tools/contract.py and run:  python tools/contract.py --write")
    A(";")
    A("; ca65 has no preprocessor, so this is .included and the symbols are plain")
    A("; equates. boot.s is the consumer: it is the code that decides which image")
    A("; owns the machine, so it is the last place a stale address should live.")
    A(";")
    A("; Changing a value here changes boot.hex, which is baked into the bitstream")
    A("; by $readmemh -- boot/build.sh touches rtl/boot_rom.sv for exactly that")
    A("; reason. Wiring boot.s to this file did NOT change boot.hex; that was")
    A("; checked byte for byte before it was committed.")
    A("; ============================================================================")
    A("")
    A(".ifndef X816_CONTRACT_INC")
    A("X816_CONTRACT_INC = 1")
    A("")
    for title, _blurb, consts in GROUPS:
        A("; ---- %s" % title)
        width = max(len(c.name) for c in consts)
        for c in consts:
            if c.kind == "str":
                continue
            line = "%-*s = %s" % (width, c.name, c.ca65_literal())
            if c.note:
                line = "%-*s ; %s" % (max(len(line), 34), line, c.note)
            A(line)
        A("")
    A(".endif")
    A("")
    return "\n".join(L)


# Every generated file: (absolute path, producer). --check regenerates each
# and compares; --write writes them.
def generated_files():
    return [
        (os.path.join(CALYPSI, "runtime", "x816_contract.h"),
         lambda: emit_c("X816_CONTRACT_H",
                        os.path.join(CALYPSI, "runtime", "x816_contract.h"))),
        (os.path.join(CALYPSI, "runtime", "x816_contract.inc"),
         emit_calypsi_asm),
        (os.path.join(CALYPSI, "runtime", "x816_kerntab.inc"),
         emit_kerntab_inc),
        (os.path.join(EMU, "src", "x816_contract.h"),
         lambda: emit_c("X816_CONTRACT_H",
                        os.path.join(EMU, "src", "x816_contract.h"))),
        (os.path.join(CORE, "boot", "x816_contract.inc"),
         emit_ca65),
    ]


# ============================================================================
# Verified sites -- the literals that stay hand-written
# ============================================================================
def hexint(s):
    """Parse the many ways this tree writes a hex number.

    Verilog 24'hF0_0000, Scheme #x010000, ca65 $9F80, C 0x2000u, or bare.
    """
    s = s.strip().replace("_", "")
    s = re.sub(r"^\d+'[hH]", "", s)          # 24'h...
    s = re.sub(r"^(#x|0x|0X|\$)", "", s)     # #x... 0x... $...
    s = re.sub(r"[uUlL]+$", "", s)
    return int(s, 16)


def read(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


class Site:
    """One hand-written literal that --check reads back.

    A Site whose pattern does not match is a FAILURE. That is not pedantry:
    the failure mode being guarded against is someone moving a constant and
    this file silently checking nothing afterwards, which is how a green suite
    ends up covering a path that no longer exists (doc/AUDIT.md H-3).
    """

    def __init__(self, path, const_name, pattern, why, parse=hexint,
                 expect=None):
        self.path = path
        self.const_name = const_name
        self.pattern = pattern
        self.why = why
        self.parse = parse
        self.expect = expect    # override: a value derived from the constant

    def label(self):
        return "%s: %s" % (os.path.relpath(self.path, PROJECTS),
                           self.const_name)

    def wanted(self):
        if self.expect is not None:
            return self.expect
        return const(self.const_name).value

    def check(self, wanted=None, text=None):
        """-> (ok, message)."""
        if wanted is None:
            wanted = self.wanted()
        rel = os.path.relpath(self.path, PROJECTS)
        try:
            text = read(self.path) if text is None else text
        except IOError as e:
            return False, "%s: cannot read (%s)" % (rel, e)
        hits = re.findall(self.pattern, text, re.M)
        if not hits:
            return False, ("%s: the pattern for %s matched NOTHING -- the site "
                           "moved or was renamed, so nothing is being checked "
                           "there any more" % (rel, self.const_name))
        for h in hits:
            got = self.parse(h)
            if got != wanted:
                return False, ("%s: %s is %r here, contract says %r (%s)"
                               % (rel, self.const_name, got, wanted, self.why))
        return True, "%s: %s x%d" % (rel, self.const_name, len(hits))

    def negatives(self):
        w = self.wanted()
        wrong = (w + "-NOT-THIS") if isinstance(w, str) else (w ^ 0x5A5A5)
        return [("a wrong value", self.check(wanted=wrong)[0])]


class Wired:
    """A consumer that must take the contract from the generated file.

    Verifying values with a regex catches the second copy going stale. This
    catches the second copy being CREATED: a file that pulls in the contract
    and then #defines one of its names again has quietly forked it, and the
    compiler will not say a word if the two happen to agree today.

    `redefines` is the language's "here is a new definition of NAME" pattern
    with %s where the name goes.
    """

    LANG = {
        "c":       r"^\s*#\s*define\s+%s\b",
        "calypsi": r"^\s*%s\s*:?\s+\.equ\b",
        "ca65":    r"^\s*%s\s*=",
    }

    def __init__(self, path, includes, lang, why, exempt=()):
        self.path = path
        self.includes = includes    # list of generated basenames it must pull in
        self.lang = lang
        self.why = why
        self.exempt = set(exempt)

    def label(self):
        return "%s: wired" % os.path.relpath(self.path, PROJECTS)

    def wanted(self):
        return None                 # nothing to perturb; see cmd_selftest

    def check(self, wanted=None, text=None):
        rel = os.path.relpath(self.path, PROJECTS)
        try:
            text = read(self.path) if text is None else text
        except IOError as e:
            return False, "%s: cannot read (%s)" % (rel, e)
        for inc in self.includes:
            pat = r'(#\s*include|\.include)\s+"[^"]*%s"' % re.escape(inc)
            if not re.search(pat, text):
                return False, ("%s: does not include %s -- it is not taking "
                               "the contract from the generated file (%s)"
                               % (rel, inc, self.why))
        names = [c.name for c in all_consts()]
        names += [n for _num, n, _t, _c in CALLS if n]
        forked = [n for n in names
                  if n not in self.exempt
                  and re.search(self.LANG[self.lang] % re.escape(n), text, re.M)]
        if forked:
            return False, ("%s: redefines contract name(s) %s -- a second copy "
                           "of a single-sourced constant"
                           % (rel, ", ".join(sorted(forked))))
        return True, "%s: includes %s, redefines nothing" % (
            rel, ", ".join(self.includes))

    def negatives(self):
        """Two ways this wiring can rot, and both must be caught."""
        text = read(self.path)
        stripped = re.sub(r'^.*(#\s*include|\.include)\s+"[^"]*x816_'
                          r'(contract|kerntab)\.(h|inc)".*$', "", text,
                          flags=re.M)
        forked = {"c": '#define KERN_TABLE 0x1234',
                  "calypsi": 'KERN_TABLE:   .equ    0x1234',
                  "ca65": 'KERN_TABLE = $1234'}[self.lang]
        return [("the include removed", self.check(text=stripped)[0]),
                ("a private redefinition added",
                 self.check(text=text + "\n" + forked + "\n")[0])]


class CardLayout:
    """mksdcard.py writes the shell where goshell.c reloads it from.

    Not one literal but two halves of one path -- the directory the card
    builder creates and the file name in its image list -- so this joins them
    and compares the whole thing.
    """

    def __init__(self, path):
        self.path = path

    def label(self):
        return "%s: X816_SHELL_PATH" % os.path.relpath(self.path, PROJECTS)

    def wanted(self):
        return const("X816_SHELL_PATH").value

    def check(self, wanted=None, text=None):
        if wanted is None:
            wanted = self.wanted()
        rel = os.path.relpath(self.path, PROJECTS)
        text = read(self.path) if text is None else text
        m = re.search(r'fs\.open\("(/[A-Z]+/)"\s*\+\s*name', text)
        if not m:
            return False, ("%s: cannot find where images are written -- the "
                           "shell's path on the card is no longer checked" % rel)
        prefix = m.group(1)
        names = re.findall(r'^\s*\("([A-Z0-9_]+\.BIN)"', text, re.M)
        if not names:
            return False, "%s: no image list found" % rel
        paths = [prefix + n for n in names]
        if wanted not in paths:
            return False, ("%s: the card gets %s but nothing writes %s, which "
                           "is the path goshell.c reloads on ESC"
                           % (rel, ", ".join(paths[:3]) + "...", wanted))
        return True, "%s: the card carries %s" % (rel, wanted)

    def negatives(self):
        return [("a wrong path",
                 self.check(wanted=self.wanted() + "-NOT-THIS")[0])]


def _c(*parts):
    return os.path.join(CALYPSI, *parts)


def _e(*parts):
    return os.path.join(EMU, *parts)


def _k(*parts):
    return os.path.join(CORE, *parts)


def sites():
    S = []

    # ---- rtl: kept hand-written, because touching it means a Quartus round --
    S += [
        Site(_k("x816.sv"), "X816_PROG_BASE",
             r"localparam \[23:0\] PROG_BASE\s*=\s*(24'h[0-9a-fA-F_]+)",
             "the core writes a downloaded program here; boot.s reads it there"),
        Site(_k("x816.sv"), "X816_FW_BASE",
             r"localparam \[23:0\] FW_BASE\s*=\s*(24'h[0-9a-fA-F_]+)",
             "the core writes boot2.rom here; boot.s jumps there"),
        Site(_k("x816.sv"), "X816_IOCTL_FW",
             r"dl_is_fw\s*=\s*\(ioctl_index == (16'h[0-9a-fA-F_]+)\)",
             "the index that says 'this download is the kernel'"),
        Site(_k("x816.sv"), "X816_IOCTL_PROG",
             r"\(ioctl_index\s*==\s*(16'h[0-9a-fA-F_]+)\)\s*\|",
             "the index MiSTer's bootN.rom loop sends for boot1.rom"),
        Site(_k("x816.sv"), "X816_IOCTL_OSD_SLOT",
             r"ioctl_index\[5:0\] == 6'd(\d+)",
             "an OSD file pick lands in the slot bits",
             parse=lambda s: int(s, 10)),
        Site(_k("x816.sv"), "X816_FW_FIRST_BANK",
             r"fw_region\s*=\s*\(cpu_a\[23:20\] == 4'h([0-9a-fA-F])\)",
             "write-protect covers exactly the firmware banks",
             parse=lambda s: int(s, 16) << 4),
        Site(_k("x816.sv"), "X816_IO_PAGE",
             r"io_page\s*=\s*bank0 & \(cpu_a\[15:8\] == 8'h([0-9a-fA-F]{2})\)",
             "the I/O page is carved out of bank 0 here",
             parse=lambda s: int(s, 16) << 8),
        Site(_k("x816.sv"), "X816_BOOT_BASE",
             r"boot_page\s*=\s*bank0 & \(cpu_a\[15:8\] == 8'h([0-9a-fA-F]{2})\)",
             "the boot overlay shadows this page",
             parse=lambda s: int(s, 16) << 8),
        Site(_k("x816.sv"), "X816_SYSCTL",
             r"sysctl_cs\s*=.*cpu_a\[7:4\] == 4'h([0-9a-fA-F])\)",
             "SYSCTL decode; boot.s stores to it to drop the overlay",
             parse=lambda s: 0x9F00 | (int(s, 16) << 4)),
        # The free-running timer. Its ADDRESS and its RATE are both checked:
        # a timer at the right address ticking at the wrong rate is worse than
        # one that is missing, because TIME_GET keeps answering and every
        # answer is wrong by a constant factor nobody measures.
        Site(_k("x816.sv"), "X816_TIMER",
             r"timer_cs\s*=.*cpu_a\[7:4\] == 4'h([0-9a-fA-F]\).*cpu_a\[3:2\] == 2'b00)",
             "the millisecond counter's decode",
             parse=lambda s: 0x9F00 | (int(s[0], 16) << 4)),
        # The divider is checked in BOTH places: the module's default, and the
        # value x816.sv actually passes. Checking only the default would miss
        # a wrong override at the instantiation, and checking only the
        # instantiation would miss the module being reused elsewhere with a
        # default nobody looked at.
        Site(_k("rtl", "ms_timer.sv"), "X816_TIMER_DIV",
             r"parameter \[12:0\] TIMER_DIV\s*=\s*13'd(\d+)",
             "cpu_clk cycles per millisecond tick, the module default",
             parse=lambda s: int(s, 10)),
        Site(_k("x816.sv"), "X816_TIMER_DIV",
             r"ms_timer #\(\.TIMER_DIV\(13'd(\d+)\)\)",
             "...and the value the core actually instantiates it with",
             parse=lambda s: int(s, 10)),
    ]

    # ---- ln65816 linker scripts: Scheme, cannot include a C header ----------
    for scm in ("x816-lib.scm", "x816-plain.scm"):
        S += [
            Site(_c("runtime", scm), "X816_PROG_BASE",
                 r"\(memory X816Header \(address \((#x[0-9a-f]+) \.",
                 "the image header must sit exactly where boot.s looks"),
            Site(_c("runtime", scm), "KERN_TABLE",
                 r"\(memory HiRAM \(address \(#x[0-9a-f]+ \. #x00([0-9a-f]{4})\)\)",
                 "near objects must stop one byte below the kernel table",
                 parse=lambda s: hexint(s) + 1),
            Site(_c("runtime", scm), "KERN_STATE",
                 r"\(memory LoStack \(address \(#x[0-9a-f]+ \. #x00([0-9a-f]{4})\)\)",
                 "the program's stack must stop below the kernel's claim",
                 parse=lambda s: hexint(s) + 1),
            Site(_c("runtime", scm), "KERN_STATE_END",
                 r"\(memory LoRAM \(address \((#x[0-9a-f]+) \.",
                 "and program data must resume above it",
                 parse=lambda s: hexint(s) - 1),
        ]
    # The heap must start exactly where the program maps stop. This is the
    # check that matters most about the arena: a linker script and an
    # allocator that disagreed would hand a program's own `far` data out as
    # scratch, and nothing would say a word.
    for scm in ("x816-lib.scm", "x816-plain.scm"):
        S.append(Site(_c("runtime", scm), "X816_HEAP_TABLE",
                      r"\(memory FarRAM \(address \(#x[0-9a-f]+ \. (#x[0-9a-f]+)\)\)",
                      "the arena starts one byte above the last program region",
                      parse=lambda s: hexint(s) + 1))

    # x16lib keeps its OWN copy of the call numbers and error codes -- it has
    # to, because those modules are 65C02-era assembly generated from ACME
    # sources in a fourth repository and cannot include a Calypsi header. So
    # it is verified instead. (The editable source is
    # X816_Library/src_acme/core/const_kernel.asm; the .s here is generated
    # from it by tools/acme2calypsi.py, so fix the ACME file, not this one.)
    S.append(Site(_c("src", "core", "const_kernel.s"), "KERN_TABLE",
                  r"X816_KERN:\s+\.equ\s+(0x[0-9A-Fa-f]+)",
                  "x16lib computes every entry address from this base"))
    for num, name, _thunk, _note in CALLS:
        if not name:
            continue
        S.append(Site(_c("src", "core", "const_kernel.s"), name,
                      r"^%s:\s*\.equ\s+X816_KERN \+ (\d+)\*4" % re.escape(name),
                      "x16lib's copy of the call number",
                      parse=lambda s: int(s, 10)))
    for err in ("KERR_NOSYS", "KERR_NOTFOUND", "KERR_NOSPACE", "KERR_BADARG",
                "KERR_IO", "KERR_EXISTS", "KERR_NOTEMPTY"):
        S.append(Site(_c("src", "core", "const_kernel.s"), err,
                      r"^%s:\s*\.equ\s+(\d+)" % re.escape(err),
                      "x16lib's copy of the error code",
                      parse=lambda s: int(s, 10)))

    S += [
        Site(_c("runtime", "x816-kernel.scm"), "X816_FW_BASE",
             r"\(memory FwHeader \(address \((#x[0-9a-f]+) \.",
             "the kernel's magic header, where boot.s checks for it"),
        Site(_c("runtime", "x816-kernel.scm"), "KERN_DP",
             r"\(memory DirectPage \(address \(#x00([0-9a-f]{4}) \.",
             "kerntab.s KENTER switches D to this exact address"),
        Site(_c("runtime", "x816-kernel.scm"), "KERN_STATE_END",
             r"\(memory KernRAM \(address \(#x[0-9a-f]+ \. #x00([0-9a-f]{4})\)\)",
             "the kernel's claim ends where the program maps expect it to"),
    ]

    # ---- the magic, which is emitted as data and cannot be an equate --------
    # boot.s compares against its own copy of the string on purpose (the bytes
    # checked and the bytes shipped then cannot drift); x816hdr.s STAMPS it
    # into every image. Two different jobs, one four-byte agreement.
    for path, why in (
            (_k("boot", "boot.s"), "what boot.s decides an image by"),
            (_c("runtime", "x816hdr.s"), "what every built image starts with")):
        S.append(Site(path, "X816_MAGIC", r'\.byte\s+"([A-Z0-9]{4})"', why,
                      parse=lambda s: s))

    # ---- the card builder ---------------------------------------------------
    S += [CardLayout(_k("tools", "mksdcard.py"))]

    # ---- consumers that must take the contract from the generated files -----
    #
    # These are not value checks. They assert the WIRING: that the file pulls
    # the contract in, and that it has not grown a private second definition
    # of anything in it. A file can pass every value check in this list while
    # quietly carrying its own copy that agrees today and will not tomorrow.
    S += [
        Wired(_c("runtime", "kernel.h"), ["x816_contract.h"], "c",
              "the kernel ABI header is where callers get the call numbers"),
        Wired(_c("runtime", "shell.c"), ["x816_contract.h"], "c",
              "`run` stages at EXEC_STAGE and exec.s copies from it"),
        Wired(_c("runtime", "goshell.c"), ["x816_contract.h"], "c",
              "ESC reloads the shell by path and re-enters firmware by address"),
        Wired(_c("runtime", "kexec.c"), ["x816_contract.h"], "c",
              "K_EXEC stages at the same address `run` does"),
        Wired(_c("runtime", "kerntab.s"),
              ["x816_contract.inc", "x816_kerntab.inc"], "calypsi",
              "the table's ORDER is the ABI the header numbers"),
        Wired(_c("runtime", "kirq.s"), ["x816_contract.inc"], "calypsi",
              "the dispatcher indexes by the same KIRQ_ slot numbers the "
              "library publishes to programs"),
        Wired(_c("runtime", "kcall.s"), ["x816_contract.inc"], "calypsi",
              "kern_call computes the table address itself"),
        Wired(_c("runtime", "exec.s"), ["x816_contract.inc"], "calypsi",
              "the relocation blob has the stage, dest and entry baked in"),
        Wired(_k("boot", "boot.s"), ["x816_contract.inc"], "ca65",
              "boot.s decides which image owns the machine"),
        Wired(_e("src", "memory.h"), ["x816_contract.h"], "c",
              "the emulator's map must be the core's map"),
    ]

    return S


# ============================================================================
# Commands
# ============================================================================
def cmd_write(args):
    changed = []
    for path, produce in generated_files():
        text = produce()
        old = None
        if os.path.exists(path):
            with open(path, "r", encoding="utf-8", newline="") as f:
                old = f.read()
        if old != text:
            d = os.path.dirname(path)
            if not os.path.isdir(d):
                os.makedirs(d)
            with open(path, "w", encoding="utf-8", newline="\n") as f:
                f.write(text)
            changed.append(path)
        print("  %-6s %s" % ("write" if old != text else "same",
                             os.path.relpath(path, PROJECTS)))
    print("%d file(s) changed" % len(changed))
    return 0


def cmd_check(args):
    bad = []

    print("--- generated files ---")
    for path, produce in generated_files():
        rel = os.path.relpath(path, PROJECTS)
        if not os.path.exists(path):
            bad.append("%s: missing -- run contract.py --write" % rel)
            print("  MISSING %s" % rel)
            continue
        with open(path, "r", encoding="utf-8", newline="") as f:
            old = f.read()
        if old != produce():
            bad.append("%s: hand-edited or stale -- run contract.py --write" % rel)
            print("  STALE   %s" % rel)
        else:
            print("  ok      %s" % rel)

    print("--- verified sites (hand-written literals) ---")
    for site in sites():
        ok, msg = site.check()
        print("  %-7s %s" % ("ok" if ok else "FAIL", msg))
        if not ok:
            bad.append(msg)

    if bad:
        print("\n*** FAIL: %d contract problem(s) ***" % len(bad))
        return 1
    print("\n*** PASS: the contract is single-sourced and every site agrees ***")
    return 0


def cmd_selftest(args):
    """Negative control.

    For every verified site, feed check() a value the file cannot contain and
    require it to go red. A site that still passes is checking nothing -- a
    typo'd pattern, a regex that matches a comment, a parse that throws away
    what it read. This is the part that makes --check worth running.
    """
    failures = []
    checked = 0
    for site in sites():
        for what, still_passes in site.negatives():
            checked += 1
            if still_passes:
                failures.append("%s still PASSES with %s -- that check is "
                                "vacuous" % (site.label(), what))
                print("  VACUOUS %s (%s)" % (site.label(), what))
            else:
                print("  ok      %s goes red with %s" % (site.label(), what))

    # And the generated files: perturb the table and require --check to notice.
    print("--- generated files react to a table change ---")
    c = const("KERN_TABLE")
    saved = c.value
    c.value = 0xDEAD00
    reacted = 0
    for path, produce in generated_files():
        if not os.path.exists(path):
            continue
        with open(path, "r", encoding="utf-8", newline="") as f:
            if f.read() != produce():
                reacted += 1
    c.value = saved
    print("  %d of the generated files change when KERN_TABLE changes" % reacted)
    if reacted == 0:
        failures.append("no generated file depends on KERN_TABLE -- the "
                        "generator is not driving anything")

    if failures:
        print("\n*** FAIL: %d vacuous check(s) ***" % len(failures))
        for f in failures:
            print("   -", f)
        return 1
    print("\n*** PASS: all %d site checks fail when they should ***" % checked)
    return 0


def cmd_list(args):
    for title, _blurb, consts in GROUPS:
        print("\n== %s ==" % title)
        for c in consts:
            print("  %-22s %-18s %s" % (c.name, c.display(), c.note))
    print("\n== kernel calls ==")
    by_n = call_by_number()
    for n in sorted(by_n):
        name, thunk, note = by_n[n]
        print("  %2d  %-16s %-16s %s" % (n, name or "-", thunk, note))
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__)
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--write", action="store_true", help="regenerate")
    g.add_argument("--check", action="store_true", help="fail on drift")
    g.add_argument("--selftest", action="store_true",
                   help="prove --check can fail")
    g.add_argument("--list", action="store_true", help="print the table")
    args = p.parse_args()
    if args.write:
        return cmd_write(args)
    if args.check:
        return cmd_check(args)
    if args.selftest:
        return cmd_selftest(args)
    return cmd_list(args)


if __name__ == "__main__":
    sys.exit(main())
