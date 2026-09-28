'use strict';
// Voice for the WoW AI bridge: listen on the PC's microphone when the addon asks
// (a "v" record), turn the speech into text, and read replies aloud.
//
//   listen()   records 16 kHz mono PCM (arecord by default, anything that writes
//              raw s16le to stdout via voice.recordCommand), with a small energy
//              VAD: it stops after `silenceMs` of quiet once speech was heard,
//              gives up if nothing was said in `noSpeechMs`, never runs past
//              `maxMs`, and can be stopped early (the addon's "vs" record, sent
//              when the push-to-talk button is released). A beep plays when it
//              starts and when it stops, on the PC's output, which Sunshine
//              streams to Moonlight like the game's own sound.
//   transcribe() and speak() go to voice_server.py, one long-lived Python
//              process holding faster-whisper and piper (loaded on first use).
//
// The pure parts (VAD, WAV headers, text for speech) are exported for tests.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');
const readline = require('readline');

const RATE = 16000;
const DEFAULT_VENV = path.join(os.homedir(), '.local', 'share', 'wow-ai-voice');

const DEFAULTS = {
  enabled: true,
  python: path.join(DEFAULT_VENV, 'bin', 'python'),
  whisperModel: 'small',
  device: 'cpu',
  computeType: 'int8',
  beamSize: 1,
  language: 'es',
  piperVoice: path.join(DEFAULT_VENV, 'voices', 'es_ES-davefx-medium.onnx'),
  recordCommand: ['arecord', '-q', '-f', 'S16_LE', '-r', String(RATE), '-c', '1', '-t', 'raw'],
  playCommand: ['pw-play'],
  maxMs: 20000,
  noSpeechMs: 6000,
  silenceMs: 1100,
  threshold: 700,    // RMS of a 30 ms frame that counts as speech (s16 scale)
  speak: 'voice',    // read replies aloud: "voice" (replies to voice messages), "always", "off"
  speakMaxChars: 400,
  beeps: true,
  prompt: 'World of Warcraft. Bolsas, banco, chatarra, misión, misiones, Ventormenta, Forjaz, Orgrimmar, ' +
    'instructor, talentos, hechizos, macro, mazmorra, banda, oro, plata, cobre.',
};

const home = (p) => (typeof p === 'string' ? p.replace(/^~(?=$|[\\/])/, os.homedir()) : p);

function settings(cfg) {
  const o = { ...DEFAULTS, ...((cfg && cfg.voice) || {}) };
  o.python = home(o.python);
  o.piperVoice = home(o.piperVoice);
  return o;
}

// ---------------------------------------------------------------------------
// Pure helpers
// ---------------------------------------------------------------------------

function wavHeader(dataBytes, rate = RATE, channels = 1, bits = 16) {
  const h = Buffer.alloc(44);
  h.write('RIFF', 0); h.writeUInt32LE(36 + dataBytes, 4); h.write('WAVE', 8);
  h.write('fmt ', 12); h.writeUInt32LE(16, 16); h.writeUInt16LE(1, 20); h.writeUInt16LE(channels, 22);
  h.writeUInt32LE(rate, 24); h.writeUInt32LE(rate * channels * bits / 8, 28);
  h.writeUInt16LE(channels * bits / 8, 32); h.writeUInt16LE(bits, 34);
  h.write('data', 36); h.writeUInt32LE(dataBytes, 40);
  return h;
}

// A short sine blip as a complete WAV: the "I'm listening" / "done" cue.
function beepWav(freq, ms, rate = RATE) {
  const n = Math.floor(rate * ms / 1000);
  const pcm = Buffer.alloc(n * 2);
  for (let i = 0; i < n; i++) {
    const env = Math.min(1, i / (rate * 0.01), (n - i) / (rate * 0.01)); // 10 ms fade in/out
    pcm.writeInt16LE(Math.round(Math.sin(2 * Math.PI * freq * i / rate) * 9000 * env), i * 2);
  }
  return Buffer.concat([wavHeader(pcm.length, rate), pcm]);
}

function rms(buf, start, end) {
  let sum = 0, n = 0;
  for (let i = start; i + 1 < end; i += 2) { const s = buf.readInt16LE(i); sum += s * s; n++; }
  return n ? Math.sqrt(sum / n) : 0;
}

// Feed PCM as it arrives; returns what to do. Frames of 30 ms.
function makeVad(o) {
  const frameBytes = Math.floor(RATE * 0.03) * 2;
  let pending = Buffer.alloc(0), elapsed = 0, speech = 0, quiet = 0, heard = false, peak = 0;
  return {
    feed(chunk) {
      pending = Buffer.concat([pending, chunk]);
      while (pending.length >= frameBytes) {
        const level = rms(pending, 0, frameBytes);
        for (let i = 0; i + 1 < frameBytes; i += 2) peak = Math.max(peak, Math.abs(pending.readInt16LE(i)));
        pending = pending.subarray(frameBytes);
        elapsed += 30;
        if (level >= o.threshold) { speech += 30; quiet = 0; if (speech >= 150) heard = true; }
        else { quiet += 30; if (!heard) speech = Math.max(0, speech - 30); }
        if (heard && quiet >= o.silenceMs) return 'done';
        if (!heard && elapsed >= o.noSpeechMs) return 'nothing';
        if (elapsed >= o.maxMs) return 'max';
      }
      return '';
    },
    get heard() { return heard; },
    get peak() { return peak; },
    get elapsed() { return elapsed; },
  };
}

// Reply text as something worth hearing: no code blocks, links or markdown marks.
function speakable(text, max = 400) {
  let t = String(text || '')
    .replace(/```[\s\S]*?```/g, ' ')
    .replace(/`([^`]*)`/g, '$1')
    .replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')
    .replace(/https?:\/\/\S+/g, '')
    .replace(/\bTL;DR:\s*/gi, '')
    .replace(/[*_#>|]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  if (t.length > max) {
    const cut = t.slice(0, max);
    const end = Math.max(cut.lastIndexOf('. '), cut.lastIndexOf('? '), cut.lastIndexOf('! '));
    t = end >= max * 0.5 ? cut.slice(0, end + 1) : cut.replace(/\s+\S*$/, '') + '…';
  }
  return t;
}

// ---------------------------------------------------------------------------
// The speech server
// ---------------------------------------------------------------------------

class VoiceServer {
  constructor(o, log) {
    this.o = o; this.log = log || (() => {});
    this.proc = null; this.next = 1; this.waiting = new Map();
  }

  available() {
    try { return fs.statSync(this.o.python).isFile(); } catch { return false; }
  }

  start() {
    if (this.proc) return;
    const script = path.join(__dirname, 'voice_server.py');
    const args = [script, '--whisper-model', this.o.whisperModel, '--device', this.o.device,
      '--compute-type', this.o.computeType, '--beam-size', String(this.o.beamSize)];
    if (this.o.piperVoice) args.push('--piper-voice', this.o.piperVoice);
    const p = spawn(this.o.python, args, { stdio: ['pipe', 'pipe', 'pipe'] });
    this.proc = p;
    readline.createInterface({ input: p.stdout }).on('line', (line) => {
      let m; try { m = JSON.parse(line); } catch { return; }
      const w = this.waiting.get(m.id);
      if (!w) return;
      this.waiting.delete(m.id); clearTimeout(w.timer);
      if (m.error) w.reject(new Error(m.error)); else w.resolve(m);
    });
    let err = '';
    p.stderr.on('data', (d) => { err = (err + d).slice(-2000); });
    p.on('error', (e) => this.log(`voice server could not start (${this.o.python}): ${e.message}`));
    p.on('close', (code) => {
      this.proc = null;
      for (const w of this.waiting.values()) { clearTimeout(w.timer); w.reject(new Error(`voice server exited (${code}) ${err.trim().split('\n').pop() || ''}`)); }
      this.waiting.clear();
      if (code) this.log(`voice server exited (${code}): ${err.trim().split('\n').slice(-3).join(' | ')}`);
    });
    p.stdin.on('error', () => {});
  }

  call(req, timeoutMs) {
    this.start();
    const id = this.next++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.waiting.delete(id); reject(new Error(`voice server: no answer in ${timeoutMs / 1000} s`)); }, timeoutMs);
      this.waiting.set(id, { resolve, reject, timer });
      try { this.proc.stdin.write(JSON.stringify({ id, ...req }) + '\n'); }
      catch (e) { clearTimeout(timer); this.waiting.delete(id); reject(e); }
    });
  }

  stop() { if (this.proc) { try { this.proc.kill(); } catch {} } }
}

// ---------------------------------------------------------------------------
// Recording and playback
// ---------------------------------------------------------------------------

function play(o, file) {
  if (!o.playCommand || !o.playCommand.length) return Promise.resolve();
  return new Promise((resolve) => {
    let p;
    try { p = spawn(o.playCommand[0], [...o.playCommand.slice(1), file], { stdio: 'ignore' }); }
    catch { resolve(); return; }
    p.on('error', () => resolve());
    p.on('close', () => resolve());
  });
}

class Voice {
  constructor(cfg, tmpDir, log) {
    this.o = settings(cfg);
    this.tmp = tmpDir;
    this.log = log || (() => {});
    this.server = new VoiceServer(this.o, this.log);
    this.recording = null; // { child, stop() }
    try { fs.mkdirSync(tmpDir, { recursive: true }); } catch {}
    this.beeps = {};
    if (this.o.beeps) {
      for (const [k, f, ms] of [['start', 880, 120], ['stop', 520, 120]]) {
        const file = path.join(tmpDir, `beep-${k}.wav`);
        try { fs.writeFileSync(file, beepWav(f, ms)); this.beeps[k] = file; } catch {}
      }
    }
  }

  get enabled() { return this.o.enabled !== false && this.server.available(); }

  status() {
    if (this.o.enabled === false) return 'off (voice.enabled in config.json)';
    if (!this.server.available()) return `NOT INSTALLED: ${this.o.python} (see docs/VOICE.md)`;
    return `on (whisper ${this.o.whisperModel} on ${this.o.device}, ${this.o.language}; replies read aloud: ${this.o.speak})`;
  }

  // Load the models in the background so the first message doesn't wait for them.
  warm() {
    if (!this.enabled) return;
    this.server.call({ op: 'warm' }, 180000)
      .then((r) => this.log(`voice: ready (${(r.loaded || []).join(', ')}, ${r.ms} ms)`))
      .catch((e) => this.log(`voice: warm-up failed: ${e.message}`));
  }

  get busy() { return !!this.recording; }

  // Stop the current recording early (push-to-talk released).
  stopListening() { if (this.recording) this.recording.stop('stopped'); }

  // Record until the VAD (or stopListening) ends it. Resolves { pcm, reason, heard, peak, ms }.
  listen() {
    if (this.recording) return Promise.reject(new Error('already listening'));
    const o = this.o;
    return new Promise((resolve, reject) => {
      if (this.beeps.start) play(o, this.beeps.start);
      let child;
      try { child = spawn(o.recordCommand[0], o.recordCommand.slice(1), { stdio: ['ignore', 'pipe', 'pipe'] }); }
      catch (e) { reject(e); return; }
      const chunks = [];
      const vad = makeVad(o);
      let finished = false, stderr = '';
      const end = (reason) => {
        if (finished) return;
        finished = true;
        this.recording = null;
        try { child.kill(); } catch {}
        if (this.beeps.stop) play(o, this.beeps.stop);
        resolve({ pcm: Buffer.concat(chunks), reason, heard: vad.heard, peak: vad.peak, ms: vad.elapsed });
      };
      this.recording = { child, stop: end };
      child.stdout.on('data', (d) => {
        chunks.push(d);
        const r = vad.feed(d);
        if (r) end(r);
      });
      child.stderr.on('data', (d) => { stderr = (stderr + d).slice(-500); });
      child.on('error', (e) => {
        if (finished) return;
        finished = true; this.recording = null;
        reject(new Error(`cannot record with ${o.recordCommand[0]}: ${e.message}`));
      });
      child.on('close', (code) => {
        if (!finished && code) { finished = true; this.recording = null; reject(new Error(`${o.recordCommand[0]} exited (${code}) ${stderr.trim()}`)); }
        else end('ended');
      });
    });
  }

  async transcribe(pcm) {
    const file = path.join(this.tmp, `voice-${Date.now().toString(36)}.wav`);
    fs.writeFileSync(file, Buffer.concat([wavHeader(pcm.length), pcm]));
    try {
      const r = await this.server.call({ op: 'stt', wav: file, lang: this.o.language, prompt: this.o.prompt }, 120000);
      return { text: String(r.text || '').trim(), ms: r.ms };
    } finally { try { fs.unlinkSync(file); } catch {} }
  }

  // Read a reply aloud (queued: one at a time).
  speak(text) {
    const t = speakable(text, this.o.speakMaxChars);
    if (!t || !this.enabled) return Promise.resolve();
    this.queue = (this.queue || Promise.resolve()).then(async () => {
      const file = path.join(this.tmp, `speak-${Date.now().toString(36)}.wav`);
      try {
        await this.server.call({ op: 'tts', text: t, out: file }, 60000);
        await play(this.o, file);
      } catch (e) { this.log(`speak: ${e.message}`); }
      finally { try { fs.unlinkSync(file); } catch {} }
    });
    return this.queue;
  }

  shouldSpeak(job) {
    return this.o.speak === 'always' || (this.o.speak === 'voice' && job.voice);
  }
}

module.exports = { Voice, VoiceServer, DEFAULTS, settings, wavHeader, beepWav, rms, makeVad, speakable, RATE };
