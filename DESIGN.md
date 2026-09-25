# gameport — design

Design statement, TODO(date). This document defines the architecture and its contracts. It changes
only with the user's approval (`AGENTS.md`). The sections marked TODO describe the original game;
write them when the port starts. The rest is the design that previous ports arrived at, and it
applies to any port of an old game as it is.

The game owns the rules, the simulation, the input interpretation, the drawing and the sound
generation. The platform supplies devices, storage, time and transport. The interfaces make
errors, memory ownership, asynchronous operations and the frame format explicit.

## 1. Principles

- **Fidelity is defined by the original game's observable behaviour.** The original executable,
  its data files and recorded traces of it running are the reference. Disassembly and recovered
  source code help to find and understand that behaviour; they are not the reference
  (`docs/reverse-engineering.md`).
- **The port chooses its own structure.** APIs, data structures, algorithms and control flow are
  chosen for clarity and portability, and their results are checked against the original. The
  original's addresses and register conventions belong in comments, port maps and compatibility
  parsers, not in the runtime's structure.
- **Linux/SDL first, the agent host alongside.** The headless agent host drives the same game
  without a window from the first items. Windows and the browser follow on the same shared code.
- **Few dependencies.** Zig and SDL2 for the native game; nothing beyond the browser for the
  browser build.
- **Static linking where practical** (section 8).
- **The repository stands alone.** No file of the original enters the repository, and no build or
  test needs one, except the standalone build that embeds a copy the user supplies (PLAN.md, S1).

## 2. The platform boundary

The application composes three interfaces:

- `Platform`: the lifecycle, the I/O workflows, events, time, presentation, PCM output and the
  transport. Implemented by the SDL backend, the browser backend and the agent backend.
- `AssetSource`: named, read-only game files, listed and read. Implemented over an ISO image, a
  directory, memory, and the files embedded in the standalone build.
- `Storage`: persistent named byte records and their listing. Implemented over a directory, the
  browser's storage, and memory.

Each interface is a context pointer and a table of functions (`src/shared/platform.zig`), so
several backends and several games can exist in one process: the computer player's trials, the
agent host's resets and the network tests all need more than one game at a time.

**The simulation depends on none of these interfaces.** It receives explicit state and commands,
and produces state changes and events. The application coordinates I/O and presentation around
it. There are no globals: a game is a value.

The host implementation is chosen at build time and passed as explicit instances. The asset
source is chosen at run time (a CD image or a directory on the command line, or the embedded
files of the standalone build).

## 3. Platform contracts

### 3.1 The game and its host

```zig
const UpdateResult = enum { running, finished };

// Game operations:
fn init(allocator: std.mem.Allocator, assets: AssetSource, storage: Storage) !Game;
fn update(self: *Game, platform: *Platform) !UpdateResult;
fn deinit(self: *Game) void;
```

The host creates the allocator, the backend, the providers and the game, and owns the outer loop.
The game's first update calls `platform.start()`, which activates the services and returns the
backend's capabilities. Each later update processes events and completed I/O results, advances
bounded work and does the rendering and audio that are due. `finished` means the game has done
its orderly shutdown (required saves included); the host then releases the game, the providers
and the backend, in that order, and the allocator last. An error returns control to the host for
reporting and cleanup.

The native host calls `update` in a loop and paces it outside the game. The browser calls one
update per `requestAnimationFrame` callback. The agent host calls updates on command, with a
virtual clock.

### 3.2 Presentation

The renderer produces a finished RGBA8 frame; indexed pixels and palettes stay inside the
renderer, where they express the original's drawing and its palette effects.

```zig
const RgbaFrame = struct {
    width: u32,
    height: u32,
    stride: usize, // bytes between row starts, at least width * 4
    pixels: []const u8, // R, G, B, A bytes per pixel; A is 255
};
fn setResolution(width: u32, height: u32) !void;
fn present(frame: RgbaFrame) !void;
```

`present` borrows the frame for the duration of the call only. The render resolution, the window
size, the fullscreen state and the pixel aspect are separate: resizing a window keeps the game's
resolution, and a failed mode change keeps the previous mode usable.

### 3.3 Input

The platform delivers ordered, timestamped events in project-owned types, never SDL or DOS scan
codes: key down and up, text input, relative mouse motion and the pointer position, buttons,
wheel, controllers, focus, quit, and drawable-size changes. The game maps them to actions, with
the original's filters, sensitivities and key tables in shared code. Relative mouse capture is a
request, and an event reports whether it was granted; losing focus or capture releases held
controls without producing an action.

The mouse travels in the game's own units. A host that passes window pixels to a game drawn at a
scale moves the game's pointer too fast (`docs/lessons.md`).

### 3.4 Audio

Audio crosses the boundary as PCM. Sequencing, sample decoding, synthesis, mixing and the
original's priorities are shared code; the platform plays the finished samples.

```zig
fn audioOpen(requested: AudioFormat) !AudioFormat;
fn audioQueue(samples: []const i16) !usize; // sample frames accepted; partial is allowed
fn audioStatus() AudioStatus; // queued and played frames, running or suspended
fn audioClear() void;
fn audioClose() void;
```

The queue is bounded and copies what it accepts. Timing is counted in sample frames, so the
render rate never decides the music's tempo, and effects are scheduled against the frame that
shows their cause. Suspension is state: a browser starts audio only after a user gesture.

### 3.5 Assets

```zig
fn open(path: []const u8) !OpenedAsset; // a handle and a length
fn readAt(file: AssetHandle, offset: u64, dst: []u8) !usize; // short reads allowed
fn list(prefix: []const u8) !OwnedAssetEntries;
fn close(file: AssetHandle) void;
fn readAll(path: []const u8, max_bytes: usize) !OwnedBytes; // shared helper over the four
```

Asset names are validated ASCII logical names, matched the way the original's file system
matched them (DOS rules). Each source converts its own names: the ISO reader drops version
suffixes, the directory source keeps the host's encoding. The ISO reader is shared code over a
byte source, so the same parser serves a native file, memory and a browser blob. An overlay
policy decides which source answers first (for example, a user configuration file over the CD's).

### 3.6 Storage

```zig
fn save(name: []const u8, bytes: []const u8) !void; // atomic replacement
fn load(name: []const u8) !OwnedBytes;
fn listSaves() !OwnedSaveNames;
fn deleteSave(name: []const u8) !void;
```

A save's name is a validated ASCII key; an invalid key is an error, never silently rewritten.
`save` returns once the store confirms the write; a failure before that keeps the previous
record. Storage holds bytes; the formats are shared code (section 7).

### 3.7 Ownership

- Inputs (paths, names, bytes, destinations) are borrowed for the duration of a call. Providers
  keep no borrow after returning.
- Returned buffers and listings belong to the caller until their `deinit`.
- Received network messages stay valid until the next `pollEvents`.
- A handle outlives every call that uses it; its owner closes it.

### 3.8 Text

- Player-entered names and descriptions follow the original's field filters and length limits.
- Save keys and asset names are validated ASCII; an invalid name is an error.
- The original's text and its rendering data keep the original's glyph and layout encoding as it
  is: spacing codes, kerning and border glyphs are part of the drawing.
- Host paths and host text keep the platform's encoding.

## 4. Execution: the host loop and the I/O workflows

An I/O workflow is a finite job: load and decode a file, prepare a set of assets, write a save,
fill one film buffer. It includes the decoding that produces its result.

The backend runs **one workflow at a time** from a bounded queue (`src/shared/workflow.zig`, the
native executor in `src/native`). The game submits workflows, and takes their completed results
at update boundaries. Why one at a time: the order of completion is then defined, which the agent
host's reproducible runs need; the queue and the buffers are bounded; and the same model runs in
a browser, where a suspended task cannot overlap another without extra stack management. A
workflow never runs inside the frame: waiting for a disk must not stall input or drawing.

The agent host completes workflows inline and publishes their results under control, so a run
replays exactly. The native executor uses `std.Io`; the browser completes its reads through the
page.

Loading, menus, films, computer players and shutdown are phases of the game, advanced by bounded
updates. A required save keeps the shutdown phase alive until it is written.

**Three clocks stay separate**: the original's simulation time, the local presentation time, and
transport deadlines. A shared conversion keeps the original's timing units and rounding where they
are observable. The simulation advances by its own scheduler; the host limits how much work one
update does, and that limit must not change the order or the result of any event.

## 5. The hosts

### 5.1 The agent host (`gameport-agent`)

A headless host for scripted runs and debugging. It links no SDL and needs no window, sound
device or input device; it implements the same platform contracts, so rendering, input
interpretation, audio scheduling and loading run through the same code as in the game.

- A JSON-lines protocol on standard input and output (`src/agent/host.zig`); diagnostics go
  to standard error.
- A virtual clock: time advances only when a command says so, never with the time an agent spends
  thinking.
- Commands to reset, inject timestamped events, step a number of updates or run until a
  condition, inspect state, capture the frame and the PCM. Every run has work, virtual-time and
  wall-clock limits, and the response says which one ended it.
- Saves go to an in-memory store or to a directory the caller names; never to the user's.
- The test runner's `agent.scenario` driver runs the same host in its own process.

The agent host is how the port is driven end to end without a display, and how a test reproduces
a defect. It is not the game the user runs: gates also run the SDL build (`docs/testing.md`).

### 5.2 The SDL host (`gameport-sdl`)

The interactive game on Linux and Windows. The first positional argument names the CD image or the
game directory. Options select the window scale, a software renderer, an event log on standard
output (the same JSON the agent host's `inject` reads, so a played session replays headlessly),
a run time, and the saves directory. Its updates are paced by the display when the renderer
presents in step with it, and by a fallback pacer otherwise: a loop that presents nothing must
not spin.

The host captures the pointer when the game reads relative motion, with a key chord that releases
it. On Windows it is a console program, so that its command-line options and messages stay
usable, and it declares itself DPI-aware (section 8).

### 5.3 The browser build

The shared game compiled for `wasm32-freestanding`: no libc, no compiler-rt and no entry point.
The page's hand-written JavaScript creates the memory, provides the host functions (canvas
presentation, input with pointer lock, Web Audio, storage, the transport) and the few helper
functions the compiler emits calls to (128-bit multiply and divide, and the math functions the
code uses), and calls one update per animation frame. The build checks the module's list of
imports: an unexpected import is an error, and each helper is tested against compiler-rt.

When every file the game needs is fetched before the first update, the module needs no
suspension mechanism. Only a game that must stream files during play needs one (Asyncify, with a
pinned `wasm-opt`, a sized continuation buffer and a larger module; or JSPI where browsers
support it), behind the same workflow interface.

The browser keeps the game's records in its own storage, per address, and gives them back before
the game starts.

### 5.4 The standalone build

`zig build standalone -Dembed-assets=<CD image or directory>` builds the SDL game with the
gameplay files built in, from an explicit list (`tools/embed_assets.zig`). It is the one build
that reads the original's files. Large optional content (films) may be left out; the game then
disables what needs it.

## 6. Determinism and state

- **Explicit state.** A game is a value; nothing is global. Several games in one process do not
  share state.
- **The original's arithmetic.** Fixed-point values keep the original's widths, signedness,
  intermediate widths, rounding, wrapping and division. Central helpers do the arithmetic; a
  wider intermediate truncates at the original's point.
- **One explicit RNG**, with the original's algorithm and the original's call order. A draw that
  the original makes, the port makes, even when it does not use the value.
- **Event order, not step size.** An event-driven simulation keeps the original's event order and
  tie-breaking; the scheduler's data structures are the port's own.
- **Flags as values.** A routine of the original that answers in a CPU flag returns an optional
  or a second value in the port.
- **Canonical state.** A hash and a serialisation over named fields in a defined order and byte
  order, never over padding or pointers, identify the state for tests, saves and the network.

## 7. Assets and saves

- **Assets.** The original's files are read at run time from the CD image or a directory, or from
  the standalone build. The port never commits them.
- **Saves.** One versioned format per kind of record (settings, a game in progress, ...). A record
  of another version is refused, not converted: no readers for old versions.
- **The original's own files** (its saves, its configuration) are the original's formats, read
  by importers; whether the port also writes them is decision D1 of the plan.

## 8. Builds and linking

The toolchain is pinned (`build.zig.zon`, `build.zig`). The modules, and what each links:

- `gameport` (`src/shared`), nothing: the game, the platform contracts, the in-memory providers
  and the ISO reader.
- `testkit`, nothing: cases, observations, comparison, verdicts and reports.
- `agent`, nothing: the agent backend and host.
- `native`, nothing: host I/O, with the directory and ISO sources, the storage and the workflow
  executor.
- `sdl`, libc and SDL2: the SDL backend and host.

- **Linux.** SDL2 is linked from its static archive; the system libraries it needs (X11, Wayland,
  PulseAudio, ALSA) stay dynamic because they have no practical static builds. A build option
  links the shared SDL2 instead.
- **The agent host** links nothing but the Zig standard library; built for a musl target it is a
  fully static binary. The `verify` step checks that it has no SDL dependency.
- **Windows.** `-Dtarget=x86_64-windows-gnu`, which needs nothing from Windows to build. SDL2 comes
  from a Zig package (a build of SDL2 by Zig, added with `zig fetch` as a lazy dependency), is
  compiled from source and linked statically: the executables import only Windows' own libraries
  and the Universal C runtime. The SDL host is a console program and declares per-monitor DPI
  awareness through SDL's hint.
- **The browser.** `wasm32-freestanding`, imported memory, no compiler-rt, imported symbols for the
  host functions, no entry point (section 5.3).

## 9. Networking (TODO: remove if the original has no network play)

**Network play simulates complete commands deterministically on both sides.** The canonical game
state holds the players, the simulation state, the rules state and the RNG; the camera, menus,
devices and connections live outside it. Human input, computer players, replays and the network
use the same typed commands, and shared game logic checks their legality.

- The game logic and the simulation apply validated commands and expose state and outcomes.
- The session protocol adapter, in shared code, encodes and decodes messages and keeps the
  handshake, the ordering, the acknowledgements, the retries and the epochs.
- The platform transport moves messages and reports connection events.

The port's own protocol is versioned: a handshake (protocol and simulation versions, asset
identity, rules, players, initial state), commands proposed by the active player and ordered by
the host peer, and a canonical state hash compared at each turn boundary. A mismatch pauses the
game with its diagnostics. Previews of aiming or movement are separate from commands, rate-limited
and discarded when stale. A disconnect keeps the session's epoch, and a duplicated command never
acts twice.

The transport delivers whole messages, reliably and in order, while a connection lives. `send`
means accepted into a bounded queue; received messages arrive through `pollEvents`. The first
transport is decision D2 of the plan (in a previous port, the native game served the browser build
and a WebSocket on one port).

Two browsers can also play with no native game (in a previous port, `--server ADDRESS:PORT`). The
native program then only serves the page and relays the session's binary messages between two
WebSockets; the first browser to connect is the host. The server tells each page its role in a
text message (`host`, `guest`), and tells the host when its guest arrives and leaves (`peer`,
`left`). The host's page shows its guest to the module as a connection of its own, so the game's
host logic needs no listening socket; its manifest says it is a relay, so the page reports the
connection open only after its role. A host that leaves ends its guest's connection, and the next
browser to join hosts.

The original's own protocol, if the port must talk to the original, is a separate adapter: an
offline codec from captured packets first, then its session rules.

TODO: what the original's network code does (message types, the synchronisation model), from
its bytes.

## 10. Faithfulness

- Every behaviour has evidence: a reading of the original's bytes, a measurement of the original
  running, or a recorded trace. A comment names the original's routine and address it follows.
- Each subsystem has a port map (`docs/port-map-template.md`): what the original's pieces are,
  where they are in the port, and how they were checked.
- A deliberate difference from the original is the user's decision, recorded where the code makes
  it and, for a feature, as an addition in the plan (A1, A2, ...).
- A report of a defect is a lead: measure the original before changing the port.

## 11. The original (TODO)

- TODO: the executable: its format (DOS extender, protected or real mode), its memory map, where
  its tables are, the version the port follows and its digest.
- TODO: video: the modes, their drivers, resolutions and palettes, and what differs per mode
  (fonts, cursors, layout).
- TODO: sound: the devices the original supports and the one the port reproduces.
- TODO: input: keyboard tables, the mouse model (absolute or integrated deltas, sensitivity),
  joysticks.
- TODO: files: the layout of the CD and of the installed game, the configuration file.
- TODO: network: the link types the original offers.
- TODO: the subsystems, each with its port map in `docs/`.
