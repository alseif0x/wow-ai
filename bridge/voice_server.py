#!/usr/bin/env python3
"""Speech for the WoW AI bridge: one long-lived process, so the models load once.

JSON lines on stdin, one JSON line per request on stdout:

  {"id": 1, "op": "stt", "wav": "/tmp/x.wav", "lang": "es"}  -> {"id": 1, "text": "...", "ms": 812}
  {"id": 2, "op": "tts", "text": "Hola", "out": "/tmp/y.wav"} -> {"id": 2, "out": "/tmp/y.wav", "ms": 240}
  {"id": 3, "op": "warm"}                                     -> {"id": 3, "loaded": ["whisper", "piper"]}
  {"id": 4, "op": "ping"}                                     -> {"id": 4, "ok": true}

Errors come back as {"id": n, "error": "..."}. Speech-to-text is faster-whisper
(CTranslate2, int8 on the CPU by default); text-to-speech is piper with an onnx
voice. Both are imported and loaded on first use, so a bridge with voice off, or
a machine missing one of them, still gets the other. Settings come from argv:

  --whisper-model small --device cpu --compute-type int8 --piper-voice <file.onnx>
"""

import argparse
import json
import sys
import time
import wave

args = argparse.ArgumentParser()
args.add_argument("--whisper-model", default="small")
args.add_argument("--device", default="cpu")
args.add_argument("--compute-type", default="int8")
args.add_argument("--piper-voice", default="")
args.add_argument("--beam-size", type=int, default=1)
opts = args.parse_args()

_whisper = None
_piper = None


def whisper():
    global _whisper
    if _whisper is None:
        from faster_whisper import WhisperModel
        _whisper = WhisperModel(opts.whisper_model, device=opts.device, compute_type=opts.compute_type)
    return _whisper


def piper():
    global _piper
    if _piper is None:
        if not opts.piper_voice:
            raise RuntimeError("no piper voice configured (voice.piperVoice in config.json)")
        from piper import PiperVoice
        _piper = PiperVoice.load(opts.piper_voice)
    return _piper


def stt(req):
    lang = req.get("lang") or None
    # Game words the player is likely to say, so "Ventormenta" isn't heard as two words.
    prompt = req.get("prompt") or None
    segments, _info = whisper().transcribe(
        req["wav"], language=lang, beam_size=opts.beam_size, vad_filter=True,
        initial_prompt=prompt, condition_on_previous_text=False)
    return {"text": " ".join(s.text.strip() for s in segments).strip()}


def tts(req):
    voice = piper()
    with wave.open(req["out"], "wb") as w:
        voice.synthesize_wav(req["text"], w)
    return {"out": req["out"]}


def warm(req):
    """Load the models now, so the first message doesn't wait for them."""
    loaded = []
    for name, load in (("whisper", whisper), ("piper", piper)):
        try:
            load()
            loaded.append(name)
        except Exception as e:  # a missing voice file only costs read-aloud
            loaded.append(f"{name} unavailable ({e})")
    return {"loaded": loaded}


OPS = {"stt": stt, "tts": tts, "warm": warm, "ping": lambda req: {"ok": True}}


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        rid = None
        try:
            req = json.loads(line)
            rid = req.get("id")
            op = OPS.get(req.get("op"))
            if op is None:
                raise ValueError("unknown op")
            started = time.monotonic()
            out = op(req)
            out["ms"] = int((time.monotonic() - started) * 1000)
        except Exception as e:  # report it and keep serving
            out = {"error": f"{type(e).__name__}: {e}"}
        out["id"] = rid
        sys.stdout.write(json.dumps(out, ensure_ascii=False) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
