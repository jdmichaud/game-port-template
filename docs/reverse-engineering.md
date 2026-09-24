# Studying the original

How to find out what the original does, and how sure to be. Everything described here runs
outside the repository; only its recorded outputs enter it (`docs/testing.md`).

## Sources, and how far to trust them

- **The original's bytes decide**: the executable and the data files of the version the port
  follows. Record that version's digest in `DESIGN.md`.
- **The disassembly** is exact about what the code does; its names are guesses.
- **A recovered C source** (decompiler output) and any earlier reading of the same bytes are
  leads, never evidence. Their known faults: call arguments lost to registers, answers that the
  original returns in a CPU flag turned into a return value or dropped, guards dropped, a 16-bit
  quantity read into a 32-bit field, wrong names. When the C and a recording disagree, find the
  missing mechanism in the bytes; never change a constant to fit a curve.
- **The manual and the game's own help text** describe the rules the player sees, often exactly.
- **Reports** from players are leads to measure, not facts.

## Reading the executable

- **Find the layout first**: the container (an MZ stub, a DOS extender, a 32-bit flat image at a
  file offset), the image's base, and the rule from a virtual address to a file offset.
- **Read the dispatch tables.** A `CALL [table + index * 4]` or a jump table says which routine
  serves which key, menu row or game state; reading the table is faster than any search.
- **Some tables are built at start-up.** The file may hold half of a table and a start-up routine
  builds the rest (in a previous port, meshes stored without their z components and face planes
  computed at boot). A port that reads such a table as data gets half a model, and a memory dump
  of the running game hides the missing builder. List the start-up routines and port each one.
- **Code may change its own data.** Menus that write marks and greyed states into their own
  labels need a writable copy of the image in the port.
- **Data can differ per mode.** Fonts, cursors and scales may exist once per video mode. Check the
  end address of each table: two modes that seem to share a table often do not.
- **Check the clock units** of every timing constant against the timer the original programs;
  names and comments in recovered code disagree about them.

## Oracles

### Routines under an interpreter

An interpreter or CPU emulator runs one of the original's routines, and the routines it calls, on
chosen registers and memory, and reports the registers, the flags and the memory written. A
previous port drove a decompiler's p-code emulator through its own small tool.

- **Seed everything the routine reads as data**: the globals, and also the tables that live in
  the code (switch and dispatch tables, constant pools). Unseeded memory reads as zero, and a
  missing dispatch table sends the run off to the program's exit.
- **Flags are outputs.** An emulator keeps the CPU flags as registers; record them where the
  original answers in a flag.
- **Sample the inputs** over the whole domain, the edges included, and record each vector with its
  inputs, so the port's function can be replayed against it.
- **Whole flows** (a computer player's turn, a rules decision) can run the same way from a memory
  dump of the running game.

The outputs become observation files in `tests/reference/data`, with the tool's revision and the
executable's digest.

### The original under an emulator

- **dosemu2 or DOSBox under Xvfb**, with the emulator's software renderer. Without a window manager,
  move the window to the origin and capture the window itself, not the root. Restart Xvfb between
  runs: its root window keeps the last picture of a dead client.
- **Copy the game directory first.** The original writes its configuration and its saves into
  its own directory.
- **Observation-only patches** (a CD check, a blocking prompt) go into the copy, identified by the
  digest of the bytes they replace. The patch tool lives outside the repository.
- **Input through XTEST.** Without a window manager, keys go to the window under the pointer. A
  game that integrates mouse deltas does not follow the host's pointer: click in a closed loop
  from screenshots, and use a clamp (sweep into a corner) as an absolute reference.
- **Memory through `/proc/<pid>/mem`.** Find the image's base by searching the emulator's
  mappings for a run of the executable's bytes far from any patch; an address is then the base
  plus the virtual address. Writing works too, but only affects code that runs afterwards.
- **One instant per dump.** Reading a large dump out of a running emulator spans frames: stop the
  emulator (SIGSTOP) around the read. A dump taken while the video driver flips pages replays
  through the wrong page: detect the driver's flip state and retake it.
- **Read a global when the original has written it.** State can be published after the event it
  describes. In a previous port, the balls-on-table mask changed a fifth of a second after the
  balls stopped, together with a shot counter, and the per-shot tally one sample after the
  counter; a read at "balls stopped" saw no pot at all. Trace every change of the watched globals
  with timestamps once before trusting a harness.
- **Unchained VGA modes** are not a linear page in memory: rebuild the page from the plane writes
  and the map mask.

### Traces

A trace records the state before a flow, every event of it, and the state after, from the
original. The port replays the same flow from the same state and compares step by step, so the
first difference names the step, the object and the field. Three fresh runs of a capture agree at
their checkpoints before it is trusted.

## Port maps

Each subsystem has a port map in `docs/` (`docs/port-map-template.md`): the original's pieces,
where each is in the port, the data layouts, the algorithms, the pitfalls, and the evidence. Code
comments cite port-map sections, so keep a section's number once it is cited. A port map records
results, one sentence per measurement; it holds no tool instructions.

## Keeping it outside the repository

The emulator setups, the capture harnesses, the interpreter tool, the patches, and every capture,
dump and screenshot live beside the repository, with a README saying what each script does. The
repository receives only recorded measurements, and builds and tests without any of this
(`PLAN.md`, S1).
