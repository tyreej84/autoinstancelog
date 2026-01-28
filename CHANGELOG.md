# Changelog

All notable changes to **Auto Instance Log** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows semantic versioning.

---

## [3.0] – 2026-01-27

### Added
- **Custom in-game configuration window**
  - Open with `/autolog ui`
  - Fully scrollable, movable, resizable
  - Tabbed layout: *General*, *Filters*, *Advanced*, *Scope / Tools*
  - Remembers window position and size
  - Live status header showing:
    - Logging ON/OFF
    - Ownership (addon vs manual)
    - Instance type, difficulty ID, instance ID
    - Whether logging is desired in the current location
- **Only log when grouped**
  - Prevents combat logging in solo instances if enabled
- **Force boundary even if manual logging is ON**
  - Quietly toggles OFF → ON when entering an eligible instance
  - Ensures clean log boundaries even if logging was already enabled
- **Separate enable/disable delays**
  - `enableDelaySeconds` (default: 1.0)
  - `disableDelaySeconds` (default: 0.5)
  - Improves reliability during rapid zoning, summons, and instance swaps
- **Improved Mythic+ detection**
  - Primary: `difficultyID == 8`
  - Fallbacks:
    - `C_ChallengeMode.IsChallengeModeActive()`
    - `C_ChallengeMode.GetActiveKeystoneInfo()`
- **DB versioning scaffold**
  - Adds internal DB version tracking for safe future migrations
- **Preset commands**
  - `/autolog preset raidprog`
  - `/autolog preset mplus`
- **Additional slash commands**
  - `/autolog ui`
  - `/autolog toggle`
  - `/autolog grouped on|off`
  - `/autolog boundarymanual on|off`
  - `/autolog delays enable <sec>`
  - `/autolog delays disable <sec>`
- **Slash alias**
  - `/ail` (identical to `/autolog`)

### Improved
- Cleaner handling of instance → instance transitions (raid summons, M+ to raid, etc.)
- More reliable combat log ownership tracking
- Better timer cleanup and debounce behavior
- Sync tools expanded:
  - Copy current scope → other scope
  - Reset other scope to defaults
- Blizzard Settings panel now includes a **live status line**

### Fixed
- Edge cases where logging could enable too early during zoning
- Rare Mythic+ detection failures during loading screens
- Options panel content overflow (proper scrolling)

---

## [2.2] – 2026-01-25

### Added
- Scrollable Blizzard Settings panel
- Quiet mode system (`off`, `auto`, `all`)
- Separate suppress toggles for auto-enable and auto-disable messages
- Account-wide vs per-character settings
- Mythic+ only option
- Raid difficulty filters (LFR / Normal / Heroic / Mythic)
- Import / Export settings
- Dry-run test mode

---

## [2.0] – 2026-01-23

### Added
- Automatic combat logging in dungeons and raids
- Automatic disable on leaving instances
- Advanced combat logging toggle
- Slash command control

---

## [1.0] – Initial Release

- Automatically enables combat logging when entering dungeons or raids
- Minimal, lightweight addon with no dependencies
