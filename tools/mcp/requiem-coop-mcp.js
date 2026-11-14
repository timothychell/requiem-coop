#!/usr/bin/env node
// Requiem Co-op MCP server (DEVELOPMENT ONLY).
//
// Exposes the running game to an MCP client (e.g. Claude Code) the same way the dev bridge does,
// AND — when a client is connected and has opted into host remote control (debug builds) — exposes
// that connected client with the same read/write reach: run Lua in its REFramework, read its state,
// deploy files, and hot-reload Lua on it.
//
// Transport: newline-delimited JSON-RPC 2.0 over stdio (MCP stdio transport).
// Mechanism: writes reframework/data/bridge_cmd.json and reads bridge_out.json, i.e. it needs the
// game running with the dev bridge (tools/dev/requiem_bridge.lua) enabled. Peer tools additionally
// need a connected partner running a DEBUG build with "Allow host remote control" ticked.
//
// Game folder: $REQUIEM_GAME_ROOT, else the first Steam library that has the game.

'use strict';
const fs = require('fs');
const path = require('path');
const os = require('os');

// ---------------------------------------------------------------------------
// locate the game + data dir
// ---------------------------------------------------------------------------
function findGameRoot() {
  if (process.env.REQUIEM_GAME_ROOT && fs.existsSync(process.env.REQUIEM_GAME_ROOT)) {
    return process.env.REQUIEM_GAME_ROOT;
  }
  const rel = 'steamapps/common/RESIDENT EVIL requiem BIOHAZARD requiem';
  const libs = [];
  // common default + libraryfolders.vdf
  const candidates = [
    'C:/Program Files (x86)/Steam',
    path.join(os.homedir(), 'scoop/apps/steam/current'),
  ];
  for (const base of candidates) libs.push(base);
  for (const base of candidates.slice()) {
    const vdf = path.join(base, 'steamapps/libraryfolders.vdf');
    try {
      const txt = fs.readFileSync(vdf, 'utf8');
      for (const m of txt.matchAll(/"path"\s+"([^"]+)"/g)) libs.push(m[1].replace(/\\\\/g, '\\'));
    } catch (_) { /* ignore */ }
  }
  // also scan every fixed drive's SteamLibrary (covers D:\SteamLibrary\...)
  for (const d of ['C', 'D', 'E', 'F', 'G']) {
    libs.push(`${d}:/SteamLibrary`);
    libs.push(`${d}:/Steam`);
  }
  for (const base of libs) {
    const p = path.join(base, rel);
    if (fs.existsSync(p)) return p;
  }
  throw new Error('Game folder not found. Set REQUIEM_GAME_ROOT to the game directory.');
}

const GAME_ROOT = findGameRoot();
const DATA_DIR = path.join(GAME_ROOT, 'reframework', 'data');
const CMD_FILE = path.join(DATA_DIR, 'bridge_cmd.json');
const OUT_FILE = path.join(DATA_DIR, 'bridge_out.json');
const LINK_FILE = path.join(DATA_DIR, 'coop_link.json');

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
function readJson(file) { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; } }

// ---------------------------------------------------------------------------
// Lua literal helpers (safely embed arbitrary text in a bridge command)
// ---------------------------------------------------------------------------
function luaLong(s) {
  s = String(s);
  let lvl = 0;
  // pick a long-bracket level that does not appear in the text
  while (s.includes(']' + '='.repeat(lvl) + ']') || s.includes('[' + '='.repeat(lvl) + '[')) lvl++;
  const eq = '='.repeat(lvl);
  // a leading newline is swallowed by Lua long strings, so add one to be safe
  return `[${eq}[\n${s}]${eq}]`;
}

// ---------------------------------------------------------------------------
// bridge round-trip
// ---------------------------------------------------------------------------
let lastProbe = 0;
async function bridgeCall(code, { depth = 4, timeoutMs = 10000 } = {}) {
  let prev = 0;
  for (const f of [OUT_FILE, CMD_FILE]) {
    const j = readJson(f);
    if (j && typeof j.id === 'number') prev = Math.max(prev, j.id);
  }
  const probe = Math.max(prev + 1, Math.floor(Date.now() / 1000), lastProbe + 1);
  lastProbe = probe;
  const payload = JSON.stringify({ id: probe, code, depth });
  const tmp = path.join(DATA_DIR, `bridge_cmd.${probe}.tmp`);
  fs.writeFileSync(tmp, payload, { encoding: 'utf8' });
  for (let i = 0; ; i++) {
    try { fs.renameSync(tmp, CMD_FILE); break; }
    catch (e) { if (i >= 20) throw new Error('bridge command file is locked'); await sleep(100); }
  }
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    await sleep(150);
    const r = readJson(OUT_FILE);
    if (r && Number(r.id) === probe) {
      if (!r.ok) throw new Error('bridge error: ' + (r.error || 'unknown'));
      return r;
    }
    if (Date.now() > deadline) {
      throw new Error('No bridge reply within ' + (timeoutMs / 1000) + 's. Is the game running with the Requiem Bridge enabled (Script Generated UI > Requiem Bridge)?');
    }
  }
}

function requireRc() {
  return '(_G.__requiem_coop_rc or error("remote control not loaded: the host must run a DEBUG build of the co-op mod"))';
}

// wait for a peer ticket to resolve
async function peerAwait(ticket, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const r = await bridgeCall(`return ${requireRc()}.result(${luaLong(ticket)})`, { depth: 10 });
    const res = r.result || {};
    if (res.error) throw new Error('peer: ' + res.error);
    if (res.done) return res;
    if (Date.now() > deadline) {
      throw new Error('No reply from the connected client within ' + (timeoutMs / 1000) + 's. ' +
        'Is a partner connected, running a DEBUG build, with "Allow host remote control" ticked?');
    }
    await sleep(300);
  }
}

// ---------------------------------------------------------------------------
// tool implementations
// ---------------------------------------------------------------------------
async function tCoopStatus() {
  const link = readJson(LINK_FILE);
  if (!link) return { text: 'No coop_link.json yet (plugin not loaded or game not running).' };
  const out = {
    mode: link.mode, state: link.state, connected: link.connected, peer: link.peer,
    me: link.me, steam: link.steam, proto: link.proto, rx_rate: link.rx_rate, tx_rate: link.tx_rate,
    error: link.error || undefined,
    link_age_s: link.updated ? Math.round(Date.now() / 1000 - link.updated) : undefined,
  };
  return { json: out };
}

async function tGameEval(args) {
  const r = await bridgeCall(String(args.code || ''), { depth: args.depth || 4, timeoutMs: (args.timeout_s || 10) * 1000 });
  return { json: { ok: r.ok, result: r.result, log: r.log && r.log.length ? r.log : undefined } };
}

async function tPeerEval(args) {
  const code = String(args.code || '');
  const t = await bridgeCall(`return ${requireRc()}.exec_peer(${luaLong(code)})`, { depth: 2 });
  const ticket = t.result;
  if (typeof ticket !== 'string') throw new Error('could not start peer exec: ' + JSON.stringify(ticket));
  const res = await peerAwait(ticket, (args.timeout_s || 20) * 1000);
  if (res.denied) return { json: { denied: true, note: 'The client has not enabled "Allow host remote control".' } };
  if (res.err) return { json: { error: res.err, log: res.log } };
  return { json: { ok: res.ok, value: res.value, log: res.log && res.log.length ? res.log : undefined } };
}

async function tPeerStatus() {
  return tPeerEval({ code: 'return (__requiem_coop_debug and __requiem_coop_debug()) or {error="debug snapshot unavailable"}', timeout_s: 20 });
}

async function tPeerDeploy(args) {
  const rel = String(args.dest_path || '');
  if (!rel) throw new Error('dest_path is required (relative path inside the client game folder)');
  let bytes;
  if (args.source_path) bytes = fs.readFileSync(args.source_path);
  else if (typeof args.content === 'string') bytes = Buffer.from(args.content, 'utf8');
  else throw new Error('provide source_path (a local file) or content (text)');
  const b64 = bytes.toString('base64');
  const t = await bridgeCall(`return ${requireRc()}.deploy_peer_b64(${luaLong(rel)}, ${luaLong(b64)})`, { depth: 2 });
  const ticket = t.result;
  if (typeof ticket !== 'string') throw new Error('could not start deploy: ' + JSON.stringify(ticket));
  const res = await peerAwait(ticket, (args.timeout_s || 30) * 1000);
  if (res.denied) return { json: { denied: true, note: 'The client has not enabled "Allow host remote control".' } };
  if (res.err) return { json: { error: res.err, tried: res.tried } };
  return { json: { ok: res.ok, path: res.path, note: res.note, bytes: bytes.length } };
}

async function tPeerReload(args) {
  const rel = String(args.path || '');
  if (!rel) throw new Error('path is required (a path the client can dofile(), e.g. an absolute game path or a reframework data-relative path)');
  const t = await bridgeCall(`return ${requireRc()}.reload_peer(${luaLong(rel)})`, { depth: 2 });
  const ticket = t.result;
  if (typeof ticket !== 'string') throw new Error('could not start reload: ' + JSON.stringify(ticket));
  const res = await peerAwait(ticket, (args.timeout_s || 20) * 1000);
  if (res.denied) return { json: { denied: true, note: 'The client has not enabled "Allow host remote control".' } };
  if (res.err) return { json: { error: res.err } };
  return { json: { ok: res.ok, value: res.value } };
}

const TOOLS = [
  {
    name: 'coop_status',
    description: 'Connection status of the local co-op session (mode, connected, partner name, rates). Read this first.',
    inputSchema: { type: 'object', properties: {} },
    handler: tCoopStatus,
  },
  {
    name: 'game_eval',
    description: 'Run Lua in the LOCAL running game\'s REFramework (via the dev bridge) and return the serialized result. Full REFramework/sdk access. Requires the Requiem Bridge to be enabled in-game.',
    inputSchema: {
      type: 'object',
      properties: {
        code: { type: 'string', description: 'Lua source. Use `return <expr>` to get a value back.' },
        depth: { type: 'number', description: 'Serialization depth (default 4).' },
        timeout_s: { type: 'number', description: 'Timeout in seconds (default 10).' },
      },
      required: ['code'],
    },
    handler: tGameEval,
  },
  {
    name: 'peer_eval',
    description: 'Run Lua in the CONNECTED CLIENT\'s REFramework and return the result. Same reach as game_eval, but on the partner\'s PC. Requires a connected partner on a DEBUG build with "Allow host remote control" enabled.',
    inputSchema: {
      type: 'object',
      properties: {
        code: { type: 'string', description: 'Lua source to run on the client. Use `return <expr>`.' },
        timeout_s: { type: 'number', description: 'Timeout in seconds (default 20).' },
      },
      required: ['code'],
    },
    handler: tPeerEval,
  },
  {
    name: 'peer_status',
    description: 'Fetch the connected client\'s co-op debug snapshot (its __requiem_coop_debug()). Convenience wrapper over peer_eval.',
    inputSchema: { type: 'object', properties: {} },
    handler: tPeerStatus,
  },
  {
    name: 'peer_deploy_file',
    description: 'Write a file onto the CONNECTED CLIENT, under its game folder (sandboxed to reframework/data). Give source_path (a local file) or content (text), and dest_path (relative path on the client). Returns the actual path written. Requires client consent.',
    inputSchema: {
      type: 'object',
      properties: {
        dest_path: { type: 'string', description: 'Relative destination path on the client (no "..", no absolute). Served under reframework/data.' },
        source_path: { type: 'string', description: 'Absolute path of a local file to send.' },
        content: { type: 'string', description: 'Text content to send instead of a file.' },
        timeout_s: { type: 'number', description: 'Timeout in seconds (default 30).' },
      },
      required: ['dest_path'],
    },
    handler: tPeerDeploy,
  },
  {
    name: 'peer_reload',
    description: 'Ask the CONNECTED CLIENT to dofile() a path (hot-reload Lua it already has, e.g. a just-deployed script). Requires client consent.',
    inputSchema: {
      type: 'object',
      properties: {
        path: { type: 'string', description: 'Path the client will dofile().' },
        timeout_s: { type: 'number', description: 'Timeout in seconds (default 20).' },
      },
      required: ['path'],
    },
    handler: tPeerReload,
  },
];

// ---------------------------------------------------------------------------
// JSON-RPC / MCP stdio loop
// ---------------------------------------------------------------------------
function send(msg) { process.stdout.write(JSON.stringify(msg) + '\n'); }
function reply(id, result) { send({ jsonrpc: '2.0', id, result }); }
function replyError(id, code, message) { send({ jsonrpc: '2.0', id, error: { code, message } }); }

async function handle(msg) {
  const { id, method, params } = msg;
  if (method === 'initialize') {
    reply(id, {
      protocolVersion: (params && params.protocolVersion) || '2024-11-05',
      capabilities: { tools: {} },
      serverInfo: { name: 'requiem-coop', version: '1.0.0' },
    });
  } else if (method === 'notifications/initialized' || method === 'notifications/cancelled') {
    // no response
  } else if (method === 'ping') {
    reply(id, {});
  } else if (method === 'tools/list') {
    reply(id, { tools: TOOLS.map(({ name, description, inputSchema }) => ({ name, description, inputSchema })) });
  } else if (method === 'tools/call') {
    const tool = TOOLS.find((t) => t.name === (params && params.name));
    if (!tool) return replyError(id, -32602, 'unknown tool: ' + (params && params.name));
    try {
      const out = await tool.handler((params && params.arguments) || {});
      const text = out.json !== undefined ? JSON.stringify(out.json, null, 2) : String(out.text);
      reply(id, { content: [{ type: 'text', text }] });
    } catch (e) {
      reply(id, { content: [{ type: 'text', text: 'ERROR: ' + (e && e.message ? e.message : String(e)) }], isError: true });
    }
  } else if (id !== undefined) {
    replyError(id, -32601, 'method not found: ' + method);
  }
}

let buf = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => {
  buf += chunk;
  let nl;
  while ((nl = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, nl).trim();
    buf = buf.slice(nl + 1);
    if (!line) continue;
    let msg;
    try { msg = JSON.parse(line); } catch (_) { continue; }
    Promise.resolve(handle(msg)).catch((e) => process.stderr.write('handler error: ' + e + '\n'));
  }
});
process.stdin.on('end', () => process.exit(0));
process.stderr.write(`requiem-coop MCP ready. game=${GAME_ROOT}\n`);
