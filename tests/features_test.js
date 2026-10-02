// Voice, the model picker, JEV quick orders and gamepad mode: the bridge's pure
// parts (jev.js, voice.js, protocol.js) and the addon's side (WoWAI.lua with
// Picker.lua and Pad.lua in the stub client, as in addon_test.js).
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const fengari = require('fengari');
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = fengari;
const P = require('../bridge/protocol');
const J = require('../bridge/jev');
const V = require('../bridge/voice');

// ---------------------------------------------------------------------------
// JEV
// ---------------------------------------------------------------------------

test('JEV analysis: one request with the intent choice, a difficulty score and a noul per game-data kind', () => {
  const req = J.analyzeRequest('¿qué vendo de mis bolsas?', { route: true, tier: true, needs: true });
  assert.equal(req.model, 'typesafe/jev-1.13');
  assert.deepEqual(req.state, { message: '¿qué vendo de mis bolsas?' }, 'only the message: unrelated state lowers accuracy');
  const q = req.questions;
  assert.equal(q.intent.type, 'choice');
  assert.deepEqual(Object.keys(q.intent.criteria), ['agent', ...Object.keys(J.QUICK)]);
  assert.equal(q.difficulty.type, 'score');
  assert.equal(q.difficulty.criteria.length, 3);
  for (const k of P.DATA_KINDS) assert.equal(q[`need_${k}`].type, 'noul', k);
  // Only what is asked for goes out.
  assert.deepEqual(Object.keys(J.analyzeRequest('x', { tier: true }).questions), ['difficulty']);
  // Every quick order is a validated action or a map command from the addon's list.
  for (const [id, quick] of Object.entries(J.QUICK)) {
    assert.ok((quick.actions && quick.actions.length) || (quick.cmds && quick.cmds.length), id);
    for (const a of quick.actions || []) assert.ok(P.validateAction(a, []), `${id}: ${a.op} is a known action`);
    for (const c of quick.cmds || []) assert.ok(['next', 'prev', 'stop', 'ore', 'herb'].includes(c), `${id}: ${c}`);
  }
});

test('JEV answers are only trusted when they have the type and range asked for', () => {
  const ok = { model: 'typesafe/jev-1.13-20260917', answers: { intent: { type: 'choice', choice: 'sort_bags', confidence: 0.98 } } };
  assert.deepEqual(J.readChoice(ok, 'intent', ['agent', 'sort_bags']), { choice: 'sort_bags', confidence: 0.98, model: 'typesafe/jev-1.13-20260917' });
  assert.equal(J.readChoice(ok, 'intent', ['agent']), null, 'a choice we did not offer');
  assert.equal(J.readChoice({ answers: { intent: { type: 'noul', noul: 1 } } }, 'intent', ['agent']), null);
  assert.equal(J.readChoice({}, 'intent', ['agent']), null);
  assert.equal(J.readChoice({ answers: { intent: { type: 'choice', choice: 'agent', confidence: 7 } } }, 'intent', ['agent']).confidence, 0);
  assert.deepEqual(J.readScore({ answers: { d: { type: 'score', score: 1.43, confidence: 0.35 } } }, 'd', 3), { score: 1.43, confidence: 0.35 });
  assert.equal(J.readScore({ answers: { d: { type: 'score', score: 5 } } }, 'd', 3), null);
  assert.equal(J.readNoul({ answers: { n: { type: 'noul', noul: 0.9 } } }, 'n'), 0.9);
  assert.equal(J.readNoul({ answers: { n: { type: 'noul', noul: 1.2 } } }, 'n'), null);
  assert.equal(J.readNoul({ answers: { n: { type: 'noul', noul: true } } }, 'n'), null);
});

test('only short, typed, one-line messages are routed; the player request is cut out of addon sends', () => {
  assert.equal(J.routable('vende la chatarra'), true);
  assert.equal(J.routable(''), false);
  assert.equal(J.routable('x'.repeat(200)), false);
  assert.equal(J.routable('[game data] bags\n...'), false);
  assert.equal(J.routable('[actions] sort_bags OK'), false);
  assert.equal(J.routable('a\nb\nc'), false);
  assert.equal(J.playerRequest('[actions] sort_bags OK\n\nvende lo gris\n\n[game data] bags\nitem...'), 'vende lo gris');
});

function mockJev(answers, status = 200) {
  return async (url, init) => {
    assert.equal(url, J.DECISIONS_URL);
    assert.equal(init.headers.Authorization, 'Bearer test-key');
    assert.equal(init.redirect, 'error');
    const body = JSON.parse(init.body);
    const a = typeof answers === 'function' ? answers(body) : answers;
    return { ok: status === 200, status, text: async () => JSON.stringify({ model: 'm', answers: a }) };
  };
}

test('analyze(): quick orders, the model tier and the data a question needs come from one answer', async () => {
  const saved = global.fetch;
  process.env.OPENROUTER_API_KEY = 'test-key';
  const noul = v => ({ type: 'noul', noul: v });
  const needs = over => Object.fromEntries(P.DATA_KINDS.map(k => [`need_${k}`, noul(over[k] || 0.02)]));
  try {
    let calls = 0;
    global.fetch = mockJev(() => { calls++; return { intent: { type: 'choice', choice: 'sell_junk', confidence: 0.97 }, ...needs({}) }; });
    const q = await J.analyze({}, 'vende la basura', { route: true, needs: true });
    assert.equal(calls, 1, 'one request');
    assert.equal(q.quick.intent, 'sell_junk');
    assert.deepEqual(q.quick.actions, [{ op: 'sell_junk' }]);
    // Not sure enough: no quick order.
    global.fetch = mockJev({ intent: { type: 'choice', choice: 'sort_bags', confidence: 0.6 } });
    const low = await J.analyze({}, 'ordena', { route: true });
    assert.equal(low.quick, undefined);
    assert.match(low.intent, /sort_bags 0.60/);
    // A question about the bags and the quests: those two, surest first; a weak one is left out.
    global.fetch = mockJev({ intent: { type: 'choice', choice: 'agent', confidence: 0.93 }, ...needs({ quests: 0.89, bags: 0.94, gear: 0.5 }) });
    const n = await J.analyze({}, '¿qué vendo y qué misión hago?', { route: true, needs: true });
    assert.deepEqual(n.needs, ['bags', 'quests']);
    // The difficulty score picks the tier; a spread-out answer takes the middle one.
    global.fetch = mockJev({ difficulty: { type: 'score', score: 0.13, confidence: 0.8 } });
    assert.equal((await J.analyze({}, '¿qué hora es?', { tier: true })).tier.model, J.DEFAULT_TIERS.fast);
    global.fetch = mockJev({ difficulty: { type: 'score', score: 2, confidence: 0.9 } });
    assert.equal((await J.analyze({ tiers: { strong: 'gpt-x' } }, 'refactoriza', { tier: true })).tier.model, 'gpt-x');
    global.fetch = mockJev({ difficulty: { type: 'score', score: 0.1, confidence: 0.1 } });
    assert.equal((await J.analyze({}, 'hmm', { tier: true })).tier.tier, 'balanced');
    // Trouble: nothing is decided, and "auto" falls back to balanced.
    global.fetch = mockJev({}, 520);
    const bad = await J.analyze({}, 'ordena', { route: true, tier: true, needs: true });
    assert.equal(bad.note, 'HTTP 520');
    assert.equal(bad.quick, undefined);
    assert.deepEqual(bad.needs, []);
    assert.equal(bad.tier.model, J.DEFAULT_TIERS.balanced);
    global.fetch = async () => { const e = new Error('t'); e.name = 'TimeoutError'; throw e; };
    assert.match((await J.analyze({ timeoutMs: 5 }, 'ordena', { route: true })).note, /no answer/);
    // Off switches, and the addon's own sends are never asked about.
    assert.equal((await J.analyze({ enabled: false }, 'ordena', { route: true })).note, 'off');
    assert.equal((await J.analyze({ router: false, prefetch: false }, 'ordena', { route: true, needs: true })).note, 'nothing to ask');
    assert.equal((await J.analyze({}, '[game data] bags\nx', { route: true, needs: true })).note, 'nothing to ask');
  } finally {
    global.fetch = saved;
    delete process.env.OPENROUTER_API_KEY;
  }
});

test('review(): one noul per proposed action against what the player asked', async () => {
  const saved = global.fetch;
  process.env.OPENROUTER_API_KEY = 'test-key';
  const seen = [];
  try {
    global.fetch = mockJev(body => {
      seen.push(body.state);
      return { asked: { type: 'noul', noul: /Abandon/.test(body.state.action) ? 0.09 : 0.96 } };
    });
    const r = await J.review({}, 'vende la chatarra', [{ op: 'sell_junk' }, { op: 'abandon_quests', ids: [33, 52] }]);
    assert.deepEqual(r.scores, [0.96, 0.09]);
    assert.deepEqual(seen[1], { request: 'vende la chatarra', action: 'Abandon 2 quest(s).' }, 'ids are counted, not listed');
    global.fetch = mockJev({}, 500);
    assert.deepEqual((await J.review({}, 'x', [{ op: 'sort_bags' }])).scores, [null]);
    assert.equal((await J.review({ review: false }, 'x', [{ op: 'sort_bags' }])).note, 'off');
  } finally {
    global.fetch = saved;
    delete process.env.OPENROUTER_API_KEY;
  }
});

test('the OpenRouter key is read from a key file as data', () => {
  const dir = fs.mkdtempSync(path.join(require('os').tmpdir(), 'jev-'));
  const f = path.join(dir, 'openrouter.env');
  fs.writeFileSync(f, '# comment\nOTHER=1\nOPENROUTER_API_KEY="sk-or-abc"\n');
  assert.equal(J.apiKey({ keyFile: f }), 'sk-or-abc');
  fs.writeFileSync(f, 'sk-or-raw\n');
  assert.equal(J.apiKey({ keyFile: f }), 'sk-or-raw');
  fs.writeFileSync(f, 'OPENROUTER_API_KEY=two words\n');
  assert.equal(J.apiKey({ keyFile: f }), '');
  assert.equal(J.apiKey({ keyFile: path.join(dir, 'missing') }), '');
});

// ---------------------------------------------------------------------------
// Voice
// ---------------------------------------------------------------------------

function pcm(parts) {
  // parts: [[ms, amplitude], ...] of a 200 Hz tone (amplitude 0 = silence)
  const bufs = parts.map(([ms, amp]) => {
    const n = Math.floor(V.RATE * ms / 1000), b = Buffer.alloc(n * 2);
    for (let i = 0; i < n; i++) b.writeInt16LE(Math.round(Math.sin(2 * Math.PI * 200 * i / V.RATE) * amp), i * 2);
    return b;
  });
  return Buffer.concat(bufs);
}

test('the VAD ends after the silence that follows speech, and gives up without speech', () => {
  const o = { ...V.DEFAULTS };
  let vad = V.makeVad(o);
  assert.equal(vad.feed(pcm([[300, 0], [1200, 6000]])), '');
  assert.equal(vad.heard, true);
  assert.equal(vad.feed(pcm([[1300, 0]])), 'done');
  vad = V.makeVad(o);
  assert.equal(vad.feed(pcm([[o.noSpeechMs + 100, 0]])), 'nothing');
  assert.equal(vad.peak, 0, 'a muted microphone reads as pure silence');
  vad = V.makeVad({ ...o, maxMs: 1000 });
  assert.equal(vad.feed(pcm([[1100, 6000]])), 'max');
  // A click shorter than 150 ms is not speech.
  vad = V.makeVad(o);
  vad.feed(pcm([[90, 9000], [500, 0]]));
  assert.equal(vad.heard, false);
});

test('beeps and recordings are valid 16 kHz mono WAV', () => {
  const w = V.beepWav(880, 120);
  assert.equal(w.toString('ascii', 0, 4), 'RIFF');
  assert.equal(w.toString('ascii', 8, 12), 'WAVE');
  assert.equal(w.readUInt32LE(24), 16000);
  assert.equal(w.readUInt16LE(22), 1);
  assert.equal(w.readUInt32LE(40), w.length - 44);
});

test('replies are read aloud without code, links or markdown, cut at a sentence', () => {
  const t = V.speakable('**Hecho.** Mira `/ai map`:\n```lua\nprint(1)\n```\nVe a [Ventormenta](https://x.y). TL;DR: listo', 400);
  assert.equal(t, 'Hecho. Mira /ai map: Ve a Ventormenta. listo');
  // Past the limit: at the last sentence when that keeps at least half, else at a word.
  assert.equal(V.speakable('Esta primera frase ya es larga. Y esta segunda sigue sin parar ' + 'mucho '.repeat(20), 60),
    'Esta primera frase ya es larga.');
  assert.equal(V.speakable('Corta. ' + 'palabra '.repeat(100), 40), 'Corta. palabra palabra palabra palabra…');
});

// ---------------------------------------------------------------------------
// Protocol
// ---------------------------------------------------------------------------

test('slot files carry the model list, voice, and per reply what was heard, the model and map commands', () => {
  const lua = P.luaTable('WoWAI_SlotData', [{ chat: 'c1', id: 3, status: 'done', text: 'ok', heard: 'ordena las bolsas', model: 'gpt-6-sol', cmds: ['next'] }],
    { models: ['gpt-6-sol', 'anthropic/claude-opus-5-5'], voice: true });
  assert.match(lua, /models = \{ "gpt-6-sol", "anthropic\/claude-opus-5-5" \},/);
  assert.match(lua, /voice = true,/);
  assert.match(lua, /heard = "ordena las bolsas",/);
  assert.match(lua, /model = "gpt-6-sol",/);
  assert.match(lua, /cmds = \{ "next" \},/);
  // Without them the file is as before.
  const plain = P.luaTable('X', [{ chat: 'c', id: 1, status: 'done', text: 't' }]);
  assert.doesNotMatch(plain, /models|voice|heard|cmds/);
});

test('the reload outbox carries the chat model', () => {
  const hex = s => Buffer.from(s).toString('hex');
  const src = `WoWAIDB = { ["outbox"] = { ["id"] = 5, ["session"] = "s1", ["chat"] = "c1", ["text"] = "${hex('hola')}", ["cwd"] = "", ["model"] = "gpt-6-luna--fast", } }`;
  assert.equal(P.parseOutbox(src).model, 'gpt-6-luna--fast');
  assert.equal(P.parseOutbox(src.replace('gpt-6-luna--fast', '; rm -rf /')).model, undefined);
});

// ---------------------------------------------------------------------------
// Addon
// ---------------------------------------------------------------------------

const ADDON = path.join(__dirname, '..', 'addon', 'WoWAI');

function newVM() {
  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);
  const run = (code, arg) => {
    if (lauxlib.luaL_loadstring(L, to_luastring(code)) !== lua.LUA_OK) throw new Error('Lua load: ' + to_jsstring(lua.lua_tostring(L, -1)));
    let nargs = 0;
    if (arg !== undefined) { lua.lua_pushstring(L, to_luastring(arg)); nargs = 1; }
    if (lua.lua_pcall(L, nargs, 0, 0) !== lua.LUA_OK) throw new Error('Lua error: ' + to_jsstring(lua.lua_tostring(L, -1)));
  };
  const evaluate = (expr) => {
    run(`local v = (${expr}); if v == nil then RESULT = nil else RESULT = tostring(v) end`);
    lua.lua_getglobal(L, to_luastring('RESULT'));
    const s = lua.lua_isnil(L, -1) ? null : to_jsstring(lua.lua_tolstring(L, -1));
    lua.lua_pop(L, 1);
    return s;
  };
  run(fs.readFileSync(path.join(__dirname, 'wow_stub.lua'), 'utf8'));
  // Map.lua needs the world map; a stand-in records the commands it is given.
  run('WoWAIMap = { calls = {}, Command = function(c) table.insert(WoWAIMap.calls, c) end, Sync = function() end }');
  for (const f of ['Codec.lua', 'Inbox.lua', 'WoWAI.lua', 'Picker.lua', 'Pad.lua']) run(fs.readFileSync(path.join(ADDON, f), 'utf8'), 'WoWAI');
  return { run, evaluate, num: e => Number(evaluate(e)) };
}

// Decode the strip (see addon_test.js) into records.
function stripRecords(vm) {
  if (vm.evaluate('WoWAIStrip and WoWAIStrip.shown') !== 'true') return [];
  vm.run(`
    local parts = {}
    for _, t in ipairs(WoWAIStrip.textures) do
      if t.shown and t.color then
        local c, r = math.floor(t.x / 4), math.floor(-t.y / 4)
        local v = (t.color[1] >= 0.5 and 4 or 0) + (t.color[2] >= 0.5 and 2 or 0) + (t.color[3] >= 0.5 and 1 or 0)
        parts[#parts + 1] = (r * 200 + c) .. ":" .. v
      end
    end
    RESULT = table.concat(parts, ",")`);
  const cells = [];
  for (const p of vm.evaluate('RESULT').split(',')) { const [i, v] = p.split(':').map(Number); cells[i] = v; }
  const bytes = [];
  let acc = 0, nbits = 0;
  for (let i = 0; i < cells.length; i++) {
    acc = (acc << 3) | (cells[i] || 0); nbits += 3;
    while (nbits >= 8) { bytes.push((acc >> (nbits - 8)) & 0xff); nbits -= 8; acc &= (1 << nbits) - 1; }
  }
  const len = bytes[4] * 256 + bytes[5];
  return Buffer.from(bytes.slice(6, 6 + len)).toString('utf8').split('\x1E').map(r => {
    const p = r.split('\x1F');
    const withCtx = p[4].split(';').includes('c');
    return { id: Number(p[2]), flags: p[4], text: p.slice(withCtx ? 7 : 6).join('\x1F') };
  });
}

const SLOT = (replies = '') => `{ now = time(), cwd = "", agent = "claude", agents = { "claude", "codex" },
  models = { "gpt-6-sol", "gpt-6-luna--fast", "anthropic/claude-opus-5-5" }, voice = true, replies = { ${replies} } }`;

function connected() {
  const vm = newVM();
  vm.run('STUB.FireEvent("ADDON_LOADED", "WoWAI")');
  vm.run('STUB.FireEvent("PLAYER_LOGIN")');
  vm.run('STUB.RunTimers()');
  vm.run(`STUB.onLoadAddOn = function() WoWAI_SlotData = ${SLOT()} end`);
  vm.run('STUB.now = STUB.now + 6; STUB.Tick()');
  assert.equal(vm.evaluate('WoWAI.IsConnected()'), 'true');
  return vm;
}

const last = 'WoWAIDB.chats[1].history[#WoWAIDB.chats[1].history]';

test('a chat picks its model: by name, by a unique part of it, auto, or back to the default', () => {
  const vm = connected();
  vm.run('SlashCmdList.WOWAI("model gpt-6-sol")');
  assert.equal(vm.evaluate('WoWAIDB.chats[1].model'), 'gpt-6-sol');
  vm.run('WoWAI.Send("hola")');
  assert.equal(stripRecords(vm).find(r => r.text === 'hola').flags, 'model=gpt-6-sol');
  assert.equal(vm.evaluate('WoWAIDB.outbox.model'), 'gpt-6-sol');
  vm.run('SlashCmdList.WOWAI("cancel")');
  vm.run('SlashCmdList.WOWAI("modelo opus-5-5")');
  assert.equal(vm.evaluate('WoWAIDB.chats[1].model'), 'anthropic/claude-opus-5-5', 'a part that names one model is enough');
  vm.run('SlashCmdList.WOWAI("model gpt-6")');
  assert.equal(vm.evaluate('WoWAIDB.chats[1].model'), 'anthropic/claude-opus-5-5', 'an ambiguous part changes nothing');
  assert.match(vm.evaluate(`${last}.text`), /Unknown model/);
  vm.run('SlashCmdList.WOWAI("model auto")');
  assert.equal(vm.evaluate('WoWAIDB.chats[1].model'), 'auto');
  vm.run('SlashCmdList.WOWAI("model default")');
  assert.equal(vm.evaluate('WoWAIDB.chats[1].model'), '');
  // The picker lists default, auto and the bridge's models, and picking sets it.
  vm.run('WoWAI.ModelPrompt()');
  assert.equal(vm.evaluate('WoWAIPicker.IsOpen()'), 'true');
  vm.run('WoWAIPicker.Move(2); WoWAIPicker.Accept()');
  assert.equal(vm.evaluate('WoWAIDB.chats[1].model'), 'gpt-6-sol');
  assert.equal(vm.evaluate('WoWAIPicker.IsOpen()'), 'false');
  // A new chat starts on the same model; the reply bubble names it.
  vm.run('WoWAI.NewChat("Second")');
  assert.equal(vm.evaluate('WoWAIDB.chats[2].model'), 'gpt-6-sol');
});

test('a voice message goes out empty with "v", and what the bridge heard replaces the placeholder', () => {
  const vm = connected();
  vm.run('SlashCmdList.WOWAI("voz")');
  const rec = stripRecords(vm).find(r => r.flags.split(';').includes('v'));
  assert.ok(rec, 'a record with the voice flag');
  assert.equal(rec.text, '');
  assert.match(vm.evaluate(`${last}.text`), /^\[voz\] /);
  const chatId = vm.evaluate('WoWAIDB.chats[1].id');
  const id = vm.num('WoWAIDB.chats[1].pendingId');
  // Speaking again while it waits is refused, it doesn't queue a second recording.
  vm.run('WoWAI.Voice()');
  assert.match(vm.evaluate(`${last}.text`), /still waiting/);
  vm.run(`STUB.onLoadAddOn = function() WoWAI_SlotData = ${SLOT(`{ chat = "${chatId}", id = ${id}, status = "done", text = "Hecho", heard = "ordena las bolsas", agent = "claude", model = "gpt-6-sol" }`)} end`);
  vm.run('STUB.now = STUB.now + 6; STUB.Tick()');
  const user = vm.evaluate(`(function() for _, m in ipairs(WoWAIDB.chats[1].history) do if m.id == ${id} and m.role == "user" then return m.text end end end)()`);
  assert.equal(user, '[voz] ordena las bolsas');
  assert.equal(vm.evaluate(`${last}.model`), 'gpt-6-sol');
  assert.equal(vm.evaluate('WoWAIDB.chats[1].name'), 'Ordena las bolsas', 'the chat takes its title from what was said');
  // Releasing push-to-talk sends a "vs" control record, which never waits for a reply.
  vm.run('WoWAI.VoiceStop()');
  assert.ok(stripRecords(vm).some(r => r.flags === 'vs'));
  assert.equal(vm.evaluate('WoWAIDB.chats[1].pendingId'), null);
});

test('map commands of a quick order run, but only the addon\'s own short list', () => {
  const vm = connected();
  vm.run('WoWAI.Send("siguiente parada")');
  const chatId = vm.evaluate('WoWAIDB.chats[1].id');
  const id = vm.num('WoWAIDB.chats[1].pendingId');
  vm.run(`STUB.onLoadAddOn = function() WoWAI_SlotData = ${SLOT(`{ chat = "${chatId}", id = ${id}, status = "done", text = "Orden rápida", agent = "jev", cmds = { "next", "nav evil 3", "clear" } }`)} end`);
  vm.run('STUB.now = STUB.now + 6; STUB.Tick()');
  assert.equal(vm.evaluate('table.concat(WoWAIMap.calls, ",")'), 'next');
  assert.equal(vm.evaluate(`${last}.agent`), 'jev');
});

test('a prefetch from the bridge is not a reply: the game data goes out for the question at once', () => {
  const vm = newVM();
  vm.run('STUB.FireEvent("ADDON_LOADED", "WoWAI")');
  vm.run('STUB.FireEvent("PLAYER_LOGIN")');
  vm.run('STUB.RunTimers()');
  vm.run(`STUB.onLoadAddOn = function() WoWAI_SlotData = ${SLOT()} end`);
  vm.run('STUB.now = STUB.now + 6; STUB.Tick()');
  vm.run('WoWAIData = { Collect = function(kinds) return "Bags: 3 x Linen Cloth" end, KINDS = { "bags" } }');
  vm.run('WoWAI.Send("¿qué vendo?")');
  const chatId = vm.evaluate('WoWAIDB.chats[1].id');
  const id = vm.num('WoWAIDB.chats[1].pendingId');
  const before = vm.num('#WoWAIDB.chats[1].history');
  vm.run(`STUB.onLoadAddOn = function() WoWAI_SlotData = ${SLOT(`{ chat = "${chatId}", id = ${id}, status = "done", text = "Reuniendo", agent = "jev", need = { "bags" }, prefetch = true }`)} end`);
  vm.run('STUB.now = STUB.now + 6; STUB.Tick()');
  vm.run('STUB.RunTimers()');
  const rec = stripRecords(vm).find(r => r.text.startsWith('[game data] bags'));
  assert.ok(rec, 'the data went out');
  assert.match(rec.text, /Linen Cloth/);
  assert.equal(vm.evaluate(`(function() for _, m in ipairs(WoWAIDB.chats[1].history) do if m.role == "assistant" then return "yes" end end return "no" end)()`), 'no', 'no reply bubble');
  assert.equal(vm.num('#WoWAIDB.chats[1].history'), before + 1, 'one line: the data sent');
  assert.match(vm.evaluate(`${last}.text`), /JEV/);
});

test('actions JEV flagged are marked (!), and X in gamepad mode wants a second press for them', () => {
  const vm = connected();
  vm.run('WoWAIActions = { Describe = function(a) return a.op end, IsRunning = function() return false end, Run = function(list, done) APPLIED = #list return true end }');
  vm.run('WoWAI.Send("vende la chatarra")');
  const chatId = vm.evaluate('WoWAIDB.chats[1].id');
  const id = vm.num('WoWAIDB.chats[1].pendingId');
  vm.run(`STUB.onLoadAddOn = function() WoWAI_SlotData = ${SLOT(`{ chat = "${chatId}", id = ${id}, status = "done", text = "Vale", agent = "claude",
    actions = { { op = "sell_junk" }, { op = "abandon_quests", ids = { 33 }, warn = true } } }`)} end`);
  vm.run('STUB.now = STUB.now + 6; STUB.Tick()');
  const texts = vm.evaluate('table.concat(STUB.texts, "|")');
  assert.ok(texts.includes('- sell_junk'));
  assert.ok(texts.includes('- (!) not asked for? abandon_quests'));
  assert.equal(vm.evaluate('WoWAI.HasWarnedActions()'), 'true');
  vm.run('WoWAIPad.Enter()');
  const press = key => vm.run(`WoWAIPadButton.scripts.OnClick(WoWAIPadButton, "${key}", true)`);
  press('PAD3');
  assert.equal(vm.evaluate('APPLIED'), null, 'the first X only warns');
  assert.match(vm.evaluate(`${last}.text`), /Press X again/);
  press('PAD3');
  assert.equal(vm.evaluate('APPLIED'), '2');
});

test('gamepad mode binds the controller to the window and gives it back', () => {
  const vm = connected();
  vm.run('SlashCmdList.WOWAI("mando")');
  assert.equal(vm.evaluate('WoWAIPad.IsActive()'), 'true');
  assert.equal(vm.evaluate('STUB.overrides.PAD1.cmd'), 'CLICK WoWAIPadButton:PAD1');
  assert.equal(vm.evaluate('STUB.overrides.PAD1.priority'), 'true');
  assert.equal(vm.evaluate('WoWAIFrame.shown'), 'true');
  const press = (key, down = true) => vm.run(`WoWAIPadButton.scripts.OnClick(WoWAIPadButton, "${key}", ${down})`);
  // Y opens the menu, the d-pad moves in it, B closes it.
  press('PAD4');
  assert.equal(vm.evaluate('WoWAIPicker.IsOpen()'), 'true');
  press('PADDDOWN');
  press('PAD2');
  assert.equal(vm.evaluate('WoWAIPicker.IsOpen()'), 'false');
  // Y > Quick phrases > the first one: sent as a message.
  press('PAD4'); press('PADDDOWN'); press('PADDDOWN'); press('PAD1');
  assert.equal(vm.evaluate('WoWAIPicker.IsOpen()'), 'true');
  press('PAD1');
  assert.ok(stripRecords(vm).some(r => r.text === '¿Qué hago ahora?'));
  vm.run('SlashCmdList.WOWAI("cancel")');
  // A: talk. Held past the threshold, the release stops listening.
  press('PAD1', true);
  assert.ok(stripRecords(vm).some(r => r.flags.split(';').includes('v')));
  vm.run('STUB.now = STUB.now + 2');
  press('PAD1', false);
  assert.ok(stripRecords(vm).some(r => r.flags === 'vs'));
  vm.run('SlashCmdList.WOWAI("cancel")');
  // Right on the d-pad changes chat.
  vm.run('WoWAI.NewChat("B")');
  vm.run('WoWAI.SwitchChat(WoWAIDB.chats[1].id)');
  press('PADDRIGHT');
  assert.equal(vm.evaluate('WoWAIDB.activeChat == WoWAIDB.chats[2].id'), 'true');
  // Combat ends the mode and removes the bindings.
  vm.run('STUB.FireEvent("PLAYER_REGEN_DISABLED")');
  assert.equal(vm.evaluate('WoWAIPad.IsActive()'), 'false');
  assert.equal(vm.evaluate('next(STUB.overrides) == nil'), 'true');
  // Start and B also leave it.
  vm.run('WoWAIPad.Enter()');
  press('PADFORWARD');
  assert.equal(vm.evaluate('WoWAIPad.IsActive()'), 'false');
  // The macros for an action bar.
  vm.run('SlashCmdList.WOWAI("macros")');
  assert.equal(vm.evaluate('STUB.macros[1].body'), '/ai voz');
  assert.equal(vm.evaluate('STUB.macros[2].body'), '/ai mando');
  vm.run('SlashCmdList.WOWAI("macros")');
  assert.equal(vm.num('#STUB.macros'), 2, 'not made twice');
});

test('screenshots: the flag each way of asking sends, and the reply says the agent saw it', () => {
  const vm = connected();
  const flagsOf = () => { const r = stripRecords(vm); return r[0] ? r[0].flags.split(';') : []; };
  const flush = (text) => {
    const chatId = vm.evaluate('WoWAIDB.chats[1].id');
    const id = vm.num('WoWAIDB.chats[1].pendingId');
    vm.run(`STUB.onLoadAddOn = function() WoWAI_SlotData = ${SLOT(`{ chat = "${chatId}", id = ${id}, status = "done", text = "${text}", agent = "claude", shot = "live" }`)} end`);
    vm.run('STUB.now = STUB.now + 6; STUB.Tick()');
  };
  // Auto (the default): a message that talks about the screen says so; others carry nothing.
  vm.run('WoWAI.Send("¿qué es esto?")');
  assert.ok(flagsOf().includes('sk'));
  flush('Es una gema');
  assert.match(vm.evaluate(`${last}.text`), /vio tu pantalla|saw your screen/);
  vm.run('WoWAI.Send("ordena las bolsas")');
  assert.ok(!flagsOf().some(f => /^s[kfn]?$/.test(f)), flagsOf().join(';'));
  flush('ok');
  // The camera button arms the next message only.
  vm.run('WoWAI.ArmShot(true)');
  assert.equal(vm.evaluate('WoWAI.ShotArmed()'), 'true');
  vm.run('WoWAI.Send("ayúdame")');
  assert.ok(flagsOf().includes('s'));
  assert.equal(vm.evaluate('WoWAI.ShotArmed()'), 'false');
  assert.equal(vm.evaluate(`(function() for _, m in ipairs(WoWAIDB.chats[1].history) do if m.role == "user" and m.text == "ayúdame" then return m.shot end end end)()`), 's');
  flush('ok');
  // /ai foto <question>, /ai captura, and /ai pantalla nunca.
  vm.run('SlashCmdList.WOWAI("foto qué hago con esto")');
  assert.ok(flagsOf().includes('s'));
  flush('ok');
  vm.run('SlashCmdList.WOWAI("captura")');
  assert.ok(flagsOf().includes('sf'));
  assert.match(stripRecords(vm)[0].text, /captura|screenshot/i);
  flush('ok');
  vm.run('SlashCmdList.WOWAI("pantalla nunca")');
  assert.equal(vm.evaluate('WoWAIDB.settings.screen'), 'never');
  vm.run('WoWAI.Send("¿qué es esto?")');
  assert.ok(flagsOf().includes('sn'));
});
