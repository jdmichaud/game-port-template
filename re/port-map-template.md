# The TODO(subsystem) port map

Copy this outline to `docs/<subsystem>-port-map.md` in the `-re` repository for each subsystem of
the original (the simulation, the rules, the renderer, the audio, the computer players, the films,
the menus...). A port map is the record of what the original does and where it is in the port. It
explains the code; it does not tell a history.

Rules for the whole map:

- Every address is read out of the original's own bytes; name the version it comes from.
- One sentence per measurement: what was measured and what it showed. No tool commands, run ids
  or logs: the tools live outside the repository.
- Code comments cite the map's sections: once a section is cited, keep its number.
- A claim that the code contradicts is a defect of the map; fix it when the code changes.

## Naming warnings, read first

The names that mislead: a global whose name in the recovered code says the opposite of what it
holds, two routines with the same name, a unit that is not what it seems (a count that is not a
slot count, an angle unit that is not degrees).

## 1. The pieces

| Piece | Original (routine, address) | Port (file) |
| --- | --- | --- |
| TODO | `routine_name` 0x0000 | `src/shared/<subsystem>/<file>.zig` |

## 2. Data

The layouts the subsystem reads and writes: records with their offsets and widths, tables with
their addresses and counts, and which of them start-up code builds rather than reads from the
file.

## 3. How it works

The algorithms, in the original's order, with the details that decide results: integer widths,
rounding points, wrapping, the order of calls to the random generator, the tie-breaking of
events.

## 4. Pitfalls

What was wrong in an earlier reading or in the port, and the rule that fixed it, so that the next
reader does not repeat it.

## 5. Evidence

How the port was checked against the original, one sentence each: the reference vectors, the
traces, the screens compared, the statistics, with their counts ("21 of 21 traces agree", "480 of
480 rows identical", "no level differs, p = 0.93").

## 6. What is left out

The parts of the original the port does not reproduce, and why: unreachable code, a device the
port does not emulate, a deliberate difference decided by the user.
