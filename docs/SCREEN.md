# Screenshots: show the agent your screen

Ask about what you are looking at ("¿qué es esto?", "is this item better than mine?", "what does this error mean?") and the agent gets a picture of the game window as it was when you sent the message. You can also hand it a screenshot you already took.

## How a message gets one

| You do | The message goes with |
|---|---|
| Talk about the screen: "esto", "esta ventana", "lo que veo", "this", "here", "look"... | A screenshot, if JEV agrees the question needs it (the default, `auto`) |
| Ask something JEV judges to be about the screen, without those words | A screenshot taken then (JEV score ≥ 0.8) |
| Click **Shot** (next to Talk), press **Back/Select** in gamepad mode, or **Y > Screenshot** | A screenshot, on the next message (typed or spoken) |
| `/ai shot <question>` · `/ai foto <pregunta>` | A screenshot, with that question |
| `/ai screenshot [question]` · `/ai captura [pregunta]`, or "mi última captura", "my last screenshot" in the message | Your newest **saved** screenshot |

`/ai screen auto|always|never` (`/ai pantalla auto|siempre|nunca`) sets when messages carry one by themselves. The Shot button and `/ai shot` work in every mode. A key for the Shot button is in *Options > Keybindings > AddOns > WoW AI*.

A reply that saw a picture starts with *[saw your screen]* or *[saw your screenshot]*.

## What the picture is

- **Live:** the game window when the bridge reads your message, about a quarter of a second after you send it. The WoW AI window turns invisible for that moment. On Linux and Windows, the bridge blacks out the coloured strip the addon uses to talk to it. It does not on macOS yet.
- **Saved:** the newest picture (`.png`, `.jpg`, `.webp`) in:
  - the game's own `Screenshots` folder (Print Screen in the game, saved as `.jpg`);
  - the desktop's screenshot folder:
    - Linux: `~/Pictures/Screenshots`, or in Spanish `~/Imágenes/Capturas de pantalla`;
    - macOS: the Desktop;
    - Windows: `Pictures\Screenshots`.
  - Add more folders with `screen.folders`.

Live shots are kept in `bridge/tmp/shots/`, the newest 30 only. Nothing leaves your PC except to the agent you are already talking to.

## Agents

| Agent | How it gets the picture |
|---|---|
| Codex | `-i <file>` |
| Hermes | `--image <file>` |
| Claude | the path in the message, and `--add-dir` so its Read tool may open it |
| Grok | the path in the message (its Read tool) |
| Antigravity | not supported yet |

## Configuration (`bridge/config.json`)

```json
"screen": {
  "enabled": true,
  "maxWidth": 1920,
  "keep": 30,
  "threshold": 0.6,
  "autoThreshold": 0.8,
  "folders": ["~/Games/screens"]
}
```

| Key | Meaning |
|---|---|
| `maxWidth` | Wider windows are scaled down to this width. |
| `threshold` | How sure JEV must be when the words pointed at the screen. |
| `autoThreshold` | How sure it must be when they didn't. |
| `folders` | Extra places to look for saved screenshots. |

Without JEV, a message that mentions the screen still gets its picture, and one that doesn't never does.

## Platforms

- **Linux** (Wine or Proton, X11 or Xwayland): `capture_x11.py --shot`. The buffer is reordered in bulk, about 0.1 s for 1080p. Tested.
- **Windows:** `capture.ps1 -Shot` (GDI). Written but not tested yet.
- **macOS:** `capture_mac.py --shot` (`screencapture`, then `sips` to scale Retina down). Written but not tested yet. It needs the Screen Recording permission.

Try it without the game: `node bridge/bridge.js --inject "what does this window say?" --shot s --window-name "<a window title>"`.
