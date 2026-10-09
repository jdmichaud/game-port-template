# The browser build

For a port that runs in the browser (`src/web`, the `web` and `web-check` steps). A port without
it deletes this file, `src/web`, those steps and the browser items of its plan in one commit. It is
part of the design: change it only with the user's approval, as DESIGN.md.

## The module

The shared game compiled for `wasm32-freestanding`: no libc, no compiler-rt, no entry point,
imported memory. The page's hand-written JavaScript creates the memory, provides the host
functions (canvas presentation, input with pointer lock, Web Audio, storage) and the few helpers
the compiler emits calls to (128-bit multiply and divide, the math functions the code uses), and
calls one update per animation frame. The build checks the module's list of imports: an
unexpected import is an error, and `web-check` tests each helper against compiler-rt (it needs
Node.js).

When every file the game needs is fetched before the first update, the module needs no
suspension mechanism. Only a game that must stream files during play needs one (Asyncify, with a
pinned `wasm-opt`, a sized continuation buffer and a larger module; or JSPI where browsers
support it), behind the I/O workflows of DESIGN.md section 4.

The browser keeps the game's records in its own storage, per address, and gives them back before
the game starts.

## Where the game's files come from

The server that sends the page serves them: the page reads `assets/manifest.json` and fetches each
`assets/NAME` it lists, and that server is the native game, reading the user's copy through its
`AssetSource` (`docs/network.md`). The page never asks the player to pick or upload the original's
files. A page without a manifest says so and stops; it does not run a game without its files.

## The page looks like the game

The player sees the game's style from the first frame. The page fetches first the few files the
module needs to draw a screen, and from then on the module draws the loading screen and its
progress itself, in the game's own palette, font and boxes. Until then, and for an error, the
page's own text stands in, in the game's colours and the closest font, never in a browser or
framework style. Messages reach the player in the game's words and look, not as browser dialogs.

## Lessons

- **The test suites never load the browser module.** A 128-bit division and float `@round`,
  `@min`, `@max`, `std.math.hypot` in shared code became imports that the page refused, and the
  browser build did not start for hours while every suite passed. `zig build check` runs the
  import check; `@sqrt`, `@floor`, `@ceil`, `@trunc` and `@abs` are WebAssembly instructions, the
  others are not. A Debug build can import more than a release build.
- **Audio and pointer lock need a user gesture**, and a browser without a sound device keeps audio
  suspended. A script that waits for the page's state waits on the element that carries it, not
  on the visible text.
- **Ask for the plain pointer lock.** A lock with `unadjustedMovement` worked in every browser on
  Linux, but in Chrome and Edge on Windows the motion stopped at the browser window's border.
  Headless and Xvfb runs cannot show it: ask the user for the browser and the system.

## Items a port adds to its plan

- **Browser build and I/O**: the module without libc or compiler-rt, its imports from the page,
  the files fetched from the server before the first update. Gate: the build checks its import
  list; served by the native game, the page loads every file from it, and without a manifest it
  stops with a message.
- **Browser host services**: canvas, input and pointer lock, Web Audio, storage, the transport.
  Gate: the game runs in Chromium and Firefox; its records survive a reload; the gesture that audio
  and pointer lock need is handled; from the first frame (loading, click to start, errors) the page
  is in the game's style, checked on screenshots against the native game.
- **Browser acceptance**: the reference scenarios, and network play if the port has it, in the
  declared browsers. Gate: the required observations pass in the browsers that were run.
