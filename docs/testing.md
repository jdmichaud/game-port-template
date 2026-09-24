# Testing

What is tested, how, and what the tests may read. The contracts are in code: `src/testkit` (cases,
observations, verdicts, reports) and `src/agent/host.zig` (the agent host's commands).

## Before every commit

- `zig build test`: the unit tests of every module. **No test is skipped**: the summary says
  "N pass (N total)".
- `zig build test-public` and `zig build test-reference`: the two scenario suites.
- `zig build smoke` (the agent host over a synthetic script) and `zig build verify` (the agent
  binary links no SDL).
- `zig fmt --check src build.zig`.

The steps are listed at the top of `build.zig`; agents build into a prefix and a cache under
`/tmp/<project>`, never into `zig-out`.

## Unit tests

- **Next to the code**, as `test` blocks in the file they test. A module's root refers to its
  files so that `zig build test` finds every test.
- **Synthetic inputs.** A test builds the data it needs. A test of code that reads the original's
  tables builds a synthetic image with the same layout (the table at its address, filled by the
  test), never a copy of the game's bytes.
- **A missing file fails.** A test that reads committed data fails when the file is missing. A
  test that skips on a missing file hides a lost fixture, and a run full of skips cannot tell a
  pass from nothing.
- **Degenerate inputs lie.** A test of random draws seeds the generator with a realistic seed (the
  original's own initial seed); a small seed such as 1 or 7 gives degenerate first draws in a
  multiplicative generator (`docs/lessons.md`).

## The scenario runner and its suites

`gameport-test run <suite>` runs each `*.case.json` of the suite in its own child process under the
case's wall-clock bound. A driver that never returns is a `timeout` and a process that dies is a
`crash`; the case's inputs are checked by digest before and after. The runner prints each case's
verdict and a summary; `--report PATH` also writes one JSON line per case, with a command that
replays it. The comparison is exact and ordered, and a failure names the **first difference**.

- **`tests/public`**: synthetic and redistributable fixtures. It includes calibration cases,
  negative controls that expect a wrong value, a missing observation, an extra one, a stall, a
  crash and a bad digest: they prove the runner catches each.
- **`tests/reference`**: cases whose expectations are recordings of the original's behaviour,
  committed as observation files with their provenance.

The drivers produce the actual observations:

- `synthetic.*`: the calibration drivers.
- `recorded`: another observation file (a second run, a candidate export).
- `agent.scenario`: a script of agent-host commands and their responses, run in-process.
- Drivers the port adds for its subsystems, such as the two of a previous port: **routine
  vectors** (a function of the port against the recorded inputs and outputs of the original's
  routine) and **trace replays** (the port's simulation stepped against a recorded trace of the
  original, step by step, so the first difference names the step, the object and the field).

A case has a status: `verified` blocks a change, `provisional` and `disputed` are reported as
diagnostics and never fail a run.

## The agent host in tests

The agent host runs the whole game without a window, with a virtual clock and injected input. It
serves three kinds of checks:

- `agent.scenario` cases: a fixed script and its expected responses (phases, state, frame digests,
  audio counters).
- The `smoke` step: a short synthetic script that must run clean.
- Scripted end-to-end checks outside the suites: long games, save and load cycles, statistics
  ("Comparing behaviours with statistics", below).

It is not the game the user runs ("Gate the join", below).

## Reference data: what may be committed

**May be committed**: measurements of the original's behaviour. The inputs and outputs of its
routines, traces of its simulation, its decisions, counts, digests. Each file says where it comes
from: the tool and its revision, the digest of the executable, the capture profile.

**May not be committed**: the game's files or any part of them (code, tables copied as data,
pictures, sounds, text, films), screenshots and memory dumps of the running original, and the
tools that run it.

**Synthetic data instead**: a test that needs data in the original's format builds it.

## Oracles

The measurements come from oracles that live outside the repository
(`docs/reverse-engineering.md`):

- **Routine vectors.** An interpreter or emulator runs one of the original's routines, with its
  callees, on chosen inputs, and records the outputs.
- **Captures.** The original runs under an emulator, driven by scripted input, and its memory is
  read at checkpoints.
- **Traces.** A whole flow recorded from the original: the state before, the events, the state
  after. The port replays the flow and compares each step.

Only their outputs enter `tests/reference/data`.

## Gate the join

A green suite is not the game working. Suites hold stills and injected events; the user runs the
SDL build with a mouse, in their own video mode. In a previous port, a placeholder renderer, a
dozen dead menu rows, an unplayable play screen and a video mode nobody had looked at all passed
green suites. So, before an item is done:

- **Run the build the user runs**, in the mode they play (their configuration decides it), under
  a real or virtual display, with real input (X events through XTEST, not injected events), and
  **look at screenshots of the presented window**.
- **Gate the moving picture**, not a still: during a move, assert what moves and what must not
  (a camera that chases, an object left behind). A still cannot see motion.
- **Ask what reaches the code**: a feature gated in a test but unreachable from the menus is not
  done.

## Verify before claiming, measure before fixing

- Reproduce a report in the real build before changing code, and verify the fix the same way.
- Never re-record a baseline to bless your own change. Without independent evidence, mark the case
  `disputed`.
- An anomaly in your own measurement is the lead, not noise.
- Do not tune the gate instead of the game: a harness knob can move a number without changing the
  behaviour.
- A report can be the reverse of the truth. In a previous port, "the computer plays too well"
  measured as "it pots less than the original"; later, measured properly, the two were equal.

## Comparing behaviours with statistics

When the outcome is random (a computer player, a shuffled deck, a random start), compare rates,
never single runs:

- **The same protocol on both sides**: the same mode, the same pairing, the same cut (for example,
  leaving out the same kind of opening move).
- **Read the original at the right moment.** A global can be published after the event it
  describes; read it when the original's own code has written it (`docs/lessons.md`).
- **Sample sizes and intervals.** Give each rate with its count and its 95% interval; compare
  with a two-proportion test per group and a chi-square over the groups.
- **Say what the test rules out.** Fifty samples rule out only large differences.

A previous port compared its computer players with the original's this way: about 500 shots of
the original's own demo under an emulator against 2,000 of the port's, over nine skill levels; no
level differed and the rates agreed as a whole (chi-square p = 0.93).

## Other targets

- **Windows under Wine.** `zig build test -Dtarget=x86_64-windows-gnu -fwine` runs most unit tests.
  Wine has known limits (`docs/lessons.md`); the Windows gate needs Windows itself.
- **Browsers.** Chromium and Firefox, headless for scripted checks, and with a real display for
  input and audio.
