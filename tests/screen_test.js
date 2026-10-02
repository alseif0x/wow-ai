'use strict';
// Screenshots for the agent: flags, the words that point at the screen, JEV's
// question, the newest saved picture, and the image paths each agent gets.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const P = require('../bridge/protocol');
const S = require('../bridge/screen');
const J = require('../bridge/jev');
const { AGENTS } = require('../bridge/agents');

test('screenshot flags', () => {
  for (const f of ['s', 'sk', 'sf', 'sn']) assert.equal(P.parseFlags(`n;${f}`).shot, f);
  assert.equal(P.parseFlags('n;v').shot, '');
});

test('words that point at the screen, or at a saved screenshot', () => {
  for (const t of ['¿qué es esto?', 'mira esta ventana', 'what is this', 'look at the map here']) assert.ok(S.refersToScreen(t), t);
  for (const t of ['ordena las bolsas', 'sort my bags', 'cuánto oro tengo']) assert.ok(!S.refersToScreen(t), t);
  for (const t of ['mira mi última captura', 'qué sale en la captura de pantalla', 'check my last screenshot']) assert.ok(S.refersToSaved(t), t);
  assert.ok(!S.refersToSaved('captura ese bicho'));
});

test('JEV is asked about the screen only when wanted', () => {
  assert.ok(J.analyzeRequest('qué es esto', { screen: true }).questions.screen);
  assert.equal(J.analyzeRequest('qué es esto', {}).questions.screen, undefined);
});

test('the newest saved picture wins, other files are ignored', () => {
  const a = fs.mkdtempSync(path.join(os.tmpdir(), 'shots-a-'));
  const b = fs.mkdtempSync(path.join(os.tmpdir(), 'shots-b-'));
  const old = path.join(a, 'WoWScrnShot_old.jpg'), nu = path.join(b, 'Captura nueva.png'), txt = path.join(b, 'notes.txt');
  for (const f of [old, nu, txt]) fs.writeFileSync(f, 'x');
  fs.utimesSync(old, new Date(2020, 1, 1), new Date(2020, 1, 1));
  fs.utimesSync(txt, new Date(2030, 1, 1), new Date(2030, 1, 1));
  assert.equal(S.latestSaved([a, b, path.join(a, 'missing')]), nu);
  assert.equal(S.latestSaved([path.join(a, 'missing')]), null);
  assert.ok(S.savedFolders('/g/_classic_beta_/Interface/AddOns').includes(path.resolve('/g/_classic_beta_/Screenshots')));
});

test('prune keeps the newest live shots', () => {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), 'shots-'));
  for (let i = 0; i < 5; i++) { const f = path.join(d, `shot-${i}-x.png`); fs.writeFileSync(f, 'x'); fs.utimesSync(f, new Date(2026, 0, i + 1), new Date(2026, 0, i + 1)); }
  S.prune(d, 2);
  assert.deepEqual(fs.readdirSync(d).sort(), ['shot-3-x.png', 'shot-4-x.png']);
});

test('the shot command is the strip capture script with --shot', () => {
  const [, args] = S.shotCommand({ cellPx: 4, cellsPerRow: 200, maxRows: 48, processName: 'WowB' }, '/b', '/tmp/s.png', 1920);
  if (process.platform !== 'win32') {
    assert.ok(args.includes('--shot') && args.includes('/tmp/s.png'));
    assert.equal(args[args.indexOf('--shot-max-width') + 1], '1920');
  }
});

test('Claude may read the screenshot folder; Codex gets -i; Hermes --image', () => {
  const img = '/home/x/wow-ai/bridge/tmp/shots/shot-1.png';
  const c = AGENTS.claude.args({ cfg: {}, images: [img] });
  assert.equal(c[c.indexOf('--add-dir') + 1], path.dirname(img));
  assert.match(AGENTS.claude.input({ prompt: 'q', images: [img] }).stdin, /shot-1\.png/);
  assert.ok(AGENTS.codex.args({ cfg: {}, cwd: '/w', images: [img] }).includes('-i'));
  assert.ok(!AGENTS.claude.args({ cfg: {} }).includes('--add-dir'));
});

test('the reply record says the agent saw a screenshot', () => {
  const lua = P.luaTable('WoWAI_Inbox', [{ chat: 'c', id: 1, status: 'done', text: 'ok', shot: 'live' }]);
  assert.match(lua, /shot = "live"/);
});
