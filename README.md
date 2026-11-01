# Eluna Enchanter NPC

**Name:** Eluna Enchanter NPC
**Author:** rkr87
**License:** GNU AGPL v3
**Requires:** AzerothCore (3.3.5a) with Eluna

**Description:** An enchanter NPC for AzerothCore + Eluna that behaves like an
enchanter player — 250 formulas across all three eras, with real reagents, a fee
that scales with required skill, and item-level gates. No core rebuild to add a
formula.

Right-click him and enchant your gear through four gossip menus: slot → era →
formula → reagents and fee.

## Why not `mod-npc-enchanter`?

AzerothCore's own [mod-npc-enchanter](https://github.com/azerothcore/mod-npc-enchanter)
is a C++ module that gives enchants away from a hardcoded list. This script is
an NPC that behaves like an enchanter *player* instead: it wants the reagents,
takes a fee, and refuses things a real enchanter could not do for you.

| | mod-npc-enchanter | this script |
|---|---|---|
| Formulas | fixed hand-picked WotLK list baked into the C++ enum | 250 formulas across all three eras, in a Lua data file |
| Adding a formula | edit C++, rebuild the core | add one row to `enchants_data.lua`, `/reload eluna` |
| Cost | free | reagents + fee scaled by required skill and era (both optional) |
| Reagents | none | consumed from the player's bags, refunded if the enchant fails |
| Item level | none | Outland formulas need ilvl 35, Northrend 60 — configurable, or off |
| Names | effect text (`"40 Stamina"`, `"225 Armor"`) | the client's own recipe names, in the player's locale |
| Menus | one flat list per slot | slot → era → formula, paginated, sorted by required Enchanting skill |
| Why can't I use this? | not shown — the row is just missing | every formula the item fits is listed, split into *available* / *unavailable* |
| Already enchanted | re-enchants silently | tagged `(current)`, no Apply button |
| Failure handling | — | re-validates live, charges first, refunds reagents and fee on any failure |
| Profession-only enchants (fur linings, embroideries, inscriptions, arcanums, ring enchants) | included, gated on the player having the profession | excluded on purpose: nobody else can cast them on your item |
| Idle chatter / emotes | yes, configurable phrases | no |

The exclusions are a design decision, not a gap: the NPC only offers what
another player could do for you in a trade window, so head arcanums, shoulder
inscriptions, leg kits, ring enchants and profession extras are out. If you want
free enchants instead of an economy, set `RequireMaterials = false` and
`GoldFee = 0` and you get close to the module's behaviour with the wider book.

## Install

1. Copy `enchanter_npc.lua` and `enchants_data.lua` into `lua_scripts/`.
2. Run `enchanter_npc.sql` against the world database.
3. Restart the worldserver, then `.npc add 601015`.

Using a different creature entry? Change `NPC_ID` at the top of
`enchanter_npc.lua` to match.

## How it works

1. **Slot** — every slot holding an item. Weapons get Main Hand / Off Hand, plus
   2H Weapon and Staff rows when the item is one.
2. **Era** — Classic, Outland, Northrend, each showing how many formulas are
   available and how many you cannot use yet.
3. **Formulas** — `Name: effect`, highest required Enchanting skill first.
4. **Materials** — the requirements, and the Apply button.

Apply re-checks the item and your bags before spending anything, takes the fee,
and refunds in full if the enchant fails.

## Configuration

Everything is in the `Config` table at the top of `enchanter_npc.lua`; no edits
elsewhere are needed.

| Key | Default | Meaning |
|---|---|---|
| `RequireMaterials` | `true` | `true` = the recipe consumes its reagents |
| `MinIlvlTBC` | `35` | minimum item level for Outland formulas (`0` = no gate) |
| `MinIlvlWotLK` | `60` | minimum item level for Northrend formulas (`0` = no gate) |
| `GoldFee` | `100000` | base fee in copper, before the skill curve (`0` = free) |
| `FeeExponent` | `2.5` | how hard the fee rises with required skill |
| `FeeEra` | `{vanilla 0.5, tbc 1.0, wotlk 2.0}` | era multiplier on that fee |
| `PageSize` | `10` | formulas per page (clamped to 4–20) |
| `ShowVanilla` / `ShowTBC` / `ShowWotLK` | `true` | switch a whole era off |
| `ShowBreadcrumbs` | `true` | print the item → formula trail in chat |
| `ShowSlotIcons` | `true` | item icon on each slot row |
| `AnnounceLogin` | `false` | broadcast a note on login |
| `VisualSpell` | `12512` | cosmetic played when an enchant lands |
| `DebugReview` | `false` | GM mode: list every formula the slot could take, gates unfiltered |

The item-level gates apply to the **item being enchanted**, not the player. If
`RequireMaterials` is `false`, `GoldFee` is `0`, or a level option is `0`, that
requirement disappears from the materials page and the popup — they only list
what is actually enforced.

### The fee

```
fee = GoldFee * (skill / 300) ^ FeeExponent * FeeEra[era]
```

Rounded to whole silver. Cheap at low skill, steep at high skill, with the era
multiplier on top:

| skill | Classic | Outland | Northrend |
|---|---|---|---|
| 100 | 32s | 64s | 1g 28s |
| 300 | 5g | 10g | 20g |
| 450 | 13g 78s | 27g 56s | 55g 11s |

`DebugReview = true` lists every formula a slot could take and offers Apply even
when a gate would refuse it, so you can trigger each gate and see what it says.

## The formula book

`enchants_data.lua` holds the formulas: 250 entries — Classic 131, Outland 50,
Northrend 69.

| Field | Meaning |
|---|---|
| `name` | fallback name, if the core cannot resolve `spell` |
| `slot` | the pool, and therefore what the item must be: `weapon`, `weapon2h`, `staff`, `shield`, `back`, `chest`, `wrist`, `hands`, `feet` |
| `eid` | `SpellItemEnchantment` id — must exist on your core |
| `exp` | `vanilla`, `tbc` or `wotlk`; also picks the item-level gate |
| `spell` | recipe spell id, so names print in the player's locale |
| `skill` | Enchanting needed to learn it; sets the list order and the fee |
| `effect` | the line the menu prints beside the name |
| `mats` | `{ itemId, count }` consumed, when `RequireMaterials` is on |

Adding a formula is one row. No rebuild, no SQL.

## Troubleshooting

| Symptom | Cause |
|---|---|
| "cannot find her formula book" | `enchants_data.lua` is not in the same folder as the script |
| NPC is silent on right-click | `npcflag` must include `1` (gossip) — the SQL sets it |
| `.npc add` fails | the SQL was not run, or against the wrong database |
| An enchant "fizzled" | that `eid` does not exist on your core build; the fee and reagents were refunded |
| Nothing appears in a slot | that slot's formulas are all gated by era switches, item level, or reagents |
| Errors on startup | check the worldserver console — the script prints a labelled error and never leaves the player in a dead gossip window |

## Credits

NPC identity, entry 601015 and archetype from
[mod-npc-enchanter](https://github.com/azerothcore/mod-npc-enchanter) — created
by StygianTheBest for StygianCore, ported to AzerothCore by gtao725. Formula
data derived from the 3.3.5a client tables.

## License

GNU Affero General Public License v3.0 — see `LICENSE`.
