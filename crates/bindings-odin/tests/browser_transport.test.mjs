import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { createBrowserTransport } from '../client/browser_transport.js';

const encoder = new TextEncoder();
const memory = new WebAssembly.Memory({ initial: 1 });

function writeString(pointer, text) {
  const bytes = encoder.encode(text);
  new Uint8Array(memory.buffer, pointer, bytes.length).set(bytes);
  return bytes.length;
}

class MockWebSocket {
  static last;
  static all = [];

  constructor(url, protocols) {
    this.url = url;
    this.protocols = protocols;
    this.protocol = protocols[0];
    this.readyState = 0;
    this.binaryType = '';
    MockWebSocket.last = this;
    MockWebSocket.all.push(this);
  }

  send(data) {
    this.sent = new Uint8Array(data);
  }

  close() {
    this.readyState = 3;
    this.onclose?.();
  }
}

test('browser transport exchanges the auth token and queues binary frames', async () => {
  const originalWebSocket = globalThis.WebSocket;
  const originalFetch = globalThis.fetch;
  globalThis.WebSocket = MockWebSocket;
  globalThis.fetch = async (url, options) => {
    assert.match(String(url), /v1\/identity\/websocket-token$/);
    assert.equal(options.headers.Authorization, 'Bearer signed-token');
    return { ok: true, json: async () => ({ token: 'temporary-token' }) };
  };

  try {
    const transport = createBrowserTransport();
    transport.attach(memory);
    const imports = transport.imports.stdb_browser;
    const hostLength = writeString(8, 'db.example');
    const pathLength = writeString(64, '/proxy/v1/database/db/subscribe?compression=Gzip');
    const tokenLength = writeString(160, 'signed-token');
    const handle = imports.browser_ws_open(8, hostLength, 3000, 64, pathLength, 160, tokenLength, 1);
    await new Promise(resolve => setImmediate(resolve));

    const socket = MockWebSocket.last;
    assert.equal(socket.binaryType, 'arraybuffer');
    const socketUrl = new URL(socket.url);
    assert.equal(socketUrl.protocol, 'wss:');
    assert.equal(socketUrl.searchParams.get('token'), 'temporary-token');
    assert.deepEqual(socket.protocols, ['v3.bsatn.spacetimedb', 'v2.bsatn.spacetimedb']);
    assert.equal(socket.protocol, 'v3.bsatn.spacetimedb');
    assert.equal(imports.browser_ws_protocol(handle), 3);
    socket.protocol = 'v2.bsatn.spacetimedb';
    assert.equal(imports.browser_ws_protocol(handle), 2);
    socket.protocol = 'v3.bsatn.spacetimedb';

    socket.readyState = 1;
    const sent = Uint8Array.of(1, 2, 3);
    new Uint8Array(memory.buffer, 256, sent.length).set(sent);
    assert.equal(imports.browser_ws_send(handle, 256, sent.length), 0);
    assert.deepEqual([...socket.sent], [...sent]);

    const frame = Uint8Array.of(0, 6, 9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1);
    socket.onmessage({ data: frame.buffer });
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(imports.browser_ws_message_length(handle), frame.length);
    assert.equal(imports.browser_ws_receive(handle, 512, frame.length), frame.length);
    assert.deepEqual([...new Uint8Array(memory.buffer, 512, frame.length)], [...frame]);
    imports.browser_ws_close(handle);
  } finally {
    globalThis.WebSocket = originalWebSocket;
    globalThis.fetch = originalFetch;
  }
});

const repositoryRoot = fileURLToPath(new URL('../../../', import.meta.url));
const browserFixturePath = fileURLToPath(new URL('./browser_wasm', import.meta.url));

test('Odin browser client completes the asynchronous connection handshake', async t => {
  const tempDirectory = await fs.mkdtemp(path.join(os.tmpdir(), 'stdb-odin-browser-'));
  const browserWasmPath = path.join(tempDirectory, 'browser_client.wasm');
  const originalWebSocket = globalThis.WebSocket;
  const originalFetch = globalThis.fetch;
  let instance;
  let tokenExchanges = 0;
  const authorizationHeaders = [];

  try {
    const build = spawnSync(
      'odin',
      [
        'build',
        browserFixturePath,
        '-collection:stdb=crates/bindings-odin',
        '-target:js_wasm32',
        `-out:${browserWasmPath}`,
      ],
      { cwd: repositoryRoot, encoding: 'utf8' }
    );
    if (build.error?.code === 'ENOENT') {
      t.skip('Odin compiler is not installed');
      return;
    }
    assert.equal(build.status, 0, `${build.stdout}\n${build.stderr}`);

    globalThis.WebSocket = MockWebSocket;
    globalThis.fetch = async (url, options) => {
      tokenExchanges += 1;
      authorizationHeaders.push(options.headers.Authorization);
      assert.match(String(url), /v1\/identity\/websocket-token$/);
      assert.ok(['Bearer signed-token', 'Bearer token'].includes(options.headers.Authorization));
      return { ok: true, json: async () => ({ token: 'temporary-token' }) };
    };

    const bridge = createBrowserTransport();
    const wasm = await fs.readFile(browserWasmPath);
    ({ instance } = await WebAssembly.instantiate(wasm, bridge.imports));
    bridge.attach(instance);
    instance.exports._start();

    assert.equal(instance.exports.browser_connect(), 0);
    await new Promise(resolve => setImmediate(resolve));
    const socket = MockWebSocket.last;
    assert.equal(new URL(socket.url).searchParams.get('token'), 'temporary-token');

    const initialConnection = new Uint8Array(59);
    initialConnection[50] = 5;
    initialConnection.set(new TextEncoder().encode('token'), 54);
    socket.readyState = 1;
    socket.onmessage({ data: initialConnection.buffer });
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(tokenExchanges, 1);
    assert.equal(bridge.imports.stdb_browser.browser_ws_message_length(1), initialConnection.length);
    assert.equal(instance.exports.browser_poll(), 0);

    assert.equal(instance.exports.browser_subscribe(), 0);
    const firstSocket = MockWebSocket.last;
    assert.ok(firstSocket.sent);
    assert.equal(firstSocket.sent[0], 0);
    firstSocket.close();
    assert.equal(instance.exports.browser_poll(), 7);
    for (let attempt = 0; attempt < 5 && MockWebSocket.last === firstSocket; attempt += 1) {
      await new Promise(resolve => setImmediate(resolve));
    }

    assert.equal(tokenExchanges, 2);
    assert.deepEqual(authorizationHeaders, ['Bearer signed-token', 'Bearer token']);
    const secondSocket = MockWebSocket.last;
    assert.notEqual(secondSocket, firstSocket);
    secondSocket.readyState = 1;
    secondSocket.onmessage({ data: initialConnection.buffer });
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(bridge.imports.stdb_browser.browser_ws_message_length(2), initialConnection.length);
    assert.equal(instance.exports.browser_poll(), 0);
    assert.ok(secondSocket.sent);
    assert.equal(secondSocket.sent[0], 5);
  } finally {
    instance?.exports.browser_disconnect();
    globalThis.WebSocket = originalWebSocket;
    globalThis.fetch = originalFetch;
    await fs.rm(tempDirectory, { recursive: true, force: true });
  }
});
