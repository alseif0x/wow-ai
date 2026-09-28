'use strict';
// JEV: TypeSafe's "System One" decision model (typesafe/jev-1.13), served by
// OpenRouter's native decisions endpoint. It doesn't write text: it answers typed
// questions about a small JSON state with probabilities (docs.typesafe.ai). The
// bridge asks it closed questions at two points, and treats every answer as a
// hint with a confidence, never as authority:
//
//   analyze(text)  One request per message the player sends, all questions in
//                  parallel ("speculative fan-out"):
//                    intent     choice: exactly one quick order, or "agent"
//                    difficulty score 0-2, only for chats on the "auto" model
//                    need_<k>   noul per game-data kind: does answering this
//                               need the bags, the quest log, ...?
//                  A sure quick order is answered by the bridge itself (game
//                  actions as an Apply proposal, map orders as addon commands);
//                  needed game data is asked from the addon before the agent
//                  runs, so the agent doesn't spend a whole run asking for it;
//                  the difficulty picks a model tier.
//   review(request, actions)
//                  After a reply proposes game actions: one noul per action,
//                  "did the player ask for this?". Low ones are flagged in the
//                  addon before Apply ("confidence-gated routing": the player
//                  still decides; nothing is blocked or run by this).
//
// The state holds only what the decision needs (the message, one action):
// accuracy drops as unrelated content grows, and JEV is weak at counting, numbers
// and dates, so it is never asked about amounts. One request, a short timeout, no
// retries; any failure leaves things as they were without JEV.

const fs = require('fs');
const os = require('os');
const path = require('path');

const DECISIONS_URL = 'https://openrouter.ai/api/alpha/decisions';
const MODEL = 'typesafe/jev-1.13';
const DEFAULT_KEY_FILE = path.join(os.homedir(), '.config', 'rustic-os', 'openrouter.env');

// The quick orders, in the order JEV sees them. `actions` are validated and
// shown with Apply like any agent proposal; `cmds` are /wow-ai map subcommands
// the addon checks against its own list before running them.
const QUICK = {
  sort_bags:        { es: 'ordenar las bolsas', actions: [{ op: 'sort_bags' }],
    criteria: 'Sort or tidy the bags / inventory ("ordena las bolsas", "sort my bags").' },
  sort_bank:        { es: 'ordenar el banco', actions: [{ op: 'sort_bank' }],
    criteria: 'Sort the bank ("ordena el banco").' },
  deposit_reagents: { es: 'depositar los componentes en el banco', actions: [{ op: 'deposit_reagents' }],
    criteria: 'Deposit reagents / crafting materials in the bank ("guarda los materiales en el banco").' },
  sell_junk:        { es: 'vender la chatarra', actions: [{ op: 'sell_junk' }],
    criteria: 'Sell junk / gray items / trash to the vendor ("vende la basura", "sell junk").' },
  train_all:        { es: 'aprender todo en el instructor', actions: [{ op: 'train_all' }],
    criteria: 'Learn or train everything available at the trainer ("aprende todo", "entrena").' },
  map_next:         { es: 'siguiente parada de la ruta', cmds: ['next'],
    criteria: 'Go on to the next stop of the route on the map ("siguiente parada", "next stop").' },
  map_prev:         { es: 'parada anterior de la ruta', cmds: ['prev'],
    criteria: 'Go back to the previous stop of the route ("parada anterior").' },
  map_stop:         { es: 'parar la navegación', cmds: ['stop'],
    criteria: 'Stop navigating / hide the route arrow ("para la navegación", "quita la flecha").' },
  map_ore:          { es: 'mostrar u ocultar los minerales en el mapa', cmds: ['ore'],
    criteria: 'Show or hide ore / mining nodes on the map ("muestra los minerales").' },
  map_herb:         { es: 'mostrar u ocultar las hierbas en el mapa', cmds: ['herb'],
    criteria: 'Show or hide herb nodes on the map ("muestra las hierbas").' },
};

const AGENT_CRITERIA = 'Anything else: a question, an explanation, advice, a plan, a task with details or ' +
  'conditions (which items, how many, where), several orders at once, chat, or anything unclear. When in doubt, this.';

const INTENT_INSTRUCTIONS =
  'The player of World of Warcraft sent `message` to their AI assistant. Decide whether it is exactly ' +
  'one of the quick orders, with nothing else asked. Pick "agent" for questions ("¿cómo ordeno las bolsas?" is a ' +
  'question), for requests with extra conditions ("vende la chatarra menos las telas"), and whenever unsure.';

const DIFFICULTY_INSTRUCTIONS =
  'How much work is answering `message` for an AI assistant that knows World of Warcraft and can edit code?';

// Score levels, low to high: 0 fast, 1 balanced, 2 strong.
const DIFFICULTY = [
  'A short factual question, a greeting, a quick lookup or a one-line answer.',
  'An ordinary request: an explanation, a guide, a macro, a plan, a small code change.',
  'Hard work: a large or multi-file code change, debugging, careful reasoning, a long plan.',
];
const TIER_NAMES = ['fast', 'balanced', 'strong'];

// What each game-data kind holds, for the need_<kind> questions (the kinds the
// addon can send, docs/ACTIONS.md). Plain yes/no wording: JEV reads literally.
const NEEDS = {
  bags: 'the items in the player\'s bags (inventory)',
  bank: 'the items in the player\'s bank',
  gear: 'the items the player has equipped',
  spells: 'the player\'s spellbook (spells and abilities)',
  bars: 'what is on the player\'s action bars',
  talents: 'the player\'s talent tree and points',
  quests: 'the player\'s quest log (quests and their objectives)',
  reputation: 'the player\'s reputation with factions',
  macros: 'the player\'s macros',
};

function analyzeRequest(text, opts = {}) {
  const questions = {};
  if (opts.route) {
    const criteria = { agent: AGENT_CRITERIA };
    for (const [id, q] of Object.entries(QUICK)) criteria[id] = q.criteria;
    questions.intent = { type: 'choice', instructions: INTENT_INSTRUCTIONS, criteria };
  }
  if (opts.tier) questions.difficulty = { type: 'score', instructions: DIFFICULTY_INSTRUCTIONS, criteria: DIFFICULTY.slice() };
  if (opts.needs) {
    for (const [kind, what] of Object.entries(NEEDS)) {
      questions[`need_${kind}`] = {
        type: 'noul',
        instructions: `Does a good answer to \`message\` need to look at ${what}?`,
        criteria: { true: `The answer depends on ${what}.`, false: `The answer does not depend on ${what}.` },
      };
    }
  }
  return { model: MODEL, state: { message: String(text).slice(0, 1500) }, questions };
}

// The one answer we asked for, when it is a well-formed choice among `allowed`.
function readChoice(response, question, allowed) {
  const a = answerOf(response, question);
  if (!a || a.type !== 'choice' || typeof a.choice !== 'string' || !allowed.includes(a.choice)) return null;
  return { choice: a.choice, confidence: unit(a.confidence), model: String(response.model || '') };
}

function readScore(response, question, levels) {
  const a = answerOf(response, question);
  const s = a && a.type === 'score' ? Number(a.score) : NaN;
  if (!Number.isFinite(s) || s < 0 || s > levels - 1) return null;
  return { score: s, confidence: unit(a.confidence) };
}

function readNoul(response, question) {
  const a = answerOf(response, question);
  const v = a && a.type === 'noul' && typeof a.noul === 'number' ? a.noul : NaN;
  return Number.isFinite(v) && v >= 0 && v <= 1 ? v : null;
}

function answerOf(response, question) {
  return response && typeof response === 'object' && response.answers && typeof response.answers === 'object'
    ? response.answers[question] : null;
}

function unit(x) { const c = Number(x); return Number.isFinite(c) && c >= 0 && c <= 1 ? c : 0; }

// A message worth routing as a quick order: short, typed by the player (not the
// addon's own "[game data]" / "[actions]" sends), one line or two.
function routable(text) {
  const t = String(text || '').trim();
  if (!t || t.length > 160) return false;
  if (/^\[(game data|actions)\]/i.test(t)) return false;
  if (/\n.*\n/.test(t)) return false;
  return true;
}

// What the player asked, without the addon's add-ons: the "[actions] ..." report
// in front and a "[game data]" block behind (both can ride along).
function playerRequest(text) {
  let t = String(text || '');
  t = t.replace(/^\[actions\][^\n]*\n*/i, '');
  const data = t.search(/\n*\[game data\]/i);
  if (data >= 0) t = t.slice(0, data);
  return t.trim().slice(0, 800);
}

// ---------------------------------------------------------------------------
// I/O
// ---------------------------------------------------------------------------

// OPENROUTER_API_KEY from the environment, else the first KEY=value (or a bare
// token) in the key file. The file is read as data, never run.
function apiKey(cfg) {
  const env = process.env.OPENROUTER_API_KEY;
  if (env && !/\s/.test(env)) return env;
  const file = (cfg && cfg.keyFile) ? String(cfg.keyFile).replace(/^~(?=$|\/)/, os.homedir()) : DEFAULT_KEY_FILE;
  let raw;
  try {
    const st = fs.lstatSync(file);
    if (!st.isFile() || st.size > 8192) return '';
    raw = fs.readFileSync(file, 'utf8');
  } catch { return ''; }
  for (const line of raw.split(/\r?\n/)) {
    const l = line.trim();
    if (!l || l.startsWith('#')) continue;
    const m = /^([A-Z_]+)\s*=\s*(.*)$/.exec(l);
    if (m) {
      if (m[1] !== 'OPENROUTER_API_KEY') continue;
      const v = m[2].trim().replace(/^(["'])(.*)\1$/, '$2');
      return /\s/.test(v) ? '' : v;
    }
    return /\s/.test(l) ? '' : l;
  }
  return '';
}

async function decide(cfg, body, timeoutMs) {
  const key = apiKey(cfg);
  if (!key) return { error: 'no OpenRouter key' };
  const started = Date.now();
  try {
    const res = await fetch(cfg.url || DECISIONS_URL, {
      method: 'POST',
      headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
      redirect: 'error',
      signal: AbortSignal.timeout(timeoutMs),
    });
    const text = await res.text();
    if (!res.ok) return { error: `HTTP ${res.status}`, ms: Date.now() - started };
    let json;
    try { json = JSON.parse(text.slice(0, 1 << 20)); } catch { return { error: 'unreadable answer', ms: Date.now() - started }; }
    return { json, ms: Date.now() - started };
  } catch (e) {
    return { error: e && e.name === 'TimeoutError' ? `no answer in ${timeoutMs} ms` : 'network error', ms: Date.now() - started };
  }
}

const DEFAULT_TIERS = { fast: 'gpt-6-luna--fast', balanced: 'gpt-6-sol', strong: 'anthropic/claude-opus-5-5' };

// Everything JEV can tell about one message, from one request:
//   { quick?: { intent, confidence, es, actions?, cmds? },
//     tier?: { tier, score, model, note? }, needs: [kinds], ms, note? }
// opts.route / opts.tier / opts.needs say which questions to ask.
async function analyze(cfg, text, opts = {}) {
  const out = { needs: [] };
  if (!cfg || cfg.enabled === false) return { ...out, note: 'off' };
  const route = !!opts.route && cfg.router !== false && routable(text);
  const tier = !!opts.tier;
  const needs = !!opts.needs && cfg.prefetch !== false && !/^\[(game data|actions)\]/i.test(String(text).trim());
  if (!route && !tier && !needs) return { ...out, note: 'nothing to ask' };
  const models = { ...DEFAULT_TIERS, ...(cfg.tiers || {}) };
  const fallbackTier = cfg.fallbackTier || 'balanced';
  const r = await decide(cfg, analyzeRequest(text, { route, tier, needs }), cfg.timeoutMs || cfg.routerTimeoutMs || 2500);
  out.ms = r.ms;
  if (tier) out.tier = { tier: fallbackTier, model: models[fallbackTier] || '' };
  if (r.error) { out.note = r.error; if (tier) out.tier.note = r.error; return out; }
  if (route) {
    const c = readChoice(r.json, 'intent', ['agent', ...Object.keys(QUICK)]);
    if (!c) out.note = 'unexpected intent answer';
    else if (c.choice !== 'agent' && c.confidence >= (cfg.minConfidence || 0.85)) {
      const q = QUICK[c.choice];
      out.quick = { intent: c.choice, confidence: c.confidence, es: q.es, actions: q.actions, cmds: q.cmds };
    } else out.intent = `${c.choice} ${c.confidence.toFixed(2)}`;
  }
  if (tier) {
    const s = readScore(r.json, 'difficulty', DIFFICULTY.length);
    if (s) {
      // Round to the nearest level; a spread-out answer leans to the middle one.
      const level = s.confidence < (cfg.minTierConfidence || 0.3) ? 1 : Math.min(2, Math.max(0, Math.round(s.score)));
      const name = TIER_NAMES[level];
      out.tier = { tier: name, score: s.score, confidence: s.confidence, model: models[name] || models[fallbackTier] || '' };
    } else out.tier.note = 'unexpected difficulty answer';
  }
  if (needs) {
    const min = cfg.needThreshold || 0.8;
    const scored = [];
    for (const kind of Object.keys(NEEDS)) {
      const v = readNoul(r.json, `need_${kind}`);
      if (v !== null && v >= min) scored.push([v, kind]);
    }
    // The most certain first, at most three (one strip message holds ~2.9 KB of data).
    out.needs = scored.sort((a, b) => b[0] - a[0]).slice(0, cfg.maxNeeds || 3).map(([, k]) => k);
    out.needScores = Object.fromEntries(scored.map(([v, k]) => [k, v]));
  }
  return out;
}

// ---------------------------------------------------------------------------
// Reviewing proposed actions
// ---------------------------------------------------------------------------

// The action in words for the review question. Ids mean nothing to JEV, so
// they're counted, not listed; the addon shows the real names to the player.
function describeAction(a) {
  const n = (list) => (Array.isArray(list) ? list.length : 0);
  switch (a && a.op) {
    case 'sort_bags': return 'Sort the bags.';
    case 'sort_bank': return 'Sort the bank.';
    case 'deposit_reagents': return 'Deposit the reagents in the bank.';
    case 'deposit': return `Move ${n(a.items)} kind(s) of item from the bags to the bank.`;
    case 'withdraw': return `Take ${n(a.items)} kind(s) of item out of the bank.`;
    case 'sell_junk': return 'Sell the junk (gray items) to the vendor.';
    case 'sell_items': return `Sell ${n(a.items)} kind(s) of item to the vendor.`;
    case 'equip': return `Equip ${n(a.items)} item(s).`;
    case 'abandon_quests': return `Abandon ${n(a.ids)} quest(s).`;
    case 'track_quests': return 'Change which quests are tracked on screen.';
    case 'place_action': return 'Put spells, items or macros on the action bars.';
    case 'clear_actions': return 'Remove things from the action bars.';
    case 'create_macro': return `Create a macro named "${String(a.name || '').slice(0, 16)}".`;
    case 'learn_talents': return 'Spend talent points.';
    case 'train_all': return 'Learn everything the trainer offers.';
    case 'arrange_bags': return `Rearrange the bags, putting ${n(a.order)} kind(s) of item first.`;
    case 'move_items': return `Move ${n(a.moves)} item(s) to other bag slots.`;
    default: return `Do "${String(a && a.op)}".`;
  }
}

const REVIEW_INSTRUCTIONS =
  'The player of World of Warcraft sent `request` to their AI assistant, which now proposes `action`. ' +
  'Did the player ask for this action, or is it plainly part of doing what they asked?';
const REVIEW_CRITERIA = {
  true: 'The request asks for this action, or doing the request clearly includes it.',
  false: 'The player did not ask for anything like this action.',
};

function reviewRequest(request, action) {
  return {
    model: MODEL,
    state: { request: String(request).slice(0, 800), action: describeAction(action) },
    questions: { asked: { type: 'noul', instructions: REVIEW_INSTRUCTIONS, criteria: { ...REVIEW_CRITERIA } } },
  };
}

// One noul per action, in parallel (each action is its own state). Returns the
// scores in order (null where JEV gave nothing), and the slowest time.
async function review(cfg, request, actions) {
  if (!cfg || cfg.enabled === false || cfg.review === false || !request || !actions || !actions.length) return { scores: [], note: 'off' };
  const list = actions.slice(0, 20);
  const results = await Promise.all(list.map(a => decide(cfg, reviewRequest(request, a), cfg.timeoutMs || cfg.routerTimeoutMs || 2500)));
  const scores = results.map(r => (r.error ? null : readNoul(r.json, 'asked')));
  const errors = results.filter(r => r.error).map(r => r.error);
  return { scores, ms: Math.max(0, ...results.map(r => r.ms || 0)), note: errors.length ? errors[0] : '' };
}

// How much an action can cost the player if it wasn't wanted: "high" ones (gold
// spent, items sold, quests lost) need a surer answer before they run without
// Apply than "low" ones (anything the player can put back by hand).
const RISK = { sell_junk: 'high', sell_items: 'high', abandon_quests: 'high', learn_talents: 'high', train_all: 'high' };
function risk(op) { return RISK[op] || 'low'; }

// Run without the Apply click? Only when every action has an answer at or above
// the threshold for its risk (scores[i] from review(), or the quick order's
// confidence for all of them).
function autoApply(cfg, actions, scores) {
  if (!cfg || cfg.enabled === false || cfg.autoApply === false || !actions || !actions.length) return false;
  const low = cfg.autoApplyLow ?? 0.85, high = cfg.autoApplyHigh ?? 0.95;
  return actions.every((a, i) => {
    const v = Array.isArray(scores) ? scores[i] : scores;
    return typeof v === 'number' && v >= (risk(a.op) === 'high' ? high : low);
  });
}

module.exports = {
  RISK, risk, autoApply,
  DECISIONS_URL, MODEL, QUICK, NEEDS, DIFFICULTY, TIER_NAMES, DEFAULT_TIERS, DEFAULT_KEY_FILE,
  analyzeRequest, reviewRequest, describeAction, readChoice, readScore, readNoul, routable, playerRequest,
  apiKey, decide, analyze, review,
};
