'use strict';
// The bridge's pure protocol code: strip records in, Lua slot files out, and the
// small rules around folders, permissions and dedup. No I/O, no config, no
// process state, so tests/bridge_test.js can exercise it directly.

const os = require('os');
const path = require('path');

function fromHex(hex) {
  return Buffer.from(hex || '', 'hex').toString('utf8');
}

function pad3(n) { return String(n).padStart(3, '0'); }

// Treat Windows paths consistently when tests or imported agent events run on
// another platform. The bridge still targets Windows, but protocol data can be
// inspected and tested elsewhere.
function isWindowsAbsolute(p) {
  const value = String(p || '');
  return /^[A-Za-z]:[\\/]/.test(value) || /^\\\\/.test(value);
}

function baseName(p) {
  return String(p || '').replace(/[\\/]+$/, '').split(/[\\/]/).pop() || '';
}

function comparableWindowsPath(p) {
  const normalized = path.win32.normalize(String(p || ''));
  return normalized.length > 3 ? normalized.replace(/[\\/]$/, '') : normalized;
}

// Reply slot / signal file number for a message id (1-based, wraps at `slots`).
function slotNumber(id, slots) { return ((id - 1) % slots) + 1; }

// A chat as the bridge tracks it: the addon's session token plus the chat id.
function chatKey(job) { return `${job.session || ''}:${job.chat || 'default'}`; }
// Agent sessions are keyed by chat id alone, which survives an addon data reset.
function sessKey(job) { return job.chat ? 'chat:' + job.chat : chatKey(job); }

// ---------------------------------------------------------------------------
// Dedup: message ids restart whenever the addon's saved data is reset, so they
// are only unique within the addon's session token.
// ---------------------------------------------------------------------------

function alreadyHandled(state, job) {
  const key = job.session || '';
  const h = state.handled[key];
  if (!h) return key === '' && job.id <= state.lastId;
  return !!h[job.id];
}

function markHandled(state, job, now = Date.now()) {
  const key = job.session || '';
  const h = (state.handled[key] = state.handled[key] || {});
  h[job.id] = 1;
  const ids = Object.keys(h);
  if (ids.length > 1000) for (const k of ids.slice(0, ids.length - 1000)) delete h[k];
  state.lastId = Math.max(state.lastId, job.id);
  (state.seen = state.seen || {})[key] = now;
}

// Every saved-data reset in the game mints a new session token; forget the ones
// not heard from in a month so state.json and transcripts.json stop growing.
const MONTH_MS = 30 * 24 * 3600 * 1000;
function pruneStale(state, transcripts, now = Date.now(), maxAgeMs = MONTH_MS) {
  let removed = 0;
  state.seen = state.seen || {};
  for (const key of Object.keys(state.handled || {})) {
    if (key === '') continue;
    if (!state.seen[key]) { state.seen[key] = now; continue; } // grace period starts now
    if (now - state.seen[key] > maxAgeMs) { delete state.handled[key]; delete state.seen[key]; removed++; }
  }
  for (const key of Object.keys(state.seen)) {
    if (!(state.handled || {})[key] && now - state.seen[key] > maxAgeMs) { delete state.seen[key]; }
  }
  for (const [tok, t] of Object.entries((transcripts && transcripts.tokens) || {})) {
    if (now - t > maxAgeMs) { delete transcripts.tokens[tok]; removed++; }
  }
  return removed;
}

// ---------------------------------------------------------------------------
// Folders
// ---------------------------------------------------------------------------

// A chat's folder as typed in game: empty = the default, relative = relative to
// the default, ~ = home. Always absolute and normalized on the way out.
function resolveCwd(raw, base) {
  let p = String(raw || '').trim();
  if (!p) return base;
  if (p === '~' || p.startsWith('~/') || p.startsWith('~\\')) {
    p = path.join(os.homedir(), p.slice(1).replace(/^[\\/]+/, ''));
  }
  if (isWindowsAbsolute(p)) return path.win32.normalize(p);
  return path.resolve(base, p);
}

function sameFolder(a, b) {
  const left = String(a || '');
  const right = String(b || '');
  if (isWindowsAbsolute(left) || isWindowsAbsolute(right)) {
    return comparableWindowsPath(left).toLowerCase() === comparableWindowsPath(right).toLowerCase();
  }
  return path.resolve(left) === path.resolve(right);
}

// ---------------------------------------------------------------------------
// In: what the game sends
// ---------------------------------------------------------------------------

// Flags field: ';'-separated tokens. "n" = fresh agent session, "h" = hello
// (no prompt), "d" = the player deleted this chat: forget its transcript and
// session (no prompt), "allow=Rule1,Rule2" = add these permission rules before
// running, "c" = the record carries a game-context field before the text (an
// empty one clears the context the bridge keeps), "agent=codex" = run this
// chat with that agent instead of the bridge's default (see agents.js),
// "model=gpt-6-sol" = run it on that model ("auto" = let JEV pick a tier, see
// jev.js), "v" = a voice message: the bridge listens on the microphone and the
// transcript becomes the text, "vs" = stop listening now (no prompt).
function parseFlags(flags) {
  const out = { newSession: false, hello: false, forget: false, context: false, allow: [], agent: '', model: '', voice: false, voiceStop: false };
  for (const tok of String(flags || '').split(';')) {
    if (tok === 'n') out.newSession = true;
    else if (tok === 'h') out.hello = true;
    else if (tok === 'd') out.forget = true;
    else if (tok === 'c') out.context = true;
    else if (tok === 'v') out.voice = true;
    else if (tok === 'vs') out.voiceStop = true;
    else if (tok.startsWith('allow=')) out.allow.push(...tok.slice(6).split(',').map(s => s.trim()).filter(Boolean));
    else if (tok.startsWith('agent=')) out.agent = tok.slice(6).trim().toLowerCase();
    else if (tok.startsWith('model=')) out.model = cleanModel(tok.slice(6));
  }
  return out;
}

// Model ids as opencodex lists them: "gpt-6-sol", "anthropic/claude-opus-5-5",
// "gpt-6-luna--fast". Anything else is dropped rather than put on a command line.
function cleanModel(s) {
  const m = String(s || '').trim();
  return /^[A-Za-z0-9][A-Za-z0-9._:/-]{0,79}$/.test(m) ? m : '';
}

// Strip payload: records separated by \x1E, fields by \x1F:
//   session, chat, id, cwd, flags, name, [ctx,] text
// `cwd` is left as typed; the bridge resolves it against its default folder.
// The ctx field is only there when the flags say "c" (older addons never set
// it), so a separator inside the text can't be mistaken for it.
function jobsFromStrip(headerId, payload) {
  const jobs = [];
  for (const rec of String(payload).split('\x1E')) {
    const p = rec.split('\x1F');
    if (p.length >= 7 && /^\d+$/.test(p[2])) {
      const flags = parseFlags(p[4]);
      const withCtx = flags.context && p.length >= 8;
      const job = { session: p[0], chat: p[1], id: Number(p[2]), cwd: p[3], ...flags, name: p[5], text: p.slice(withCtx ? 7 : 6).join('\x1F'), via: 'pixel' };
      if (withCtx) job.ctx = p[6];
      jobs.push(job);
    } else if (p.length === 6 && /^\d+$/.test(p[2])) { // previous format without the chat name
      jobs.push({ session: p[0], chat: p[1], id: Number(p[2]), cwd: p[3], ...parseFlags(p[4]), name: '', text: p[5], via: 'pixel' });
    } else if (p.length === 4) { // pre-chat format: session, cwd, flags, text
      jobs.push({ session: p[0], chat: '', id: headerId, cwd: p[1], ...parseFlags(p[2]), text: p[3], via: 'pixel' });
    }
  }
  return jobs;
}

// The reload path: the addon's SavedVariables file holds an `outbox` table with
// hex-encoded text and cwd. Returns null when there is no complete outbox.
function parseOutbox(src) {
  const block = String(src || '').match(/\["outbox"\]\s*=\s*\{([^}]*)\}/);
  if (!block) return null;
  const b = block[1];
  const id = Number((b.match(/\["id"\]\s*=\s*(\d+)/) || [])[1]);
  if (!id) return null;
  const text = fromHex((b.match(/\["text"\]\s*=\s*"([0-9a-fA-F]*)"/) || [])[1]);
  const cwd = fromHex((b.match(/\["cwd"\]\s*=\s*"([0-9a-fA-F]*)"/) || [])[1]);
  const session = (b.match(/\["session"\]\s*=\s*"([0-9a-zA-Z]*)"/) || [])[1] || '';
  const chat = (b.match(/\["chat"\]\s*=\s*"([0-9a-zA-Z]*)"/) || [])[1] || '';
  const newSession = /\["newSession"\]\s*=\s*true/.test(b);
  const job = { id, session, chat, text, cwd, newSession, via: 'reload' };
  const ctx = b.match(/\["ctx"\]\s*=\s*"([0-9a-fA-F]*)"/);
  if (ctx) job.ctx = fromHex(ctx[1]);
  const agent = b.match(/\["agent"\]\s*=\s*"([0-9a-zA-Z_-]*)"/);
  if (agent && agent[1]) job.agent = agent[1].toLowerCase();
  const model = b.match(/\["model"\]\s*=\s*"([^"]*)"/);
  if (model && cleanModel(model[1])) job.model = cleanModel(model[1]);
  const allow = b.match(/\["allow"\]\s*=\s*"([0-9a-fA-F]*)"/);
  if (allow && allow[1]) job.allow = fromHex(allow[1]).split('\x1F').filter(Boolean);
  return job;
}

// ---------------------------------------------------------------------------
// System prompt: reply format, game context, primer
// ---------------------------------------------------------------------------

// What the agent is told on every run. First how the reply is shown: the full
// reply goes to the addon's window and only its closing "TL;DR:" block is
// printed in the game chat, so every reply must end with one. Then, while the
// addon has sent a context (the player's character, location and so on; see
// GameContext in WoWAI.lua), that context plus the addon/macro primer
// (docs/WOW-ADDON-PRIMER.md) so it can write for this client whatever folder
// the chat works in. Empty context = neither is appended, so a bridge used for
// unrelated projects, or an addon with `/wow-ai context off`, only gets the
// reply-format rule. Claude and Grok take this as a system prompt; for Codex,
// agents.js puts it at the top of the prompt.
const SUMMARY_MARKER = 'TL;DR:';
const REPLY_FORMAT = [
  'The user is talking to you from inside World of Warcraft through the wow-ai addon. They type in a small in-game window and your reply is shown there as plain text (markdown is not rendered), so keep replies compact and formatting simple.',
  '',
  `Only a short summary of each reply is printed into the game chat, where the user actually sees it while playing; the full reply is only visible if they open the addon window. So end EVERY reply with a final block that starts with "${SUMMARY_MARKER}" on its own line and holds one or two short lines (under about 200 characters in total) saying what you did or what the answer is, and what you need from the user if anything. Write it as plain text. Do not repeat the summary elsewhere, and put nothing after it.`,
];

// How the agent draws on the world map (see "Map layers" below and docs/MAP.md).
// Sent with the game context, since marks only make sense in a game chat.
const MAP_HINT = [
  'You can mark the player\'s world map. Either append commands to the file named by the WOW_AI_MAP_FILE environment variable (one JSON object per line) or, for a few marks, end the reply with a fenced block whose language tag is wowmap containing them. Commands:',
  '{"op":"set","layer":"<name>","title":"<shown title>","ordered":true,"loop":false,"points":[{"m":<uiMapID>,"x":<0-100>,"y":<0-100>,"label":"<text>","kind":"quest"}]}  replaces that layer; "ordered" draws a numbered route with a navigator, "loop" closes it.',
  '{"op":"clear","layer":"<name>"} removes a layer; {"op":"clearall"} removes them all.',
  'x and y are map percent on the map with that uiMapID (the context gives the player\'s current one). kind is one of ore, herb, quest, turnin, kill, loot, object, explore, npc, trainer, vendor, dungeon, flight, poi. Only mark the map when asked for a route, marks or locations; say in the reply what you drew.',
];

// How the agent asks the addon for more game data, and proposes game actions the
// player confirms (see "Game data and actions" below, and docs/ACTIONS.md).
const DATA_HINT = [
  'When answering needs more than the context above (the player\'s bags, bank, gear, spells, action bars, talents, quest details, reputation or macros), do not guess: put a fenced block whose language tag is wowdata right before the TL;DR block, listing what you need, from: bags, bank, gear, spells, bars, talents, quests, reputation, macros. The addon then sends it on its own as the next message of this chat, starting with "[game data]", and you carry on with the player\'s request from there. Keep the reply that asks for it to one short line. bank is only known once the player has opened their bank.',
];
const ACTION_HINT = [
  'You can also act in the game, but only through the actions below. The addon lists them for the player, in its own words. When the player plainly asked for exactly those actions they run right away (the bridge checks each against the request); otherwise they wait for the player\'s Apply button. Never in combat. Put them in a fenced block whose language tag is wowact (a JSON array) right before the TL;DR block:',
  '{"op":"sort_bags"} sorts the bags with the game\'s own sorter. {"op":"sort_bank"} and {"op":"deposit_reagents"} need the bank open.',
  '{"op":"arrange_bags","order":[itemID,...]} puts those items first in the bags, in that order (every stack of each), from bag 0 slot 1 on; the rest keeps its order after them. {"op":"move_items","moves":[{"from":[bag,slot],"to":[bag,slot]},...]} moves the item in one bag slot to another (swapping with what is there); positions come from the "@bag:slot" lists in the bags game data, bags 0-4 plus 5 for the reagent bag.',
  '{"op":"deposit","items":[itemID,...]} moves every stack of those items from the bags to the bank; {"op":"withdraw","items":[itemID,...]} the other way (bank open).',
  '{"op":"sell_junk"} sells the grey items; {"op":"sell_items","items":[itemID,...]} sells those (merchant open).',
  '{"op":"abandon_quests","ids":[questID,...]}; {"op":"track_quests","add":[questID,...],"remove":[questID,...]}.',
  '{"op":"place_action","slots":[{"slot":1,"spell":spellID},{"slot":2,"item":itemID},{"slot":3,"macro":"<macro name>"}]} puts spells, items or macros on action slots 1-180 (1-12 is the main bar); {"op":"clear_actions","slots":[slot,...]} empties slots.',
  '{"op":"create_macro","name":"<up to 16 chars>","body":"<up to 255 chars>","icon":"INV_Misc_QuestionMark","perCharacter":true} creates the macro, or rewrites the one with that name.',
  '{"op":"learn_talents","nodes":[{"node":nodeID,"entry":entryID,"ranks":1}]} spends talent points on those nodes (entry only for choice nodes) and applies the tree.',
  '{"op":"train_all"} learns everything the open trainer offers that the player can afford. {"op":"equip","items":[itemID,...]} equips those items from the bags.',
  'Use the ids from the game data (ask for it with wowdata first when you don\'t have it). Only propose actions when the player asks you to do something in the game, and say in the reply what they will do. Deleting items is not possible.',
  'A message whose first line starts with "[actions]" is the addon reporting how the actions the player applied went.',
];

function systemPrompt(ctx, primer) {
  const lines = [...REPLY_FORMAT];
  const text = String(ctx || '').trim();
  if (text) {
    lines.push('',
      'Their in-game situation when the message was written, as reported by the addon:',
      text,
      '',
      'Use this when the request is about the game or the character (questions, macros, addon code, gear advice); ignore it when the task is unrelated. Items, spells or quests the player shift-clicked into a message appear as [Name] in the text, with their tooltip in a "Linked from the game" block at the end of the message.',
      '',
      ...MAP_HINT,
      '',
      ...DATA_HINT,
      '',
      ...ACTION_HINT);
  }
  const ref = text ? String(primer || '').trim() : '';
  if (ref) {
    lines.push('', 'Reference for writing addons and macros for this client. Follow it when the task is about WoW, and check anything it marks as uncertain against the Blizzard UI source it names:', '', ref);
  }
  return lines.join('\n');
}

// Pull the game-chat summary out of a reply: whatever follows the last "TL;DR:"
// marker that starts a line (bold or a heading around it is tolerated:
// "**TL;DR:**", "## TL;DR"). The text for the window stays the whole reply, so
// nothing the agent wrote is lost however the addon cuts the echo; without a
// marker the summary is empty and the addon falls back to the reply's first
// lines.
const MARKER_RE = /(?:^|\n)[ \t]*(?:#+[ \t]*)?(?:\*\*|__)?[ \t]*TL;?DR[ \t]*:?[ \t]*(?:\*\*|__)?[ \t]*:?[ \t]*/gi;
function splitSummary(text) {
  const full = String(text || '').trim();
  const last = [...full.matchAll(MARKER_RE)].pop();
  const summary = last ? full.slice(last.index + last[0].length).trim() : '';
  return { text: full, summary };
}

// ---------------------------------------------------------------------------
// Permissions and progress
// ---------------------------------------------------------------------------

// Turn a permission denial (Claude's shape: tool_name, tool_input) into an
// allowlist rule the user can accept. Rules are in Claude Code's syntax for
// every agent; agents.js translates where an agent's own syntax differs.
function ruleFor(d) {
  const name = d.tool_name || 'Unknown';
  if (name === 'Bash') {
    const cmd = String((d.tool_input && d.tool_input.command) || '').trim();
    const word = cmd.split(/\s+/)[0];
    if (word && /^[\w.\-]+$/.test(word)) return `Bash(${word}:*)`;
    return 'Bash';
  }
  return name;
}

// One progress line per Claude tool call, as shown in the game's "working"
// bubble (Codex and Grok have their own in agents.js).
function describeToolUse(block) {
  const inp = block.input || {};
  switch (block.name) {
    case 'Bash': return `$ ${String(inp.command || '').split('\n')[0].slice(0, 110)}`;
    case 'Read': return `read ${baseName(inp.file_path)}`;
    case 'Edit': return `edit ${baseName(inp.file_path)}`;
    case 'Write': return `write ${baseName(inp.file_path)}`;
    case 'Grep': return `grep ${inp.pattern || ''}`;
    case 'Glob': return `glob ${inp.pattern || ''}`;
    case 'Agent': return `agent: ${inp.description || ''}`;
    case 'WebSearch': return `search: ${inp.query || ''}`;
    case 'WebFetch': return `fetch ${inp.url || ''}`;
    default: return block.name;
  }
}

// ---------------------------------------------------------------------------
// Out: what the game reads
// ---------------------------------------------------------------------------

// Escape for a double-quoted Lua 5.1 string literal.
function luaStr(s) {
  return '"' + String(s ?? '')
    .replace(/\\/g, '\\\\')
    .replace(/"/g, '\\"')
    .replace(/\r/g, '')
    .replace(/\n/g, '\\n')
    .replace(/[\x00-\x08\x0b-\x1f\x7f]/g, c => '\\' + String(c.charCodeAt(0)).padStart(3, '0'))
    + '"';
}

// The slot file / Inbox.lua body: the latest record of every chat, the bridge's
// clock, default folder and default agent (plus the agents it knows), and
// (right after a saved-data reset) a restore bundle.
function luaTable(globalName, records, opts = {}) {
  const now = opts.now || Date.now();
  const agents = Array.isArray(opts.agents) ? opts.agents : [];
  const lines = [
    '-- Written by the wow-ai bridge (bridge/bridge.js). Do not edit by hand.',
    `${globalName} = {`,
    `\tts = ${luaStr(new Date(now).toISOString())},`,
    `\tnow = ${Math.floor(now / 1000)},`,
    `\tcwd = ${luaStr(opts.cwd || '')},`,
    `\tagent = ${luaStr(opts.agent || '')},`,
    `\tagents = { ${agents.map(luaStr).join(', ')} },`,
  ];
  // The models the chats can pick (opencodex's catalog), and whether the bridge
  // can listen on the microphone. Both only when known, so older tests stay exact.
  if (Array.isArray(opts.models) && opts.models.length) lines.push(`\tmodels = { ${opts.models.map(luaStr).join(', ')} },`);
  if (opts.voice !== undefined) lines.push(`\tvoice = ${opts.voice ? 'true' : 'false'},`);
  lines.push('\treplies = {');
  for (const r of records) {
    lines.push('\t\t{');
    lines.push(`\t\t\tchat = ${luaStr(r.chat || '')},`);
    lines.push(`\t\t\tid = ${Number(r.id) || 0},`);
    lines.push(`\t\t\tstatus = ${luaStr(r.status)},`);
    lines.push(`\t\t\ttext = ${luaStr(r.text)},`);
    lines.push(`\t\t\tcwd = ${luaStr(r.cwd || '')},`);
    lines.push(`\t\t\tsession = ${luaStr(r.session || '')},`);
    lines.push(`\t\t\tagent = ${luaStr(r.agent || '')},`);
    if (r.summary) lines.push(`\t\t\tsummary = ${luaStr(r.summary)},`);
    // What the bridge heard on a voice message, the model that answered, and
    // map commands a quick order (jev.js) asks the addon to run.
    if (r.heard) lines.push(`\t\t\theard = ${luaStr(r.heard)},`);
    if (r.model) lines.push(`\t\t\tmodel = ${luaStr(r.model)},`);
    if (Array.isArray(r.cmds) && r.cmds.length) lines.push(`\t\t\tcmds = ${luaValue(r.cmds)},`);
    // The bridge asking for game data before the question runs (jev.js), not a reply.
    if (r.prefetch) lines.push('\t\t\tprefetch = true,');
    // The actions were plainly asked for: the addon applies them without the click.
    if (r.auto) lines.push('\t\t\tauto = true,');
    if (Array.isArray(r.denied) && r.denied.length) {
      lines.push(`\t\t\tdenied = { ${r.denied.map(luaStr).join(', ')} },`);
    }
    if (Array.isArray(r.need) && r.need.length) lines.push(`\t\t\tneed = ${luaValue(r.need)},`);
    if (Array.isArray(r.actions) && r.actions.length) lines.push(`\t\t\tactions = ${luaValue(r.actions)},`);
    lines.push('\t\t},');
  }
  lines.push('\t},');
  if (opts.map) lines.push(luaMap(opts.map));
  const restore = opts.restore;
  if (restore) {
    lines.push('\trestore = {', `\t\ttoken = ${luaStr(restore.token)},`, '\t\tchats = {');
    for (const c of restore.chats) {
      lines.push('\t\t\t{', `\t\t\t\tid = ${luaStr(c.id)},`, `\t\t\t\tname = ${luaStr(c.name)},`, `\t\t\t\tcwd = ${luaStr(c.cwd)},`, '\t\t\t\tmessages = {');
      for (const m of c.messages) {
        lines.push(`\t\t\t\t\t{ role = ${luaStr(m.role)}, id = ${Number(m.id) || 0}, t = ${Number(m.t) || 0}, agent = ${luaStr(m.agent || '')}, text = ${luaStr(m.text)} },`);
      }
      lines.push('\t\t\t\t},', '\t\t\t},');
    }
    lines.push('\t\t},', '\t},');
  }
  lines.push('}', '');
  return lines.join('\n');
}

// ---------------------------------------------------------------------------
// Map layers
// ---------------------------------------------------------------------------
//
// The agent marks the in-game map by writing commands, one JSON object per line,
// to the file named by WOW_AI_MAP_FILE in its environment (a tool of its own can
// do that), or with a ```wowmap fenced block in its reply for a few hand-made marks.
// The system prompt (MAP_HINT) tells it so.
// The bridge owns the resulting layers (state.json) and ships the whole set,
// versioned, in the slot files; the addon replaces its copy when the version is
// newer. So a mark is never applied twice, and a client that lost its saved data
// gets everything back on its next hello.
//
//   {"op":"set","layer":"mining","title":"Copper loop","ordered":true,"loop":true,
//    "points":[{"m":1432,"x":41.5,"y":47.8,"label":"1. Copper Vein","kind":"ore"}]}
//   {"op":"clear","layer":"mining"}    {"op":"clearall"}

const MAP_KINDS = new Set(['ore', 'herb', 'quest', 'turnin', 'kill', 'loot', 'object', 'explore', 'npc', 'trainer', 'vendor', 'dungeon', 'flight', 'poi']);
const MAP_LIMITS = { layers: 12, pointsPerLayer: 400, totalPoints: 1500, label: 80, title: 80 };

function cleanText(s, max) {
  return String(s ?? '').replace(/[\x00-\x1f\x7f|]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, max);
}

// One command, sanitized, or null (with the reason in `why`).
function validateMapCommand(c, why = []) {
  if (!c || typeof c !== 'object') { why.push('not an object'); return null; }
  if (c.op === 'clearall') return { op: 'clearall' };
  const layer = String(c.layer ?? '');
  if (!/^[A-Za-z0-9_.-]{1,32}$/.test(layer)) { why.push(`bad layer name "${layer.slice(0, 40)}"`); return null; }
  if (c.op === 'clear') return { op: 'clear', layer };
  if (c.op !== 'set') { why.push(`unknown op "${String(c.op).slice(0, 20)}"`); return null; }
  if (!Array.isArray(c.points)) { why.push(`layer ${layer}: points must be an array`); return null; }
  const points = [];
  for (const p of c.points.slice(0, MAP_LIMITS.pointsPerLayer)) {
    const m = Number(p && p.m), x = Number(p && p.x), y = Number(p && p.y);
    if (!Number.isInteger(m) || m <= 0 || m > 99999 || !Number.isFinite(x) || !Number.isFinite(y)) continue;
    points.push({
      m, x: Math.round(Math.min(100, Math.max(0, x)) * 100) / 100, y: Math.round(Math.min(100, Math.max(0, y)) * 100) / 100,
      label: cleanText(p.label, MAP_LIMITS.label), kind: MAP_KINDS.has(p.kind) ? p.kind : 'poi',
    });
  }
  if (c.points.length > MAP_LIMITS.pointsPerLayer) why.push(`layer ${layer}: kept the first ${MAP_LIMITS.pointsPerLayer} points`);
  if (points.length < c.points.slice(0, MAP_LIMITS.pointsPerLayer).length) why.push(`layer ${layer}: dropped invalid points`);
  if (!points.length) { why.push(`layer ${layer}: no valid points`); return null; }
  return { op: 'set', layer, title: cleanText(c.title || layer, MAP_LIMITS.title), ordered: !!c.ordered, loop: !!c.loop, points };
}

function newMap(epoch) {
  return { epoch: epoch || Math.random().toString(36).slice(2, 10), version: 0, layers: {} };
}

// Apply commands in order. Returns { changed, notes } and mutates `map`.
function applyMapCommands(map, cmds, now = Date.now()) {
  const notes = [];
  let changed = false;
  for (const raw of cmds || []) {
    const why = [];
    const c = validateMapCommand(raw, why);
    notes.push(...why);
    if (!c) continue;
    if (c.op === 'clearall') {
      if (Object.keys(map.layers).length) { map.layers = {}; changed = true; }
      notes.push('cleared all layers');
    } else if (c.op === 'clear') {
      if (map.layers[c.layer]) { delete map.layers[c.layer]; changed = true; notes.push(`cleared layer ${c.layer}`); }
    } else {
      map.layers[c.layer] = { title: c.title, ordered: c.ordered, loop: c.loop, points: c.points, t: now };
      changed = true;
      notes.push(`layer ${c.layer}: ${c.points.length} point(s)`);
    }
  }
  // Keep within budget: drop the oldest layers first.
  const total = () => Object.values(map.layers).reduce((s, l) => s + l.points.length, 0);
  const names = () => Object.keys(map.layers).sort((a, b) => map.layers[a].t - map.layers[b].t);
  while (Object.keys(map.layers).length > MAP_LIMITS.layers || total() > MAP_LIMITS.totalPoints) {
    const old = names()[0];
    delete map.layers[old];
    notes.push(`dropped old layer ${old} (map full)`);
    changed = true;
  }
  if (changed) map.version = (map.version || 0) + 1;
  return { changed, notes };
}

// Pull ```wowmap blocks out of a reply: a JSON object, an array, or one object per line.
function extractMapBlocks(text) {
  const cmds = [], errors = [];
  const stripped = String(text ?? '').replace(/```wowmap[^\n]*\n([\s\S]*?)```/g, (_, body) => {
    const src = body.trim();
    try {
      const v = JSON.parse(src);
      cmds.push(...(Array.isArray(v) ? v : [v]));
    } catch {
      for (const line of src.split('\n')) {
        if (!line.trim()) continue;
        try { cmds.push(JSON.parse(line)); } catch { errors.push('unreadable wowmap line: ' + line.trim().slice(0, 60)); }
      }
    }
    return '';
  }).replace(/\n{3,}/g, '\n\n').trim();
  return { text: stripped, cmds, errors };
}

// Commands the agent's tools appended to WOW_AI_MAP_FILE (one JSON per line).
function parseMapFile(src) {
  const cmds = [], errors = [];
  for (const line of String(src || '').split('\n')) {
    if (!line.trim()) continue;
    try { cmds.push(JSON.parse(line)); } catch { errors.push('unreadable map file line'); }
  }
  return { cmds, errors };
}

function luaMap(map) {
  const lines = ['\tmap = {', `\t\tepoch = ${luaStr(map.epoch)},`, `\t\tversion = ${Number(map.version) || 0},`, '\t\tlayers = {'];
  for (const [name, l] of Object.entries(map.layers || {})) {
    lines.push(`\t\t\t{ name = ${luaStr(name)}, title = ${luaStr(l.title)}, ordered = ${l.ordered ? 'true' : 'false'}, loop = ${l.loop ? 'true' : 'false'}, points = {`);
    for (const p of l.points) lines.push(`\t\t\t\t{ ${p.m}, ${p.x}, ${p.y}, ${luaStr(p.label)}, ${luaStr(p.kind)} },`);
    lines.push('\t\t\t} },');
  }
  lines.push('\t\t},', '\t},');
  return lines.join('\n');
}

// ---------------------------------------------------------------------------
// Game data and actions
// ---------------------------------------------------------------------------
//
// Two more fenced blocks an agent may put in a reply (DATA_HINT and ACTION_HINT
// in the system prompt say how; docs/ACTIONS.md has the details):
//   ```wowdata  what game data it needs: bags bank gear ... The reply record
//               carries it as `need`, and the addon answers on its own with the
//               next message of the chat (GameData.lua).
//   ```wowact   game actions it proposes. The bridge keeps only the ones below,
//               with their arguments checked; the reply record carries them as
//               `actions`, and the addon lists them in its own words and runs them
//               when the player clicks Apply (Actions.lua). Nothing the agent
//               writes is ever run as code.

const DATA_KINDS = ['bags', 'bank', 'gear', 'spells', 'bars', 'talents', 'quests', 'reputation', 'macros'];
const ACTION_LIMITS = { actions: 20, ids: 40, slots: 60, macroName: 16, macroBody: 255, icon: 64 };

function idList(v, max = ACTION_LIMITS.ids) {
  if (!Array.isArray(v)) return [];
  const out = [];
  for (const x of v) {
    const n = Number(x);
    if (Number.isInteger(n) && n > 0 && n < 1e9 && !out.includes(n)) out.push(n);
    if (out.length >= max) break;
  }
  return out;
}

// op -> (action, why) -> the sanitized action, or null.
const ACTION_OPS = {
  sort_bags: () => ({}),
  sort_bank: () => ({}),
  deposit_reagents: () => ({}),
  sell_junk: () => ({}),
  train_all: () => ({}),
  deposit: (a) => { const items = idList(a.items); return items.length ? { items } : null; },
  withdraw: (a) => { const items = idList(a.items); return items.length ? { items } : null; },
  sell_items: (a) => { const items = idList(a.items); return items.length ? { items } : null; },
  equip: (a) => { const items = idList(a.items, 20); return items.length ? { items } : null; },
  abandon_quests: (a) => { const ids = idList(a.ids); return ids.length ? { ids } : null; },
  track_quests: (a) => {
    const add = idList(a.add), remove = idList(a.remove);
    return add.length || remove.length ? { add, remove } : null;
  },
  place_action: (a, why) => {
    if (!Array.isArray(a.slots)) return null;
    const slots = [];
    for (const s of a.slots.slice(0, ACTION_LIMITS.slots)) {
      const slot = Number(s && s.slot);
      if (!Number.isInteger(slot) || slot < 1 || slot > 180) { why.push('place_action: bad slot'); continue; }
      const spell = Number(s.spell), item = Number(s.item);
      if (Number.isInteger(spell) && spell > 0) slots.push({ slot, spell });
      else if (Number.isInteger(item) && item > 0) slots.push({ slot, item });
      else if (typeof s.macro === 'string' && s.macro.trim()) slots.push({ slot, macro: cleanText(s.macro, ACTION_LIMITS.macroName) });
      else why.push(`place_action: slot ${slot} names no spell, item or macro`);
    }
    return slots.length ? { slots } : null;
  },
  clear_actions: (a) => {
    const slots = idList(a.slots, ACTION_LIMITS.slots).filter(n => n <= 180);
    return slots.length ? { slots } : null;
  },
  create_macro: (a, why) => {
    const name = cleanText(a.name, ACTION_LIMITS.macroName);
    // Macro bodies are multi-line; keep newlines, drop other control characters and |.
    const body = String(a.body ?? '').replace(/\r/g, '').replace(/[\x00-\x09\x0b-\x1f\x7f|]/g, ' ').trim();
    if (!name || !body) { why.push('create_macro needs a name and a body'); return null; }
    if (body.length > ACTION_LIMITS.macroBody) { why.push(`create_macro: body over ${ACTION_LIMITS.macroBody} characters`); return null; }
    const out = { name, body, perCharacter: a.perCharacter !== false };
    const icon = a.icon;
    if (Number.isInteger(Number(icon)) && Number(icon) > 0) out.icon = Number(icon);
    else if (typeof icon === 'string' && /^[A-Za-z0-9_]{1,64}$/.test(icon)) out.icon = icon;
    return out;
  },
  // Put these items first in the bags, in this order (every stack of each); the
  // rest keeps its order after them. The addon works out the moves itself.
  arrange_bags: (a) => { const order = idList(a.order); return order.length ? { order } : null; },
  // Explicit moves between bag slots, as the "bags" game data shows them
  // (bag 0-5, slot 1-40). Only the bags: nothing is moved to or from the bank here.
  move_items: (a, why) => {
    if (!Array.isArray(a.moves)) return null;
    const pos = (v) => {
      const b = Number(Array.isArray(v) ? v[0] : v && v.bag), sl = Number(Array.isArray(v) ? v[1] : v && v.slot);
      return Number.isInteger(b) && b >= 0 && b <= 5 && Number.isInteger(sl) && sl >= 1 && sl <= 40 ? [b, sl] : null;
    };
    const moves = [];
    for (const m of a.moves.slice(0, ACTION_LIMITS.ids)) {
      const from = pos(m && m.from), to = pos(m && m.to);
      if (!from || !to) { why.push('move_items: a move needs from and to as [bag, slot], bag 0-5, slot 1-40'); continue; }
      if (from[0] === to[0] && from[1] === to[1]) continue;
      moves.push({ from, to });
    }
    return moves.length ? { moves } : null;
  },
  learn_talents: (a, why) => {
    if (!Array.isArray(a.nodes)) return null;
    const nodes = [];
    for (const n of a.nodes.slice(0, ACTION_LIMITS.ids)) {
      const node = Number(n && n.node), entry = Number(n && n.entry), ranks = Number((n && n.ranks) ?? 1);
      if (!Number.isInteger(node) || node <= 0) { why.push('learn_talents: bad node id'); continue; }
      const t = { node, ranks: Number.isInteger(ranks) ? Math.min(10, Math.max(1, ranks)) : 1 };
      if (Number.isInteger(entry) && entry > 0) t.entry = entry;
      nodes.push(t);
    }
    return nodes.length ? { nodes } : null;
  },
};

// One action, sanitized, or null (with the reason in `why`).
function validateAction(a, why = []) {
  if (!a || typeof a !== 'object' || Array.isArray(a)) { why.push('an action is not an object'); return null; }
  const op = String(a.op ?? '');
  const check = Object.prototype.hasOwnProperty.call(ACTION_OPS, op) && ACTION_OPS[op];
  if (!check) { why.push(`unknown action "${op.slice(0, 30)}"`); return null; }
  const args = check(a, why);
  if (!args) { why.push(`${op}: nothing valid to do`); return null; }
  return { op, ...args };
}

function validateActions(list, why = []) {
  const out = [];
  for (const a of list || []) {
    const v = validateAction(a, why);
    if (v) out.push(v);
    if (out.length >= ACTION_LIMITS.actions) { why.push(`kept the first ${ACTION_LIMITS.actions} actions`); break; }
  }
  return out;
}

// Pull every ```<tag> block out of a reply: returns the text without them and
// their bodies.
function extractFenced(text, tag) {
  const bodies = [];
  const re = new RegExp('```' + tag + '[^\\n]*\\n([\\s\\S]*?)```', 'g');
  const stripped = String(text ?? '').replace(re, (_, body) => { bodies.push(body.trim()); return ''; })
    .replace(/\n{3,}/g, '\n\n').trim();
  return { text: stripped, bodies };
}

// Agents answering in Spanish sometimes translate the kinds too.
const DATA_ALIASES = {
  bolsas: 'bags', inventario: 'bags', banco: 'bank', equipo: 'gear', hechizos: 'spells', barras: 'bars',
  talentos: 'talents', misiones: 'quests', reputacion: 'reputation', 'reputación': 'reputation',
};

// ```wowdata blocks: the data kinds asked for, known ones only, in a fixed order.
function extractDataRequests(text) {
  const { text: stripped, bodies } = extractFenced(text, 'wowdata');
  const words = new Set(bodies.join(' ').toLowerCase().split(/[^a-zñáéíóú]+/).filter(Boolean)
    .map(w => DATA_ALIASES[w] || w));
  return { text: stripped, need: DATA_KINDS.filter(k => words.has(k)) };
}

// ```wowact blocks: a JSON array, one object, or one object per line.
function extractActionBlocks(text) {
  const { text: stripped, bodies } = extractFenced(text, 'wowact');
  const raw = [], errors = [];
  for (const src of bodies) {
    try {
      const v = JSON.parse(src);
      raw.push(...(Array.isArray(v) ? v : [v]));
    } catch {
      for (const line of src.split('\n')) {
        if (!line.trim()) continue;
        try { raw.push(JSON.parse(line)); } catch { errors.push('unreadable wowact line: ' + line.trim().slice(0, 60)); }
      }
    }
  }
  const actions = validateActions(raw, errors);
  return { text: stripped, actions, errors };
}

// A Lua literal for the simple values actions are made of: numbers, strings,
// booleans, arrays and objects with identifier keys (validateAction's output).
function luaValue(v) {
  if (Array.isArray(v)) return '{ ' + v.map(luaValue).join(', ') + ' }';
  if (v && typeof v === 'object') {
    return '{ ' + Object.entries(v).map(([k, x]) => (/^[A-Za-z_]\w*$/.test(k) ? k : `[${luaStr(k)}]`) + ' = ' + luaValue(x)).join(', ') + ' }';
  }
  if (typeof v === 'number') return Number.isFinite(v) ? String(v) : '0';
  if (typeof v === 'boolean') return v ? 'true' : 'false';
  return luaStr(v);
}

// A valid, silent 10 ms WAV. An empty file "won't play"; this one will.
const SILENT_WAV = (() => {
  const rate = 8000, samples = 80;
  const b = Buffer.alloc(44 + samples);
  b.write('RIFF', 0); b.writeUInt32LE(36 + samples, 4); b.write('WAVE', 8);
  b.write('fmt ', 12); b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22);
  b.writeUInt32LE(rate, 24); b.writeUInt32LE(rate, 28); b.writeUInt16LE(1, 32); b.writeUInt16LE(8, 34);
  b.write('data', 36); b.writeUInt32LE(samples, 40);
  b.fill(128, 44);
  return b;
})();

module.exports = {
  fromHex, pad3, slotNumber, chatKey, sessKey,
  alreadyHandled, markHandled, pruneStale, MONTH_MS,
  resolveCwd, sameFolder, baseName,
  parseFlags, cleanModel, jobsFromStrip, parseOutbox, systemPrompt, splitSummary,
  ruleFor, describeToolUse,
  luaStr, luaTable, SILENT_WAV,
  MAP_LIMITS, validateMapCommand, newMap, applyMapCommands, extractMapBlocks, parseMapFile, luaMap,
  DATA_KINDS, ACTION_LIMITS, validateAction, validateActions, extractFenced, extractDataRequests, extractActionBlocks, luaValue,
};
