const PROTOCOLS = ['v3.bsatn.spacetimedb', 'v2.bsatn.spacetimedb'];
const OPEN = 1;
const MAX_MESSAGE_BYTES = 64 * 1024 * 1024;

export function createBrowserTransport() {
  let memory;
  let nextHandle = 1;
  const sockets = new Map();
  const decoder = new TextDecoder();

  function readString(pointer, length) {
    return decoder.decode(new Uint8Array(memory.buffer, pointer >>> 0, length >>> 0));
  }

  async function decompressFrame(data) {
    if (data.length === 0) throw new Error('Empty WebSocket frame');
    if (data.length > MAX_MESSAGE_BYTES) throw new Error('WebSocket message too large');
    const tag = data[0];
    if (tag === 0) return data;
    const format = tag === 1 ? 'brotli' : tag === 2 ? 'gzip' : undefined;
    if (!format) throw new Error(`Unknown SpacetimeDB compression tag ${tag}`);
    if (typeof DecompressionStream === 'undefined') {
      throw new Error(`${format} decompression is unavailable in this browser`);
    }
    const stream = new Blob([data.subarray(1)]).stream().pipeThrough(new DecompressionStream(format));
    const reader = stream.getReader();
    const chunks = [];
    let total = 0;
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      total += value.length;
      if (total > MAX_MESSAGE_BYTES - 1) {
        await reader.cancel();
        throw new Error('Decompressed WebSocket message too large');
      }
      chunks.push(value);
    }
    const body = new Uint8Array(total);
    let offset = 0;
    for (const chunk of chunks) {
      body.set(chunk, offset);
      offset += chunk.length;
    }
    const frame = new Uint8Array(body.length + 1);
    frame[0] = 0;
    frame.set(body, 1);
    return frame;
  }

  async function openSocket(entry, host, port, path, token, secure) {
    const hostname = host.includes(':') && !host.startsWith('[') ? `[${host}]` : host;
    const authority = `${hostname}:${port}`;
    const wsScheme = secure ? 'wss:' : 'ws:';
    const httpScheme = secure ? 'https:' : 'http:';
    const base = `${wsScheme}//${authority}`;
    const url = new URL(path, base);

    if (token) {
      const marker = '/v1/database/';
      const markerIndex = url.pathname.indexOf(marker);
      const prefix = markerIndex >= 0 ? url.pathname.slice(0, markerIndex + 1) : '/';
      const tokenUrl = new URL(`${prefix}v1/identity/websocket-token`, `${httpScheme}//${authority}`);
      const response = await fetch(tokenUrl, {
        method: 'POST',
        headers: { Authorization: `Bearer ${token}` },
      });
      if (!response.ok) throw new Error(`WebSocket token exchange failed: ${response.status}`);
      const body = await response.json();
      url.searchParams.set('token', body.token);
    }

    const socket = new WebSocket(url, PROTOCOLS);
    socket.binaryType = 'arraybuffer';
    entry.socket = socket;
    socket.onopen = () => {
      if (!PROTOCOLS.includes(socket.protocol)) {
        entry.failed = true;
        socket.close();
      }
    };
    socket.onmessage = event => {
      const previous = entry.tail;
      entry.tail = previous.then(async () => {
        const normalized = await decompressFrame(new Uint8Array(event.data));
        if (normalized.length > 64 * 1024 * 1024) throw new Error('WebSocket message too large');
        entry.queue.push(normalized);
      }).catch(() => {
        entry.failed = true;
        socket.close();
      });
    };
    socket.onerror = () => {
      entry.failed = true;
    };
    socket.onclose = () => {
      entry.closed = true;
    };
  }

  const imports = {
    browser_ws_open(hostPointer, hostLength, port, pathPointer, pathLength, tokenPointer, tokenLength, secure) {
      if (!memory) return -1;
      const handle = nextHandle++;
      const entry = { socket: null, queue: [], tail: Promise.resolve(), closed: false, failed: false };
      sockets.set(handle, entry);
      const host = readString(hostPointer, hostLength);
      const path = readString(pathPointer, pathLength);
      const token = readString(tokenPointer, tokenLength);
      void openSocket(entry, host, port, path, token, secure !== 0).catch(() => {
        entry.failed = true;
      });
      return handle;
    },

    browser_ws_close(handle) {
      const entry = sockets.get(handle);
      if (!entry) return;
      entry.socket?.close();
      sockets.delete(handle);
    },

    browser_ws_send(handle, dataPointer, dataLength) {
      const entry = sockets.get(handle);
      if (!entry || entry.socket?.readyState !== OPEN || !memory) return -1;
      entry.socket.send(new Uint8Array(memory.buffer, dataPointer >>> 0, dataLength >>> 0));
      return 0;
    },

    browser_ws_message_length(handle) {
      const entry = sockets.get(handle);
      if (!entry || entry.failed) return -2;
      if (entry.queue.length > 0) return entry.queue[0].length;
      return entry.closed ? -1 : 0;
    },

    browser_ws_receive(handle, dataPointer, capacity) {
      const entry = sockets.get(handle);
      const frame = entry?.queue[0];
      if (!frame || !memory || capacity < frame.length) return -1;
      new Uint8Array(memory.buffer, dataPointer >>> 0, frame.length).set(frame);
      entry.queue.shift();
      return frame.length;
    },

    browser_ws_protocol(handle) {
      const protocol = sockets.get(handle)?.socket?.protocol;
      if (protocol === PROTOCOLS[0]) return 3;
      if (protocol === PROTOCOLS[1]) return 2;
      return 0;
    },
  };

  const odinEnv = {
    write(fd, pointer, length) {
      if (!memory || length === 0) return;
      const text = decoder.decode(new Uint8Array(memory.buffer, pointer >>> 0, length >>> 0));
      (fd === 2 ? console.error : console.log)(text);
    },
    rand_bytes(pointer, length) {
      if (!memory) throw new Error('Odin WASM memory is not attached');
      const bytes = new Uint8Array(memory.buffer, pointer >>> 0, length >>> 0);
      for (let offset = 0; offset < bytes.length; offset += 65536) {
        globalThis.crypto.getRandomValues(bytes.subarray(offset, Math.min(offset + 65536, bytes.length)));
      }
    },
    time_now() {
      return BigInt(Date.now());
    },
    time_sleep(milliseconds) {
      if (milliseconds > 0) throw new Error('Blocking time.sleep is unavailable in browser clients');
    },
    tick_now() {
      return performance.now();
    },
  };

  return {
    imports: { odin_env: odinEnv, stdb_browser: imports },
    attach(instanceOrMemory) {
      memory = instanceOrMemory instanceof WebAssembly.Memory
        ? instanceOrMemory
        : instanceOrMemory.exports.memory;
      if (!(memory instanceof WebAssembly.Memory)) throw new Error('Odin WASM memory is not exported');
    },
  };
}
