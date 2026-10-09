# Game port template

A starting point for porting an old game (a DOS program, a console cartridge, ...) to Linux,
Windows and the browser with Zig. It holds the way of working and the technical design that
previous ports arrived at; the examples in its documents come from them.

The template has two parts:

- **The way of working.** The rules for agents (`AGENTS.md`), the plan (`PLAN.md`), the design
  (`DESIGN.md`), and the notes in `docs/` on the tests, the study of the original and
  the lessons learned.
- **A skeleton that builds and tests as it is.** The platform boundary, the three hosts (a
  headless agent host, an SDL host and a browser build) and a placeholder game in place of the
  real one. It holds what every port needs the same way; what depends on the game (a network
  link, background I/O, a test runner, a build with the game's files inside) is described in
  `DESIGN.md` and `docs/testing.md` and grown by the port when its game asks for it.

The placeholder name of the project is `gameport`.

## Starting a port

1. **Copy the folder and name the project.** The name becomes the Zig module, the binaries
   (`mygame-agent`, `mygame-sdl`) and the browser files, so it must be a lowercase
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

2. **Keep the original out of the repository, and the research beside it.** The game's files and
   captures of it live outside both repositories. The study of the original gets its own versioned
   repository beside the port, `mygame-re`, not pushed unless the user decides: the tools that drive
   the emulator and the decompiler, the capture and compare scripts, and the port maps with the
   original's addresses. The port commits only recorded measurements (`docs/testing.md`).
3. **Write the game into `DESIGN.md`.** Its TODO sections describe the original: the executable,
   the video modes, the sound hardware, the input devices, the network, and the subsystems that
   the port maps will cover. The rest of the design applies as it is; change it only with the
   user's approval.
4. **Plan the first items.** `PLAN.md` holds the phases that previous ports went through, with
   placeholders where the game decides. Fill in the scope and the gate of the first items, and
   commit the plan before the work starts.
5. **Check the start.** The steps are listed at the top of `build.zig`: `zig build`, `zig build
   test` and `zig build smoke` pass on the skeleton before the first change. `zig build all`
   builds every binary at once: this machine's, Windows's under `zig-out/windows`, and the browser
   build.
6. **Replace the placeholder game.** `src/shared/game.zig` is where the real game grows, behind
   the same platform contracts that the hosts already drive.

## The folder

- `AGENTS.md`: the rules for agents working in the repository. Read it first.
- `PLAN.md`: the work, in phases and items, each with a scope and a gate.
- `DESIGN.md`: the technical design: the platform boundary, the hosts, determinism, the builds.
- `docs/testing.md`: what is tested, how, and what may be committed as reference data.
- `docs/reverse-engineering.md`: how to study the original: sources, oracles, emulators, port
  maps.
- `docs/port-map-template.md`: the outline of a subsystem's port map.
- `docs/lessons.md`: the lessons and traps of previous ports that apply to any port.
- `docs/browser.md`, `docs/network.md`: the browser build and network play, for a port that has
  them; a port without one deletes the file and its code in one commit.
- `src/shared`: the `gameport` module, the game and everything the targets share. It links
  nothing. `platform.zig` holds the platform contract, `memory.zig` the in-memory providers, and
  `game.zig` the placeholder game.
- `src/agent`: `gameport-agent`, the headless host: the agent backend under a virtual 60 Hz clock
  and a frame runner that injects keys and prints one JSON line of counters and digests. It never
  links SDL. A port grows it into the driver its checks need.
- `src/native`: host I/O for the native targets: the directory asset source, the directory
  storage, their shared contract tests, and the command line.
- `src/sdl`: `gameport-sdl`, the interactive host on SDL2, for Linux and Windows.
- `src/web`: the browser build: the WebAssembly module, its backend, the page and its script.
- `tools`: build helpers only: the check that the agent binary links no SDL. Tools that study the
  original do not belong here.
