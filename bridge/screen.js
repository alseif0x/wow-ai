'use strict';
// Screenshots for the agent (docs/SCREEN.md).
//
// Live: the game window when the message came in, taken by the same script that
// reads the strip (--shot / -Shot), with the strip blanked out. Saved: the newest
// picture in the game's Screenshots folder or the desktop's screenshot folder, when
// the player asks about "mi última captura" / "my last screenshot".
//
// Which messages get one is decided by the addon's flag (see protocol.parseFlags:
// s = attach one, sk = the text talks about the screen, sf = the newest saved one,
// sn = never, none = auto) and, for sk and auto, by JEV (jev.js, the "screen" question).

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFile, execFileSync } = require('child_process');

const IMAGE = /\.(png|jpe?g|webp)$/i;

// Words that point at something on screen. Only a hint: JEV has the last word.
// Whole words, accents included (\b in JavaScript only knows a-z, so "última" would never match).
const word = (alts) => new RegExp(`(?<![\\p{L}\\p{N}])(?:${alts})(?![\\p{L}\\p{N}])`, 'iu');
const SCREEN_WORDS = word('pantalla|veo|ves|esto|esta|este|eso|esa|ese|aquí|aqui|ahí|ahi|ventana|tooltip|mira|screen|this|that|see|look|here|window');
const SAVED_WORDS = word('(?:mi|la|una|última|ultima)\\s+(?:captura|foto|screenshot)|capturas?\\s+de\\s+pantalla|(?:my|the|last|latest)\\s+(?:screenshot|screen\\s*shot|capture)');

function refersToScreen(text) { return SCREEN_WORDS.test(String(text || '')); }
function refersToSaved(text) { return SAVED_WORDS.test(String(text || '')); }

// The command that saves the game window to `file` (same scripts as the strip capture).
function shotCommand(cap, here, file, maxWidth) {
  if (process.platform === 'win32') {
    return ['powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(here, 'capture.ps1'),
      '-Cell', String(cap.cellPx), '-Cells', String(cap.cellsPerRow), '-MaxRows', String(cap.maxRows),
      '-ProcessName', cap.processName, '-Shot', file, '-ShotMaxWidth', String(maxWidth)]];
  }
  const script = process.platform === 'darwin' ? 'capture_mac.py' : 'capture_x11.py';
  const args = [path.join(here, script), '--cell', String(cap.cellPx), '--cells', String(cap.cellsPerRow),
    '--max-rows', String(cap.maxRows), '--process-name', cap.processName, '--shot', file, '--shot-max-width', String(maxWidth)];
  if (cap.windowName) args.push('--window-name', cap.windowName);
  if (process.platform !== 'darwin' && cap.source) args.push('--source', cap.source);
  return [cap.python || 'python3', args];
}

// Take one: resolves { path, info } or { error } (never rejects).
function takeShot(opts) {
  const { cap, here, dir, id, maxWidth = 1920, timeoutMs = 6000 } = opts;
  return new Promise((resolve) => {
    try { fs.mkdirSync(dir, { recursive: true }); } catch (e) { resolve({ error: e.message }); return; }
    const file = path.join(dir, `shot-${id}-${Date.now().toString(36)}.png`);
    const [cmd, args] = shotCommand(cap, here, file, maxWidth);
    const t0 = Date.now();
    execFile(cmd, args, { timeout: timeoutMs, windowsHide: true }, (err, stdout) => {
      let ev = {};
      for (const line of String(stdout || '').trim().split('\n').reverse()) {
        try { ev = JSON.parse(line); break; } catch {}
      }
      if (ev.path && fs.existsSync(ev.path)) resolve({ path: ev.path, info: `${ev.info || 'shot'}${ev.masked ? ', strip blanked' : ''}, ${Date.now() - t0} ms` });
      else resolve({ error: ev.error || (err && err.message) || 'no picture' });
    });
  });
}

// Folders the player's own screenshots land in, most specific first.
function savedFolders(addonDir, extra = []) {
  const home = os.homedir();
  const out = [...extra];
  if (addonDir) out.push(path.resolve(addonDir, '..', '..', 'Screenshots')); // <flavor>/Interface/AddOns -> <flavor>/Screenshots
  if (process.platform === 'win32') {
    out.push(path.join(home, 'Pictures', 'Screenshots'), path.join(home, 'OneDrive', 'Pictures', 'Screenshots'));
  } else if (process.platform === 'darwin') {
    out.push(path.join(home, 'Desktop'), path.join(home, 'Pictures', 'Screenshots'));
  } else {
    let pics = path.join(home, 'Pictures');
    try { pics = execFileSync('xdg-user-dir', ['PICTURES'], { encoding: 'utf8', timeout: 2000 }).trim() || pics; } catch {}
    out.push(path.join(pics, 'Capturas de pantalla'), path.join(pics, 'Screenshots'), pics);
  }
  return [...new Set(out.map((p) => String(p).replace(/^~(?=$|[\\/])/, home)))];
}

// The newest picture in those folders (not looking into subfolders), or null.
function latestSaved(folders) {
  let best = null;
  for (const dir of folders) {
    let names;
    try { names = fs.readdirSync(dir); } catch { continue; }
    for (const n of names) {
      if (!IMAGE.test(n)) continue;
      const p = path.join(dir, n);
      try {
        const st = fs.statSync(p);
        if (st.isFile() && (!best || st.mtimeMs > best.mtime)) best = { path: p, mtime: st.mtimeMs };
      } catch {}
    }
  }
  return best && best.path;
}

// Keep the newest `keep` live shots.
function prune(dir, keep = 30) {
  let files;
  try { files = fs.readdirSync(dir).filter((n) => /^shot-.*\.png$/.test(n)); } catch { return; }
  const dated = files.map((n) => { const p = path.join(dir, n); try { return [fs.statSync(p).mtimeMs, p]; } catch { return [0, p]; } });
  for (const [, p] of dated.sort((a, b) => b[0] - a[0]).slice(keep)) { try { fs.rmSync(p, { force: true }); } catch {} }
}

module.exports = { refersToScreen, refersToSaved, shotCommand, takeShot, savedFolders, latestSaved, prune };
