# Network play

For a port whose original plays over a link, or that adds network play. A port without it deletes
this file and the network items from its plan in one commit. It is part of the design: change it
only with the user's approval, as DESIGN.md.

## The model

Every peer runs the whole game and applies the same inputs in the same order; the canonical game
state (players, simulation, rules, RNG; never the camera, menus, devices or connections) stays
equal, and a state hash compared on a schedule proves it. Human input, computer players, replays
and the network use the same typed commands, checked by shared game logic. Pick the model by the
game:

- **Turn-based**: the active player proposes complete commands, the host peer orders them, and
  the state hash is compared at each turn boundary. Previews of aiming or movement are separate
  from commands, rate-limited and dropped when stale.
- **Real-time**: input lockstep. Each peer sends its input for tick `T + delay`, and a tick runs
  only once every peer's input for it is in. The delay (2 to 6 ticks in a previous port) is chosen
  from the measured round trip; the state hash is compared every few ticks.

Lockstep runs at the slower peer's pace: a line per machine (ticks run, time busy, time waiting,
round trip) tells a slow machine from a slow link.

In both, a mismatch pauses the game with its diagnostics, a disconnect keeps the session's epoch,
and a duplicated message never acts twice.

## The pieces

- The game logic applies validated commands or inputs and exposes state and outcomes.
- The session protocol, in shared code, is versioned: a handshake (protocol and simulation
  versions, asset identity, rules, players, initial state), ordering, acknowledgements, retries
  and epochs.
- The platform transport moves whole messages, reliably and in order, while a connection lives,
  and reports connection events. The skeleton has none: the port adds it to the platform contract
  (connect, listen, send, close; connected, disconnected and received events) and to each backend.
  `send` means accepted into a bounded queue; received messages arrive through `pollEvents` and
  stay valid until the next call.

## The native game as the server

The native game serves the browser build (`docs/browser.md`) and a WebSocket on one port
(`--netplay [ADDRESS:]PORT` in previous ports). It serves the page, script and module built into
the executable, never files beside it, and the game's files from its `AssetSource`.

A relay mode of the same program (`--server [ADDRESS:]PORT`) serves the page and runs no game:
the first page to connect hosts, the others are clients. The server tells each page its role in a
text message (`host`, `client`), and tells the host when a client arrives and leaves (`peer N`,
`left N`); a two-byte client number goes before each binary message. The host's page shows each
client to the module as a connection of its own, so the game's host logic needs no listening
socket. When the host leaves, its clients' connections end and the next page to join hosts. Two
browsers is the special case of one client.

## Talking to the original

If the port must play against the original, its protocol is a separate adapter: an offline codec
from captured packets first, then its session rules.

## Testing

The test that matters most: two sessions in one process over a fake link, run for whole games and
compared by state hash. The link has latency (a delay too short for the game's must hold both
peers, not split them) and a dropped connection that reconnects into the same session; it does
not lose or reorder messages, which the transport's contract excludes. Then two real machines.

## Items a port adds to its plan

- **Session protocol**: handshake, ordering, commands or inputs, state hashes, recovery.
  Gate: two sessions over the fake link survive duplicates, stale epochs, invalid actions, a
  mismatch and a disconnect; protocol state stays outside the simulation.
- **First real transport** (a decision of the user's: WebSocket, the relay, ...): framing,
  connection events, queue limits, backpressure. Gate: two games play through it; failure and
  reconnection follow the contract.
- **Multiplayer acceptance**: whole games between two machines and under controlled latency.
  Gate: the peers agree on canonical outcomes; latency and duplicates do not change a result.
- **The original's protocol** (only if needed): a packet codec from verified captures, then its
  session rules. Gate: recorded sessions replay; a real original peer completes the supported
  actions.

TODO: what the original's network code does (message types, the synchronisation model), from its
bytes.
