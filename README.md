# Game port template

A starting point for porting an old game, typically a DOS game, to Linux, Windows and the browser
with Zig. It holds the way of working and the technical design that previous ports arrived at;
the examples in its documents come from them.

The template has two parts:

- **The way of working.** The rules for agents (`AGENTS.md`), the plan (`PLAN.md`), the design
  (`DESIGN.md`), and the notes in `docs/` on the process, the tests, the study of the original and
  the lessons learned.
- **A skeleton that builds and tests as it is.** The platform boundary, the three hosts (a
  headless agent host, an SDL host and a browser build), the test runner with its two suites, and
  a placeholder game in place of the real one.

The placeholder name of the project is `gameport`.

## Starting a port

1. **Copy the folder and name the project.** The name becomes the Zig module, the binaries
   (`mygame-agent`, `mygame-sdl`, `mygame-test`) and the browser files, so it must be a lowercase
   Zig identifier that is not a keyword: letters, digits and underscores. Replace `gameport`
   everywhere, in the contents and in the file names, give the package its own fingerprint, and
   start the port's own history:

   ```sh
   cp -r game-port-template mygame && cd mygame
   rm -rf .git .zig-cache zig-out zig-pkg
   grep -rlI gameport . | xargs sed -i 's/gameport/mygame/g'
   find . -depth -name '*gameport*' \
       -execdir sh -c 'mv "$1" "$(echo "$1" | sed s/gameport/mygame/g)"' _ {} \;
   grep -rniI gameport . || echo "renamed everywhere"
   # A renamed package needs its own fingerprint; `zig build` rejects the old one and suggests one.
   fp=$(zig build --prefix /tmp/mygame/out 2>&1 |
       sed -n 's/.*use this value: \(0x[0-9a-f]*\).*/\1/p')
   sed -i "s/\.fingerprint = 0x[0-9a-f]*/.fingerprint = $fp/" build.zig.zon
   git init && git add -A && git commit -m "Start mygame from the game port template"
   ```

   The test formats keep their `testkit-` names: they belong to the test kit, not to the game, so
   the rename leaves the recorded data and its digests as they are.

2. **Keep the original out of the repository.** The CD image, the installed game, captures of it
   and the tools that study it live outside the repository. Only the standalone build reads the
   game's files, to embed them. Recorded measurements of the original's behaviour may be
   committed as test data (`docs/testing.md`).
3. **Write the game into `DESIGN.md`.** Its TODO sections describe the original: the executable,
   the video modes, the sound hardware, the input devices, the network, and the subsystems that
   the port maps will cover. The rest of the design applies as it is; change it only with the
   user's approval.
4. **Plan the first items.** `PLAN.md` holds the phases that previous ports went through, with
   placeholders where the game decides. Fill in the scope and the gate of the first items, and
   commit the plan before the work starts.
5. **Check the start.** The steps are listed at the top of `build.zig`: `zig build`, `zig build
   test` and the two suites pass on the skeleton before the first change.
6. **Replace the placeholder game.** `src/shared/game.zig` is where the real game grows, behind
   the same platform contracts that the hosts already drive.

## The folder

- `AGENTS.md`: the rules for agents working in the repository. Read it first.
- `PLAN.md`: the work, in phases and items, each with a scope and a gate.
- `DESIGN.md`: the technical design: the platform boundary, the hosts, determinism, the builds.
- `docs/process.md`: how a session and an item go, and how to work with the user and with
  subagents.
- `docs/testing.md`: what is tested, how, and what may be committed as reference data.
- `docs/reverse-engineering.md`: how to study the original: sources, oracles, emulators, port
  maps.
- `docs/port-map-template.md`: the outline of a subsystem's port map.
- `docs/lessons.md`: the lessons and traps of previous ports that apply to any port.
- `src/shared`: the `gameport` module, the game and everything the targets share. It links
  nothing. `platform.zig` holds the platform contracts, `workflow.zig` the interface of the I/O
  workflow executor, `memory.zig` the in-memory providers, `iso.zig` the ISO 9660 reader, and
  `game.zig` the placeholder game.
- `src/testkit`: cases, typed observations, comparison, verdicts and reports. It depends only on
  the standard library.
- `src/testrunner`: `gameport-test`, the scenario runner, and its drivers.
- `src/agent`: `gameport-agent`, the headless host: the agent backend and the JSON-lines host,
  whose commands `host.zig` lists. It never links SDL.
- `src/native`: host I/O for the native targets: the directory and ISO asset sources, the storage,
  the workflow executor and the command line.
- `src/sdl`: `gameport-sdl`, the interactive host on SDL2, for Linux and Windows.
- `src/web`: the browser build: the WebAssembly module, its backend, the page and its script.
- `tests/public`: synthetic and redistributable test cases.
- `tests/reference`: cases whose expectations are recordings of the original's behaviour.
- `tools`: build helpers only: the check that the agent binary links no SDL, and the asset
  embedding of the standalone build. Tools that study the original do not belong here.
