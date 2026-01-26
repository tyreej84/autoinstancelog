# autoinstancelog
Auto Instance Logging for World of Warcraft
# Auto Instance Log

Auto Instance Log is a lightweight World of Warcraft addon that automatically enables Combat Logging when you enter eligible instances (dungeons and raids), and optionally disables it when you leave. It is designed to make logging for tools like Warcraft Logs effortless — no more forgetting `/combatlog`.

## Features

- Automatically enables Combat Logging in dungeons (`party`) and raids (`raid`)
- Optional Mythic+ only mode for dungeons
- Raid difficulty filtering (LFR / Normal / Heroic / Mythic)
- Optional Max level only logging
- Per-character participation toggle
- Account-wide or per-character settings scope
- Quiet modes and message suppression options
- Output messages to ChatFrame or UIErrorsFrame
- Resilient handling of zone changes and instance swaps (debounced logic)
- Optional logging boundary reset on instance swap (dungeon ↔ raid)
- “Dry run” test mode to preview behavior without changing logging state
- Export and Import settings string for easy sharing
- Sync settings between account and character scopes

## Installation

Manual installation:
1. Download or clone this repository.
2. Copy the `AutoInstanceLog` folder into your WoW AddOns directory.

Retail path:
World of Warcraft\_retail_\Interface\AddOns\

3. Verify the folder structure:
AutoInstanceLog/
  AutoInstanceLog.toc
  AutoInstanceLog.lua

4. Launch World of Warcraft and enable Auto Instance Log from the AddOns menu.

Git clone (development):
git clone <your-repo-url> "World of Warcraft/_retail_/Interface/AddOns/AutoInstanceLog"

## Usage

Type the following in-game to see all available commands:
/autolog help

Common commands:
- /autolog on | off
- /autolog status | debug | test
- /autolog both | raids | dungeons
- /autolog maxlevel on|off
- /autolog mplusonly on|off
- /autolog raidfilter lfr|normal|heroic|mythic on|off
- /autolog participate on|off
- /autolog quiet [off|auto|all]
- /autolog output chat|errors
- /autolog export | import
- /autolog scope account|character

## Settings Panel

Open via:
Esc → Options → AddOns → Auto Instance Log

Available options include:
- Enable or disable the addon
- Per-character participation
- Dungeon, raid, or combined logging modes
- Max level only logging
- Mythic+ only dungeon logging
- Raid difficulty filters
- Quiet and message suppression controls
- Output destination (chat or UIErrorsFrame)
- Sync account ↔ character settings
- Export / Import configuration
- Dry-run test button

## Recommended Configurations

Raid logging (Normal+):
- Mode: raids or both
- Raid difficulties:
  - Normal: ON
  - Heroic: ON
  - Mythic: ON
  - LFR: OFF (optional)

Mythic+ only logging:
- Mode: dungeons or both
- Mythic+ only: ON

## Behavior Notes

Manual logging ownership:
If combat logging is already enabled when you enter an instance, the addon can treat it as manually enabled and avoid disabling it later. This prevents the addon from interfering with user-controlled logging unless explicitly configured to do so.

Instance swap handling:
When enabled, the addon can reset logging boundaries during dungeon ↔ raid transitions by briefly disabling and re-enabling logging to ensure clean log segmentation.

Advanced Combat Logging:
When enabled, the addon sets AdvancedCombatLogging=1, which is recommended for Warcraft Logs.

## Troubleshooting

Logging did not enable:
1. Run /autolog debug
2. Confirm:
   - Addon is enabled
   - Participation is enabled for the character
   - You are in a dungeon or raid
   - Mythic+ only mode is not blocking logging

Logging disabled unexpectedly:
- Enable “Respect manual logging” in settings
- Disable the strict “disable on leaving any instance” option if enabled

## Contributing

Pull requests are welcome. Please keep changes focused on stability, correctness, and compatibility with future WoW patches.
