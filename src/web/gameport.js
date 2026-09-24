// The host of the browser build. It loads the game's files and the WebAssembly module from the
// server that sent this page, then runs the game: one update for each animation frame, the frames
// to the canvas, the keys, the mouse and the sound to the module and back. The module keeps the
// one table of keys and all game logic; this script only moves data.
'use strict';

// --- the helpers that the module imports in place of compiler-rt ------------------------------

// The module links no compiler-rt (DESIGN.md 5.3), so the functions of it that the game calls are
// imports, and these give the same results to the bit. `__multi3` is the product of two 128-bit
// integers: BigInt is exact. A 128-bit value crosses as two 64-bit halves, low first, and the
// result goes to the address in the first argument. `zig build web-check` compares each helper
// with compiler-rt's. A game that calls another (a 128-bit quotient, `exp`) adds its helper here,
// as a previous port's script did for `__udivti3` and `exp`.
function gameportHelpers(memory) {
  const mask64 = (1n << 64n) - 1n;

  function wide(lo, hi) {
    return (BigInt.asUintN(64, hi) << 64n) | BigInt.asUintN(64, lo);
  }

  function store(at, value) {
    const view = new DataView(memory.buffer);
    view.setBigUint64(at, value & mask64, true);
    view.setBigUint64(at + 8, (value >> 64n) & mask64, true);
  }

  return {
    __multi3(at, aLo, aHi, bLo, bHi) {
      store(at, wide(aLo, aHi) * wide(bLo, bHi));
    },
  };
}

(() => {
  // Under Node, which `zig build web-check` uses for the helpers above, there is no page.
  if (typeof document === 'undefined') return;
  const canvas = document.getElementById('screen');
  const overlay = document.getElementById('overlay');
  const message = document.getElementById('message');
  const context = canvas.getContext('2d', { alpha: false });
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();

  let memory = null;
  let wasm = null;
  let image = null;
  let started = false;

  // --- text through the module's scratch buffer ---------------------------------------------

  function writeScratch(text) {
    const bytes = encoder.encode(text);
    const n = Math.min(bytes.length, wasm.gp_scratch_len());
    new Uint8Array(memory.buffer, wasm.gp_scratch(), n).set(bytes.subarray(0, n));
    return n;
  }

  function readScratch(len) {
    return decoder.decode(new Uint8Array(memory.buffer, wasm.gp_scratch(), len));
  }

  function readString(ptr, len) {
    return decoder.decode(new Uint8Array(memory.buffer, ptr, len));
  }

  function errorText() {
    return readScratch(wasm.gp_error()) || 'unknown error';
  }

  // --- the memory that the module imports ---------------------------------------------------

  // The module declares the limits of the memory that it imports. The script reads them from the
  // import section, so the build is the one place that sets them.
  function memoryLimits(buffer) {
    const bytes = new Uint8Array(buffer);
    let at = 8;
    const leb = () => {
      let value = 0;
      let scale = 1;
      for (;;) {
        const b = bytes[at++];
        value += (b & 0x7f) * scale;
        if ((b & 0x80) === 0) return value;
        scale *= 128;
      }
    };
    // Two steps: `at += leb()` would add the length to the position from before the length.
    const skipName = () => {
      const length = leb();
      at += length;
    };
    while (at < bytes.length) {
      const id = bytes[at++];
      const size = leb();
      const end = at + size;
      if (id === 2) {
        const count = leb();
        for (let i = 0; i < count; i++) {
          skipName();
          skipName();
          const kind = bytes[at++];
          if (kind === 0) {
            leb();
          } else if (kind === 1) {
            at++;
            const flags = bytes[at++];
            leb();
            if (flags & 1) leb();
          } else if (kind === 2) {
            const flags = bytes[at++];
            const initial = leb();
            const maximum = (flags & 1) ? leb() : undefined;
            return { initial, maximum };
          } else if (kind === 3) {
            at += 2;
          }
        }
      }
      at = end;
    }
    return null;
  }

  // --- presentation -------------------------------------------------------------------------

  // The canvas has the size of the game's page. CSS scales it to the window: by a whole factor of
  // device pixels when the page fits, else by the largest factor that fits.
  function fit() {
    const ratio = window.devicePixelRatio || 1;
    const room = Math.min(window.innerWidth * ratio / canvas.width, window.innerHeight * ratio / canvas.height);
    const scale = room >= 1 ? Math.floor(room) : room;
    canvas.style.width = (canvas.width * scale / ratio) + 'px';
    canvas.style.height = (canvas.height * scale / ratio) + 'px';
  }

  function setResolution(width, height) {
    canvas.width = width;
    canvas.height = height;
    image = context.createImageData(width, height);
    fit();
  }

  function present(ptr, width, height, stride) {
    if (!image || image.width !== width || image.height !== height) setResolution(width, height);
    const row = width * 4;
    const pixels = new Uint8Array(memory.buffer, ptr, stride * (height - 1) + row);
    if (stride === row) {
      image.data.set(pixels);
    } else {
      for (let y = 0; y < height; y++) image.data.set(pixels.subarray(y * stride, y * stride + row), y * row);
    }
    context.putImageData(image, 0, 0);
  }

  window.addEventListener('resize', () => {
    fit();
    if (started) {
      const ratio = window.devicePixelRatio || 1;
      wasm.gp_resized(Math.round(window.innerWidth * ratio), Math.round(window.innerHeight * ratio));
    }
  });

  // --- sound --------------------------------------------------------------------------------

  // The module queues interleaved 16-bit frames. Each block becomes an AudioBuffer that starts
  // where the previous block ends, on the output's own clock. The queue is at most one second.
  const audio = { context: null, open: false, rate: 0, next: 0, nodes: [] };

  function makeAudioContext(rate) {
    const Context = window.AudioContext || window.webkitAudioContext;
    if (!Context) return null;
    try {
      return new Context({ sampleRate: rate, latencyHint: 'interactive' });
    } catch (e) {
      try {
        return new Context({ latencyHint: 'interactive' });
      } catch (e2) {
        return null;
      }
    }
  }

  function audioOpen(rate, channels) {
    if (channels < 1 || channels > 2) return 0;
    if (!audio.context || audio.context.sampleRate !== rate) {
      const made = makeAudioContext(rate);
      if (!made) return 0;
      if (audio.context) audio.context.close().catch(() => {});
      audio.context = made;
    }
    audio.context.resume().catch(() => {});
    audio.open = true;
    audio.rate = audio.context.sampleRate;
    audio.next = 0;
    audio.nodes = [];
    return audio.rate;
  }

  function clockFrames() {
    return audio.context.currentTime * audio.rate;
  }

  function audioQueued() {
    if (!audio.open) return 0;
    return Math.max(0, audio.next - clockFrames());
  }

  function audioQueue(ptr, frames, channels) {
    if (!audio.open) return 0;
    const now = clockFrames();
    // A queue that ran dry starts again five milliseconds ahead of the clock, not in the past.
    if (audio.next < now) audio.next = Math.ceil(now + audio.rate * 0.005);
    const room = Math.floor(audio.rate - (audio.next - now));
    const n = Math.min(frames, Math.max(room, 0));
    if (n <= 0) return 0;
    const buffer = audio.context.createBuffer(channels, n, audio.rate);
    const samples = new Int16Array(memory.buffer, ptr, n * channels);
    for (let c = 0; c < channels; c++) {
      const out = buffer.getChannelData(c);
      for (let i = 0; i < n; i++) out[i] = samples[i * channels + c] / 32768;
    }
    const node = audio.context.createBufferSource();
    node.buffer = buffer;
    node.connect(audio.context.destination);
    node.onended = () => {
      const i = audio.nodes.indexOf(node);
      if (i >= 0) audio.nodes.splice(i, 1);
    };
    node.start(audio.next / audio.rate);
    audio.nodes.push(node);
    audio.next += n;
    return n;
  }

  function audioState() {
    if (!audio.open || !audio.context) return 0;
    return audio.context.state === 'running' ? 1 : 2;
  }

  function audioClear() {
    for (const node of audio.nodes) {
      try { node.stop(); } catch (e) { /* It has already stopped. */ }
    }
    audio.nodes = [];
    if (audio.context) audio.next = Math.ceil(clockFrames());
  }

  function audioClose() {
    audioClear();
    audio.open = false;
  }

  // --- the pointer --------------------------------------------------------------------------

  // A game that reads the mouse as relative counts asks for the pointer lock. A browser gives the
  // lock only for a click: the click that takes the lock belongs to the page, not to the game.
  const pointer = { wanted: false, locked: false, swallowUp: false, x: 0, y: 0, restX: 0, restY: 0 };

  // The counts without the system's pointer acceleration where the browser can, as the native
  // host reads them; else the plain lock.
  function requestLock() {
    const fallback = () => {
      try {
        const again = canvas.requestPointerLock();
        if (again && again.catch) again.catch(() => {});
      } catch (e) { /* The browser refused; the next click asks again. */ }
    };
    try {
      const request = canvas.requestPointerLock({ unadjustedMovement: true });
      if (request && request.catch) request.catch(fallback);
    } catch (e) {
      fallback();
    }
  }

  function setRelativeMouse(enabled) {
    pointer.wanted = enabled !== 0;
    if (pointer.wanted && !pointer.locked) requestLock();
    if (!pointer.wanted && pointer.locked) document.exitPointerLock();
    return pointer.locked ? 1 : 0;
  }

  document.addEventListener('pointerlockchange', () => {
    pointer.locked = document.pointerLockElement === canvas;
    if (started) wasm.gp_capture(pointer.locked ? 1 : 0);
  });

  // A position on the canvas in page pixels, clamped to the page.
  function pagePoint(event) {
    const box = canvas.getBoundingClientRect();
    const x = Math.floor((event.clientX - box.left) * canvas.width / Math.max(box.width, 1));
    const y = Math.floor((event.clientY - box.top) * canvas.height / Math.max(box.height, 1));
    return [Math.min(Math.max(x, 0), canvas.width - 1), Math.min(Math.max(y, 0), canvas.height - 1)];
  }

  // --- the network --------------------------------------------------------------------------

  // The skeleton has no network game. A port that adds one opens WebSockets here and reports
  // their events to the module (see the platform's Transport).
  const netConnect = () => -1;
  const netSend = () => -1;
  const netClose = () => {};

  // --- the game's records, kept in the browser ----------------------------------------------

  // Each record that the game saves is kept in the browser's storage for this page's address, as
  // base64 under `gameport:NAME`, and goes back to the module at the next load, before the game
  // starts. A browser that refuses (no storage, or a full one) fails the save, as a disk would.
  const recordPrefix = 'gameport:';

  function toBase64(bytes) {
    let text = '';
    for (let i = 0; i < bytes.length; i += 0x8000) text += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    return btoa(text);
  }

  function fromBase64(text) {
    const raw = atob(text);
    const bytes = new Uint8Array(raw.length);
    for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
    return bytes;
  }

  function storageSave(namePtr, nameLen, bytesPtr, len) {
    try {
      localStorage.setItem(recordPrefix + readString(namePtr, nameLen), toBase64(new Uint8Array(memory.buffer, bytesPtr, len)));
      return 1;
    } catch (e) {
      console.warn('[gameport] the browser did not keep a record: ' + e.message);
      return 0;
    }
  }

  function storageDelete(namePtr, nameLen) {
    try {
      localStorage.removeItem(recordPrefix + readString(namePtr, nameLen));
      return 1;
    } catch (e) {
      return 0;
    }
  }

  // The records of earlier loads. A damaged one is left out; without storage there are none.
  function storedRecords() {
    const records = [];
    try {
      for (let i = 0; i < localStorage.length; i++) {
        const key = localStorage.key(i);
        if (!key || !key.startsWith(recordPrefix)) continue;
        try {
          records.push([key.slice(recordPrefix.length), fromBase64(localStorage.getItem(key))]);
        } catch (e) { /* Not base64: left out. */ }
      }
    } catch (e) { /* No storage for this page. */ }
    return records;
  }

  function log(level, ptr, len) {
    const text = '[gameport] ' + readString(ptr, len);
    if (level === 0) console.error(text);
    else if (level === 1) console.warn(text);
    else console.log(text);
  }

  const imports = {
    js_now: () => performance.now(),
    js_set_resolution: setResolution,
    js_present: present,
    js_audio_open: audioOpen,
    js_audio_queue: audioQueue,
    js_audio_queued: audioQueued,
    js_audio_state: audioState,
    js_audio_clear: audioClear,
    js_audio_close: audioClose,
    js_set_relative_mouse: setRelativeMouse,
    js_net_connect: netConnect,
    js_net_send: netSend,
    js_net_close: netClose,
    js_log: log,
    js_storage_save: storageSave,
    js_storage_delete: storageDelete,
  };

  // --- input --------------------------------------------------------------------------------

  function onKey(event, down) {
    if (!started) return;
    const used = wasm.gp_key(writeScratch(event.code), down ? 1 : 0, event.repeat ? 1 : 0);
    // A key that types a character also gives the text, after the key, as the native host does.
    // AltGr types the characters of the keyboard's third level.
    const altGraph = event.getModifierState && event.getModifierState('AltGraph');
    if (down && event.key.length === 1 && !event.ctrlKey && !event.metaKey && (!event.altKey || altGraph)) {
      wasm.gp_text(writeScratch(event.key));
    }
    // The game's keys do not reach the browser: F5 does not reload, Tab does not move the focus.
    if (used) event.preventDefault();
  }

  function onMouseDown(event) {
    if (!started) return;
    event.preventDefault();
    canvas.focus();
    if (pointer.wanted && !pointer.locked) {
      requestLock();
      pointer.swallowUp = true;
      return;
    }
    const [x, y] = pointer.locked ? [pointer.x, pointer.y] : pagePoint(event);
    wasm.gp_button(event.button, 1, x, y);
  }

  function onMouseUp(event) {
    if (!started) return;
    if (pointer.swallowUp) {
      pointer.swallowUp = false;
      return;
    }
    const [x, y] = pointer.locked ? [pointer.x, pointer.y] : pagePoint(event);
    wasm.gp_button(event.button, 0, x, y);
  }

  function onMouseMove(event) {
    if (!started) return;
    // Whole counts only; each axis keeps its remainder, so a slow motion on a display with
    // fractional device pixels does not round to zero.
    pointer.restX += event.movementX || 0;
    pointer.restY += event.movementY || 0;
    const dx = Math.trunc(pointer.restX);
    const dy = Math.trunc(pointer.restY);
    pointer.restX -= dx;
    pointer.restY -= dy;
    if (pointer.locked) {
      pointer.x = Math.min(Math.max(pointer.x + dx, 0), canvas.width - 1);
      pointer.y = Math.min(Math.max(pointer.y + dy, 0), canvas.height - 1);
    } else {
      [pointer.x, pointer.y] = pagePoint(event);
    }
    if (dx !== 0 || dy !== 0 || !pointer.locked) wasm.gp_motion(dx, dy, pointer.x, pointer.y);
  }

  function onWheel(event) {
    if (!started) return;
    event.preventDefault();
    // One step for each event. Up, away from the player, is positive, as the native host has it.
    wasm.gp_wheel(Math.sign(event.deltaX), -Math.sign(event.deltaY));
  }

  function installInput() {
    window.addEventListener('keydown', (event) => onKey(event, true));
    window.addEventListener('keyup', (event) => onKey(event, false));
    canvas.addEventListener('mousedown', onMouseDown);
    window.addEventListener('mouseup', onMouseUp);
    document.addEventListener('mousemove', onMouseMove);
    canvas.addEventListener('wheel', onWheel, { passive: false });
    canvas.addEventListener('contextmenu', (event) => event.preventDefault());
    window.addEventListener('blur', () => { if (started) wasm.gp_focus(0); });
    window.addEventListener('focus', () => { if (started) wasm.gp_focus(1); });
  }

  // --- running ------------------------------------------------------------------------------

  function stop(text) {
    started = false;
    if (document.pointerLockElement) document.exitPointerLock();
    message.textContent = text;
    overlay.classList.remove('hidden', 'ready');
    overlay.onclick = null;
  }

  function frame() {
    let result;
    try {
      result = wasm.gp_frame();
    } catch (e) {
      stop('The game stopped: ' + e.message);
      return;
    }
    if (result === 0) requestAnimationFrame(frame);
    else if (result === 1) stop('The game has ended. Reload the page to play again.');
    else stop('The game stopped: ' + errorText());
  }

  // The first click starts the game. Browsers give sound and the pointer lock only after one.
  function begin() {
    overlay.classList.add('hidden');
    overlay.onclick = null;
    audio.context = makeAudioContext(44100);
    if (audio.context) audio.context.resume().catch(() => {});
    started = true;
    canvas.focus();
    requestAnimationFrame(frame);
  }

  async function fetchBytes(url) {
    const response = await fetch(url);
    if (!response.ok) throw new Error(url + ': ' + response.status + ' ' + response.statusText);
    return response.arrayBuffer();
  }

  function giveBytes(name, bytes, add) {
    const encoded = encoder.encode(name);
    const namePtr = wasm.gp_alloc(encoded.length);
    const dataPtr = wasm.gp_alloc(bytes.length);
    if (!namePtr || !dataPtr) throw new Error('out of memory for ' + name);
    new Uint8Array(memory.buffer, namePtr, encoded.length).set(encoded);
    new Uint8Array(memory.buffer, dataPtr, bytes.length).set(bytes);
    return add(namePtr, encoded.length, dataPtr, bytes.length);
  }

  async function load() {
    const code = await fetchBytes('gameport.wasm');
    const limits = memoryLimits(code);
    if (!limits) throw new Error('the module imports no memory');
    memory = new WebAssembly.Memory(limits.maximum === undefined
      ? { initial: limits.initial }
      : { initial: limits.initial, maximum: limits.maximum });
    const { instance } = await WebAssembly.instantiate(code, { env: { memory, ...imports, ...gameportHelpers(memory) } });
    wasm = instance.exports;
    wasm.gp_init();

    // The game's files: `assets/manifest.json` lists them as {"files": [{"name", "size"}]}. The
    // server that sends the page serves them; the skeleton's placeholder game runs without any.
    // Six are fetched at a time, and a file of another size than the listed one stops the load:
    // a server's error page is not a game file.
    let files = [];
    try {
      files = JSON.parse(decoder.decode(await fetchBytes('assets/manifest.json'))).files || [];
    } catch (e) { /* No manifest: no files. */ }
    let next = 0;
    let done = 0;
    const fetchSome = async () => {
      while (next < files.length) {
        const file = files[next++];
        // Each part of the name is escaped, and the separators stay.
        const url = 'assets/' + file.name.split('/').map(encodeURIComponent).join('/');
        const bytes = new Uint8Array(await fetchBytes(url));
        if (bytes.length !== file.size) throw new Error(file.name + ': ' + bytes.length + ' bytes, not ' + file.size);
        if (giveBytes(file.name, bytes, wasm.gp_add_asset) !== 0) throw new Error('invalid file name ' + file.name);
        done += 1;
        message.textContent = 'Loading… ' + done + ' of ' + files.length + ' files';
      }
    };
    await Promise.all(Array.from({ length: 6 }, fetchSome));

    // The records of earlier loads, before the game reads them.
    for (const [name, bytes] of storedRecords()) {
      if (giveBytes(name, bytes, wasm.gp_add_record) !== 0) console.warn('[gameport] a kept record was left out: ' + name);
    }

    if (wasm.gp_start() !== 0) throw new Error(errorText());
    installInput();
    message.textContent = 'Click to play';
    overlay.classList.add('ready');
    overlay.onclick = begin;
  }

  // For the page's own tests and for debugging: the state of the game as the module reports it.
  window.gameport = {
    inspect() {
      const n = wasm ? wasm.gp_inspect() : 0;
      return n ? JSON.parse(readScratch(n)) : null;
    },
    get started() { return started; },
  };

  load().catch((e) => stop('The game could not start: ' + e.message));
})();

if (typeof module === 'object') module.exports = { gameportHelpers };
