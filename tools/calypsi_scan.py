#!/usr/bin/env python3
# ============================================================================
# calypsi_scan.py -- find the Calypsi 5.18 sign-extension miscompile in the
# tree, and fail if a NEW one appears.
#
#   python tools/calypsi_scan.py --check     fail on an unexpected site (CI)
#   python tools/calypsi_scan.py --list      show every site with its verdict
#   python tools/calypsi_scan.py --selftest  prove --check can actually fail
#
# THE BUG
# -------
# Calypsi 5.18 compiles
#
#     <byte loaded from memory>  ==  (unsigned char)(<expression>)
#
# as a SIXTEEN-bit comparison with mismatched extensions. The loaded byte is
# zero-extended:
#
#     lda [.tiny _Dp] / and ##255          -> $00EE
#
# while the cast expression gets the SIGNED-char promotion idiom:
#
#     eor ##128 / and ##255 / sec / sbc ##128   -> $FFEE
#
# so any value with bit 7 set compares unequal to itself. Values below $80
# are unaffected, which is why it presents as intermittent: in the run that
# found it, `sig ^ 0x5A` = $4B passed and `sig ^ 0xFF` = $EE failed, in
# adjacent lines of the same function.
#
# WHAT TRIGGERS IT, measured rather than assumed (doc/AUDIT.md 6.2):
#
#   fires        (unsigned char)(expr) against a byte from memory, for EVERY
#                storage class -- parameter, local, static, array element,
#                struct member, function return value
#   does NOT     a cast with no expression, `(uint8_t)x`
#   does NOT     an expression with no cast, `x ^ 0xFF`
#   does NOT     comparison against a CONSTANT, which compiles 8-bit
#   does NOT     `(expr) & 0xFF`  <- the fix
#   does NOT     an expression the compiler knows cannot set bit 7, e.g. >>1
#
# So the rule is: **mask with `& 0xFF`, do not cast with `(unsigned char)`,
# when the result meets another byte.** Copying the value to a local first
# does NOT help, and neither does the storage class -- both were tried.
#
# WHY A SCANNER AND NOT A REWRITE
# -------------------------------
# The three sites below are all HARMLESS, each by a value-range argument that
# happens to hold. That is exactly the kind of safety this project has learned
# not to leave unwritten: it is true today, nothing checks it, and the next
# edit to a mask or a loop bound turns it into a silent wrong answer. So the
# arguments are written down here and a FOURTH site is an error.
# ============================================================================

import argparse
import glob
import io
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CORE = os.path.dirname(HERE)
PROJECTS = os.path.dirname(CORE)
CALYPSI = os.environ.get("CALYPSI_REPO", os.path.join(PROJECTS, "X816_Calypsi"))
CC = os.path.join(CALYPSI, "Calypsi", "calypsi-65816-5.18", "bin", "cc65816.exe")
RT = os.path.join(CALYPSI, "runtime")

# The signature. `sbc ##128` after `eor ##128 / and ##255` is the compiler's
# signed-char promotion; on an UNSIGNED char it is the bug.
SIGNATURE = "sbc     ##128"

# ---------------------------------------------------------------------------
# Known sites, each with the argument for why it cannot bite. A site here that
# stops appearing is also reported -- it means the code changed and the
# justification below is now describing something that is not there.
# ---------------------------------------------------------------------------
#
# NOT EVERY HIT IS THE BUG. The signature also matches a genuine SIGNED
# right-shift, where sign extension is what C asks for -- see the fxtest.c
# entries below. So a new hit needs the same two questions answered as any
# other: can the value have bit 7 set, and does anything compare or widen it?
# Do not add an entry without writing the answer.
KNOWN = {
    ("runtime/fat32.c", "up"):
        "the cast runs only on 'a'-'z', so the result is $41-$5A and bit 7 "
        "is never set",
    ("examples/vera/fxtest.c", "fx_set_incr"):
        "NOT the miscompile: `ix`/`iy` are int16_t and `>> 8` on a signed "
        "value is an arithmetic shift, which is what C specifies. The result "
        "is masked with 0x7F (bit 7 can never be set) and stored to a "
        "volatile uint8_t, so only the low byte reaches the register either "
        "way. Two hits, one per axis.",
    ("examples/shell/keyscan.c", "main"):
        "(r & 0x7F) cannot set bit 7 by construction",
    ("examples/shell/shtest.c", "main"):
        "(i + 1) over a loop of 0..7, so the values are 1..8",
}


def sources():
    out = sorted(glob.glob(os.path.join(RT, "*.c")))
    for d in sorted(glob.glob(os.path.join(CALYPSI, "examples", "*"))):
        if os.path.isdir(d):
            out += sorted(glob.glob(os.path.join(d, "*.c")))
    return out


def scan(tmpdir):
    """-> list of (relpath, function, attributed source line)."""
    found = []
    for src in sources():
        stem = os.path.basename(src)[:-2]
        asm = os.path.join(tmpdir, "sx_%s.s" % stem)
        r = subprocess.run(
            [CC, "--core=65816", "--code-model=large", "--data-model=small",
             "-O0", "-I", RT, "--assembly-source", asm, src,
             "-o", os.path.join(tmpdir, "sx_%s.o" % stem)],
            capture_output=True, text=True)
        if r.returncode:
            continue            # not compilable on its own; nothing to scan
        text = io.open(asm, encoding="utf-8", errors="replace").read()
        fn, cline = "?", "?"
        for line in text.split("\n"):
            m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):", line)
            if m:
                fn = m.group(1)
            c = re.match(r"^;\s{2,}(\S.*)$", line)
            if c:
                cline = c.group(1).strip()
            if SIGNATURE in line:
                rel = os.path.relpath(src, CALYPSI).replace("\\", "/")
                found.append((rel, fn, cline))
    return found


def tmpdir():
    import tempfile
    return tempfile.mkdtemp(prefix="calypsi_scan_")


def cmd_list(args):
    d = tmpdir()
    for rel, fn, cline in scan(d):
        why = KNOWN.get((rel, fn), "*** NOT IN THE KNOWN LIST ***")
        print("  %s  %s()" % (rel, fn))
        print("      %s" % cline[:74])
        print("      %s" % why)
    return 0


def cmd_check(args):
    d = tmpdir()
    found = scan(d)
    seen = set()
    bad = []
    for rel, fn, cline in found:
        key = (rel, fn)
        seen.add(key)
        if key not in KNOWN:
            bad.append("NEW sign-extension site: %s %s()  --  %s"
                       % (rel, fn, cline[:60]))
            print("  NEW     %s %s()" % (rel, fn))
        else:
            print("  known   %s %s()" % (rel, fn))
    for key in KNOWN:
        if key not in seen:
            bad.append("%s %s() no longer has the site the allow-list "
                       "justifies -- remove the entry, do not leave it "
                       "describing code that is gone" % key)
            print("  GONE    %s %s()" % key)

    if bad:
        print("\n*** FAIL: %d problem(s) ***" % len(bad))
        for b in bad:
            print("   -", b)
        print("\nA new site is not automatically a bug -- it is a bug only if "
              "the value can have bit 7 set. Work that out, and either fix it "
              "with `& 0xFF` or add it to KNOWN with the argument.")
        return 1
    print("\n*** PASS: %d known-harmless site(s), no new ones ***" % len(found))
    return 0


def cmd_selftest(args):
    """Negative control: plant the pattern and require --check to notice.

    A scanner that has only ever been run on a clean tree is a scanner nobody
    should trust -- if the signature string were wrong, or the compile step
    silently failed, this would print PASS for ever.
    """
    d = tmpdir()
    probe = os.path.join(RT, "zz_calypsi_selftest.c")
    io.open(probe, "w", encoding="utf-8", newline="\n").write(
        "/* TEMPORARY: planted by tools/calypsi_scan.py --selftest. */\n"
        "extern unsigned char __far *g;\n"
        "int zz_probe(unsigned char v) "
        "{ return g[0] == (unsigned char)(v ^ 0xFF); }\n")
    try:
        found = scan(d)
        hit = [f for f in found if f[0].endswith("zz_calypsi_selftest.c")]
        if not hit:
            print("*** FAIL: the scanner did not find a PLANTED site. It is "
                  "not detecting anything -- check the signature string and "
                  "that the compile step actually runs. ***")
            return 1
        print("  planted site detected: %s %s()" % (hit[0][0], hit[0][1]))
        # And the clean-tree control: the same file without the cast.
        io.open(probe, "w", encoding="utf-8", newline="\n").write(
            "extern unsigned char __far *g;\n"
            "int zz_probe(unsigned char v) "
            "{ return g[0] == ((v ^ 0xFF) & 0xFF); }\n")
        found = scan(d)
        if [f for f in found if f[0].endswith("zz_calypsi_selftest.c")]:
            print("*** FAIL: the `& 0xFF` form was flagged too, so the "
                  "signature does not distinguish the bug from the fix ***")
            return 1
        print("  the `& 0xFF` form is NOT flagged, so the two are told apart")
    finally:
        if os.path.exists(probe):
            os.remove(probe)
    print("\n*** PASS: the scan detects the pattern and clears its fix ***")
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__)
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--check", action="store_true")
    g.add_argument("--list", action="store_true")
    g.add_argument("--selftest", action="store_true")
    a = p.parse_args()
    if not os.path.exists(CC):
        print("calypsi_scan: no toolchain at %s -- skipping" % CC)
        return 0
    if a.check:
        return cmd_check(a)
    if a.selftest:
        return cmd_selftest(a)
    return cmd_list(a)


if __name__ == "__main__":
    sys.exit(main())
