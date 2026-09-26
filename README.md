# armory

A World of Warcraft: Forever addon that keeps a record of your characters. It
changes nothing in the game and sends nothing anywhere: everything it collects
lands in its SavedVariables file (`WTF/Account/<account>/SavedVariables/armory.lua`),
which the game writes on `/reload` and logout.

- `armory.lua` snapshots the logged-in character into `armory_db`: equipment
  with tooltip text and icons, the character sheet's stats, both talent specs
  and the Legacy trees, skills, money and XP. `/armory` takes a snapshot now.
- `memory.lua` records what happens into `armory_memory`: items gained and lost
  (tagged loot, vendor, mail, trade, auction, bank or quest), money, XP and
  levels, quests with their text and chosen rewards, gossip, zones, map
  position while moving, deaths, group changes and loot/skill/rep messages. It
  keeps the quest log with objective progress, the players you meet (full
  name, class, race, level, guild) and a catalogue of every item
  seen (name, icon, quality), remembers when each item was first seen on the
  character, keeps 30 days of
  events, and turns on the game's own chat and combat logs (with Advanced Combat
  Logging) at login.

Install by putting (or symlinking) this repository into
`_classic_beta_/Interface/AddOns/armory`; the folder must be called `armory`.
Adding or renaming files needs a full client restart, not just `/reload`.

The companion tools (a sync that publishes the snapshot to a website and
archives the recordings to git) live in stru.ci's `wow/` project.
