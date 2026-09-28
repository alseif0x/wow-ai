# Game data and actions

The agent can ask the game for more than the context line (your bags, bank, spells…), and it can propose **actions** (sort the bags, abandon quests, put a spell on a bar…) that the addon runs **only after you click Apply**. Both follow the map's pattern ([MAP.md](MAP.md)): the agent writes a fenced block in its reply, the bridge validates it, and the addon acts on it.

## Game data: ```` ```wowdata ````

When a request needs data the context doesn't carry, the agent ends its reply with:

````
```wowdata
bags quests
```
````

The bridge takes the block out of the text and puts `need = { "bags", "quests" }` on the reply record. The addon then sends that data **on its own** as the next message of the chat. It starts with `[game data]`, and the transcript shows it as a single line. The agent answers the original request from there.

| Kind | What the agent gets |
|---|---|
| `bags` | Every distinct item in the bags, with its total count, quality, type, item level (gear), vendor price and "bound"/"nosell" flags, plus free slots |
| `bank` | The same for the character bank and the warband bank. The bank can only be read while it is open, so the addon keeps a copy per character (`WoWAIDataDB`) from the last time you opened it, and says how old that copy is |
| `gear` | The equipped item in each slot, with its item level |
| `spells` | The spellbook by tab: spell id, name, rank, passive |
| `bars` | Every action slot that holds something: type, id, name |
| `talents` | The active talent tree: points left, and every node as `node: entry name / entry name  rank/max`, marked `*` (has points) or `+` (can take a point now) |
| `quests` | The quest log: id, level, title, zone, unfinished objectives, `[ready to turn in]`, `[failed]`, `[gray]` |
| `reputation` | Every faction with its standing and progress |
| `macros` | Macro index, name and body |

Everything must fit in one strip message (about 2.9 KB). A section that doesn't fit whole is cut short with a note, and the agent can ask for that kind on its own. To stop an agent from asking forever, the addon answers at most **two** data requests per message you type.

`/wow-ai data [kinds]` (`/wow-ai datos`) shows exactly what would be sent, in the copy box, without sending anything.

## Actions: ```` ```wowact ````

````
```wowact
[{"op":"sort_bags"},{"op":"abandon_quests","ids":[33,52]}]
```
````

The bridge keeps only the operations below and checks their arguments (types, ranges, lengths; at most 20 actions, 40 ids each). Anything else is dropped, and a `[bridge] actions: …` line in the reply says why. The addon lists what's left **in its own words**, looking up quest, spell, item and talent names itself instead of trusting the agent's text, and shows **Apply (n)** and **Discard** buttons under the reply.

| Op | Arguments | Needs |
|---|---|---|
| `sort_bags` | | |
| `sort_bank` | | bank open |
| `deposit_reagents` | | bank open |
| `deposit` / `withdraw` | `items`: item ids (every stack of each) | bank open |
| `sell_junk` | | vendor open |
| `sell_items` | `items`: item ids | vendor open |
| `equip` | `items`: item ids | |
| `abandon_quests` | `ids`: quest ids | |
| `track_quests` | `add`, `remove`: quest ids | |
| `place_action` | `slots`: `[{ slot, spell \| item \| macro }]`, slots 1–180 | |
| `clear_actions` | `slots`: slot numbers | |
| `create_macro` | `name` (≤16), `body` (≤255), `icon`, `perCharacter` | |
| `learn_talents` | `nodes`: `[{ node, entry?, ranks? }]` (entry for choice nodes) | |
| `train_all` | | trainer open |
| `arrange_bags` | `order`: item ids, put first in that order (every stack of each); the rest keeps its order after them | |
| `move_items` | `moves`: `[{ from: [bag, slot], to: [bag, slot] }]`, bags 0-5, slots 1-40; a taken target swaps | |

There is no operation to delete or destroy items. Every op is a fixed function in `Actions.lua`: nothing the agent writes is ever run as code.

**Clear orders run by themselves.** JEV checks each proposed action against your request (see [VOICE-GAMEPAD-MODELS.md](VOICE-GAMEPAD-MODELS.md#jev)). When every action is plainly what you asked for, the addon applies them without the click: at ≥ 0.85 for actions you can put back by hand, at ≥ 0.95 for selling, abandoning quests, talents and training. In combat they wait for combat to end, and ones that need the bank, a vendor or a trainer run when you open it. The report says "Done without asking". Anything doubtful waits for Apply as below. `/wow-ai autoapply off` (`/ai autoaplicar off`) makes every action wait for Apply.

The `bags` game data lists where each item is (`@bag:slot`) and the size of each bag, so the agent can plan `move_items`.

When you click **Apply** (or type `/wow-ai apply` / `/wow-ai aplicar`):

- Nothing runs in combat. If combat starts mid-way, the run stops, and whatever it didn't finish stays on the reply for another Apply.
- An action that needs a window (bank, vendor, trainer) waits on the reply, with a note saying which window to open, while the others run.
- The steps run one at a time with short pauses, so the server keeps up.
- The transcript gets a report: one line per action, `OK` or `NO` with the reason. The next message you send starts with that report as `[actions] …`, so the agent knows what happened.

**Discard** (`/wow-ai discard`) drops the actions and tells the agent the same way.

Messages you typed while waiting (the queue, `/wow-ai queue`) wait while a reply has actions on it, so its buttons stay. They go out once you apply them all or discard them, and the first one carries the report.

All the game functions used here are unprotected on the Forever client (checked against Blizzard's UI source for 1.60.1). If the game ever blocks one, the report says so.

## Language

The addon's new texts (the action list, the buttons, the reports) are in Spanish on esES/esMX clients and in English elsewhere.
