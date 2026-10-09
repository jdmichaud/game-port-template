# gameport implementation plan

- Design: `DESIGN.md`. Tests: `docs/testing.md`.
- Unchecked items are open work, in the order they are to be done; dependencies name the
  prerequisites. The user's decisions are recorded under Decisions, each with its date.
- An item is a title, its dependencies, one line of scope and a gate. Complete it through small
  commits with its tests; tick it ([x]) when the gate is met. A partly done item may carry checked
  and unchecked sub-points. No commentary: evidence goes in commit messages and docs.
- A missing item is added here first, in its own commit, with the rationale in the commit message.
- Keep proprietary inputs and captures outside the repository, and personal paths out of committed
  files.
- TODO: replace every TODO below with the game's own scope. Remove the items that the game does
  not need (no multiplayer, no films, no computer player) in a commit that says why.

## P0 — Build and testing foundations

- [ ] **01 — Build structure and toolchain** — Depends: none.
  - Pin Zig and SDL; separate the shared module, the SDL host, the agent host and the browser
    build. The template's skeleton is the start. Prefer static native linking where practical.
  - Gate: clean builds and a runnable synthetic test; the agent binary has no SDL dependency.

- [ ] **02 — Test harness and fixture contract** — Depends: 01.
  - TODO(the harness the game's checks need, `docs/testing.md`): at least provenance for committed
    reference data, exact comparisons that name the first difference, and bounded runs.
  - Gate: deliberately wrong outputs, missing observations, crashes and timeouts give the expected
    verdicts; reference files stay unchanged.

- [ ] **03 — Original routine references** — Depends: 02.
  - Run the original's arithmetic, RNG and other leaf routines under an interpreter or emulator
    outside the repository, and commit their recorded outputs as reference vectors.
  - Gate: repeatable results; the comparator detects altered values and reports the first
    difference. No original code is committed.

- [ ] **04 — Original gameplay capture** — Depends: 02.
  - Run the original under an emulator outside the repository: a pinned profile, scripted input,
    and observations of state, events, input timing and images at defined checkpoints.
  - Gate: three fresh runs agree at the checkpoints; the capture and its decoding are checked
    independently.

- [ ] **05 — Minimal agent host and backend** — Depends: 01, 02.
  - Grow the skeleton's frame runner (`src/agent/main.zig`) into what the checks drive:
    TODO(scripted events, reset, bounded stepping, state inspection, frame and PCM capture).
  - Gate: synthetic input and time scenarios replay identically; limits stop stalled runs; reset
    frees resources and isolates instances.

## P1 — First verified headless slice

- [ ] **06 — Numeric core and explicit state** — Depends: 03.
  - The original's fixed-point and vector operations, its RNG, and the typed state of TODO(the
    core mechanic: balls, units, ships...). No platform service in the simulation.
  - Gate: the reference vectors pass exactly in Debug, ReleaseSafe and ReleaseFast; independent
    instances share no state.

- [ ] **07 — TODO(the core simulation)** — Depends: 04, 05, 06.
  - TODO(the mechanic the game is about: physics, movement, combat...), driven through the agent
    host from fixture-supplied state.
  - Gate: the original's traces and resulting state match, step by step, for TODO(three
    representative cases, one a numerical boundary); work budgets do not change results.

- [ ] **Milestone M1:** a reproducible, original-backed TODO(core event) with first-difference
  diagnostics.

## P1 — Playable slice

- [ ] **08 — Native I/O and storage** — Depends: 01, 02.
  - Bound providers, result ownership, atomic named storage, shared by the SDL and agent hosts;
    TODO(I/O workflows if loads would stall the frame, DESIGN.md section 4).
  - Gate: short reads, provider and allocation errors and a required save at shutdown pass the
    contract tests (and queue limits and cancellation, with workflows).

- [ ] **09 — Asset sources** — Depends: 08.
  - The directory source (in the skeleton), logical names, listing and `read_all`. TODO(the
    original's file layout; an ISO 9660 reader if the port reads the CD image; overlays such as a
    user configuration file or mod files).
  - Gate: equivalent contents from every source, bounded range reads, malformed input refused.

- [ ] **10 — SDL presentation and input** — Depends: 01, 02.
  - Lifecycle, resolution, borrowed RGBA8 presentation, monotonic time, keyboard, mouse,
    controller and focus events, mouse capture.
  - Gate: synthetic frames check channel order and stride; real SDL events match the shared
    contract; failed start-up and mode changes clean up.

- [ ] **11 — Asset decoding and rendering** — Depends: 04, 05, 06, 09.
  - TODO(the formats: images, fonts, palettes, meshes, sprites) into owned data; the original's
    drawing in an indexed page, then the RGBA8 conversion. Start with one video mode.
  - Gate: the port's frame equals the original's at TODO(checkpoints), row by row.

- [ ] **12 — Interactive play of the first mode** — Depends: 07, 10, 11.
  - Loading and play phases, the input interpretation, command validation, TODO(the first
    ruleset or level).
  - Gate: TODO(a whole game or level played in the SDL build, and the same inputs through the
    agent host reach the same outcome).

- [ ] **13 — Save, load and configuration** — Depends: 08, 12, D1.
  - One versioned save format per kind; the settings record; TODO(the original's save files, as
    decision D1 says).
  - Gate: the state survives save, load and restart; bad names, damaged data and an interrupted
    replacement keep a defined behaviour.

- [ ] **Milestone M2:** a playable Linux game in one mode, launched from TODO(the game directory
  or the CD image), with working controls, persistence, and equivalent agent scenarios.

## P1 — Complete local gameplay

- [ ] **14 — Remaining rules, UI and video modes** — Depends: 12, 13.
  - TODO(the other rulesets or levels), the menus and dialogs, the options, and every video mode
    the original has.
  - Gate: rules, input and image cases cover each flow and mode; each mode is looked at in the
    SDL build; no layout is assumed without the original's evidence.

- [ ] **15 — Audio** — Depends: 07, 10, 11.
  - TODO(the sound hardware: a PC's speaker, FM or sample cards, MIDI; a console's sound chips):
    decoding, sequencing, synthesis, mixing, priorities; SDL audio and the agent's PCM capture.
  - Gate: event timing and the applicable sample references match; sounds follow the picture;
    underruns, suspension and queue pressure are exercised.

- [ ] **16 — TODO(computer players and demo)** — Depends: 14.
  - TODO(the original's decisions, its RNG consumption, the demo mode).
  - Gate: seeded decisions agree with the original's, and TODO(a whole demo or match).

- [ ] **17 — TODO(films and intro)** — Depends: 14, 15.
  - TODO(the film format): incremental decoding, bounded buffers, pacing, skip and quit.
  - Gate: reference frames and audio timing match; delayed reads, truncated streams and
    cancellation do not hang or leak.

- [ ] **18 — Local-play acceptance** — Depends: 11, 14, 15, 16, 17.
  - The whole local game in every mode, long games, repeated save, load and reset, and real SDL
    devices. A regression test for each defect found.
  - Gate: the required observations pass; no known fidelity defect; the user has played it.

- [ ] **Milestone M3:** the complete local game on Linux, with the agent host.

## P2 — Network play

Only if the game plays over a link: the items of `docs/network.md`.

## P3 — Windows/SDL

- [ ] **22 — Windows build and packaging** — Depends: 18.
  - `x86_64-windows-gnu` with SDL2 compiled from a Zig package and linked statically; Windows
    paths and storage; DPI awareness; packaging.
  - Gate: the tests and the local game run on Windows itself; the linked libraries are Windows'
    own.

- [ ] **23 — Windows acceptance** — Depends: 22.
  - Replays (and network play, if any) between Linux and Windows; restarts and real devices.
  - Gate: canonical state agrees across the native platforms. Cross-compilation alone does not
    complete this item.

## P4 — Browser

Only if the port runs in the browser: the items of `docs/browser.md`.

## Standing rule

- [ ] **S1 — The repository stands alone** — Depends: none.
  - Building and testing use nothing outside the repository and no proprietary data of the game.
    Only a build that embeds the game's files (if the port has one) reads them, from the user's
    copy.
  - Gate, checked at each milestone: in a fresh clone with an empty environment, `zig build`,
    `zig build test` (no test skipped), `smoke`, `verify`, `web` and TODO(the port's own suites)
    pass; and each executable, copied alone into an empty directory, runs (with network play, it
    serves its page, script and module with its server options).

## Additions to the original

Items the original does not have, added at the user's request, one per addition (A1, A2, ...),
each with a scope and a gate like the items above.

## Decisions

Each with the date the user took it; a decision that changes is edited, and git log keeps the old.

- [ ] **D1 — Saved-position interchange**: TODO(whether the port imports the original's save
  files, and whether it writes them).
- Pin concrete versions and API schemas within their owning items; they are not reasons to reopen
  settled architecture.
