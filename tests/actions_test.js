// Game data requests (```wowdata) and game actions (```wowact): the bridge's
// extraction and validation (protocol.js), and the addon side (GameData.lua,
// Actions.lua and their wiring in WoWAI.lua) run in the Lua VM with the stub WoW
// API plus the container, quest, spell and macro calls they use.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const fengari = require('fengari');
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = fengari;
const P = require('../bridge/protocol');

const ADDON = path.join(__dirname, '..', 'addon', 'WoWAI');

// ---------------------------------------------------------------------------
// Bridge
// ---------------------------------------------------------------------------

test('wowdata blocks name known kinds only, in a fixed order, Spanish names too', () => {
  const r = P.extractDataRequests('Voy a mirarlo.\n```wowdata\nquests, banco bags\nfoo\n```\nTL;DR: mirando');
  assert.deepEqual(r.need, ['bags', 'bank', 'quests']);
  assert.equal(r.text, 'Voy a mirarlo.\n\nTL;DR: mirando');
  assert.deepEqual(P.extractDataRequests('no block here').need, []);
});

test('wowact blocks keep only known actions, with their arguments checked', () => {
  const reply = [
    'Hecho.',
    '```wowact',
    JSON.stringify([
      { op: 'sort_bags' },
      { op: 'abandon_quests', ids: [123, '456', -1, 123, 'x'] },
      { op: 'delete_item', items: [5] },
      { op: 'run_lua', code: 'os.exit()' },
      { op: 'place_action', slots: [{ slot: 3, spell: 133 }, { slot: 999, spell: 1 }, { slot: 4 }, { slot: 5, macro: 'Ataque|cff' }] },
      { op: 'create_macro', name: 'Ataque|Total muy largo', body: '/cast Bola de Fuego\n/startattack', icon: '../hack' },
      { op: 'create_macro', name: 'Larga', body: 'x'.repeat(300) },
      { op: 'learn_talents', nodes: [{ node: 5, ranks: 99 }, { node: 'x' }, { node: 7, entry: 70 }] },
      { op: 'deposit', items: [] },
    ]),
    '```',
    'TL;DR: listo',
  ].join('\n');
  const r = P.extractActionBlocks(reply);
  assert.deepEqual(r.actions, [
    { op: 'sort_bags' },
    { op: 'abandon_quests', ids: [123, 456] },
    { op: 'place_action', slots: [{ slot: 3, spell: 133 }, { slot: 5, macro: 'Ataque cff' }] },
    { op: 'create_macro', name: 'Ataque Total muy', body: '/cast Bola de Fuego\n/startattack', perCharacter: true },
    { op: 'learn_talents', nodes: [{ node: 5, ranks: 10 }, { node: 7, ranks: 1, entry: 70 }] },
  ]);
  assert.ok(r.errors.includes('unknown action "delete_item"'));
  assert.ok(r.errors.includes('unknown action "run_lua"'));
  assert.ok(r.errors.some(e => e.includes('body over 255')));
  assert.ok(r.errors.includes('deposit: nothing valid to do'));
  assert.equal(r.text, 'Hecho.\n\nTL;DR: listo');
});

test('wowact accepts one object per line and reports unreadable lines', () => {
  const r = P.extractActionBlocks('```wowact\n{"op":"sell_junk"}\nnot json\n{"op":"train_all"}\n```');
  assert.deepEqual(r.actions, [{ op: 'sell_junk' }, { op: 'train_all' }]);
  assert.equal(r.errors.length, 1);
  assert.ok(r.errors[0].startsWith('unreadable wowact line'));
});

test('at most 20 actions are kept', () => {
  const many = Array.from({ length: 30 }, () => ({ op: 'sort_bags' }));
  const r = P.extractActionBlocks('```wowact\n' + JSON.stringify(many) + '\n```');
  assert.equal(r.actions.length, P.ACTION_LIMITS.actions);
});

test('the system prompt explains data requests and actions only alongside the game context', () => {
  assert.ok(!P.systemPrompt('', '').includes('wowact'));
  const sp = P.systemPrompt('Character: Test', '');
  assert.ok(sp.includes('wowdata') && sp.includes('wowact') && sp.includes('"op":"sort_bags"'));
});

test('slot files carry need and actions as Lua tables the game can read', () => {
  const body = P.luaTable('WoWAI_SlotData', [{
    chat: 'c1', id: 3, status: 'done', text: 'ok', need: ['bags', 'quests'],
    actions: [{ op: 'abandon_quests', ids: [11, 12] }, { op: 'create_macro', name: 'M "q"', body: 'a\nb', perCharacter: true }],
  }]);
  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);
  const code = body + `
    local r = WoWAI_SlotData.replies[1]
    RESULT = table.concat({ r.need[1], r.need[2], r.actions[1].op, r.actions[1].ids[2], r.actions[2].name, r.actions[2].body, tostring(r.actions[2].perCharacter) }, "|")`;
  const status = lauxlib.luaL_dostring(L, to_luastring(code));
  assert.equal(status, lua.LUA_OK, status === lua.LUA_OK ? '' : to_jsstring(lua.lua_tostring(L, -1)));
  lua.lua_getglobal(L, to_luastring('RESULT'));
  assert.equal(to_jsstring(lua.lua_tostring(L, -1)), 'bags|quests|abandon_quests|12|M "q"|a\nb|true');
});

// ---------------------------------------------------------------------------
// Addon
// ---------------------------------------------------------------------------

// The game calls GameData.lua and Actions.lua use, recording what was done.
const GAME_STUB = `
CALLS = {}
local function rec(name) return function(...) table.insert(CALLS, { name, ... }); return true end end
BAGS = { [0] = { [1] = { itemID = 2589, stackCount = 12, quality = 1 }, [2] = { itemID = 3300, stackCount = 1, quality = 0 } } }
C_Container = {
  GetContainerNumSlots = function(bag) return bag == 0 and 16 or 0 end,
  GetContainerItemInfo = function(bag, slot) return BAGS[bag] and BAGS[bag][slot] end,
  SortBags = rec("SortBags"), SortBank = rec("SortBank"), UseContainerItem = rec("UseContainerItem"),
}
ITEMS = { [2589] = "Linen Cloth", [3300] = "Rabbit's Foot" }
C_Item.GetItemNameByID = function(id) return ITEMS[id] end
C_Item.EquipItemByName = rec("EquipItemByName")
QUESTS = { { title = "Elwynn Forest", isHeader = true }, { title = "Wolves Across the Border", questID = 33, level = 2 } }
C_QuestLog = {
  GetNumQuestLogEntries = function() return #QUESTS end,
  GetInfo = function(i) return QUESTS[i] end,
  GetTitleForQuestID = function(id) for _, q in ipairs(QUESTS) do if q.questID == id then return q.title end end end,
  GetLogIndexForQuestID = function(id) for i, q in ipairs(QUESTS) do if q.questID == id then return i end end end,
  IsComplete = function() return false end, GetQuestObjectives = function() return { { text = "Wolf killed: 3/8", finished = false } } end,
  SetSelectedQuest = rec("SetSelectedQuest"), SetAbandonQuest = rec("SetAbandonQuest"), AbandonQuest = rec("AbandonQuest"),
  AddQuestWatch = rec("AddQuestWatch"), RemoveQuestWatch = rec("RemoveQuestWatch"),
}
C_Spell = { GetSpellName = function(id) return id == 133 and "Fireball" or nil end, PickupSpell = function(id) if id == 133 then CURSOR = { "spell", id } end end }
function GetCursorInfo() if CURSOR then return unpack(CURSOR) end end
function ClearCursor() CURSOR = nil end
PlaceAction = rec("PlaceAction")
function GetNumMacros() return 0, 0 end
function GetMacroInfo() return nil end
CreateMacro = rec("CreateMacro")
`;

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
    const isNil = lua.lua_isnil(L, -1);
    const s = isNil ? null : to_jsstring(lua.lua_tolstring(L, -1));
    lua.lua_pop(L, 1);
    return s;
  };
  run(fs.readFileSync(path.join(__dirname, 'wow_stub.lua'), 'utf8'));
  run('unpack = unpack or table.unpack');
  run(GAME_STUB);
  for (const f of ['Codec.lua', 'Inbox.lua', 'GameData.lua', 'Actions.lua', 'WoWAI.lua']) run(fs.readFileSync(path.join(ADDON, f), 'utf8'), 'WoWAI');
  return { run, evaluate, num: (e) => Number(evaluate(e)) };
}

function nextSlot(vm, luaBody) { vm.run(`STUB.onLoadAddOn = function(name) WoWAI_SlotData = ${luaBody} end`); }

function connected() {
  const vm = newVM();
  vm.run('STUB.FireEvent("ADDON_LOADED", "WoWAI"); STUB.FireEvent("PLAYER_LOGIN")');
  vm.run('STUB.RunTimers()');
  nextSlot(vm, '{ now = time(), cwd = "", replies = {} }');
  vm.run('STUB.now = STUB.now + 6; STUB.Tick()');
  assert.equal(vm.evaluate('WoWAI.IsConnected()'), 'true');
  return vm;
}

// Send a message and deliver the bridge's reply (extra Lua fields for the record).
function exchange(vm, text, extra) {
  vm.run(`WoWAI.Send(${JSON.stringify(text)})`);
  const id = vm.num('WoWAIDB.chats[1].pendingId');
  const chat = vm.evaluate('WoWAIDB.chats[1].id');
  nextSlot(vm, `{ now = time(), cwd = "", replies = { { chat = "${chat}", id = ${id}, status = "done", text = "ok", ${extra} } } }`);
  vm.run('STUB.now = STUB.now + 6; STUB.Tick()');
  assert.equal(vm.evaluate('WoWAIDB.chats[1].pendingId'), null, 'the reply was taken');
  return id;
}

function drain(vm) { for (let i = 0; i < 80; i++) vm.run('STUB.RunTimers()'); }
const calls = (vm, name) => vm.num(`(function() local n = 0 for _, c in ipairs(CALLS) do if c[1] == "${name}" then n = n + 1 end end return n end)()`);
const lastHistory = (vm) => vm.evaluate('WoWAIDB.chats[1].history[#WoWAIDB.chats[1].history].text');

test('a reply asking for game data gets it sent back on its own, shown as one line', () => {
  const vm = connected();
  const id = exchange(vm, 'what should I sell?', 'need = { "bags", "quests" }');
  vm.run('STUB.RunTimers()'); // C_Timer.After(0.5, SendGameData)
  const pending = vm.num('WoWAIDB.chats[1].pendingId');
  assert.ok(pending > id, 'a new message went out');
  const sent = Buffer.from(vm.evaluate('WoWAIDB.outbox.text'), 'hex').toString('utf8');
  assert.ok(sent.startsWith('[game data] bags, quests\n'), sent);
  assert.ok(sent.includes('2589 Linen Cloth x12 q1'), sent);
  assert.ok(sent.includes('3300 Rabbit\'s Foot x1 q0'), sent);
  assert.ok(sent.includes('(14 free of 16 slots'), sent);
  assert.ok(sent.includes('33 L2 Wolves Across the Border (Elwynn Forest) [Wolf killed: 3/8]'), sent);
  assert.equal(lastHistory(vm), 'Game data sent to the agent: bags, quests');
  assert.equal(vm.evaluate('WoWAIDB.chats[1].history[#WoWAIDB.chats[1].history].role'), 'system');
});

test('game data on request stops after two sends until the player types again', () => {
  const vm = connected();
  vm.run('WoWAI.Send("start")');
  for (let round = 1; round <= 3; round++) {
    const id = vm.num('WoWAIDB.chats[1].pendingId');
    const chat = vm.evaluate('WoWAIDB.chats[1].id');
    nextSlot(vm, `{ now = time(), cwd = "", replies = { { chat = "${chat}", id = ${id}, status = "done", text = "need more", need = { "gear" } } } }`);
    vm.run('STUB.now = STUB.now + 6; STUB.Tick(); STUB.RunTimers()');
  }
  assert.equal(vm.evaluate('WoWAIDB.chats[1].pendingId'), null, 'the third request is not answered');
  assert.ok(lastHistory(vm).includes('asked for game data again'));
});

test('proposed actions are listed in the addon\'s words with Apply, and run only when applied', () => {
  const vm = connected();
  exchange(vm, 'clean up', 'actions = { { op = "sort_bags" }, { op = "abandon_quests", ids = { 33 } }, { op = "sort_bank" } }');
  assert.equal(calls(vm, 'SortBags'), 0, 'nothing runs before Apply');
  const texts = vm.evaluate('table.concat(STUB.texts, "\\n")');
  assert.ok(texts.includes('Proposed actions (nothing happens until you click Apply):\n- Sort your bags\n- Abandon: [Wolves Across the Border]\n- Sort your bank'), texts);
  assert.ok(texts.includes('Apply (3)'));
  // Apply: the bags are sorted and the quest abandoned; the bank waits for the bank.
  vm.run('SlashCmdList.WOWAI("aplicar")');
  drain(vm);
  assert.equal(calls(vm, 'SortBags'), 1);
  assert.equal(calls(vm, 'AbandonQuest'), 1);
  assert.equal(calls(vm, 'SortBank'), 0);
  const report = lastHistory(vm);
  assert.ok(report.startsWith('Actions:\nOK  Sort your bags\nOK  Abandon: [Wolves Across the Border]\n...  Sort your bank: open your bank and click Apply again'), report);
  assert.equal(vm.num('#WoWAIDB.chats[1].history[#WoWAIDB.chats[1].history - 1].actions'), 1, 'only the bank action is left');
  // With the bank open, Apply again does the rest and the button goes away.
  vm.run('STUB.FireEvent("BANKFRAME_OPENED"); WoWAI.ApplyActions()');
  drain(vm);
  assert.equal(calls(vm, 'SortBank'), 1);
  assert.equal(vm.evaluate('WoWAIDB.chats[1].history[#WoWAIDB.chats[1].history - 2].actions'), null);
  // The next message tells the agent how it went.
  vm.run('WoWAI.Send("thanks")');
  const sent = Buffer.from(vm.evaluate('WoWAIDB.outbox.text'), 'hex').toString('utf8');
  assert.ok(sent.startsWith('[actions] OK  Sort your bank\n\nthanks'), sent);
  assert.equal(lastHistory(vm), 'thanks', 'the transcript shows what the player typed');
});

test('actions never run in combat', () => {
  const vm = connected();
  exchange(vm, 'sort', 'actions = { { op = "sort_bags" } }');
  vm.run('InCombatLockdown = function() return true end; WoWAI.ApplyActions()');
  drain(vm);
  assert.equal(calls(vm, 'SortBags'), 0);
  assert.equal(lastHistory(vm), 'Not possible in combat.');
});

test('spells go on the bars through the cursor, and macros are created', () => {
  const vm = connected();
  exchange(vm, 'set me up', 'actions = { { op = "place_action", slots = { { slot = 2, spell = 133 }, { slot = 3, spell = 999 } } }, { op = "create_macro", name = "Pull", body = "/cast Fireball", perCharacter = true } }');
  vm.run('WoWAI.ApplyActions()');
  drain(vm);
  assert.equal(vm.evaluate('(function() for _, c in ipairs(CALLS) do if c[1] == "PlaceAction" then return c[2] end end end)()'), '2');
  assert.equal(calls(vm, 'PlaceAction'), 1, 'an unknown spell is not placed');
  assert.equal(vm.evaluate('(function() for _, c in ipairs(CALLS) do if c[1] == "CreateMacro" then return c[2] .. "|" .. c[4] end end end)()'), 'Pull|/cast Fireball');
  const report = lastHistory(vm);
  assert.ok(report.includes('OK  Action bars: Fireball -> main bar, button 2; spell 999 -> main bar, button 3 (1 done, 1 failed; couldn\'t pick up spell 999 (not known?))'), report);
  assert.ok(report.includes('OK  Macro "Pull": /cast Fireball'), report);
});

test('discarded actions are dropped and the agent is told', () => {
  const vm = connected();
  exchange(vm, 'sort', 'actions = { { op = "sort_bags" } }');
  vm.run('SlashCmdList.WOWAI("descartar")');
  assert.equal(lastHistory(vm), 'Proposed actions discarded.');
  vm.run('WoWAI.ApplyActions()');
  assert.equal(lastHistory(vm), 'There are no proposed actions to apply.');
  vm.run('WoWAI.Send("ok")');
  const sent = Buffer.from(vm.evaluate('WoWAIDB.outbox.text'), 'hex').toString('utf8');
  assert.ok(sent.startsWith('[actions] the player discarded the proposed actions'), sent);
});

test('/wow-ai data is a command only for known kinds; other text is a message', () => {
  const vm = connected();
  vm.run('SlashCmdList.WOWAI("datos bolsas")');
  assert.equal(vm.evaluate('WoWAIDB.chats[1].pendingId'), null, 'a preview sends nothing');
  vm.run('SlashCmdList.WOWAI("datos de mi personaje")');
  assert.ok(vm.num('WoWAIDB.chats[1].pendingId') > 0, 'free text starting with "datos" is sent to the agent');
});

test('talents: points are bought node by node and the tree is applied once', () => {
  const vm = connected();
  vm.run(`
    C_ClassTalents = { GetActiveConfigID = function() return 9 end }
    NODES = { [100] = { type = 0, entryIDs = { 1000 }, maxRanks = 2, currentRank = 0, canPurchaseRank = true, isAvailable = true },
              [200] = { type = 2, entryIDs = { 2001, 2002 }, maxRanks = 1, currentRank = 0 } }
    C_Traits = {
      GetConfigInfo = function() return { treeIDs = { 7 } } end,
      GetTreeNodes = function() return { 100, 200 } end,
      GetNodeInfo = function(_, id) return NODES[id] end,
      GetEntryInfo = function(_, e) return { definitionID = e } end,
      GetDefinitionInfo = function(d) return { overrideName = "Talent " .. d } end,
      GetTreeCurrencyInfo = function() return { { quantity = 3, spent = 0 } } end,
      PurchaseRank = function(c, n) table.insert(CALLS, { "PurchaseRank", n }); return true end,
      SetSelection = function(c, n, e) table.insert(CALLS, { "SetSelection", n, e }); return true end,
      CommitConfig = function(c) table.insert(CALLS, { "CommitConfig", c }); return true end,
    }`);
  const data = vm.evaluate('WoWAIData.Collect({ "talents" }, 3000)');
  assert.ok(data.includes('tree 7: 3 left, 0 spent'), data);
  assert.ok(data.includes('+100: 1000 Talent 1000 0/2'), data);
  assert.ok(data.includes('200: 2001 Talent 2001 | 2002 Talent 2002 0/1'), data);
  exchange(vm, 'talents', 'actions = { { op = "learn_talents", nodes = { { node = 100, ranks = 2 }, { node = 200, entry = 2002, ranks = 1 } } } }');
  assert.ok(vm.evaluate('table.concat(STUB.texts, "\\n")').includes('- Learn talents: Talent 1000 x2, Talent 2002'));
  vm.run('WoWAI.ApplyActions()');
  drain(vm);
  assert.equal(calls(vm, 'PurchaseRank'), 2);
  assert.equal(vm.evaluate('(function() for _, c in ipairs(CALLS) do if c[1] == "SetSelection" then return c[2] .. ":" .. c[3] end end end)()'), '200:2002');
  assert.equal(calls(vm, 'CommitConfig'), 1);
  assert.ok(lastHistory(vm).includes('OK  Learn talents: Talent 1000 x2, Talent 2002 (3)'), lastHistory(vm));
});

test('deposit and selling move the matching stacks only, with the window open', () => {
  const vm = connected();
  exchange(vm, 'bank my cloth and sell junk', 'actions = { { op = "deposit", items = { 2589 } }, { op = "sell_junk" } }');
  vm.run('STUB.FireEvent("BANKFRAME_OPENED"); WoWAI.ApplyActions()');
  drain(vm);
  assert.equal(vm.evaluate('(function() for _, c in ipairs(CALLS) do if c[1] == "UseContainerItem" then return c[2] .. ":" .. c[3] .. ":" .. tostring(c[5]) end end end)()'), '0:1:0', 'bag 0 slot 1 into the character bank');
  assert.equal(calls(vm, 'UseContainerItem'), 1, 'the junk waits for a vendor');
  assert.ok(lastHistory(vm).includes('...  Sell the gray items: talk to a vendor and click Apply again'));
  vm.run('STUB.FireEvent("MERCHANT_SHOW"); WoWAI.ApplyActions()');
  drain(vm);
  assert.equal(calls(vm, 'UseContainerItem'), 2, 'the gray Rabbit\'s Foot is sold');
  assert.equal(vm.evaluate('(function() local l for _, c in ipairs(CALLS) do if c[1] == "UseContainerItem" then l = c[2] .. ":" .. c[3] end end return l end)()'), '0:2');
});

// Deliver the bridge's reply to the chat's pending message.
function reply(vm, extra = '') {
  const id = vm.num('WoWAIDB.chats[1].pendingId');
  const chat = vm.evaluate('WoWAIDB.chats[1].id');
  nextSlot(vm, `{ now = time(), cwd = "", replies = { { chat = "${chat}", id = ${id}, status = "done", text = "reply ${id}", ${extra} } } }`);
  // The poll schedule restarts after a manual check, so let time pass until it's taken.
  for (let k = 0; k < 20 && vm.evaluate('WoWAIDB.chats[1].pendingId') === String(id); k++) {
    vm.run('STUB.now = STUB.now + 6; STUB.Tick(); STUB.RunTimers()');
  }
  vm.run('STUB.RunTimers()');
  return id;
}
const outboxText = (vm) => Buffer.from(vm.evaluate('WoWAIDB.outbox.text'), 'hex').toString('utf8');

test('messages typed while waiting are queued and go out one after another', () => {
  const vm = connected();
  vm.run('WoWAI.Send("uno"); WoWAI.Send("dos"); WoWAI.Send("tres")');
  assert.equal(outboxText(vm), 'uno');
  assert.equal(vm.num('#WoWAIDB.chats[1].queue'), 2);
  assert.ok(vm.evaluate('table.concat(STUB.texts, "\\n")').includes('queued 2'), 'queued messages show in the transcript');
  vm.run('WoWAI.Send("")'); // Enter on an empty box only checks for the reply
  assert.equal(vm.num('#WoWAIDB.chats[1].queue'), 2);
  reply(vm);
  assert.equal(outboxText(vm), 'dos', 'the next one went out after the reply');
  reply(vm);
  assert.equal(outboxText(vm), 'tres');
  reply(vm);
  assert.equal(vm.num('#WoWAIDB.chats[1].queue'), 0);
  assert.equal(vm.evaluate('WoWAIDB.chats[1].pendingId'), null);
  const users = vm.evaluate('(function() local t = {} for _, m in ipairs(WoWAIDB.chats[1].history) do if m.role == "user" then t[#t+1] = m.text end end return table.concat(t, ",") end)()');
  assert.equal(users, 'uno,dos,tres');
});

test('a reply with actions pauses the queue until they are applied or discarded', () => {
  const vm = connected();
  vm.run('WoWAI.Send("ordena"); WoWAI.Send("y luego esto")');
  reply(vm, 'actions = { { op = "sort_bags" } }');
  assert.equal(vm.evaluate('WoWAIDB.chats[1].pendingId'), null, 'paused: nothing sent');
  assert.equal(vm.num('#WoWAIDB.chats[1].queue'), 1);
  assert.ok(lastHistory(vm).startsWith('Queue paused (1 waiting)'));
  vm.run('WoWAI.DiscardActions()');
  assert.ok(outboxText(vm).startsWith('[actions] the player discarded the proposed actions\n\ny luego esto'), outboxText(vm));
});

test('applying every action resumes the queue with the report', () => {
  const vm = connected();
  vm.run('WoWAI.Send("ordena"); WoWAI.Send("siguiente")');
  reply(vm, 'actions = { { op = "sort_bags" } }');
  vm.run('WoWAI.ApplyActions()');
  drain(vm);
  assert.ok(outboxText(vm).startsWith('[actions] OK  Sort your bags\n\nsiguiente'), outboxText(vm));
});

test('game data the agent asks for goes before the next queued message', () => {
  const vm = connected();
  vm.run('WoWAI.Send("qué vendo"); WoWAI.Send("gracias")');
  reply(vm, 'need = { "bags" }');
  assert.ok(outboxText(vm).startsWith('[game data] bags'), 'the data goes first');
  assert.equal(vm.num('#WoWAIDB.chats[1].queue'), 1);
  reply(vm);
  assert.equal(outboxText(vm), 'gracias');
});

test('the queue holds ten messages and can be emptied', () => {
  const vm = connected();
  vm.run('WoWAI.Send("primero")');
  for (let i = 1; i <= 11; i++) vm.run(`WoWAI.Send("m${i}")`);
  assert.equal(vm.num('#WoWAIDB.chats[1].queue'), 10);
  assert.ok(lastHistory(vm).startsWith('The queue is full (10 messages)'));
  vm.run('SlashCmdList.WOWAI("cola vaciar")');
  assert.equal(vm.num('#WoWAIDB.chats[1].queue'), 0);
  assert.equal(lastHistory(vm), 'Queue cleared (10).');
  vm.run('SlashCmdList.WOWAI("cola")');
  assert.ok(lastHistory(vm).startsWith('The queue is empty.'));
});
