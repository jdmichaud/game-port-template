# gameport implementation plan

- Design: `DESIGN.md`. Tests: `docs/testing.md`.
- Unchecked items are open work, in the order they are to be done; dependencies name the
  prerequisites. The user's decisions are recorded under Decisions, each with its date.
- An item is a title, its dependencies, one line of scope and a gate. Complete it through small
  commits with its tests; tick it ([x]) when the gate is met. A partly done item may carry checked
  and unchecked sub-points. No commentary: evidence goes in commit messages and docs.
- A missing item is added here first, in its own commit, with the rationale in the commit message.
  Concrete versions and API schemas are pinned within their items; they do not reopen settled
  architecture.
- Keep proprietary inputs and captures outside the repository, and personal paths out of committed
  files.
- The items are the game's own. Previous ports went through these phases, each closed by a
  milestone that the user played: build and test foundations (the oracles of the original
  first); a first verified headless slice of the core mechanic (M1); a playable slice in one mode
  (M2); the complete local game (M3); then Windows, and the browser and network play if the port
  has them (`docs/browser.md`, `docs/network.md`).

## Items

TODO: the first items, each with its scope and gate.

## Standing rule

- [ ] **S1 — The repository stands alone** — Depends: none.
  - Building and testing use nothing outside the repository and no proprietary data of the game.
    Only a build that embeds the game's files (if the port has one) reads them, from the user's
    copy.
  - Gate, checked at each milestone: in a fresh clone with an empty environment, `zig build
    check` and TODO(the port's own suites) pass; and each executable, copied alone into an empty
    directory, runs (with network play, it serves its page, script and module with its server
    options).

## Additions to the original

Items the original does not have, added at the user's request, one per addition (A1, A2, ...),
each with a scope and a gate like any item.

## Decisions

Each with the date the user took it; a decision that changes is edited, and git log keeps the old.
