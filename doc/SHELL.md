# X816 — the boot shell

What the machine comes up in: a prompt that loads programs, moves around the
filesystem and inspects memory.

**Planned. None of this is built.** Written before the code, as
[VERA816.md](VERA816.md), [KERNEL.md](KERNEL.md) and
[DUREXFORTH.md](DUREXFORTH.md) were. It sits on
[KERNEL.md](KERNEL.md) §5 — console and filesystem — and nothing else.

---

## 1. A shell, not a language

The prompt's job, from [KERNEL.md](KERNEL.md) §1, is to load programs and
manage directories and files. That is a **fixed command set**, not a
programming language, and building it as one is both smaller and sooner.

Three candidates were weighed:

| | Fits the prompt | Cost |
|---|---|---|
| **Shell** | `load prog.bin`, `cd /games`, `ls` — the syntax *is* the job | a few hundred lines; no interpreter, no allocator, no performance problem |
| **Tcl** | same shape, plus real scripting: variables, loops, `proc` | a ~600-line core is the easy part; a heap allocator with free and fragmentation handling is the real work, and everything-is-a-string is slow on an 8 MHz CPU with SDRAM stalls |
| **Forth** | `s" prog.bin" load` — RPN is a barrier for the prompt's actual users, and it is the wrong shape for "verb noun" commands | see [DUREXFORTH.md](DUREXFORTH.md); excellent as a *system* tool, poor as a shell |

So: shell first. **Tcl is the upgrade path, not the alternative** — see §7.

A useful thing that fell out of checking Tcl, recorded here because it is
non-obvious and applies to everything above: **`__far` pointers work in
Calypsi's small data model**, generating true long addressing
(`sta [.tiny (_Dp+4)]`, opcode `$87`). The C library's `malloc` returns a near
pointer and so is capped at bank `$00`, but that limit binds only the C heap —
any component willing to manage its own storage can reach the whole 16 MB
without changing the data model, and without disturbing the x16lib setup that
depends on it.

---

## 2. Where it lives

Kernel, by [KERNEL.md](KERNEL.md) §2.1 test 1: the shell owns the console when
no program has taken it, and it is what a program returns to on `EXIT`. Two
copies of that would fight over the screen and the keyboard queue.

But by §2.2 — policy, not mechanism — only the *ownership* is kernel-shaped.
The command implementations are ordinary calls onto §5, and the parser is
ordinary code. Keep them separable; §6 depends on it.

---

## 3. Command set

Deliberately small. Everything here is a thin wrapper over
[KERNEL.md](KERNEL.md) §5.

All of the file and directory commands below are **confirmed working on real
MiSTer hardware**, not only in the emulator.

**Files**

| | |
|---|---|
| `ls [path]`, `dir [path]` | directory listing — `DIR_OPEN`/`DIR_NEXT`. Two names for one handler: an alias earns its own table row rather than a special case in the parser, so it inherits argument checking and shows up in `help` |
| `cd path`, `pwd` | working directory |
| `type file` | dump a file to the console |
| `del file` | delete a file |
| `copy src dst` | copy through a small buffer; the machine has no room to hold a whole file and no need to |
| `rename old new` | rename in place. `new` is a bare name, not a path — moving between directories rewrites the entry elsewhere, which is a different operation. Works on directories too: only the name field changes, so the chain and the `.`/`..` entries are untouched |
| `mkdir path` | create a directory. The new cluster is zeroed and seeded with its own `.` and `..`; a directory without them is unnavigable from inside. `..` stores cluster **0** when the parent is the root, which is how FAT32 spells it — writing the real root cluster number builds a tree `chkdsk` rejects |
| `rmdir path` | remove an **empty** directory. Refusing a non-empty one is the invariant that stops every file inside being stranded, so it lives in the filesystem rather than the command |

**Programs**

| | |
|---|---|
| `run file` | `EXEC` — load and go |
| `load file [addr]` | load without running, for inspection |
| `save file addr len` | write memory out as a file |

**Memory** — this is where a bare machine earns its keep

| | |
|---|---|
| `dump addr [len]` | hex + ASCII, 24-bit addresses |
| `peek addr`, `poke addr val` | single bytes |
| `fill addr len val`, `move dst src len` | block operations |

Memory commands are not a luxury. There is no debugger and no monitor, and
`dump 01:0000` is how you check that a program loaded where you thought. This
is the one thing Forth would have given for free, and it costs a few dozen
lines to have anyway.

**System**

| | |
|---|---|
| `ver` | version |
| `mem` | free memory |
| `sd lba` | read one raw block and dump it |

`sd` is there for the same reason `dump` is: when FAT32 misbehaves, the first
question is whether the block device is returning what the card holds.

---

## 4. The command table is the extension point

One table, one entry per command:

```
{ name, min_args, max_args, handler }
```

The parser splits a line on whitespace, looks the first word up, and calls the
handler with an argument vector. That is the whole design, and the reason to
write it down is §7: **a scripting language added later reuses this table
verbatim**, gaining every command the shell has for free. Anything that
bypasses the table — a command special-cased in the parser — is a command the
scripting layer will not have.

Argument syntax stays minimal: whitespace-separated words, no quoting. FAT32
short names have no spaces, so quoting earns nothing yet. When it is needed,
it belongs in the tokeniser, not in individual handlers.

---

## 5. Line editing

The keyboard already works on hardware (`boot/kbd.s`). The prompt needs, in
order of value:

1. **Backspace.** Non-negotiable.
2. **A one-line history.** Re-running the last command is most of what a
   person does at a prompt while debugging.
3. Left/right cursor movement, insert.

Anything beyond that is polish and can wait. A shell that cannot correct a
typo is genuinely unpleasant; a shell without word-wise cursor movement is
merely spartan.

---

## 6. Size and language

Target a few hundred lines. C is appropriate — the toolchain is proven on
hardware ([TOOLCHAIN.md](TOOLCHAIN.md)) and the shell is not performance
critical.

Two constraints carried over from the FAT32 work:

* **Build anything that touches a device register at `-O0`.** Calypsi 5.18
  eliminates volatile reads at `-O1` and above. The shell itself touches few
  registers, but the memory commands touch them directly.
* **String literals and `const` arrays land in `cdata`**, which cannot be
  delivered to bank `$00` by a loaded image. Use non-`const` `static char[]`,
  or place the shell in the firmware region where `cdata` is simply part of
  the image.

The second is worth thinking about early: as kernel code in the firmware
region, the shell's command-name strings are ordinary content and the problem
disappears. It only bites code shipped as a loadable image.

---

## 7. Upgrade paths

**Tcl**, when scripting is wanted. It reuses the §4 command table, so the work
is the interpreter core (~600 lines) plus a `__far` heap allocator — and the
allocator is the larger half. The commands come free.

**Forth** stays a separate loadable program ([DUREXFORTH.md](DUREXFORTH.md)),
not the shell. It is the better *system* tool — a monitor, a debugger, a way
to poke hardware interactively — and being loadable means it does not have to
work for the machine to boot.

The two are complementary, and neither blocks the other.

---

## 8. Testing

The shell is the first thing here that a person uses directly, so the
green/red screen convention does not fit — a human reading the output is the
test. But the parts underneath it should be tested the usual way:

* Command dispatch: a table lookup with wrong argument counts, an unknown
  command, and an empty line, each producing the right error rather than
  running something.
* The tokeniser: trailing spaces, repeated spaces, a line of only spaces, and
  a line longer than the buffer — that last one is where shells get buffer
  overruns.
* Path handling: `..` at the root, a path component that is a file, a name too
  long for 8.3.

**A test that cannot fail proves nothing.** Each needs its negative control,
as `run-emu.sh --negative` does in X816_Calypsi.

---

## 9. Order of work

1. [KERNEL.md](KERNEL.md) §9 steps 1-4 — SD card, FAT32, native API, console
2. Tokeniser and command table, with the dispatch tests above
3. Memory commands (`dump`, `peek`, `poke`) — useful immediately, and they
   need no filesystem
4. File commands
5. `run` / `load`
6. Line editing: backspace, then history
7. Optional later: Tcl over the same table
