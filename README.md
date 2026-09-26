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
  keeps the quest log with objective progress, the parts of each zone map
  the character has explored, where it stands with each faction (standing,
  value, at war, and when each standing was reached, with every change
  logged), the players you meet (full
  name, class, race, level, guild) and a catalogue of every item
  seen (name, icon, quality), remembers when each item was first seen on the
  character, keeps 30 days of
  events, and turns on the game's own chat and combat logs (with Advanced Combat
  Logging) at login.

The easiest way to install it is from the [Forever Memory](https://github.com/stockime/forever-memory-app)
app, which ships with it (Settings → Addon → Install), and which turns the
recordings into an armory, a map, a journal and a diary.

To install it by hand, download `armory-addon.zip` from the
[latest release](https://github.com/stockime/forever-memory-app/releases/latest)
and unpack it into `_classic_beta_/Interface/AddOns/`, so the files end up in
`Interface/AddOns/armory` (the folder must be called `armory`). Adding or
renaming files needs a full client restart, not just `/reload`.

## License

MIT, see [LICENSE](LICENSE).
