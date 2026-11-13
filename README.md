# CrossHotbar Forever

An FFXIV-style **cross hotbar** for **World of Warcraft: Forever**'s built-in gamepad support.

Keep your LT and RT bars on screen at all times so you can watch cooldowns at a glance, double-tap a trigger for an extra "x2" flyout set, and do it all with Blizzard's own gamepad button art.

## Features
- **LT and RT bars** always visible along the bottom (dimmed until you hold the trigger), with your base set and the two x2 flyouts above them
- **Hold LT, RT or both** to use that set, just like the native gamepad bar
- **Double-tap and hold LT or RT** for the **x2 flyouts** (face buttons). One press snaps you back to the main set, like FFXIV
- **Native look**: Blizzard's gamepad button art, round face buttons, trigger and button glyphs that follow Xbox / PlayStation controllers
- **Button styles**: Native, Classic, Minimal and Flat
- **Works with Blizzard's bind flow**: LT, RT, LT + RT and the base D-pad share slots with the native bar, so spellbook / bag **Bind** fills them
- **Drag & drop**: pick up a spell or item with the spellbook or bags open and every set appears as a drop target, glowing under your cursor
- **Controller-friendly settings window**: hold **LT + RT** and press **View** (an "Edit" prompt shows while both triggers are held), or type `/xhb`

## Getting started
1. Turn on **Gamepad** in Blizzard's options.
2. Your existing LT / RT / LT + RT spells appear on the bars automatically.
3. To fill the **x2 flyouts**, open your spellbook or bags and drag spells or items onto them.

## Settings
Double-tap window, dim amount, bar and flyout size, button style, position, flyout visibility, hiding Blizzard's bar, and button labels.

## Commands
- `/xhb` — open settings
- `/xhb edit` — small drag & drop panel
- `/xhb slots` — show which action slots each set uses
- `/xhb native` — re-sync with Blizzard's bar after changing bar pages
- `/xhb debug` — check that the triggers reach the addon

## Notes
- WoW doesn't let addons time things during combat, so in combat a quick trigger tap stays "armed" for the flyout until your next press of that trigger.
- Blizzard's protected bind window can't bind to the flyouts; use drag & drop for those.

License: MIT
