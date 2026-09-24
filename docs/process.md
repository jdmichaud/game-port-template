# How the work is done

The way of working of previous ports, written for the next one. `AGENTS.md` has the rules; this
page says how they play out in a session.

## Starting a session

- Read `AGENTS.md` and `PLAN.md`, and the notes that the last session left ("Notes that outlive
  the session", below).
- Look at the repository before touching it: `git status`, the stashes, the branches, the
  worktrees. The user's uncommitted work and stashes are theirs: never stash, drop or overwrite
  them.
- Before a milestone, or when the user asks "do you need anything?", list what the item's gates
  read from outside the repository (the CD image, an emulator, a device, a package, a decision)
  and check the machine for each. An input nobody asked for is a gate that silently does not run.

## One item, from the plan to the tick

1. **Add the item first.** Work that the plan does not have goes into `PLAN.md` in its own
   commit, with a one-line scope, a gate, and the rationale in the commit message.
2. **Investigate.** Read the code, the port map of the subsystem, and the original's bytes. The
   recovered source and old notes are leads (`docs/reverse-engineering.md`).
3. **Measure the original.** Before a behaviour changes, measure what the original does, with an
   oracle outside the repository. A report can be the reverse of the truth.
4. **Implement** in the port's own structure, with a comment naming the original's routine and
   address that the code follows.
5. **Gate.** The unit tests and the suites pass (`docs/testing.md`), and the change is seen in the
   build the user runs: the SDL game, in the mode the user plays, with real input. The agent host
   and injected events do not stand in for that.
6. **Commit small.** One defect or one step per commit, each building and passing the tests.
   Subject `area: description`; the body, wrapped at 100 columns, says why, and how it was
   verified. A commit that adds a tool rule or a doc section carries it with the fix it explains.
7. **Tick** the item when its gate is met, with the evidence in the commit message. A partly done
   item gets checked and unchecked sub-points, not paragraphs.

## Working with the user

- **Short status updates** during long work: what is being done and what comes next, in a line
  or two. Never let a long silence stand.
- **Ask only real decisions**: a choice that is the user's and changes what happens next. Give
  the options and a recommendation. Everything with a conventional answer is decided and
  mentioned.
- **Report plainly.** What changed, how it was verified in the real build, and what is not
  verified. A failing test is reported with its output. Never claim done on a self-certified
  gate.
- **When a report and a measurement disagree**, ask which build the user ran (its commit or the
  binary's digest) before arguing: an old binary that looks the same is not evidence.
- **The user plays outside the development machine** in most setups: give steps to reproduce, not
  only results.
- **Deliberate differences from the original** are the user's decisions. Record them where the
  code makes the difference, in their words when possible, and as plan items when they are
  features.
- Do not push. What leaves the machine is the user's call.

## Parallel work

- Independent pieces of work (separate files, separate documents, separate measurements) can go to
  subagents or forks that run at the same time. Give each one a precise brief: its files, what it
  must not touch, how it verifies, and to report without committing when the pieces land
  together.
- **Review every diff** a helper produces before it lands, and check its claims against the code:
  a helper that corrects a document may introduce a wrong statement with the right tone.
- Each helper writes its scratch output under its own `/tmp/<project>/<task>/`. Two helpers
  sharing a build prefix change each other's binaries under a running measurement.
- A helper in a git worktree lands by cherry-pick or rework; then the worktree and its branch are
  removed.
- Long measurements run in the background. Parallel runs of an emulator or of the agent host
  speed up statistics, one process per core at most.

## Notes that outlive the session

- **State and decisions** go where the next session will look: the plan's ticks, commit
  messages, the port maps, and the agent's own notes (memory) for what the repository should not
  hold: where the captures are, the harness scripts, the traps of the machine.
- **The user's decisions** are recorded with their words and the date.
- **Tool defects.** A problem found in a tool (decompiler, emulator, interpreter) is logged in
  that tool's own log, outside the repository, in the same pass that finds it: the symptom, what
  the original's bytes say, what the tool produced, and a reproduction. If it blocks the work,
  stop and raise the flag.

## Housekeeping

- Scratch output under `/tmp/<project>` (a memory file system, cleared at reboot), deleted when the
  check is done. Never build into `zig-out`, where the user's own build lives.
- Copy the game directory before an emulator runs it: the original writes its configuration and
  its saves into its own directory.
- Stop emulators, Xvfb servers and hosts by PID when a check ends: a forgotten emulator plays
  sound on the user's machine, and a forgotten X server keeps its last picture for the next run.
- The harness scripts that study the original or drive the game live outside the repository,
  with a README of what each one does.
