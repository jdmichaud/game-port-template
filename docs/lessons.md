# Lessons from previous ports

The lessons and traps of previous ports that apply to any port of an old game. Each one cost real
time once.

## Evidence and the user

- **Gate the join, not one side of it.** Four times, a green suite hid a broken game: a milestone
  reached over a placeholder renderer, menus whose runner and drawer were tested while nothing put
  a box up, an unplayable play screen, and a video mode nobody had looked at. Suites hold stills
  and injected events; run the build the user runs, in their mode, with real input, and look.
- **Measure before fixing.** A report is a lead. Of four claims about the demo ("too fast, too
  good, the cue does not move, the ball is not placed"), two were the reverse of the truth.
- **The bytes outrank a curve fit.** A timing divisor changed to fit a recording was wrong and was
  reverted; the missing mechanism was elsewhere. Never change a transcribed constant to fit.
- **Never re-record a baseline to bless your own change**, and never invent a rationale for a
  number ("an old mouse gave 200 counts to the inch"): find the original's rule (a quadratic mouse
  curve, off in one mode).
- **An anomaly in your own measurement is the lead.** Constant runs of samples in a film's audio
  were the defect (the wrong audio stream mixed in), not "silence between sections".
- **Name the external inputs up front.** A gate that needs the CD image, a device or a decision
  nobody asked for silently does not run, and "58 of 60" gets reported instead of a clean pass.
- **When the user's picture disagrees with yours**, ask for their build's commit or digest first:
  an old binary that looks the same is not evidence.

## Reading the original

- **CPU-flag answers become optionals.** Decompilers lose answers returned in the carry flag; the
  port returns a second value, never a global flag, which is easy to clobber across calls.
- **Lost arguments.** Recovered C often drops the register arguments of calls; where a routine is
  still raw decompiler output, port it from the bytes.
- **Start-up builders.** The executable can hold half-built tables that start-up code completes
  (meshes without their z components, planes computed at boot). Read as data, they give half a
  model, and a dump of the running game hides the missing builder.
- **State published after the event.** A global can change a fraction of a second after the event
  it describes (a balls-on-table mask, after the balls stopped). Trace the raw changes with
  timestamps before trusting a measurement: a harness that read too early counted zero pots.
- **A generator's value range.** A multiplicative generator whose state stays below its modulus
  never sets the top bits: one port's high half never reached the sign bit, so a "uniform" draw
  from it erred to one side only. Use the bits the original's callers read. Small seeds (1, 7)
  give degenerate first draws: test with the original's own seed.
- **Distributions matter when extending the original.** Scaling the original's aim error could not
  make a much weaker computer player: its binomial draw is zero one time in five, and those shots
  are perfect. A new behaviour may need a new distribution; measure it.
- **Special cases hide in tables.** The computer never thought about its opening break: the
  original plays a canned shot from a table, mirrored by a coin flip.
- **Name by behaviour, check with the bytes.** A card byte named "OPL3" in the port was the letter
  `A`, the mono AdLib, as its behaviour showed (it fakes panning by volume). Bytes are often
  letters; decode them before naming them.
- **A dead menu row looks like a working one.** A pick lights, answers and closes the box either
  way. Publish whether the game served the row, and gate a row that must act and one that must be
  refused.
- **Each video mode is its own picture.** Fonts, cursors, scales and layout differ per mode; check
  the end address of each table, and look at every mode in the game.
- **How each screen reads input.** A screen reads either a latch set by the keyboard interrupt (one
  action per press) or the held state; get it wrong and a key still held from the previous screen
  skips the next film, or a quick press is lost. Key repeat rates
  are the original's (in its ticks), and global hotkeys (pause, sound) are bypassed during text
  entry: a password with a P paused a film into a black screen.
- **Pacing is the original's clock.** Measure its tick source and its frame wait (the timer's
  divisor, N ticks a frame, catching up when late) and port them as rational deadlines, never as
  display frames.
- **Emulated hardware has start-up requirements.** An OPL3 answers as an OPL2 until register 0x105
  is written, and its second bank of nine channels does not exist before that: every note the
  driver gave to those channels was silent.

## The port's code

- **Every screen reads input through one mapping**, the port's own screens (settings, network
  menus) included: they read raw events and ignored a pad's stick that the game's menus handled.
  A pad without a hat reports its d-pad as axes, so the agent host injects axes as well as keys.
- **Window pixels are not game pixels.** A host that passes window coordinates to a game drawn at
  a scale of three moves its pointer three times too fast. Convert in the host.
- **A loop that presents nothing must not spin.** Display pacing only paces a present; a film at
  15 frames a second let the loop run millions of empty updates and starved the audio queue.
- **Audio in sample frames.** Count music time in samples, not frames, and schedule each effect
  against the frame that shows its cause.
- **One save format.** Keep one version per kind of record and refuse the others; readers for old
  versions clutter the code for no user.
- **Menus that write their own bytes** need a writable copy of the original's image in the port.
- **A work budget must not change results.** Limit the events per update, never their order.

## Tools and environment

- **`pkill -f` and `pgrep -f` match the caller's own command line**, including a shell whose script
  contains the pattern; a cleanup kills itself. Stop processes by PID.
- **Xlib's default error handler exits the process**, before a script's cleanup runs, and leaves an
  orphan X server and game that later runs photograph. Install a no-op handler, and refuse to
  start when the display is taken or the game's window already exists.
- **Xvfb keeps the last picture** of a dead client on its root window: restart it between runs.
- **Capture the presented window**, not the game's internal page: a capture of the page cannot see
  a defect of the presentation.
- **A shell command sent to the background with `&` dies with its tool call** in agent harnesses:
  use the harness's own background mode for long-running hosts.
- **A killed Zig build can leave cache directories** that make later builds fail with a permission
  error, and the binary under test is then stale: delete them and rebuild.
- **Scratch output in a memory file system** (`/tmp`), not `/var/tmp`, which persists: a few weeks
  of captures filled tens of gigabytes there.
- **Emulators**: dosemu2 needs its software renderer under Xvfb (its X output fails there); the
  original writes into its own directory, so run a copy; a forgotten emulator plays sound on the
  user's machine.
- **Mouse-driven scripts go stale** when a fix moves the cursor's start: a click lands on "Exit"
  and a measurement reads zero. Drive menus by keys where the game allows it.
- **Wine** (checked with Wine 10) runs most unit tests of a Windows build, but: Zig's Windows
  sockets fail (Wine lacks the AFD device), a child process's timeout never fires and killing it
  aborts (a missing `RtlReportSilentProcessExit`), XTEST pointer motion does not reach a game on a
  bare Xvfb, and Wine emulates DPI scaling. The Windows gate needs Windows.
- **Zig development versions** move: `@cImport` was removed (declare SDL's externs by hand);
  `zig fmt` rewrites renamed builtins such as `@enumFromInt` into `@fromBackingInt(@intCast(...))`,
  so run it before every commit; `**` array repetition is refused (use `@splat`); standard output
  needs a streaming writer; directory entries can report an unknown kind; `std.process.Args.iterate`
  does not compile for Windows (use `iterateAllocator`); `setenv` does not exist there (set SDL's
  hints with override priority instead).
- **The browser build without compiler-rt** imports the helpers the compiler calls (128-bit
  multiply and divide, some math): the page provides them, tested against compiler-rt, and the
  build checks the import list. A Debug build can import more than a release build.
- **Browsers**: audio starts only after a user gesture, and a browser without a sound device keeps
  it suspended; pointer lock also needs a gesture; a script that waits for the page's state should
  wait on the element that carries it, not on the visible text.
- **Ask for the plain pointer lock.** A lock with `unadjustedMovement` (counts without the system's
  acceleration) worked in every browser on Linux, but in Chrome and Edge on a Windows PC the
  motion stopped at the browser window's border. Headless and Xvfb runs cannot show it: ask the
  user for the browser and the system, and check the fix there.
- **The test suites never load the browser module.** A 128-bit division and float `@round`,
  `@min`, `@max`, `std.math.hypot` in shared code became imports that the page refused, and the
  browser build did not start for hours while every suite passed. Run the browser build's import
  check before each commit of shared code; `@sqrt`, `@floor`, `@ceil`, `@trunc` and `@abs` are
  WebAssembly instructions, the others are not.
