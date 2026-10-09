# Lessons from previous ports

Rules that each cost a previous port real time. The browser's are in `docs/browser.md`, network
play's in `docs/network.md`.

## Evidence and the user

- **Gate the join, not one side of it.** Suites hold stills and injected events; a green suite
  hid a broken game four times. Run the build the user runs, in their mode, with real input, and
  look at it.
- **Measure before fixing.** A report is a lead, and can be the reverse of the truth.
- **The bytes outrank a curve fit.** Never change a transcribed constant to fit a recording, and
  never invent a rationale for a number: find the original's rule.
- **Never re-record a baseline to bless your own change.**
- **An anomaly in your own measurement is the lead**, not noise.
- **Name the external inputs up front.** A gate that needs a file, a device or a decision nobody
  asked for silently does not run.
- **When the user's picture disagrees with yours**, ask for their build's commit or digest first.

## Reading the original

- **Flag answers become second values.** Decompilers lose answers returned in a CPU flag; the port
  returns them, never through a global.
- **Lost arguments.** Recovered C drops register arguments; port raw decompiler output from the
  bytes.
- **Start-up builders.** Tables can be half-built in the file and completed at start-up; read as
  data they give half a model, and a dump of the running game hides the builder. Trace from
  power-on.
- **State published after the event.** A global can change after the event it describes. Trace
  the raw changes with timestamps before trusting a measurement.
- **A generator's value range.** Use the bits the original's callers read; a generator's top bits
  may never be set. Test with the original's own seed, not 1 or 7.
- **Distributions matter when extending the original**: a new behaviour may need a new
  distribution; measure it.
- **Special cases hide in tables** (a canned opening move, a mirrored variant).
- **Name by behaviour, check with the bytes.** Bytes are often letters; decode before naming.
- **A dead menu row looks like a working one.** Publish whether the game served a row, and gate a
  row that must act and one that must be refused.
- **Each video mode is its own picture**: fonts, cursors, scales and layout differ; look at every
  mode.
- **Emulated hardware has start-up requirements** (a sound chip's extended mode that exists only
  once a register is written).
- **How each screen reads input**: a latch set by the interrupt (one action per press) or the held
  state. Repeat rates are the original's, and global hotkeys are bypassed during text entry.
- **Pacing is the original's clock**: port its tick source and frame wait as rational deadlines,
  never as display frames.

## The port's code

- **Every screen reads input through one mapping**, the port's own screens included; the agent
  host injects axes as well as keys (a hat-less pad reports its d-pad as axes).
- **Window pixels are not game pixels.** Convert pointer coordinates in the host.
- **A loop that presents nothing must not spin**: display pacing only paces a present.
- **Audio in sample frames**: count music time in samples, and schedule each effect against the
  frame that shows its cause.
- **One save format**: one version per kind of record; every change is breaking.
- **Menus that write their own bytes** need a writable copy of the original's image.
- **A work budget must not change results**: limit the events per update, never their order.

## Tools and environment

- **`pkill -f` and `pgrep -f` match the caller's own command line.** Stop processes by PID.
- **Capture the presented window**, not the game's internal page.
- **Under Xvfb**: install a no-op Xlib error handler (the default exits before cleanup), restart
  Xvfb between runs (it keeps a dead client's picture), and drive menus by keys, not by mouse
  positions that go stale.
- **A shell command sent to the background with `&` dies with its tool call** in agent harnesses:
  use the harness's background mode.
- **Scratch in `/tmp`** (a memory file system), never `/var/tmp`.
- **A killed or confused Zig build** can leave a stale cache and binary: rebuild from a fresh
  `--cache-dir`. On a network-mounted tree with coarse or skewed timestamps, a file restored within
  the same second can look unchanged to Zig's cache and to `zig fmt`.
- **Wine** runs most unit tests of a Windows build, but not sockets, child-process timeouts or
  pointer motion; the Windows gate needs Windows.
- **Zig 0.17**: no `@cImport` (declare SDL's externs by hand); `@enumFromInt` became
  `@fromBackingInt`; `std.process.Args.iterate` does not compile for Windows (use
  `iterateAllocator`), and there is no `setenv` (set SDL's hints with override priority).
