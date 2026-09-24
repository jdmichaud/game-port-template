// `zig build web-check`: the helpers that `gameport.js` gives the browser module in place of
// compiler-rt against compiler-rt itself.
//
//   node helpers_check.cjs GAMEPORT_JS PROBE_WITH_COMPILER_RT PROBE_WITH_HELPERS
//
// The two probes are `helpers_probe.zig`, built with compiler-rt and without it. Both run over the
// same inputs, the second with the script's helpers, and every result must be the same to the
// bit.
'use strict';
const fs = require('node:fs');
const path = require('node:path');

const [scriptPath, referencePath, probePath] = process.argv.slice(2);
if (!probePath) {
  console.error('usage: node helpers_check.cjs GAMEPORT_JS PROBE_WITH_COMPILER_RT PROBE_WITH_HELPERS');
  process.exit(2);
}
const { gameportHelpers } = require(path.resolve(scriptPath));

let failures = 0;
function fail(text) {
  failures += 1;
  if (failures <= 20) console.log('FAIL ' + text);
}

// The probes declare 2 MiB of memory, at least and at most (build.zig).
function load(file, withHelpers) {
  const module = new WebAssembly.Module(fs.readFileSync(file));
  const memory = new WebAssembly.Memory({ initial: 32, maximum: 32 });
  const env = { memory };
  if (withHelpers) Object.assign(env, gameportHelpers(memory));
  const imports = WebAssembly.Module.imports(module).map((i) => `${i.module}.${i.name}`).sort();
  const instance = new WebAssembly.Instance(module, { env });
  return { exports: instance.exports, memory, imports };
}

const reference = load(referencePath, false);
const probe = load(probePath, true);
const importsText = (list) => list.join(', ');
if (importsText(reference.imports) !== 'env.memory') fail('the probe with compiler-rt imports ' + importsText(reference.imports));
if (importsText(probe.imports) !== 'env.__multi3, env.memory') fail('the probe without compiler-rt imports ' + importsText(probe.imports));
console.log('imports without compiler-rt: ' + importsText(probe.imports));

// A fixed sequence of 32-bit words (mulberry32), so that a failure can be repeated.
let seed = 0x5eed2023;
function word() {
  seed = (seed + 0x6d2b79f5) >>> 0;
  let t = seed;
  t = Math.imul(t ^ (t >>> 15), t | 1);
  t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
  return (t ^ (t >>> 14)) >>> 0;
}
const u64 = () => (BigInt(word()) << 32n) | BigInt(word());
const mask = (bits) => (1n << BigInt(bits)) - 1n;
const specials128 = [0n, 1n, 2n, mask(32), mask(63), 1n << 63n, mask(64), 1n << 64n, (1n << 64n) + 1n, 1n << 127n, mask(127), mask(128)];

// An operand of each shape: any 128 bits, a 64-bit value (the widening products of a hash), a
// short value, one of a random length, or a special.
function operand() {
  switch (word() % 6) {
    case 0: return (u64() << 64n) | u64();
    case 1: return u64();
    case 2: return BigInt(word());
    case 3: return ((u64() << 64n) | u64()) & mask(word() % 129);
    case 4: return specials128[word() % specials128.length];
    default: return ((u64() << 64n) | u64()) >> BigInt(word() % 128);
  }
}

const lo = (v) => v & mask(64);
const hi = (v) => v >> 64n;
function result(side) {
  const view = new DataView(side.memory.buffer);
  const at = side.exports.probe_result();
  return view.getBigUint64(at, true) | (view.getBigUint64(at + 8, true) << 64n);
}

function checkWide(name, fn, count) {
  for (let i = 0; i < count; i++) {
    const a = operand();
    const b = operand();
    reference.exports[fn](lo(a), hi(a), lo(b), hi(b));
    probe.exports[fn](lo(a), hi(a), lo(b), hi(b));
    const want = result(reference);
    const got = result(probe);
    if (want !== got) fail(`${name}(${a}, ${b}): ${got}, not ${want}`);
  }
  return count;
}

const products = checkWide('__multi3', 'probe_mul', 300000);
console.log(`__multi3: ${products} products`);
console.log(failures === 0 ? 'the helpers give compiler-rt\'s results to the bit' : `${failures} differences`);
process.exitCode = failures === 0 ? 0 : 1;
