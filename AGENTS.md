Purpose of this project:
Implement a modern port of TODO(game name). The code is portable and maintainable, with modern
engineering practices.

The targeted platforms are Linux/SDL, Windows/SDL and the browser through WebAssembly.

The game plays as the original does: the port recreates the experience of the original
game on its original platform.

Rules:
- Create small self-contained commits on the main branch. Each passes `zig build compile`
  (formatted, every binary and test binary compiled) and the one check that measures its change;
  run `zig build check` before handing over a batch. The subject is `area: description`; the body
  says why and how it was verified, wrapped at 100 columns. Do not push: the user decides what
  leaves the machine.
- Maintain PLAN.md: a missing item is first documented in PLAN.md, in its own commit, with the
  rationale in the commit message. When an item's gate is met, flag it ([x]). The plan holds
  items, scopes and gates, not commentary.
- DO NOT modify DESIGN.md, docs/browser.md or docs/network.md without explicit approval.
- This file holds rules only. A user's decision goes under PLAN.md's Decisions with its date; the
  priority is the plan's order; history is git log. Nothing here is dated or "current".
- Use as few dependencies as possible.
- Link native binaries statically when practical. Depend on a dynamic library only when no other
  practical choice is possible.
- Build and test with the repository alone. No file of the original game and no capture of it is
  in the repository or needed by a build or a test (a build that embeds the game's files takes
  them from a copy the user supplies). Recorded measurements of the original's behaviour
  (traces, routine outputs, decisions) may be committed as test data; tests that need game data
  use synthetic data. No personal paths or identifiers in committed files.
- Verify before claiming. Reproduce a report in the build the user runs before changing code, and
  verify the fix the same way. Never re-record a baseline to bless your own change. Say what is
  not verified.
- The original's bytes decide. Measure the original before changing a behaviour; a recovered
  source, a curve fit or a report is a lead, not evidence.
- Log each problem found in a tool (decompiler, emulator, interpreter) in that tool's log,
  outside the repository, with a reproduction. If it blocks the work, stop and raise the flag.
- Put scratch output (builds, captures, screenshots, logs) under /tmp/<project>, never in the
  repository or in zig-out, and delete it when the check is done.
- Never write into the original's files: copy the game directory before an emulator runs it.
- Stop processes by PID. `pkill -f` and `pgrep -f` also match the caller's own command line.
- Remove an agent worktree and its branch once its work has landed.
