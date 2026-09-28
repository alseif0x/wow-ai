# Voice, gamepad, model picker and JEV

Four ways to use WoW AI without a keyboard or with a different model per chat. They all work through the same pixel strip and slot files as a typed message (see [ARCHITECTURE.md](ARCHITECTURE.md)).

## Model picker

Every chat can run on any model the local [opencodex](https://github.com/lidge-jun/opencodex) proxy serves. The bridge reads the catalog from `http://127.0.0.1:10100/v1/models` at start and every 10 minutes, and lists it in every slot file.

- **In game:** the **Model** button under the transcript, **Model...** in a chat's right-click menu, `/ai model <name>` (`/ai modelo`), or **Y > Model** in gamepad mode. A unique part of a name is enough: `/ai modelo opus-5-5`.
- **Choices:** *Default* (the agent's own `agents.<id>.model`, or its CLI default), *Auto* (JEV picks a tier per message, see below), or any listed model id.
- **How it runs:** the record carries a `model=<id>` flag, and the bridge passes it on:
  - **Codex** gets `-m <id>`. Codex already goes through opencodex (its config points `openai_base_url` at the proxy), so every catalog model works, Claude's included.
  - **Claude Code** on a picked model runs as `ocx claude <the usual arguments> --model <id>`. That command sets the gateway variables and runs `claude`, so GPT and DeepSeek models work there too. With no model picked, Claude runs natively as before.
  - **Grok** only knows its own models, so a picked proxy model is left out for it.
- The session carries on across a model change. The reply bubble is labelled with the model that wrote it (`Claude  gpt-6-sol`).

## Voice

Press **Talk** (or `/ai voz`, **A** in gamepad mode, or the "IA Voz" macro) and speak. The bridge listens on the **PC's microphone**, turns what you said into text, and sends it as your message. The transcript replaces the "[voz] escuchando..." placeholder. Replies to voice messages are read aloud on the PC's speakers, which Sunshine streams to Moonlight along with the game's sound.

- **When it stops listening:** after about 1.1 s of silence once you have spoken, after 6 s with no speech, after 20 s at most, or when you release a held Talk / A (push-to-talk sends a `vs` stop record). A short beep marks the start and the end.
- **Speech to text:** [faster-whisper](https://github.com/SYSTRAN/faster-whisper), model `small`, int8 on the CPU: about 1.3 s for a short phrase once loaded. A list of game words (bags, bank, Stormwind...) is passed as a hint.
- **Read aloud:** [piper](https://github.com/OHF-Voice/piper1-gpl) with the `es_ES-davefx-medium` voice. The reply's `TL;DR:` lines are spoken, without code blocks or links.
- **The process:** `bridge/voice_server.py` is one Python process that keeps both models loaded. The bridge starts it and warms it up when it starts.

**Install** (done on this PC under `~/.local/share/wow-ai-voice`):

```bash
python3 -m venv ~/.local/share/wow-ai-voice
~/.local/share/wow-ai-voice/bin/pip install faster-whisper piper-tts
mkdir -p ~/.local/share/wow-ai-voice/voices && cd ~/.local/share/wow-ai-voice/voices
B=https://huggingface.co/rhasspy/piper-voices/resolve/main/es/es_ES/davefx/medium
curl -LO $B/es_ES-davefx-medium.onnx -LO $B/es_ES-davefx-medium.onnx.json
```

The Whisper model downloads itself on first use (about 480 MB for `small`).

**Microphone:** `arecord` records from the default PipeWire source. If the reply says the microphone gave "pure silence", the source is muted (`wpctl set-mute @DEFAULT_SOURCE@ 0`), or `voice.recordCommand` should name another device (`["arecord", "-D", "pipewire", ...]`, or `["pw-record", "--rate", "16000", "--channels", "1", "--format", "s16", "-"]`). Moonlight does not send the client's microphone to the PC, so voice uses a microphone on the PC itself.

## Gamepad mode

`/ai mando` (`/ai pad`), the "IA Mando" macro, or the *Gamepad mode* key binding hands the controller to the window until you leave:

| Button | Does |
|---|---|
| **A** | Talk: tap and speak, or hold while speaking. In a list: pick |
| **B** | Close the list, or leave gamepad mode and minimize the window |
| **X** | Apply the proposed actions (when the reply has them), else check for the reply now |
| **Y** | Menu: model, agent, quick phrases, new chat, discard actions, show the last reply |
| **D-pad up / down** | Scroll the transcript, or move in a list |
| **D-pad left / right** | Previous / next chat (in a list: ±8 rows) |
| **LB / RB** | Page up / down |
| **Start** | Leave gamepad mode |

**How it works:** the Forever client turns controller buttons into binding keys (`PAD1`, `PADDUP`...), and its gamepad UI works with override bindings. Gamepad mode puts **priority override bindings** for those keys on a frame of its own, sent to the hidden `WoWAIPadButton` as `CLICK` bindings, both press and release. Leaving the mode clears them, which gives the game's gamepad bindings back.

**What it avoids:** it never calls into Blizzard's gamepad code (SmartNavigation, FrameControlsManager). In the Forever beta, an addon that touches that code taints it: Questie did, and the result was "can move but can't act". For the same reason, the new lists (model, agent, menu) are frames of the addon's own (`Picker.lua`), not Blizzard `StaticPopup`s.

**Limits:**
- Bindings can't change in combat, so the mode ends when combat starts (`PLAYER_REGEN_DISABLED`, the last moment it still can). Type `/ai mando` or press the macro again afterwards.
- To reach the mode with the controller, run `/ai macros`. It creates the account macros **IA Voz** (`/ai voz`) and **IA Mando** (`/ai mando`); drag them onto an action bar you use with the controller.

**Quick phrases:** the **Y > Quick phrases** list is `WoWAIDB.settings.phrases`, or these defaults: *¿Qué hago ahora?*, *Resume mis misiones y dime cuál me conviene*, *¿Qué pieza de equipo debería mejorar?*, *Ordena las bolsas*, *Vende la chatarra*, *Siguiente parada*.

## JEV

[JEV](https://openrouter.ai/typesafe/jev-1.13) is TypeSafe's "System One" decision model, served by OpenRouter's native decisions endpoint (`POST /api/alpha/decisions`). It is not a chat model: it doesn't write text, and you can't ask it things the way you ask an agent. It answers **closed, typed questions** about a small JSON state, and gives a probability or a confidence with every answer:

- `choice`: one option from a list.
- `score`: a position on 2-10 ordered levels.
- `noul`: yes/no as a number from 0 to 1.

In its own docs: *"a judgment a knowledgeable person makes in a second given the right context"*. It is weak at counting, numbers, dates and negations, and it reads literally. Unrelated state lowers its accuracy. So the bridge only ever asks it simple questions about **the message alone** (or one action), and treats every answer as a hint. If anything fails (no key, network, HTTP error, a malformed answer, low confidence), things go on exactly as they would without JEV.

### 1. One request per message

Every message you type or say gets **one** request, with all its questions answered in parallel. TypeSafe calls this pattern "speculative fan-out":

| Question | Type | Used for |
|---|---|---|
| `intent` | choice: `agent` or one of 10 quick orders | Only for short messages. A sure quick order (confidence ≥ 0.85) is answered by the bridge without an agent run. Game actions come back as an **Apply** proposal: sort bags, sort bank, deposit reagents, sell junk, train all. Map orders run at once from the addon's own list: next / previous stop, stop navigating, ore, herbs. Questions and orders with conditions go to the agent. |
| `difficulty` | score, 3 levels | Only for chats on **Auto**. It rounds to `fast`, `balanced` or `strong`, and the message runs on `jev.tiers.<tier>`. A spread-out answer takes `balanced`. |
| `need_<kind>` | noul, one per game-data kind (bags, bank, gear, spells, bars, talents, quests, reputation, macros) | **Game data by prefetch.** When answering needs your bags or quest log (≥ 0.8, at most 3 kinds), the bridge asks the addon for them first, and the question runs with the data attached. Without this, the agent spends a whole run just to ask for it with a `wowdata` block, and a second run to answer. |

### 2. Reviewing proposed actions

When a reply proposes game actions, each one gets a `noul`: *"Did the player ask for this action, or is it plainly part of doing what they asked?"* The state is your request and the action in words; ids are counted, not listed. Actions under 0.5 are marked **(!)** in the list above Apply. In gamepad mode, **X** needs a second press within 5 s when there are marked actions. Nothing is blocked or run by the review: you still decide.

### Measured on this PC (2026-09-28), all questions in one request

| Message | Answer | Time |
|---|---|---|
| "¿Qué objetos de mis bolsas debería vender?" | agent 0.93, needs **bags** 0.94 | 482 ms |
| "ordena las bolsas" | quick order `sort_bags` | 252 ms |
| "¿Qué misión me conviene hacer ahora?" | agent 0.93, needs **quests** 0.89 | 235 ms |
| "Refactoriza todo el módulo de mapas del addon y añade tests" | difficulty 2.0 → strong | 240 ms |
| "¿Qué hora es en Ventormenta?" | difficulty 0.13 → fast | 251 ms |
| review of "vende la chatarra" | sell junk 0.96, abandon quests **0.09**, sort bags **0.38** | 305 ms |

End-to-end prefetch through the bridge, in an isolated copy: "¿Cuál de estos objetos de mis bolsas debería vender?" → JEV: needs bags (360 ms) → the data came in → one agent run (4.4 s) → "Vende las Broken Fang y el Worn Dagger; conserva la Linen Cloth".

Earlier single requests took 6.6 s once and returned HTTP 520 once, which is why every call has a 2.5 s timeout and a fallback.

**Key:** `OPENROUTER_API_KEY` from the environment, or the first `OPENROUTER_API_KEY=...` line of `jev.keyFile` (default `~/.config/rustic-os/openrouter.env`, the same file the RusticOS JEV pilots use). The file is read as data, never run. Cost: about USD 0.00002 per message.

### Ideas not built (yet)

TypeSafe's and OpenRouter's guides list more uses. These fit WoW AI:

- **Permission prompts:** when Claude or Grok is refused a command, a JEV reversibility check could auto-approve **read-only** ones, retrying without the **Allow** click. That helps with a controller or voice. Their guide auto-approves only at p ≥ 0.95, and approved 0 of 8 state-changing commands in its test. It needs the command text, not just the rule, and it touches what the agent may run on this PC, so it stays opt-in and unbuilt for now.
- **"Done" claim check:** a noul on whether the reply's "done" is backed by the run's tool results.
- **Which chat a voice message is for:** a choice among the chat names.
- **Speak now or later:** a noul on whether a background reply is worth interrupting for, for example during combat.

Not a fit: playing the game (Blizzard's terms forbid automation, and the addon API can't act on its own anyway), and anything about amounts of gold, item counts or times, which are JEV's weak points.

## Configuration

New `bridge/config.json` blocks. Everything has a default, so a missing block behaves as shown:

```json
"opencodex": { "enabled": true, "url": "http://127.0.0.1:10100", "ocxPath": "", "claudeViaOcx": true },
"jev": {
  "enabled": true, "keyFile": "~/.config/rustic-os/openrouter.env", "timeoutMs": 2500,
  "router": true, "minConfidence": 0.85,
  "prefetch": true, "needThreshold": 0.8, "maxNeeds": 3,
  "review": true, "reviewThreshold": 0.5,
  "fallbackTier": "balanced", "minTierConfidence": 0.3,
  "tiers": { "fast": "gpt-6-luna--fast", "balanced": "gpt-6-sol", "strong": "anthropic/claude-opus-5-5" }
},
"voice": {
  "enabled": true, "python": "~/.local/share/wow-ai-voice/bin/python",
  "whisperModel": "small", "device": "cpu", "computeType": "int8", "language": "es",
  "piperVoice": "~/.local/share/wow-ai-voice/voices/es_ES-davefx-medium.onnx",
  "recordCommand": ["arecord", "-q", "-f", "S16_LE", "-r", "16000", "-c", "1", "-t", "raw"],
  "playCommand": ["pw-play"], "speak": "voice",
  "maxMs": 20000, "silenceMs": 1100, "noSpeechMs": 6000, "threshold": 700
}
```

- `voice.speak`: `"voice"` reads aloud replies to voice messages, `"always"` reads every reply, `"off"` reads none.
- `voice.threshold`: the RMS level (16-bit scale) that counts as speech. Raise it in a noisy room.
- `voice.whisperModel`: `large-v3-turbo` is more accurate but takes about 5 s per phrase on this CPU. `device: "cuda"` needs the NVIDIA cuBLAS/cuDNN wheels in the venv.
- `--inject "text" --model <id|auto>` tries a model, or the JEV router, without the game.
