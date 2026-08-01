#!/usr/bin/env python3
"""Generate the CP437 8x8 font for X816.

    python tools/mkfont.py            # -> X816_Calypsi/runtime/font_cp437.s
    python tools/mkfont.py --preview  # also dump every glyph as ASCII art

WHY GENERATED RATHER THAN IMPORTED
----------------------------------
boot/font8x8.inc says it plainly: typeface *designs* are not copyrightable
(only specific font software is), and its glyphs were written for this project,
so there is no third-party provenance to track -- consistent with the ROM-free
stance of the core. Importing a font would give that up. Every free CP437 set
carries a licence that would have to be honoured (CC BY-SA, GPL, OFL), and the
original IBM BIOS font was never released at all.

It is also less work than it sounds, because most of CP437 is mechanical:

  * $20-$5F   the 64 glyphs already in boot/font8x8.inc, reused verbatim
  * $60-$7E   lower case and the remaining ASCII punctuation, authored here
  * $B0-$DF   box drawing and blocks -- ALGORITHMIC, see box() and shade()
  * $80-$A7   accented letters -- a base glyph COMPOSITED with a diacritic
  * $E0-$FF   Greek and maths, the only substantial hand-drawn part

So roughly 70 glyphs are drawn and 180 are computed.

WHY IT EMITS ASSEMBLY
---------------------
Into a `code` section, i.e. bank $01 with the program. As a C array it would
land in bank $00 -- 2 KB of the machine's only 64 KB of fast memory, for data
that is read exactly once at boot to push into VRAM. The upload routine ships
alongside it so the data never has to be addressed from C, which Calypsi cannot
do for a `cdata` symbol anyway.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CORE = os.path.dirname(HERE)
CALYPSI = os.path.join(os.path.dirname(CORE), "X816_Calypsi")

W, H = 8, 8


def blank():
    return [0] * H


def from_art(rows):
    """8 strings of 8 chars; '#' or any non-'.' is a set pixel, MSB left."""
    out = []
    for r in rows:
        v = 0
        for i, c in enumerate(r[:W]):
            if c not in ".- ":
                v |= 0x80 >> i
        out.append(v)
    while len(out) < H:
        out.append(0)
    return out[:H]


# ---------------------------------------------------------------------------
# $20-$5F: reuse the glyphs already proven on hardware.
# ---------------------------------------------------------------------------
def load_existing():
    path = os.path.join(CORE, "boot", "font8x8.inc")
    vals = []
    for line in open(path, encoding="utf-8"):
        m = re.match(r"\s*\.byte\s+(.*)$", line.split(";")[0])
        if m:
            vals += [int(x.strip().lstrip("$"), 16)
                     for x in m.group(1).split(",") if x.strip()]
    if len(vals) != 64 * 8:
        raise SystemExit("font8x8.inc: expected 512 bytes, got %d" % len(vals))
    return {0x20 + i: vals[i * 8:(i + 1) * 8] for i in range(64)}


# ---------------------------------------------------------------------------
# Box drawing, $B3-$DA.
#
# Each glyph is described by how many lines leave the cell in each direction:
# 0 none, 1 single, 2 double. Everything else falls out of that.
#
# A single line runs along the centre rail (row/col 3). A double line runs
# along rails 2 and 4. The interesting part is where they meet: an arm must
# stop at the perpendicular rail that CLOSES it, or the corner fills in and
# looks like a blob.
#
# Which rail closes it depends on the quadrant. For a corner opening
# down+right or up+left the rails pair straight across (outer to outer); for
# down+left or up+right they cross. Getting this wrong is the difference
# between a box that looks drawn and one that looks smudged.
# ---------------------------------------------------------------------------
BOX = {
    0xB3: (1, 1, 0, 0), 0xB4: (1, 1, 1, 0), 0xB5: (1, 1, 2, 0),
    0xB6: (2, 2, 1, 0), 0xB7: (0, 2, 1, 0), 0xB8: (0, 1, 2, 0),
    0xB9: (2, 2, 2, 0), 0xBA: (2, 2, 0, 0), 0xBB: (0, 2, 2, 0),
    0xBC: (2, 0, 2, 0), 0xBD: (2, 0, 1, 0), 0xBE: (1, 0, 2, 0),
    0xBF: (0, 1, 1, 0), 0xC0: (1, 0, 0, 1), 0xC1: (1, 0, 1, 1),
    0xC2: (0, 1, 1, 1), 0xC3: (1, 1, 0, 1), 0xC4: (0, 0, 1, 1),
    0xC5: (1, 1, 1, 1), 0xC6: (1, 1, 0, 2), 0xC7: (2, 2, 0, 1),
    0xC8: (2, 0, 0, 2), 0xC9: (0, 2, 0, 2), 0xCA: (2, 0, 2, 2),
    0xCB: (0, 2, 2, 2), 0xCC: (2, 2, 0, 2), 0xCD: (0, 0, 2, 2),
    0xCE: (2, 2, 2, 2), 0xCF: (1, 0, 2, 2), 0xD0: (2, 0, 1, 1),
    0xD1: (0, 1, 2, 2), 0xD2: (0, 2, 1, 1), 0xD3: (2, 0, 0, 1),
    0xD4: (1, 0, 0, 2), 0xD5: (0, 1, 0, 2), 0xD6: (0, 2, 0, 1),
    0xD7: (2, 2, 1, 1), 0xD8: (1, 1, 2, 2), 0xD9: (1, 0, 1, 0),
    0xDA: (0, 1, 0, 1),
}


def rails(n):
    return [3] if n == 1 else ([2, 4] if n == 2 else [])


def box(u, d, l, r):
    px = [[0] * W for _ in range(H)]
    vr, hr = rails(max(u, d)), rails(max(l, r))

    def hspan(row, c0, c1):
        for c in range(min(c0, c1), max(c0, c1) + 1):
            px[row][c] = 1

    def vspan(col, r0, r1):
        for rr in range(min(r0, r1), max(r0, r1) + 1):
            px[rr][col] = 1

    # A straight run with nothing crossing it: full width/height.
    if not hr:
        for c in vr:
            if u:
                vspan(c, 0, 3 if not d else H - 1)
            if d:
                vspan(c, 0 if u else 3, H - 1)
    if not vr:
        for rr in hr:
            if l:
                hspan(rr, 0, 3 if not r else W - 1)
            if r:
                hspan(rr, 0 if l else 3, W - 1)

    if vr and hr:
        # Pair the rails. Straight across for down+right / up+left, crossed
        # for down+left / up+right -- see the note above.
        for i, c in enumerate(vr):
            for j, rr in enumerate(hr):
                pass
        n = max(len(vr), len(hr))

        def pair(idx, seq):
            if len(seq) == 1:
                return seq[0]
            return seq[idx if straight else (len(seq) - 1 - idx)]

        straight = (bool(d) and bool(r)) or (bool(u) and bool(l))
        # Vertical arms stop at their partner horizontal rail.
        for i, c in enumerate(vr):
            stop = pair(i, hr)
            if u:
                vspan(c, 0, stop)
            if d:
                vspan(c, stop, H - 1)
            if u and d:
                vspan(c, 0, H - 1)
        straight = (bool(d) and bool(r)) or (bool(u) and bool(l))
        for j, rr in enumerate(hr):
            stop = pair(j, vr)
            if l:
                hspan(rr, 0, stop)
            if r:
                hspan(rr, stop, W - 1)
            if l and r:
                hspan(rr, 0, W - 1)

    return [sum(0x80 >> c for c in range(W) if px[row][c]) for row in range(H)]


# ---------------------------------------------------------------------------
# Blocks and shading, $B0-$B2 and $DB-$DF.
# ---------------------------------------------------------------------------
def shade(kind):
    out = []
    for y in range(H):
        v = 0
        for x in range(W):
            if kind == 1:
                on = (x % 4 == 0 and y % 2 == 0) or (x % 4 == 2 and y % 2 == 1)
            elif kind == 2:
                on = (x + y) % 2 == 0
            else:
                on = not ((x % 4 == 0 and y % 2 == 0) or
                          (x % 4 == 2 and y % 2 == 1))
            if on:
                v |= 0x80 >> x
        out.append(v)
    return out


def block(left=0, right=W, top=0, bottom=H):
    out = []
    for y in range(H):
        v = 0
        if top <= y < bottom:
            for x in range(left, right):
                v |= 0x80 >> x
        out.append(v)
    return out


# ---------------------------------------------------------------------------
# Accents: a base glyph pushed down a row, with a mark dropped in above.
# ---------------------------------------------------------------------------
ACUTE = from_art(["...##...", "..##....", "........", "........",
                  "........", "........", "........", "........"])
GRAVE = from_art(["..##....", "...##...", "........", "........",
                  "........", "........", "........", "........"])
CIRC = from_art(["..###...", ".##.##..", "........", "........",
                 "........", "........", "........", "........"])
DIAER = from_art([".##.##..", "........", "........", "........",
                  "........", "........", "........", "........"])
TILDE = from_art(["..##.##.", ".##.##..", "........", "........",
                  "........", "........", "........", "........"])
RING = from_art(["...##...", "..#..#..", "...##...", "........",
                 "........", "........", "........", "........"])
CEDIL = from_art(["........", "........", "........", "........",
                  "........", "........", "........", "..####.."])


def accent(base, mark, shift=2):
    """Push the base down by `shift` rows and OR the mark on top."""
    out = [0] * H
    for i, v in enumerate(base):
        if i + shift < H:
            out[i + shift] |= v
    for i, v in enumerate(mark):
        out[i] |= v
    return out


def below(base, mark):
    return [a | b for a, b in zip(base, mark)]


def main():
    g = load_existing()

    # ---- $60-$7E: lower case and the rest of ASCII -------------------------
    art = {
        0x60: ["..##....", "...##...", "........", "........",
               "........", "........", "........", "........"],
        0x61: ["........", "........", ".####...", "....##..",
               ".#####..", "##..##..", ".###.##.", "........"],
        0x62: ["##......", "##......", "#####...", "##..##..",
               "##..##..", "##..##..", "#####...", "........"],
        0x63: ["........", "........", ".#####..", "##......",
               "##......", "##......", ".#####..", "........"],
        0x64: ["....##..", "....##..", ".#####..", "##..##..",
               "##..##..", "##..##..", ".#####..", "........"],
        0x65: ["........", "........", ".####...", "##..##..",
               "######..", "##......", ".#####..", "........"],
        0x66: ["..####..", ".##.....", "#####...", ".##.....",
               ".##.....", ".##.....", ".##.....", "........"],
        0x67: ["........", "........", ".#####..", "##..##..",
               "##..##..", ".#####..", "....##..", "#####..."],
        0x68: ["##......", "##......", "#####...", "##..##..",
               "##..##..", "##..##..", "##..##..", "........"],
        0x69: ["..##....", "........", ".###....", "..##....",
               "..##....", "..##....", ".####...", "........"],
        0x6A: ["....##..", "........", "...###..", "....##..",
               "....##..", "##..##..", ".####...", "........"],
        0x6B: ["##......", "##......", "##..##..", "##.##...",
               "####....", "##.##...", "##..##..", "........"],
        0x6C: [".###....", "..##....", "..##....", "..##....",
               "..##....", "..##....", ".####...", "........"],
        0x6D: ["........", "........", "##.##...", "#######.",
               "##.#.##.", "##.#.##.", "##.#.##.", "........"],
        0x6E: ["........", "........", "#####...", "##..##..",
               "##..##..", "##..##..", "##..##..", "........"],
        0x6F: ["........", "........", ".####...", "##..##..",
               "##..##..", "##..##..", ".####...", "........"],
        0x70: ["........", "........", "#####...", "##..##..",
               "##..##..", "#####...", "##......", "##......"],
        0x71: ["........", "........", ".#####..", "##..##..",
               "##..##..", ".#####..", "....##..", "....##.."],
        0x72: ["........", "........", "##.###..", ".###.##.",
               ".##.....", ".##.....", "####....", "........"],
        0x73: ["........", "........", ".#####..", "##......",
               ".####...", "....##..", "#####...", "........"],
        0x74: [".##.....", ".##.....", "#####...", ".##.....",
               ".##.....", ".##.##..", "..###...", "........"],
        0x75: ["........", "........", "##..##..", "##..##..",
               "##..##..", "##..##..", ".###.##.", "........"],
        0x76: ["........", "........", "##..##..", "##..##..",
               "##..##..", ".####...", "..##....", "........"],
        0x77: ["........", "........", "##...##.", "##.#.##.",
               "##.#.##.", "#######.", ".##.##..", "........"],
        0x78: ["........", "........", "##..##..", ".####...",
               "..##....", ".####...", "##..##..", "........"],
        0x79: ["........", "........", "##..##..", "##..##..",
               "##..##..", ".#####..", "....##..", "#####..."],
        0x7A: ["........", "........", "######..", "...##...",
               "..##....", ".##.....", "######..", "........"],
        0x7B: ["...###..", "..##....", "..##....", "###.....",
               "..##....", "..##....", "...###..", "........"],
        0x7C: ["..##....", "..##....", "..##....", "........",
               "..##....", "..##....", "..##....", "........"],
        0x7D: ["###.....", "..##....", "..##....", "...###..",
               "..##....", "..##....", "###.....", "........"],
        0x7E: [".###.##.", "##.###..", "........", "........",
               "........", "........", "........", "........"],
        0x7F: ["...##...", "..####..", ".##..##.", "##....##",
               "##....##", "########", "........", "........"],
        # A few of the $00-$1F pictures that earn their place: arrows for a
        # UI, and the card suits because they cost nothing.
        0x10: ["........", "##......", "####....", "######..",
               "####....", "##......", "........", "........"],
        0x11: ["........", "....##..", "..####..", "######..",
               "..####..", "....##..", "........", "........"],
        0x18: ["...##...", "..####..", ".##..##.", "...##...",
               "...##...", "...##...", "........", "........"],
        0x19: ["...##...", "...##...", "...##...", ".##..##.",
               "..####..", "...##...", "........", "........"],
        0x1A: ["........", "...#....", "....#...", "#######.",
               "....#...", "...#....", "........", "........"],
        0x1B: ["........", "...#....", "..#.....", "#######.",
               "..#.....", "...#....", "........", "........"],
        0x1E: ["........", "...##...", "..####..", ".######.",
               "........", "........", "........", "........"],
        0x1F: ["........", "........", ".######.", "..####..",
               "...##...", "........", "........", "........"],
    }
    for code, rows in art.items():
        g[code] = from_art(rows)

    # ---- $B0-$B2 shading, $DB-$DF blocks -----------------------------------
    g[0xB0], g[0xB1], g[0xB2] = shade(1), shade(2), shade(3)
    g[0xDB] = block()
    g[0xDC] = block(top=4)
    g[0xDD] = block(right=4)
    g[0xDE] = block(left=4)
    g[0xDF] = block(bottom=4)
    g[0xFE] = block(2, 6, 2, 6)      # centred square

    # ---- $B3-$DA box drawing ----------------------------------------------
    for code, spec in BOX.items():
        g[code] = box(*spec)

    # ---- $80-$A7 accented letters -----------------------------------------
    acc = [
        (0x80, 0x43, CEDIL, 0), (0x81, 0x75, DIAER, 1), (0x82, 0x65, ACUTE, 1),
        (0x83, 0x61, CIRC, 1),  (0x84, 0x61, DIAER, 1), (0x85, 0x61, GRAVE, 1),
        (0x86, 0x61, RING, 1),  (0x87, 0x63, CEDIL, 0), (0x88, 0x65, CIRC, 1),
        (0x89, 0x65, DIAER, 1), (0x8A, 0x65, GRAVE, 1), (0x8B, 0x69, DIAER, 1),
        (0x8C, 0x69, CIRC, 1),  (0x8D, 0x69, GRAVE, 1), (0x8E, 0x41, DIAER, 2),
        (0x8F, 0x41, RING, 2),  (0x90, 0x45, ACUTE, 2), (0x93, 0x6F, CIRC, 1),
        (0x94, 0x6F, DIAER, 1), (0x95, 0x6F, GRAVE, 1), (0x96, 0x75, CIRC, 1),
        (0x97, 0x75, GRAVE, 1), (0x98, 0x79, DIAER, 1), (0x99, 0x4F, DIAER, 2),
        (0x9A, 0x55, DIAER, 2), (0xA0, 0x61, ACUTE, 1), (0xA1, 0x69, ACUTE, 1),
        (0xA2, 0x6F, ACUTE, 1), (0xA3, 0x75, ACUTE, 1), (0xA4, 0x6E, TILDE, 1),
        (0xA5, 0x4E, TILDE, 2),
    ]
    for code, base, mark, shift in acc:
        if mark is CEDIL:
            g[code] = below(g[base], mark)
        else:
            g[code] = accent(g[base], mark, shift)

    # ---- the rest, hand drawn ---------------------------------------------
    rest = {
        0x9B: ["...##...", "..####..", ".##.....", ".##.....",
               ".##.....", "..####..", "...##...", "........"],   # cent
        0x9C: ["..###...", ".##.##..", ".##.....", "####....",
               ".##.....", ".##.##..", "#######.", "........"],   # pound
        0x9D: ["##...##.", "##...##.", ".##.##..", "#######.",
               "..###...", "#######.", "..###...", "........"],   # yen
        0x9F: ["...###..", "..##.##.", "..##....", ".####...",
               "..##....", "..##....", "####....", "........"],   # florin
        0xA6: ["..###...", "....##..", "..####..", "##..##..",
               "..####..", "........", "######..", "........"],   # ordinal a
        0xA7: ["..###...", ".##.##..", ".##.##..", "..###...",
               "........", "######..", "........", "........"],   # ordinal o
        0xA8: ["...##...", "........", "...##...", "..##....",
               "##......", "##..##..", ".####...", "........"],   # inverted ?
        0xA9: ["........", "........", "######..", "##......",
               "##......", "........", "........", "........"],   # not, mirrored
        0xAA: ["........", "........", "######..", "....##..",
               "....##..", "........", "........", "........"],   # not
        0xAB: ["##...##.", "##..##..", "##.##...", "..##.##.",
               ".##.###.", "##.####.", "......##", "........"],   # 1/2
        0xAC: ["##...##.", "##..##..", "##.##...", "..##.##.",
               ".##.####", "##....##", "....####", "........"],   # 1/4
        0xAD: ["...##...", "........", "...##...", "...##...",
               "...##...", "...##...", "...##...", "........"],   # inverted !
        0xAE: ["........", "..##.##.", ".##.##..", "##.##...",
               ".##.##..", "..##.##.", "........", "........"],   # <<
        0xAF: ["........", "##.##...", ".##.##..", "..##.##.",
               ".##.##..", "##.##...", "........", "........"],   # >>
        0xE0: ["........", "........", ".###.##.", "##.###..",
               "##..##..", "##.###..", ".###.##.", "........"],   # alpha
        0xE1: [".#####..", "##...##.", "##...##.", "#####...",
               "##...##.", "##...##.", "#####...", "##......"],   # sharp s
        0xE2: ["#######.", "##...##.", "##......", "##......",
               "##......", "##......", "##......", "........"],   # Gamma
        0xE3: ["........", "########", ".##..##.", ".##..##.",
               ".##..##.", ".##..##.", ".##..##.", "........"],   # pi
        0xE4: ["#######.", "##...##.", "...##...", "..##....",
               "...##...", "##...##.", "#######.", "........"],   # Sigma
        0xE5: ["........", "........", ".#####..", "##..##..",
               "##..##..", "##..##..", ".####...", "........"],   # sigma
        0xE6: ["........", "........", "##..##..", "##..##..",
               "##..##..", "#####...", "##......", "##......"],   # mu
        0xE7: ["........", "########", "..##....", "..##....",
               "..##....", "..##.##.", "...###..", "........"],   # tau
        0xE8: ["..####..", ".##..##.", "##.##.##", "##.##.##",
               "##.##.##", ".##..##.", "..####..", "........"],   # Phi
        0xE9: ["..####..", ".##..##.", "##.##.##", "##.##.##",
               ".##..##.", "..####..", "........", "........"],   # Theta
        0xEA: ["..####..", ".##..##.", "##....##", "##....##",
               ".##..##.", "##....##", "##....##", "........"],   # Omega
        0xEC: ["........", "........", ".##..##.", "##.##.##",
               "##.##.##", ".##..##.", "........", "........"],   # infinity
        0xF0: ["........", "########", "........", "########",
               "........", "########", "........", "........"],   # identical
        0xF1: ["...##...", "...##...", ".######.", "...##...",
               "...##...", ".######.", "........", "........"],   # plus-minus
        0xF2: ["..##....", "...##...", "....##..", ".....##.",
               "....##..", "...##...", "..##....", "######.."],   # >=
        0xF3: ["....##..", "...##...", "..##....", ".##.....",
               "..##....", "...##...", "....##..", "######.."],   # <=
        0xF7: ["........", ".###.##.", "##.###..", "........",
               ".###.##.", "##.###..", "........", "........"],   # approx
        0xF8: ["..###...", ".##.##..", ".##.##..", "..###...",
               "........", "........", "........", "........"],   # degree
        0xF9: ["........", "........", "..####..", "..####..",
               "..####..", "........", "........", "........"],   # bullet
        0xFA: ["........", "........", "........", "...##...",
               "........", "........", "........", "........"],   # middle dot
        0xFB: ["....####", "....##..", "....##..", "....##..",
               "##..##..", "##..##..", ".####...", "........"],   # sqrt
        0xFC: [".####...", "##..##..", "##..##..", "##..##..",
               "##..##..", "........", "........", "........"],   # superscript n
        0xFD: [".####...", "##..##..", "...##...", "..##....",
               "######..", "........", "........", "........"],   # superscript 2
        0xF6: ["........", "...##...", "........", "######..",
               "........", "...##...", "........", "........"],   # divide
    }
    for code, rows in rest.items():
        g[code] = from_art(rows)

    # $FF is a non-breaking space in CP437: blank, deliberately.
    for c in range(256):
        g.setdefault(c, blank())

    if "--preview" in sys.argv:
        for c in range(256):
            print("--- $%02X ---" % c)
            for v in g[c]:
                print("".join("#" if v & (0x80 >> i) else "." for i in range(8)))
        return

    out = os.path.join(CALYPSI, "runtime", "font_cp437.s")
    with open(out, "w", newline="\n", encoding="utf-8") as f:
        f.write(HEADER)
        for c in range(256):
            f.write("              .byte   %s   ; $%02X\n"
                    % (",".join("0x%02X" % v for v in g[c]), c))
        f.write(FOOTER)

    drawn = len(art) + len(rest)
    print("%s: 256 glyphs, 2048 bytes (%d drawn, %d generated)"
          % (out, drawn + 64, 256 - drawn - 64))


HEADER = '''; ============================================================================
; font_cp437.s -- the full 256-glyph CP437 character set, 8x8, 1bpp.
;
; GENERATED by X816_core/tools/mkfont.py. Do not edit: regenerate.
;
; IN A CODE SECTION, NOT A C ARRAY, and that is the point. As a C array this
; would land in bank $00 -- 2 KB of the machine's only 64 KB of fast memory,
; for data read exactly once at boot and pushed into VRAM. Here it rides in
; bank $01 with the program and costs bank $00 nothing.
;
; That also sidesteps a Calypsi limitation: a `cdata` symbol's address cannot
; be formed in C (the compiler builds even a __far pointer from a 16-bit
; immediate), so the upload loop lives here too and C never has to name the
; data at all.
;
; Layout is VERA's 1bpp tile format: 8 bytes per glyph, one per scanline,
; MSB = leftmost pixel. Glyph N sits at TILE_BASE + N*8, so the tile index in
; a map entry IS the character code.
; ============================================================================

              .rtmodel version, "1"
              .rtmodel core, "65816"
              .rtmodel codeModel, "large"

              .public font_cp437_upload

VERA_ADDR_L:  .equ    0x9F20
VERA_ADDR_M:  .equ    0x9F21
VERA_ADDR_H:  .equ    0x9F22
VERA_DATA0:   .equ    0x9F23
VERA_CTRL:    .equ    0x9F25

; $04000, matching TILE_VRAM in console.c. Glyph 0 starts here, so unlike the
; old 64-glyph font there is no $20 bias to subtract.
TILE_VRAM_L:  .equ    0x00
TILE_VRAM_M:  .equ    0x40
TILE_VRAM_H:  .equ    0x10            ; bank 0, auto-increment 1

              .section code

; ----------------------------------------------------------------------------
; void font_cp437_upload(void);
;
; Stream all 2048 bytes into VRAM. Entered from C by jsl with 16-bit A and
; index registers, and returns the same way.
; ----------------------------------------------------------------------------
font_cp437_upload:
              phx
              php
              sep     #0x20                   ; 8-bit A
              rep     #0x10                   ; 16-bit X

              lda     #0
              sta     VERA_CTRL
              lda     #TILE_VRAM_L
              sta     VERA_ADDR_L
              lda     #TILE_VRAM_M
              sta     VERA_ADDR_M
              lda     #TILE_VRAM_H
              sta     VERA_ADDR_H

              ldx     ##0
font_upload_loop:
              lda     long:font_cp437_data,x
              sta     VERA_DATA0
              inx
              cpx     ##2048
              bne     font_upload_loop

              plp
              plx
              rtl

font_cp437_data:
'''

FOOTER = '''
; 2048 bytes exactly: 256 glyphs of 8.
'''


if __name__ == "__main__":
    main()
