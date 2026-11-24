# ProfTracker 0.1.5

Per-character profession and recipe tracker for the WoW Forever beta (Interface 16001). **Passive reads only**: it reads your skills and
the recipe list the client shows when you open a profession window, and saves them to `ProfTrackerDB`. It never crafts, clicks, sends
input or calls protected functions.

With **AltStash 0.2.0+** loaded (listed as `## OptionalDeps`), "Can make" counts materials from **all** your characters' bags, bank and mail
and tells you which alt holds what. Without AltStash it still works, using only the logged-in character's bags.

## Requirements
- WoW: Forever client 1.60.1 (`## Interface: 16001`)
- Optional: **AltStash** — "can make" counts use materials from all your characters' bags, bank and mail. Without AltStash, only the logged-in character's bags are counted.

## Install
Unzip the release (`ProfTracker-v0.1.5.zip`) into `Interface/AddOns`, so you have `Interface/AddOns/ProfTracker/ProfTracker.toc`. On the Forever client that is typically `World of Warcraft/_classic_beta_/Interface/AddOns/`. Restart the game or `/reload`.

Author: **Demnock**.

## Features
- **Professions** saved on login and on `SKILL_LINES_CHANGED` / `CHAT_MSG_SKILL` / opening a profession: name, current/max skill, primary vs secondary, last updated (`GetProfessions` + `GetProfessionInfo`; legacy `GetNumSkillLines`/`GetSkillLineInfo` fallback).
- **Recipes** saved when you open a profession window (`TRADE_SKILL_SHOW` / `TRADE_SKILL_LIST_UPDATE`): every recipe with `learned == true` (strictly; `GetAllRecipeIDs` also lists the profession's unlearned recipes, whose difficulty is ignored) with name, id, output item, skill-up colour (Orange / Yellow / Green / **White** - the lowest colour is called White, not Gray, because gray means junk in WoW) and reagents (item id + count). Saved per character, so you can browse an alt's recipes while playing another one. Linked / guild / NPC crafting windows are ignored (they show other people's recipes), and an empty read never overwrites saved data.
- **Window** (`/pt`): left = characters with their professions and skill bars; top right = recipe list (difficulty, name, "Can make: N all  (M this char)"); bottom right = details (materials needed vs held, which alt holds what and where: bags / bank / mail, and a "Missing from every character" list). "Crafts:" box = how many crafts to plan for. Sorted **orange first, then craftable now**.
- **Search box**: filters by recipe name, reagent name, or an item/recipe id.
- **White-at level** (0.1.2): for every learned recipe the game's `maxTrivialLevel` is saved as `trivial` - the skill at which the recipe turns trivial (white). It is shown in the recipe details ("Turns white at skill") and used by the skill-up path. (Unlearned recipes report a placeholder such as 300; they are never saved.) Recipes saved by 0.1.1 have no value until you open that profession window once.
- **Skill-up path / "next steps"** (button or `/pt path [target]`): a greedy plan in **stages of ~12 skill points** (default: the next 3 stages, up to 6), limited to recipes the character knows. Stage 1 uses the colours saved at the last scan; each later stage **assumes every recipe has dropped one colour** (orange -> yellow -> green) - **these orange->yellow and yellow->green changes are ESTIMATES** (the game does not expose those thresholds). The **white threshold is real** where known: a recipe with a saved `maxTrivialLevel` is dropped from the plan at that skill (capped inside the stage where it turns white, never used afterwards, and never guessed to be white earlier); recipes without a saved value (not rescanned since 0.1.1) still use the old stage-based guess. White is never used. Within a stage: best colour first, cheapest by reagent count, using materials from all characters; a stage that can't be covered ends with one "needs materials" step. Lists total materials needed vs owned, what is missing and who holds the rest. Estimates: orange ~1 point per craft, yellow ~0.5, green ~0.25. The real colour thresholds aren't exposed, so **reopen the profession window after crafting** and ask again.
- **Makes:** shows the output item and quantity per craft (`Item`, `Item x2`, `Item x2-3`); the detail pane also shows items per craft for what you can make.
- **Cooldowns (0.1.4):** reads profession cooldowns and saves the **absolute ready time** (epoch seconds via `time()`) per character per recipe in `chars[guid].cooldowns[recipeID] = { ready, at, src, dur, day }`, plus `recipe.cd = true` (has a cooldown; sticky across rescans) and `recipe.cdGroup = "transmute"` (shared cooldown). Readers, all feature-detected and pcall-wrapped: Classic `GetTradeSkillCooldown(index)` during a classic scan, `C_TradeSkillUI.GetRecipeCooldown(recipeID)` while the profession window is open, `C_Spell.GetSpellCooldown` / `GetSpellCooldown(recipeSpellID)` at any time (GetTime-relative values converted to epoch; the ~1.5 s global cooldown is ignored), and the tool item's cooldown (`C_Container.GetItemCooldown` / `GetItemCooldown`) for Refined Deeprock Salt (Salt Shaker). Captured on every profession scan, on login (all saved recipes), on `SPELL_UPDATE_COOLDOWN` / `BAG_UPDATE_COOLDOWN` (only recipes known to have a cooldown) and after you craft one of your recipes (`UNIT_SPELLCAST_SUCCEEDED`, player only). Transmutes share one cooldown: every transmute gets the group's latest ready time; if nothing is readable right after a craft, the last known duration is used. Recipes flagged by English name (`Transmute...`, `Mooncloth`, `Refined Deeprock Salt`) or seen on cooldown once. Shown in the recipe details ("Cooldown: 17h 23m left (ready Sun 03:12, shared with all transmutes)" / "Cooldown: Ready") and in AltStash 0.3.3's Craftables list. Optional fields: schema stays 2, older data loads unchanged.
- Data schema versioned (`ProfTrackerDB.schemaVersion`, currently 2); newer data is never overwritten.

## Commands (`/pt` or `/proftracker`)
`/pt` toggle window | `/pt list` | `/pt char <name>` (first, second or full name, or the `[suffix]`) | `/pt path [target]` | `/pt search <text>` | `/pt reset <name>` | `/pt scan` (with a profession window open: scan now and print what was saved, or exactly why nothing was) | `/pt debug` (0.1.3: first lines = version/client build, recipe API path, open profession, last scan result and per-profession saved counts; then API availability, "learned N of M", `maxTrivialLevel` of the first learned recipe and how many learned/saved recipes have one, reagent counts and the schematic layout - paste it if something is empty) | `/pt help`

## How materials are counted
- "all": the crafting character's own items (bags + bank + mail, **soulbound included**) **plus** every other character's **tradeable** items. For other characters ProfTracker always uses tradeable-only counts, whatever AltStash's own "tradeable only" setting is (needs AltStash 0.2.1+; an older AltStash falls back to its setting). "Own" means the character whose recipes you are viewing.
- "this char": only what the crafting character itself holds (bags + bank + mail).
- Items are counted from AltStash's last scan of each character (bags/bank/mail update when you visit them).

## Caveats
- Recipes and difficulty colours only update when you open the profession window on each character; colours drift as your skill rises.
- Counts are only as fresh as AltStash's scans (bank/mail only when those windows were opened).
- Reagents are read with `GetRecipeSchematic`; if it errors or yields nothing, ProfTracker falls through to the older `C_TradeSkillUI` reagent calls, then to legacy `GetTradeSkill*` (matched by recipe name). `/pt debug` prints how many saved recipes have/lack reagents per profession and the schematic layout of the first learned recipe.
- Reagent alternatives with qualities (Retail-style) use the first listed item.
- Not covered: crafting cooldowns, vendor/auction prices, trainer recipes you haven't learned.

## Changelog
See [CHANGELOG.md](CHANGELOG.md).
