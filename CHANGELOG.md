# Changelog

All notable changes to ProfTracker. Newest first.

## v0.1.5

- Fix: cooldowns could show about 49.7 days too long (for example "50d 22h" when the game said "1 Day 5 Hours"). GetSpellCooldown start times are based on GetTime() (seconds since the PC booted); a cooldown that started before the last reboot was reported wrapped by 2^32 ms. A start in the future is now unwrapped, remaining time cannot exceed the duration, GetRecipeCooldown / GetTradeSkillCooldown are used as seconds remaining, and anything over 7 days is ignored. Bad values saved by 0.1.4 are repaired or dropped on load, for every character.

## v0.1.4

- Profession cooldowns: GetRecipeCooldown / GetSpellCooldown / GetTradeSkillCooldown / tool-item cooldown, saved as absolute ready times per character and recipe, with a shared transmute group. Captured on scan, login, cooldown updates, and after crafting. Shown in recipe details and in AltStash 0.3.3+'s Craftables list. Schema unchanged (2).

## v0.1.3

- Scan fixes for "ProfTracker is empty":
  - If C_TradeSkillUI exists but returns no learned recipes, the classic GetNumTradeSkills path is tried too. Classic Enchanting is supported; Beast Training is ignored.
  - Listens to more trade-skill and craft update events. A scan that finds no data yet is retried while the window is open.
  - Classic window: collapsed headers are expanded before reading; filtered scans merge into the saved list instead of replacing it.
  - Skill rescans no longer delete a profession's saved recipes when the skill-list name differs from the window name.
  - learned == nil recipes count as learned when IsPlayerSpell says so. New `/pt scan`; `/pt debug` starts with a summary.

## v0.1.2

- Saves maxTrivialLevel per learned recipe (the skill at which it turns white). The skill-up path uses that real white threshold; orange-to-yellow and yellow-to-green remain estimates. Recipe details show "Turns white at skill".

## v0.1.1

- Only learned recipes are saved, with reagent fallbacks, a staged skill-up path, correct "Makes" quantity, tradeable-only counts for other characters (AltStash 0.2.1+), and the lowest difficulty colour called "White" everywhere.

## v0.1.0

- First version.
