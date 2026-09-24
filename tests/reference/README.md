# The reference suite

Cases whose expectations are recordings of the original's behaviour: the outputs of its routines
over many inputs, traces of its simulation, the decisions of its rules, read out of the running
game. The recordings are made outside this repository, with tools that run the original; only
their outputs, as observation files under `data/`, are committed (docs/testing.md).

`zig-xorshift32.case.json` is an example of the main pattern and replays vectors of the placeholder
game's generator. Replace it with the first recording of the original.
