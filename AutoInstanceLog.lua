-- AutoInstanceLog.lua (v3.0)
-- Adds:
--  - Custom in-game config window (/autolog ui) with tabs + scrolling
--  - DB versioning + migrations
--  - Smarter Mythic+ detection fallback
--  - Enable/disable delays (configurable)
--  - Only-when-grouped option
--  - Force boundary even if manual logging is ON (optional)
--  - Scope utilities (copy + reset other scope)
--  - Live status lines in both Settings panel + custom UI
--  - /autolog toggle + /ail alias + preset(s)

local ADDON_NAME = ...
local f = CreateFrame("Frame")

-- ============================================================
-- Defaults + DB versioning
-- ============================================================
local DB_VERSION = 1

local DEFAULTS = {
  dbVersion = DB_VERSION,

  enabled = true,

  -- Quiet:
  -- off  = show auto enable/disable + confirmations
  -- auto = hide auto enable/disable, still show confirmations + help/status/debug
  -- all  = hide auto + confirmations, only explicit help/status/debug
  quietMode = "off",

  -- Split quiet toggles (override quietMode behavior for auto messages)
  suppressAutoEnable = false,
  suppressAutoDisable = false,

  -- Output target: "chat" or "errors"
  output = "chat",

  -- What to log:
  mode = "both", -- both | raids | dungeons

  -- Optional extra instance types (still optional; default off)
  logScenario = false,
  logPvP = false,
  logArena = false,

  -- Settings scope selector stored in ACCOUNT DB only
  perCharacter = false,

  -- Level gating
  onlyMaxLevel = false,

  -- Only enable in group (prevents solo old content logging if desired)
  onlyWhenGrouped = false,

  -- Dungeons
  mythicPlusOnly = false, -- if true, only log M+ (keystone) dungeons

  -- Raids: difficulty filters
  raidAllowLFR = true,
  raidAllowNormal = true,
  raidAllowHeroic = true,
  raidAllowMythic = true,

  -- Disable / ownership behavior
  respectManualLogging = true,          -- if logging was ON before addon would enable, treat it as manual and never auto-disable it
  disableWhenLeavingLogged = true,      -- disable only if addon enabled it (addon-owned)
  disableOnLeaveAnyIfEnabled = false,   -- leaving ANY instance: disable if logging ON (even if manual), quietly

  -- Instance swap boundary reset
  resetOnInstanceSwap = true,

  -- Force a clean boundary even if logging was already ON (manual),
  -- by briefly toggling OFF->ON when entering an eligible instance.
  forceBoundaryEvenIfManual = false,

  -- Advanced combat logging
  advancedCombatLogging = true,

  -- Recheck insurance
  recheckSeconds = 2.5, -- 0 disables recheck

  -- Debounce decision-making
  debounceSeconds = 0.35,

  -- NEW: Separate delays for toggles (helps with edge-case zoning)
  enableDelaySeconds = 1.0,
  disableDelaySeconds = 0.5,

  -- Custom UI window
  uiLocked = false,
  uiW = 640,
  uiH = 520,
  uiPoint = "CENTER",
  uiRelPoint = "CENTER",
  uiX = 0,
  uiY = 0,
  uiLastTab = 1,
}

local CHAR_DEFAULTS = {
  participate = true, -- "Enable for this character"
}

-- ============================================================
-- Runtime state (NOT saved)
-- ============================================================
local STATE = {
  addonEnabledLogging = false, -- did addon enable logging for the current signature?
  manualOwnedLogging = false,  -- treat as manual-owned (don't auto-disable)
  lastSig = nil,

  pendingTimer = nil,
  recheckTimer = nil,

  enableTimer = nil,
  disableTimer = nil,

  -- UI
  settingsCategory = nil,
  settingsPanel = nil,
  cfgFrame = nil,
  cfgTicker = nil,
}

-- ============================================================
-- Small helpers
-- ============================================================
local function trim(s)
  return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function boolStr(b) return b and "ON" or "OFF" end

local function SafeCancel(timer)
  if timer and timer.Cancel then timer:Cancel() end
end

-- ============================================================
-- DB helpers + migrations
-- ============================================================
local function CopyDefaultsInto(tbl, defaults)
  for k, v in pairs(defaults) do
    if tbl[k] == nil then tbl[k] = v end
  end
end

local function ResetToDefaults(targetTbl)
  for k, v in pairs(DEFAULTS) do
    if k ~= "perCharacter" then
      targetTbl[k] = v
    end
  end
end

local function ShallowCopyDefaults(from, to)
  for k, _ in pairs(DEFAULTS) do
    if k ~= "perCharacter" then
      to[k] = from[k]
    end
  end
end

local function MigrateDB(db)
  local v = tonumber(db.dbVersion) or 0
  if v >= DB_VERSION then
    db.dbVersion = DB_VERSION
    return
  end

  -- Future migrations would go here:
  -- if v < 1 then ... end

  db.dbVersion = DB_VERSION
end

local function EnsureDBs()
  AutoInstanceLogDB = AutoInstanceLogDB or {}
  AutoInstanceLogCharDB = AutoInstanceLogCharDB or {}

  if AutoInstanceLogDB.perCharacter == nil then
    AutoInstanceLogDB.perCharacter = DEFAULTS.perCharacter
  end

  CopyDefaultsInto(AutoInstanceLogDB, DEFAULTS)
  CopyDefaultsInto(AutoInstanceLogCharDB, DEFAULTS)

  -- perCharacter selector lives only in account DB
  AutoInstanceLogCharDB.perCharacter = nil

  CopyDefaultsInto(AutoInstanceLogCharDB, CHAR_DEFAULTS)

  -- Migrations
  MigrateDB(AutoInstanceLogDB)
  MigrateDB(AutoInstanceLogCharDB)
end

local function GetDB()
  if AutoInstanceLogDB and AutoInstanceLogDB.perCharacter then
    return AutoInstanceLogCharDB
  end
  return AutoInstanceLogDB
end

local function GetCharDB()
  return AutoInstanceLogCharDB
end

local function GetScopeName()
  return (AutoInstanceLogDB and AutoInstanceLogDB.perCharacter) and "CHARACTER" or "ACCOUNT"
end

local function GetOtherScopeDB()
  if AutoInstanceLogDB and AutoInstanceLogDB.perCharacter then
    return AutoInstanceLogDB -- other is account
  end
  return AutoInstanceLogCharDB -- other is character
end

-- ============================================================
-- Output / printing
-- ============================================================
local function OutputLine(msg)
  local db = GetDB()
  if db.output == "errors" and UIErrorsFrame and UIErrorsFrame.AddMessage then
    UIErrorsFrame:AddMessage(msg)
  else
    DEFAULT_CHAT_FRAME:AddMessage(msg)
  end
end

local function AutoEnableSuppressed()
  local db = GetDB()
  if db.suppressAutoEnable then return true end
  return (db.quietMode == "auto" or db.quietMode == "all")
end

local function AutoDisableSuppressed()
  local db = GetDB()
  if db.suppressAutoDisable then return true end
  return (db.quietMode == "auto" or db.quietMode == "all")
end

local function ConfirmSuppressed()
  return (GetDB().quietMode == "all")
end

local function PrintAutoEnable(msg)
  if not AutoEnableSuppressed() then OutputLine(msg) end
end

local function PrintAutoDisable(msg)
  if not AutoDisableSuppressed() then OutputLine(msg) end
end

local function PrintConfirm(msg)
  if not ConfirmSuppressed() then OutputLine(msg) end
end

local function PrintAlways(msg)
  OutputLine(msg)
end

-- ============================================================
-- Game state helpers
-- ============================================================
local function GetPlayerMaxLevel()
  if GetMaxPlayerLevel then
    local ok, v = pcall(GetMaxPlayerLevel)
    if ok and type(v) == "number" then return v end
  end
  if MAX_PLAYER_LEVEL and type(MAX_PLAYER_LEVEL) == "number" then
    return MAX_PLAYER_LEVEL
  end
  return 80
end

local function GetInstanceInfoSafe()
  local name, itype, difficultyID, difficultyName, maxPlayers, dynamicDifficulty, isDynamic, instanceID, lfgID = GetInstanceInfo()
  return {
    name = name,
    instanceType = itype,
    difficultyID = difficultyID,
    difficultyName = difficultyName,
    maxPlayers = maxPlayers,
    instanceID = instanceID,
    lfgID = lfgID,
  }
end

local function GetInstanceSignature()
  local inInstance, instanceType = IsInInstance()
  if not inInstance then return "world" end
  local info = GetInstanceInfoSafe()
  return string.format("inst:%s:%s:%s", tostring(instanceType), tostring(info.instanceID or 0), tostring(info.difficultyID or 0))
end

-- ============================================================
-- Difficulty + M+ detection
-- ============================================================
local function IsMythicKeystoneDifficulty(difficultyID)
  return difficultyID == 8
end

local function IsChallengeModeActiveSafe()
  if C_ChallengeMode and C_ChallengeMode.IsChallengeModeActive then
    local ok, active = pcall(C_ChallengeMode.IsChallengeModeActive)
    if ok then return active and true or false end
  end
  return false
end

local function HasActiveKeystoneInfoSafe()
  if C_ChallengeMode and C_ChallengeMode.GetActiveKeystoneInfo then
    local ok, mapID, level = pcall(C_ChallengeMode.GetActiveKeystoneInfo)
    if ok and mapID and mapID ~= 0 and level and level > 0 then
      return true
    end
  end
  return false
end

local function IsMythicPlusNow(difficultyID)
  -- Primary: difficultyID == 8
  if IsMythicKeystoneDifficulty(difficultyID) then return true end
  -- Fallbacks (helpful during zoning hiccups / edge cases)
  if IsChallengeModeActiveSafe() then return true end
  if HasActiveKeystoneInfoSafe() then return true end
  return false
end

local function IsRaidDifficultyAllowed(db, difficultyID)
  -- Common retail raid IDs: 17 LFR, 14 Normal, 15 Heroic, 16 Mythic
  if difficultyID == 17 then return db.raidAllowLFR end
  if difficultyID == 14 then return db.raidAllowNormal end
  if difficultyID == 15 then return db.raidAllowHeroic end
  if difficultyID == 16 then return db.raidAllowMythic end
  -- Unknown => allow (avoid false negatives)
  return true
end

-- ============================================================
-- Eligibility
-- ============================================================
local function PassesMaxLevelGate(db)
  if not db.onlyMaxLevel then return true end
  local lvl = UnitLevel("player") or 1
  return lvl >= GetPlayerMaxLevel()
end

local function PassesGroupGate(db)
  if not db.onlyWhenGrouped then return true end
  return IsInGroup() or IsInRaid()
end

local function IsDesiredInstance()
  EnsureDBs()
  local db = GetDB()
  local charDB = GetCharDB()

  if not db.enabled then return false end
  if not charDB.participate then return false end
  if not PassesMaxLevelGate(db) then return false end
  if not PassesGroupGate(db) then return false end

  local inInstance, instanceType = IsInInstance()
  if not inInstance then return false end

  local info = GetInstanceInfoSafe()
  local difficultyID = info.difficultyID or 0

  -- Optional extra types
  if instanceType == "scenario" and db.logScenario then return true end
  if instanceType == "pvp" and db.logPvP then return true end
  if instanceType == "arena" and db.logArena then return true end

  if instanceType == "raid" then
    if db.mode == "raids" or db.mode == "both" then
      return IsRaidDifficultyAllowed(db, difficultyID)
    end
    return false
  end

  if instanceType == "party" then
    if db.mode == "dungeons" or db.mode == "both" then
      if db.mythicPlusOnly then
        return IsMythicPlusNow(difficultyID)
      end
      return true
    end
    return false
  end

  return false
end

-- ============================================================
-- Logging helpers + ownership tracking
-- ============================================================
local function SetAdvancedLoggingIfNeeded(db)
  if db.advancedCombatLogging and C_CVar and C_CVar.SetCVar then
    C_CVar.SetCVar("AdvancedCombatLogging", "1")
  end
end

local function EstablishOwnershipOnEntry(db)
  STATE.addonEnabledLogging = false
  STATE.manualOwnedLogging = false
  if db.respectManualLogging and LoggingCombat() then
    STATE.manualOwnedLogging = true
  end
end

local function DisableCombatLoggingQuietly()
  if LoggingCombat() then
    LoggingCombat(false)
  end
end

local function DisableCombatLogging(db, announce)
  if LoggingCombat() then
    LoggingCombat(false)
    STATE.addonEnabledLogging = false
    if announce then
      PrintAutoDisable("|cffff5555AutoInstanceLog:|r Combat logging disabled.")
    end
  end
end

local function EnableCombatLoggingNow(db, announce)
  SetAdvancedLoggingIfNeeded(db)
  if not LoggingCombat() then
    LoggingCombat(true)
    STATE.addonEnabledLogging = true
    STATE.manualOwnedLogging = false
    if announce then
      PrintAutoEnable("|cff00ff00AutoInstanceLog:|r Combat logging enabled.")
    end
  end
end

-- ============================================================
-- Recheck insurance
-- ============================================================
local function CancelRecheck()
  SafeCancel(STATE.recheckTimer)
  STATE.recheckTimer = nil
end

local function ScheduleRecheck()
  CancelRecheck()

  local db = GetDB()
  local seconds = tonumber(db.recheckSeconds) or 0
  if seconds <= 0 then return end

  STATE.recheckTimer = C_Timer.NewTimer(seconds, function()
    STATE.recheckTimer = nil
    local dbNow = GetDB()
    if dbNow.enabled and IsDesiredInstance() and (not STATE.manualOwnedLogging) then
      EnableCombatLoggingNow(dbNow, false) -- no extra spam
    end
  end)
end

-- ============================================================
-- Enable/disable scheduling (NEW)
-- ============================================================
local function CancelEnableDisableTimers()
  SafeCancel(STATE.enableTimer); STATE.enableTimer = nil
  SafeCancel(STATE.disableTimer); STATE.disableTimer = nil
end

local function RequestEnable(db, announce)
  SafeCancel(STATE.disableTimer); STATE.disableTimer = nil
  SafeCancel(STATE.enableTimer); STATE.enableTimer = nil

  local delay = tonumber(db.enableDelaySeconds) or 0
  if delay < 0 then delay = 0 end

  if delay == 0 then
    EnableCombatLoggingNow(db, announce)
    ScheduleRecheck()
    return
  end

  STATE.enableTimer = C_Timer.NewTimer(delay, function()
    STATE.enableTimer = nil
    local dbNow = GetDB()
    if dbNow.enabled and IsDesiredInstance() and (not STATE.manualOwnedLogging) then
      EnableCombatLoggingNow(dbNow, announce)
      ScheduleRecheck()
    end
  end)
end

local function RequestDisable(db, announce, quiet)
  SafeCancel(STATE.enableTimer); STATE.enableTimer = nil
  SafeCancel(STATE.disableTimer); STATE.disableTimer = nil

  local delay = tonumber(db.disableDelaySeconds) or 0
  if delay < 0 then delay = 0 end

  local function doDisable()
    if quiet then
      DisableCombatLoggingQuietly()
      STATE.addonEnabledLogging = false
      STATE.manualOwnedLogging = false
    else
      DisableCombatLogging(db, announce)
    end
  end

  if delay == 0 then
    doDisable()
    return
  end

  STATE.disableTimer = C_Timer.NewTimer(delay, function()
    STATE.disableTimer = nil
    doDisable()
  end)
end

-- ============================================================
-- Force boundary even if manual logging is ON (NEW)
-- ============================================================
local function ForceBoundary(db)
  -- Quietly OFF then ON, then recheck.
  DisableCombatLoggingQuietly()
  STATE.addonEnabledLogging = false
  STATE.manualOwnedLogging = false

  C_Timer.After(0.75, function()
    local dbNow = GetDB()
    if dbNow.enabled and IsDesiredInstance() then
      EstablishOwnershipOnEntry(dbNow)
      -- after boundary, treat as addon-owned
      STATE.manualOwnedLogging = false
      RequestEnable(dbNow, true)
    end
  end)
end

-- ============================================================
-- Instance swap boundary reset
-- ============================================================
local function ResetLoggingForNewInstance(db, shouldLogDestination)
  if not db.resetOnInstanceSwap then
    EstablishOwnershipOnEntry(db)
    if shouldLogDestination then
      -- manual boundary option
      if db.forceBoundaryEvenIfManual and LoggingCombat() then
        ForceBoundary(db)
        return
      end
      if not STATE.manualOwnedLogging then
        RequestEnable(db, true)
      end
    end
    return
  end

  -- Respect manual logging unless strict leave-any override OR addon already owned it OR boundary-forcing is on
  local ownsOrStrict = (STATE.addonEnabledLogging == true) or (db.disableOnLeaveAnyIfEnabled == true)
  local boundaryOverride = db.forceBoundaryEvenIfManual

  if db.respectManualLogging and LoggingCombat() and (not ownsOrStrict) and (not boundaryOverride) then
    EstablishOwnershipOnEntry(db)
    return
  end

  -- Boundary reset: disable (quiet), then possibly re-enable
  DisableCombatLoggingQuietly()
  STATE.addonEnabledLogging = false
  STATE.manualOwnedLogging = false

  if shouldLogDestination then
    C_Timer.After(0.75, function()
      local dbNow = GetDB()
      if dbNow.enabled and IsDesiredInstance() then
        EstablishOwnershipOnEntry(dbNow)
        STATE.manualOwnedLogging = false
        RequestEnable(dbNow, true)
      end
    end)
  end
end

-- ============================================================
-- Core apply (debounced)
-- ============================================================
local function ApplyLoggingStateCore()
  local db = GetDB()
  if not db.enabled then return end

  local sigNow = GetInstanceSignature()
  local sigPrev = STATE.lastSig
  local shouldLogHere = IsDesiredInstance()

  if sigPrev and sigPrev ~= sigNow then
    local wasInInstance = (sigPrev ~= "world")
    local nowInInstance = (sigNow ~= "world")

    -- Leaving instance -> world
    if wasInInstance and not nowInInstance then
      CancelRecheck()
      CancelEnableDisableTimers()

      if db.disableOnLeaveAnyIfEnabled then
        RequestDisable(db, false, true) -- quiet forced off
      else
        if db.disableWhenLeavingLogged and STATE.addonEnabledLogging and (not STATE.manualOwnedLogging) then
          RequestDisable(db, true, false)
        end
      end

      STATE.lastSig = sigNow
      return
    end

    -- Instance -> Instance swap
    if wasInInstance and nowInInstance then
      CancelRecheck()
      CancelEnableDisableTimers()
      ResetLoggingForNewInstance(db, shouldLogHere)
      STATE.lastSig = sigNow
      return
    end
    -- World -> Instance falls through
  end

  -- Steady state
  if shouldLogHere then
    if STATE.lastSig ~= sigNow then
      EstablishOwnershipOnEntry(db)
    end

    if LoggingCombat() and db.forceBoundaryEvenIfManual and STATE.manualOwnedLogging then
      -- user had logging already on, but asked to enforce a new boundary
      ForceBoundary(db)
    elseif not STATE.manualOwnedLogging then
      RequestEnable(db, true)
    end
  else
    CancelRecheck()
    -- If we are still in an instance type we don't care about, don't auto-disable unless we own it.
    if db.disableWhenLeavingLogged and STATE.addonEnabledLogging and (not STATE.manualOwnedLogging) then
      RequestDisable(db, true, false)
    end
  end

  STATE.lastSig = sigNow
end

local function DebouncedApply()
  EnsureDBs()
  local db = GetDB()
  local delay = tonumber(db.debounceSeconds) or DEFAULTS.debounceSeconds
  if delay < 0 then delay = 0 end

  SafeCancel(STATE.pendingTimer)
  STATE.pendingTimer = C_Timer.NewTimer(delay, function()
    STATE.pendingTimer = nil
    ApplyLoggingStateCore()
  end)
end

-- ============================================================
-- Export / Import (key=val; includes participate)
-- ============================================================
local function EnsurePopups()
  if StaticPopupDialogs["AUTOINSTANCELOG_EXPORT"] then return end

  StaticPopupDialogs["AUTOINSTANCELOG_EXPORT"] = {
    text = "AutoInstanceLog Export String (copy):",
    button1 = "Close",
    hasEditBox = true,
    editBoxWidth = 340,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
    OnShow = function(self, data)
      local eb = self.editBox
      eb:SetAutoFocus(true)
      eb:SetText(data or "")
      eb:HighlightText()
    end,
  }

  StaticPopupDialogs["AUTOINSTANCELOG_IMPORT"] = {
    text = "AutoInstanceLog Import String (paste):",
    button1 = "Import",
    button2 = "Cancel",
    hasEditBox = true,
    editBoxWidth = 340,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
    OnShow = function(self)
      self.editBox:SetAutoFocus(true)
      self.editBox:SetText("")
    end,
    OnAccept = function(self)
      local s = self.editBox:GetText() or ""
      local ok, err = (function(serial)
        serial = trim(serial)
        if serial == "" then return false, "Empty string." end

        local db = GetDB()
        local charDB = GetCharDB()

        local function unescape(x)
          return (x or ""):gsub("%%3D", "="):gsub("%%3B", ";"):gsub("%%25", "%%")
        end

        for pair in serial:gmatch("[^;]+") do
          local k, v = pair:match("^([^=]+)=(.*)$")
          if k and v then
            k = trim(k)
            v = unescape(trim(v))

            if k == "participate" then
              charDB.participate = (v == "1" or v == "true")
            elseif DEFAULTS[k] ~= nil and k ~= "perCharacter" then
              local def = DEFAULTS[k]
              if type(def) == "boolean" then
                db[k] = (v == "1" or v == "true")
              elseif type(def) == "number" then
                db[k] = tonumber(v) or def
              else
                db[k] = v
              end
            end
          end
        end

        return true
      end)(s)

      if ok then
        PrintConfirm("|cffffff00AutoInstanceLog:|r Imported settings into " .. GetScopeName() .. " scope.")
        DebouncedApply()
      else
        PrintAlways("|cffff5555AutoInstanceLog:|r Import failed: " .. tostring(err))
      end
    end,
  }
end

local function SerializeDB()
  local db = GetDB()
  local charDB = GetCharDB()

  local function esc(v)
    if type(v) == "string" then
      return v:gsub("%%", "%%25"):gsub(";", "%%3B"):gsub("=", "%%3D")
    end
    return tostring(v)
  end

  local parts = {}
  for k, def in pairs(DEFAULTS) do
    if k ~= "perCharacter" then
      local v = db[k]
      if type(def) == "boolean" then
        v = (v and "1" or "0")
      end
      table.insert(parts, k .. "=" .. esc(v))
    end
  end
  table.insert(parts, "participate=" .. (charDB.participate and "1" or "0"))

  return table.concat(parts, ";")
end

-- ============================================================
-- Status snapshot (for UI + debug)
-- ============================================================
local function GetStatusSnapshot()
  EnsureDBs()
  local db = GetDB()
  local charDB = GetCharDB()

  local inInstance, instanceType = IsInInstance()
  local info = GetInstanceInfoSafe()
  local desired = IsDesiredInstance()
  local sig = GetInstanceSignature()

  local owner = "NONE"
  if STATE.manualOwnedLogging then owner = "MANUAL"
  elseif STATE.addonEnabledLogging then owner = "ADDON" end

  local mplus = IsMythicPlusNow(info.difficultyID or 0)

  return {
    scope = GetScopeName(),
    enabled = db.enabled,
    participate = charDB.participate,
    logging = LoggingCombat(),
    owner = owner,
    sig = sig,
    inInstance = inInstance,
    instanceType = tostring(instanceType),
    instanceID = tostring(info.instanceID),
    difficultyID = tostring(info.difficultyID),
    difficultyName = tostring(info.difficultyName),
    desired = desired,
    mplus = mplus,
  }
end

-- ============================================================
-- Dry run tester
-- ============================================================
local function DryRunReport(source)
  local s = GetStatusSnapshot()
  PrintAlways("|cffffff00AutoInstanceLog TEST (" .. tostring(source) .. "):|r")
  PrintAlways("  Scope=" .. s.scope ..
    " participate=" .. tostring(s.participate) ..
    " enabled=" .. tostring(s.enabled))
  PrintAlways("  sig=" .. s.sig ..
    " inInstance=" .. tostring(s.inInstance) ..
    " type=" .. s.instanceType ..
    " instID=" .. s.instanceID ..
    " diffID=" .. s.difficultyID ..
    " mplus=" .. tostring(s.mplus))
  PrintAlways("  desiredHere=" .. tostring(s.desired) ..
    " loggingNow=" .. tostring(s.logging) ..
    " owner=" .. tostring(s.owner))
end

-- ============================================================
-- Presets
-- ============================================================
local function ApplyPreset(name)
  EnsureDBs()
  local db = GetDB()
  name = (name or ""):lower()

  if name == "raidprog" or name == "raid" then
    db.mode = "raids"
    db.raidAllowLFR = false
    db.raidAllowNormal = true
    db.raidAllowHeroic = true
    db.raidAllowMythic = true
    PrintConfirm("|cffffff00AutoInstanceLog:|r Preset applied: Raid Progression (Normal/Heroic/Mythic).")
    DebouncedApply()
    return true
  end

  if name == "mplus" then
    db.mode = "dungeons"
    db.mythicPlusOnly = true
    PrintConfirm("|cffffff00AutoInstanceLog:|r Preset applied: Mythic+ only.")
    DebouncedApply()
    return true
  end

  return false
end

-- ============================================================
-- Slash commands
-- ============================================================
local function ShowHelp()
  PrintAlways("|cffffff00AutoInstanceLog commands:|r")
  PrintAlways("  /autolog help | status | debug | test | ui")
  PrintAlways("  /autolog on | off | toggle")
  PrintAlways("  /autolog quiet [off|auto|all]")
  PrintAlways("  /autolog quietenable on|off")
  PrintAlways("  /autolog quietdisable on|off")
  PrintAlways("  /autolog output chat|errors")
  PrintAlways("  /autolog both | raids | dungeons")
  PrintAlways("  /autolog participate on|off      (this character)")
  PrintAlways("  /autolog maxlevel on|off")
  PrintAlways("  /autolog grouped on|off          (only log when grouped)")
  PrintAlways("  /autolog mplusonly on|off")
  PrintAlways("  /autolog raidfilter lfr|normal|heroic|mythic on|off")
  PrintAlways("  /autolog boundarymanual on|off   (force boundary even if manual)")
  PrintAlways("  /autolog delays enable <sec> | disable <sec>")
  PrintAlways("  /autolog reset | export | import")
  PrintAlways("  /autolog scope account|character")
  PrintAlways("  /autolog preset raidprog|mplus")
  PrintAlways("  Alias: /ail")
end

local function ShowStatus()
  local db = GetDB()
  local charDB = GetCharDB()
  local snap = GetStatusSnapshot()

  PrintAlways("|cffffff00AutoInstanceLog:|r " ..
    "Scope=" .. snap.scope ..
    " | Participate=" .. (charDB.participate and "ON" or "OFF") ..
    " | Enabled=" .. (db.enabled and "ON" or "OFF") ..
    " | Mode=" .. tostring(db.mode) ..
    " | GroupedOnly=" .. (db.onlyWhenGrouped and "ON" or "OFF") ..
    " | MaxLevelOnly=" .. (db.onlyMaxLevel and "ON" or "OFF") ..
    " | M+Only=" .. (db.mythicPlusOnly and "ON" or "OFF") ..
    " | RaidDiff(L/N/H/M)=" .. (db.raidAllowLFR and "1" or "0") .. "/" .. (db.raidAllowNormal and "1" or "0") .. "/" .. (db.raidAllowHeroic and "1" or "0") .. "/" .. (db.raidAllowMythic and "1" or "0") ..
    " | Sig=" .. tostring(snap.sig) ..
    " | Desired=" .. (snap.desired and "YES" or "NO") ..
    " | Logging=" .. (snap.logging and "ON" or "OFF") ..
    " | Owner=" .. tostring(snap.owner))
end

local function ShowDebug()
  EnsureDBs()
  local db = GetDB()
  local charDB = GetCharDB()
  local inInstance, instanceType = IsInInstance()
  local info = GetInstanceInfoSafe()

  PrintAlways("|cffffff00AutoInstanceLog DEBUG:|r")
  PrintAlways("  Scope=" .. GetScopeName() ..
    " participate=" .. tostring(charDB.participate) ..
    " enabled=" .. tostring(db.enabled) ..
    " output=" .. tostring(db.output) ..
    " quietMode=" .. tostring(db.quietMode))
  PrintAlways("  mode=" .. tostring(db.mode) ..
    " onlyMaxLevel=" .. tostring(db.onlyMaxLevel) ..
    " onlyWhenGrouped=" .. tostring(db.onlyWhenGrouped) ..
    " mythicPlusOnly=" .. tostring(db.mythicPlusOnly))
  PrintAlways("  raidAllow(LFR/Normal/Heroic/Mythic)=" ..
    tostring(db.raidAllowLFR) .. "/" .. tostring(db.raidAllowNormal) .. "/" .. tostring(db.raidAllowHeroic) .. "/" .. tostring(db.raidAllowMythic))
  PrintAlways("  respectManualLogging=" .. tostring(db.respectManualLogging) ..
    " disableWhenLeavingLogged=" .. tostring(db.disableWhenLeavingLogged) ..
    " disableOnLeaveAnyIfEnabled=" .. tostring(db.disableOnLeaveAnyIfEnabled) ..
    " resetOnInstanceSwap=" .. tostring(db.resetOnInstanceSwap) ..
    " forceBoundaryEvenIfManual=" .. tostring(db.forceBoundaryEvenIfManual))
  PrintAlways("  delays enable/disable=" .. tostring(db.enableDelaySeconds) .. "/" .. tostring(db.disableDelaySeconds))
  PrintAlways("  IsInInstance=" .. tostring(inInstance) .. " instanceType=" .. tostring(instanceType))
  PrintAlways("  instanceID=" .. tostring(info.instanceID) ..
    " difficultyID=" .. tostring(info.difficultyID) ..
    " difficultyName=" .. tostring(info.difficultyName) ..
    " mplus=" .. tostring(IsMythicPlusNow(info.difficultyID or 0)))
  PrintAlways("  signature=" .. tostring(GetInstanceSignature()) .. " lastSig=" .. tostring(STATE.lastSig))
  PrintAlways("  desiredHere=" .. tostring(IsDesiredInstance()))
  PrintAlways("  LoggingCombat=" .. tostring(LoggingCombat()))
  PrintAlways("  addonEnabledLogging=" .. tostring(STATE.addonEnabledLogging) ..
    " manualOwnedLogging=" .. tostring(STATE.manualOwnedLogging))
end

-- ============================================================
-- Blizzard Settings panel (scrolling) + live status line
-- ============================================================
local function TryOpenBlizzardSettings()
  if not Settings then return end
  if STATE.settingsCategory and Settings.OpenToCategory then
    -- Different builds accept either category object or ID.
    local ok = pcall(Settings.OpenToCategory, STATE.settingsCategory)
    if ok then return end
    if STATE.settingsCategory.GetID then
      pcall(Settings.OpenToCategory, STATE.settingsCategory:GetID())
    end
  end
end

local function CreateSettingsPanel()
  if not Settings or not Settings.RegisterCanvasLayoutCategory then
    return
  end

  EnsurePopups()

  local panel = CreateFrame("Frame")
  panel.name = "Auto Instance Log"
  STATE.settingsPanel = panel

  -- Scroll wrapper
  local scrollFrame = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
  scrollFrame:SetPoint("TOPLEFT", 0, -4)
  scrollFrame:SetPoint("BOTTOMRIGHT", -27, 4)

  local content = CreateFrame("Frame", nil, scrollFrame)
  content:SetSize(1, 1)
  scrollFrame:SetScrollChild(content)

  panel:SetScript("OnShow", function()
    local w = scrollFrame:GetWidth()
    if w and w > 1 then content:SetWidth(w) end
  end)

  local y = -16

  local function AddTitle(text)
    local t = content:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    t:SetPoint("TOPLEFT", 16, y)
    t:SetText(text)
    y = y - 28
    return t
  end

  local function AddSub(text)
    local s = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    s:SetPoint("TOPLEFT", 16, y)
    s:SetJustifyH("LEFT")
    s:SetText(text)
    y = y - 22
    return s
  end

  local function AddSpacer(px) y = y - (px or 10) end

  local function AddCheck(label, tip, getf, setf)
    local cb = CreateFrame("CheckButton", nil, content, "InterfaceOptionsCheckButtonTemplate")
    cb:SetPoint("TOPLEFT", 16, y)
    cb.Text:SetText(label)
    cb.tooltipText = tip
    cb:SetScript("OnShow", function(self) self:SetChecked(getf()) end)
    cb:SetScript("OnClick", function(self)
      setf(self:GetChecked())
      DebouncedApply()
    end)
    y = y - 28
    return cb
  end

  local function AddDropdown(labelText, values, getf, setf)
    local label = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    label:SetPoint("TOPLEFT", 16, y)
    label:SetText(labelText)

    local dd = CreateFrame("Frame", nil, content, "UIDropDownMenuTemplate")
    dd:SetPoint("TOPLEFT", label, "BOTTOMLEFT", -16, -6)

    local function SetValue(v)
      setf(v)
      UIDropDownMenu_SetText(dd, v)
      DebouncedApply()
    end

    UIDropDownMenu_Initialize(dd, function(self, level)
      for _, v in ipairs(values) do
        local info = UIDropDownMenu_CreateInfo()
        info.text = v
        info.func = function() SetValue(v) end
        info.checked = (getf() == v)
        UIDropDownMenu_AddButton(info, level)
      end
    end)

    dd:SetScript("OnShow", function() UIDropDownMenu_SetText(dd, getf()) end)

    y = y - 62
    return dd
  end

  local function AddButton(text, x, yOffset, onClick)
    local b = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    b:SetSize(160, 22)
    b:SetPoint("TOPLEFT", x, yOffset)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
  end

  local function DB() return GetDB() end
  local function CDB() return GetCharDB() end

  AddTitle("Auto Instance Log")

  local statusLine = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  statusLine:SetPoint("TOPLEFT", 16, y)
  statusLine:SetJustifyH("LEFT")
  statusLine:SetText("Status: ...")
  y = y - 24

  AddSub("Auto-enable combat logging in dungeons/raids with Mythic+ and raid difficulty filters.")
  AddSpacer(6)

  AddCheck("Enabled", "Master enable for addon behavior.", function() return DB().enabled end, function(v) DB().enabled = v end)
  AddCheck("Enable for this character (participate)", "If off, this character will never be auto-logged.", function() return CDB().participate end, function(v) CDB().participate = v end)

  AddDropdown("Output:", { "chat", "errors" }, function() return DB().output end, function(v) DB().output = v end)
  AddDropdown("Quiet mode:", { "off", "auto", "all" }, function() return DB().quietMode end, function(v) DB().quietMode = v end)
  AddCheck("Suppress auto ENABLE message", "Hide the automatic 'combat logging enabled' message.", function() return DB().suppressAutoEnable end, function(v) DB().suppressAutoEnable = v end)
  AddCheck("Suppress auto DISABLE message", "Hide the automatic 'combat logging disabled' message.", function() return DB().suppressAutoDisable end, function(v) DB().suppressAutoDisable = v end)

  AddDropdown("Logging Mode:", { "both", "raids", "dungeons" }, function() return DB().mode end, function(v) DB().mode = v end)

  AddCheck("Only log when grouped", "If enabled, will only log when you are in a group/raid.", function() return DB().onlyWhenGrouped end, function(v) DB().onlyWhenGrouped = v end)
  AddCheck("Max level only", "Only enable logging at current max level.", function() return DB().onlyMaxLevel end, function(v) DB().onlyMaxLevel = v end)
  AddCheck("Mythic+ only (dungeons)", "Only enable logging in M+ keystone dungeons.", function() return DB().mythicPlusOnly end, function(v) DB().mythicPlusOnly = v end)

  AddSpacer(6)
  local raidHeader = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  raidHeader:SetPoint("TOPLEFT", 16, y)
  raidHeader:SetText("Raid difficulties to log:")
  y = y - 24

  AddCheck("LFR", "Enable logging in LFR raids.", function() return DB().raidAllowLFR end, function(v) DB().raidAllowLFR = v end)
  AddCheck("Normal", "Enable logging in Normal raids.", function() return DB().raidAllowNormal end, function(v) DB().raidAllowNormal = v end)
  AddCheck("Heroic", "Enable logging in Heroic raids.", function() return DB().raidAllowHeroic end, function(v) DB().raidAllowHeroic = v end)
  AddCheck("Mythic", "Enable logging in Mythic raids.", function() return DB().raidAllowMythic end, function(v) DB().raidAllowMythic = v end)

  AddSpacer(6)
  AddCheck("Respect manual logging (ownership)", "If combat logging was already ON when you enter, treat it as manual and never auto-disable it.", function() return DB().respectManualLogging end, function(v) DB().respectManualLogging = v end)
  AddCheck("Disable logging when leaving (addon-owned only)", "Only disable if the addon enabled it.", function() return DB().disableWhenLeavingLogged end, function(v) DB().disableWhenLeavingLogged = v end)
  AddCheck("Disable on leaving ANY instance if logging is ON (quiet)", "Overrides manual ownership and disables logging on leaving any instance.", function() return DB().disableOnLeaveAnyIfEnabled end, function(v) DB().disableOnLeaveAnyIfEnabled = v end)
  AddCheck("Reset logging boundary on instance swap", "On dungeon↔raid swaps, disable then re-enable to ensure clean boundaries.", function() return DB().resetOnInstanceSwap end, function(v) DB().resetOnInstanceSwap = v end)
  AddCheck("Force boundary even if manual logging is ON", "If logging is already ON when entering an eligible instance, briefly toggle OFF→ON to make a clean boundary.", function() return DB().forceBoundaryEvenIfManual end, function(v) DB().forceBoundaryEvenIfManual = v end)

  AddCheck("Enable Advanced Combat Logging", "Sets AdvancedCombatLogging=1 when enabling logging.", function() return DB().advancedCombatLogging end, function(v) DB().advancedCombatLogging = v end)

  AddSpacer(6)
  local delaysHeader = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  delaysHeader:SetPoint("TOPLEFT", 16, y)
  delaysHeader:SetText("Delays (seconds):")
  y = y - 20

  local enableEdit = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
  enableEdit:SetAutoFocus(false)
  enableEdit:SetSize(60, 20)
  enableEdit:SetPoint("TOPLEFT", 16, y)
  enableEdit:SetText(tostring(DB().enableDelaySeconds))
  local enableLbl = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  enableLbl:SetPoint("LEFT", enableEdit, "RIGHT", 8, 0)
  enableLbl:SetText("Enable delay")

  local disableEdit = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
  disableEdit:SetAutoFocus(false)
  disableEdit:SetSize(60, 20)
  disableEdit:SetPoint("TOPLEFT", 220, y)
  disableEdit:SetText(tostring(DB().disableDelaySeconds))
  local disableLbl = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  disableLbl:SetPoint("LEFT", disableEdit, "RIGHT", 8, 0)
  disableLbl:SetText("Disable delay")

  local function ApplyDelayBoxes()
    local db = GetDB()
    local a = tonumber(enableEdit:GetText() or "") or DEFAULTS.enableDelaySeconds
    local b = tonumber(disableEdit:GetText() or "") or DEFAULTS.disableDelaySeconds
    if a < 0 then a = 0 end
    if b < 0 then b = 0 end
    db.enableDelaySeconds = a
    db.disableDelaySeconds = b
    DebouncedApply()
  end

  enableEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus(); ApplyDelayBoxes() end)
  enableEdit:SetScript("OnEditFocusLost", function() ApplyDelayBoxes() end)
  disableEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus(); ApplyDelayBoxes() end)
  disableEdit:SetScript("OnEditFocusLost", function() ApplyDelayBoxes() end)

  y = y - 40

  -- Buttons row
  local buttonsY = y
  AddButton("Test (dry run)", 16, buttonsY, function() DryRunReport("settings") end)
  AddButton("Export", 190, buttonsY, function()
    local s = SerializeDB()
    PrintAlways("|cffffff00AutoInstanceLog:|r Export string created.")
    StaticPopup_Show("AUTOINSTANCELOG_EXPORT", nil, nil, s)
  end)
  AddButton("Import", 364, buttonsY, function() StaticPopup_Show("AUTOINSTANCELOG_IMPORT") end)
  y = y - 34

  AddButton("Open Custom UI (/autolog ui)", 16, y, function()
    -- open custom UI
    SlashCmdList["AUTOINSTANCELOG"]("ui")
  end)
  AddButton("Apply Preset: RaidProg", 190, y, function() ApplyPreset("raidprog") end)
  AddButton("Apply Preset: M+", 364, y, function() ApplyPreset("mplus") end)
  y = y - 34

  local syncLabel = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  syncLabel:SetPoint("TOPLEFT", 16, y)
  syncLabel:SetText("Scope + Sync:")
  y = y - 22

  AddCheck("Per-character settings (instead of account-wide)", "Settings scope selector (account vs character).", function() return AutoInstanceLogDB.perCharacter end, function(v) AutoInstanceLogDB.perCharacter = v end)

  AddButton("Copy THIS scope → OTHER", 16, y, function()
    EnsureDBs()
    local from = GetDB()
    local to = GetOtherScopeDB()
    ShallowCopyDefaults(from, to)
    PrintConfirm("|cffffff00AutoInstanceLog:|r Copied " .. GetScopeName() .. " → OTHER scope.")
    DebouncedApply()
  end)

  AddButton("Reset OTHER scope defaults", 190, y, function()
    EnsureDBs()
    local to = GetOtherScopeDB()
    ResetToDefaults(to)
    PrintConfirm("|cffffff00AutoInstanceLog:|r Reset OTHER scope to defaults.")
    DebouncedApply()
  end)

  AddButton("Reset THIS scope defaults", 364, y, function()
    EnsureDBs()
    ResetToDefaults(GetDB())
    PrintConfirm("|cffffff00AutoInstanceLog:|r Reset " .. GetScopeName() .. " to defaults.")
    DebouncedApply()
  end)

  y = y - 44

  local help = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  help:SetPoint("TOPLEFT", 16, y)
  help:SetJustifyH("LEFT")
  help:SetText("Commands: /autolog help   |   Tip: /autolog debug shows instanceID & difficultyID")
  y = y - 34

  content:SetHeight(math.abs(y) + 120)

  local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
  Settings.RegisterAddOnCategory(category)
  STATE.settingsCategory = category

  -- Live status updater while shown
  local ticker = nil
  panel:SetScript("OnShow", function()
    local w = scrollFrame:GetWidth()
    if w and w > 1 then content:SetWidth(w) end
    if ticker then ticker:Cancel() ticker = nil end

    local function refresh()
      local snap = GetStatusSnapshot()
      statusLine:SetText(
        string.format(
          "Status: logging=%s | owner=%s | desired=%s | type=%s | diffID=%s | instID=%s",
          boolStr(snap.logging), snap.owner, (snap.desired and "YES" or "NO"),
          snap.instanceType, snap.difficultyID, snap.instanceID
        )
      )
    end

    refresh()
    ticker = C_Timer.NewTicker(1.0, refresh)
  end)
  panel:SetScript("OnHide", function()
    if ticker then ticker:Cancel() ticker = nil end
  end)
end

-- ============================================================
-- Custom configuration window (/autolog ui) with tabs + scrolling
-- ============================================================
local function StopCfgTicker()
  if STATE.cfgTicker then
    STATE.cfgTicker:Cancel()
    STATE.cfgTicker = nil
  end
end

local function SaveCfgPosition()
  local db = GetDB()
  local frame = STATE.cfgFrame
  if not frame then return end
  local p, _, rp, x, y = frame:GetPoint(1)
  db.uiPoint, db.uiRelPoint = p or "CENTER", rp or "CENTER"
  db.uiX, db.uiY = x or 0, y or 0
  db.uiW, db.uiH = frame:GetWidth(), frame:GetHeight()
end

local function ApplyCfgPosition()
  local db = GetDB()
  local frame = STATE.cfgFrame
  if not frame then return end

  frame:ClearAllPoints()
  frame:SetPoint(db.uiPoint or "CENTER", UIParent, db.uiRelPoint or "CENTER", db.uiX or 0, db.uiY or 0)

  local w = tonumber(db.uiW) or DEFAULTS.uiW
  local h = tonumber(db.uiH) or DEFAULTS.uiH
  if w < 420 then w = 420 end
  if h < 320 then h = 320 end
  frame:SetSize(w, h)
end

local function SetCfgLocked(locked)
  local db = GetDB()
  db.uiLocked = locked and true or false

  local frame = STATE.cfgFrame
  if not frame then return end

  if db.uiLocked then
    frame:SetMovable(false)
    frame:EnableMouse(false)
  else
    frame:SetMovable(true)
    frame:EnableMouse(true)
  end
end

local function BuildConfigTabContent(parent, tabIndex, refreshStatusFn)
  -- Clear old children (except the scroll frame itself structure is rebuilt by caller)
  local db = GetDB()
  local cdb = GetCharDB()

  local y = -16

  local function AddTitle(text)
    local t = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    t:SetPoint("TOPLEFT", 16, y)
    t:SetText(text)
    y = y - 28
    return t
  end

  local function AddSection(text)
    local s = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    s:SetPoint("TOPLEFT", 16, y)
    s:SetText(text)
    y = y - 22
    return s
  end

  local function AddSub(text)
    local s = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    s:SetPoint("TOPLEFT", 16, y)
    s:SetJustifyH("LEFT")
    s:SetText(text)
    y = y - 18
    return s
  end

  local function AddSpacer(px) y = y - (px or 10) end

  local function AddCheck(label, tip, getf, setf)
    local cb = CreateFrame("CheckButton", nil, parent, "InterfaceOptionsCheckButtonTemplate")
    cb:SetPoint("TOPLEFT", 16, y)
    cb.Text:SetText(label)
    cb.tooltipText = tip
    cb:SetChecked(getf())
    cb:SetScript("OnClick", function(self)
      setf(self:GetChecked())
      DebouncedApply()
      if refreshStatusFn then refreshStatusFn() end
    end)
    y = y - 28
    return cb
  end

  local function AddDropdown(labelText, values, getf, setf)
    local label = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    label:SetPoint("TOPLEFT", 16, y)
    label:SetText(labelText)

    local dd = CreateFrame("Frame", nil, parent, "UIDropDownMenuTemplate")
    dd:SetPoint("TOPLEFT", label, "BOTTOMLEFT", -16, -6)

    local function SetValue(v)
      setf(v)
      UIDropDownMenu_SetText(dd, v)
      DebouncedApply()
      if refreshStatusFn then refreshStatusFn() end
    end

    UIDropDownMenu_Initialize(dd, function(self, level)
      for _, v in ipairs(values) do
        local info = UIDropDownMenu_CreateInfo()
        info.text = v
        info.func = function() SetValue(v) end
        info.checked = (getf() == v)
        UIDropDownMenu_AddButton(info, level)
      end
    end)

    UIDropDownMenu_SetText(dd, getf())
    y = y - 62
    return dd
  end

  local function AddButton(text, x, yOffset, onClick, w)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w or 160, 22)
    b:SetPoint("TOPLEFT", x, yOffset)
    b:SetText(text)
    b:SetScript("OnClick", function()
      onClick()
      if refreshStatusFn then refreshStatusFn() end
    end)
    return b
  end

  if tabIndex == 1 then
    AddTitle("Auto Instance Log - General")

    AddSub("Quick settings for enabling/disabling and basic behavior.")
    AddSpacer(6)

    AddCheck("Enabled", "Master enable for addon behavior.", function() return db.enabled end, function(v) db.enabled = v end)
    AddCheck("Enable for this character (participate)", "If off, this character will never be auto-logged.", function() return cdb.participate end, function(v) cdb.participate = v end)

    AddDropdown("Logging Mode:", { "both", "raids", "dungeons" }, function() return db.mode end, function(v) db.mode = v end)

    AddCheck("Only log when grouped", "If enabled, will only log when you are in a group/raid.", function() return db.onlyWhenGrouped end, function(v) db.onlyWhenGrouped = v end)
    AddCheck("Max level only", "Only enable logging at current max level.", function() return db.onlyMaxLevel end, function(v) db.onlyMaxLevel = v end)

    AddDropdown("Output:", { "chat", "errors" }, function() return db.output end, function(v) db.output = v end)
    AddDropdown("Quiet mode:", { "off", "auto", "all" }, function() return db.quietMode end, function(v) db.quietMode = v end)
    AddCheck("Suppress auto ENABLE message", "Hide automatic enable messages.", function() return db.suppressAutoEnable end, function(v) db.suppressAutoEnable = v end)
    AddCheck("Suppress auto DISABLE message", "Hide automatic disable messages.", function() return db.suppressAutoDisable end, function(v) db.suppressAutoDisable = v end)

    AddSpacer(6)
    local by = y - 4
    AddButton("Test (dry run)", 16, by, function() DryRunReport("ui") end)
    AddButton("Preset: RaidProg", 190, by, function() ApplyPreset("raidprog") end)
    AddButton("Preset: M+ Only", 364, by, function() ApplyPreset("mplus") end)
    y = by - 34

    AddButton("Open Blizzard Settings", 16, y, function() TryOpenBlizzardSettings() end, 220)
    AddButton("Export", 250, y, function()
      local s = SerializeDB()
      StaticPopup_Show("AUTOINSTANCELOG_EXPORT", nil, nil, s)
      PrintAlways("|cffffff00AutoInstanceLog:|r Export string created.")
    end, 160)
    AddButton("Import", 424, y, function() StaticPopup_Show("AUTOINSTANCELOG_IMPORT") end, 160)
    y = y - 34

  elseif tabIndex == 2 then
    AddTitle("Filters")

    AddSub("Control what instances cause logging.")
    AddSpacer(6)

    AddCheck("Mythic+ only (dungeons)", "Only enable logging in M+ keystone dungeons.", function() return db.mythicPlusOnly end, function(v) db.mythicPlusOnly = v end)

    AddSpacer(4)
    AddSection("Raid difficulties to log:")
    AddCheck("LFR", "Enable logging in LFR raids.", function() return db.raidAllowLFR end, function(v) db.raidAllowLFR = v end)
    AddCheck("Normal", "Enable logging in Normal raids.", function() return db.raidAllowNormal end, function(v) db.raidAllowNormal = v end)
    AddCheck("Heroic", "Enable logging in Heroic raids.", function() return db.raidAllowHeroic end, function(v) db.raidAllowHeroic = v end)
    AddCheck("Mythic", "Enable logging in Mythic raids.", function() return db.raidAllowMythic end, function(v) db.raidAllowMythic = v end)

    AddSpacer(6)
    AddSection("Optional instance types:")
    AddCheck("Log scenarios", "Enable logging in scenario instances.", function() return db.logScenario end, function(v) db.logScenario = v end)
    AddCheck("Log battlegrounds", "Enable logging in pvp instances.", function() return db.logPvP end, function(v) db.logPvP = v end)
    AddCheck("Log arenas", "Enable logging in arena instances.", function() return db.logArena end, function(v) db.logArena = v end)

  elseif tabIndex == 3 then
    AddTitle("Advanced")

    AddSub("Ownership, boundary, and timing behavior.")
    AddSpacer(6)

    AddCheck("Respect manual logging (ownership)", "If logging is ON when you enter, treat it as manual and never auto-disable.", function() return db.respectManualLogging end, function(v) db.respectManualLogging = v end)
    AddCheck("Disable when leaving (addon-owned only)", "Only disable when addon enabled logging.", function() return db.disableWhenLeavingLogged end, function(v) db.disableWhenLeavingLogged = v end)
    AddCheck("Disable on leaving ANY instance if logging is ON (quiet)", "Forces logging OFF on leaving any instance even if manually enabled.", function() return db.disableOnLeaveAnyIfEnabled end, function(v) db.disableOnLeaveAnyIfEnabled = v end)

    AddSpacer(4)
    AddCheck("Reset logging boundary on instance swap", "On dungeon↔raid swaps, disable then re-enable to create clean boundaries.", function() return db.resetOnInstanceSwap end, function(v) db.resetOnInstanceSwap = v end)
    AddCheck("Force boundary even if manual logging is ON", "If logging already ON entering an eligible instance, briefly toggle OFF→ON.", function() return db.forceBoundaryEvenIfManual end, function(v) db.forceBoundaryEvenIfManual = v end)

    AddSpacer(4)
    AddCheck("Enable Advanced Combat Logging", "Sets AdvancedCombatLogging=1 when enabling logging.", function() return db.advancedCombatLogging end, function(v) db.advancedCombatLogging = v end)

    AddSpacer(8)
    AddSection("Delays (seconds):")

    local enableEdit = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    enableEdit:SetAutoFocus(false)
    enableEdit:SetSize(60, 20)
    enableEdit:SetPoint("TOPLEFT", 16, y)
    enableEdit:SetText(tostring(db.enableDelaySeconds))
    local enableLbl = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    enableLbl:SetPoint("LEFT", enableEdit, "RIGHT", 8, 0)
    enableLbl:SetText("Enable delay")
    y = y - 30

    local disableEdit = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    disableEdit:SetAutoFocus(false)
    disableEdit:SetSize(60, 20)
    disableEdit:SetPoint("TOPLEFT", 16, y)
    disableEdit:SetText(tostring(db.disableDelaySeconds))
    local disableLbl = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    disableLbl:SetPoint("LEFT", disableEdit, "RIGHT", 8, 0)
    disableLbl:SetText("Disable delay")
    y = y - 30

    local function ApplyDelayBoxes()
      local a = tonumber(enableEdit:GetText() or "") or DEFAULTS.enableDelaySeconds
      local b = tonumber(disableEdit:GetText() or "") or DEFAULTS.disableDelaySeconds
      if a < 0 then a = 0 end
      if b < 0 then b = 0 end
      db.enableDelaySeconds = a
      db.disableDelaySeconds = b
      DebouncedApply()
    end

    enableEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus(); ApplyDelayBoxes() end)
    enableEdit:SetScript("OnEditFocusLost", function() ApplyDelayBoxes() end)
    disableEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus(); ApplyDelayBoxes() end)
    disableEdit:SetScript("OnEditFocusLost", function() ApplyDelayBoxes() end)

    AddSpacer(8)
    AddSection("Custom UI window:")
    AddCheck("Lock window", "Prevents dragging/click-through on the custom UI window frame.", function() return db.uiLocked end, function(v) SetCfgLocked(v) end)

  elseif tabIndex == 4 then
    AddTitle("Scope + Tools")

    AddSub("Manage account/character scope and import/export.")
    AddSpacer(6)

    AddSection("Scope:")
    AddCheck("Per-character settings", "If checked, uses per-character settings. Otherwise account-wide.", function() return AutoInstanceLogDB.perCharacter end, function(v) AutoInstanceLogDB.perCharacter = v end)

    AddSpacer(6)
    AddSection("Copy / Reset:")

    local by = y - 4
    AddButton("Copy THIS → OTHER", 16, by, function()
      EnsureDBs()
      local from = GetDB()
      local to = GetOtherScopeDB()
      ShallowCopyDefaults(from, to)
      PrintConfirm("|cffffff00AutoInstanceLog:|r Copied " .. GetScopeName() .. " → OTHER scope.")
      DebouncedApply()
    end, 200)

    AddButton("Reset THIS defaults", 230, by, function()
      EnsureDBs()
      ResetToDefaults(GetDB())
      PrintConfirm("|cffffff00AutoInstanceLog:|r Reset " .. GetScopeName() .. " to defaults.")
      DebouncedApply()
    end, 200)

    AddButton("Reset OTHER defaults", 444, by, function()
      EnsureDBs()
      ResetToDefaults(GetOtherScopeDB())
      PrintConfirm("|cffffff00AutoInstanceLog:|r Reset OTHER scope to defaults.")
      DebouncedApply()
    end, 200)

    y = by - 34

    AddSpacer(6)
    AddSection("Export / Import:")
    local by2 = y - 4
    AddButton("Export", 16, by2, function()
      local s = SerializeDB()
      StaticPopup_Show("AUTOINSTANCELOG_EXPORT", nil, nil, s)
      PrintAlways("|cffffff00AutoInstanceLog:|r Export string created.")
    end, 200)
    AddButton("Import", 230, by2, function()
      StaticPopup_Show("AUTOINSTANCELOG_IMPORT")
    end, 200)
    AddButton("Test (dry run)", 444, by2, function()
      DryRunReport("ui-tools")
    end, 200)
    y = by2 - 34
  end

  parent:SetHeight(math.abs(y) + 100)
end

local function CreateOrShowConfigWindow()
  EnsurePopups()
  EnsureDBs()

  if STATE.cfgFrame and STATE.cfgFrame:IsShown() then
    STATE.cfgFrame:Hide()
    return
  end

  if not STATE.cfgFrame then
    local frame = CreateFrame("Frame", "AutoInstanceLogConfigFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetClampedToScreen(true)
    frame:SetResizeBounds(420, 320, 1000, 900)
    frame:SetResizable(true)

    frame.TitleText:SetText("Auto Instance Log")

    -- drag
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self)
      if GetDB().uiLocked then return end
      self:StartMoving()
    end)
    frame:SetScript("OnDragStop", function(self)
      self:StopMovingOrSizing()
      SaveCfgPosition()
    end)

    -- resize handle (simple)
    local sizer = CreateFrame("Button", nil, frame)
    sizer:SetSize(16, 16)
    sizer:SetPoint("BOTTOMRIGHT", -6, 6)
    sizer:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    sizer:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    sizer:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    sizer:SetScript("OnMouseDown", function()
      frame:StartSizing("BOTTOMRIGHT")
    end)
    sizer:SetScript("OnMouseUp", function()
      frame:StopMovingOrSizing()
      SaveCfgPosition()
    end)

    -- Status line
    local status = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    status:SetPoint("TOPLEFT", 16, -32)
    status:SetJustifyH("LEFT")
    status:SetText("Status: ...")

    -- Tabs
    PanelTemplates_SetNumTabs(frame, 4)

    local tabNames = { "General", "Filters", "Advanced", "Scope/Tools" }
    frame.tabs = {}

    for i = 1, 4 do
      local tab = CreateFrame("Button", nil, frame, "CharacterFrameTabButtonTemplate")
      tab:SetID(i)
      tab:SetText(tabNames[i])
      tab:SetScript("OnClick", function(self)
        local db = GetDB()
        db.uiLastTab = self:GetID()
        PanelTemplates_SetTab(frame, db.uiLastTab)
        frame:RefreshTab()
        SaveCfgPosition()
      end)
      frame.tabs[i] = tab
    end

    frame.tabs[1]:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 8, 2)
    frame.tabs[2]:SetPoint("LEFT", frame.tabs[1], "RIGHT", -14, 0)
    frame.tabs[3]:SetPoint("LEFT", frame.tabs[2], "RIGHT", -14, 0)
    frame.tabs[4]:SetPoint("LEFT", frame.tabs[3], "RIGHT", -14, 0)

    -- Scroll area
    local scrollFrame = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 12, -56)
    scrollFrame:SetPoint("BOTTOMRIGHT", -30, 12)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(1, 1)
    scrollFrame:SetScrollChild(content)

    -- Keep width synced
    frame:SetScript("OnSizeChanged", function()
      local w = scrollFrame:GetWidth()
      if w and w > 1 then content:SetWidth(w) end
      SaveCfgPosition()
    end)

    local function refreshStatus()
      local snap = GetStatusSnapshot()
      status:SetText(string.format(
        "Status: logging=%s | owner=%s | desired=%s | type=%s | diffID=%s | instID=%s",
        boolStr(snap.logging), snap.owner, (snap.desired and "YES" or "NO"),
        snap.instanceType, snap.difficultyID, snap.instanceID
      ))
    end

    frame.RefreshTab = function()
      -- clear children of content
      local kids = { content:GetChildren() }
      for _, k in ipairs(kids) do k:Hide() k:SetParent(nil) end

      local tabIndex = GetDB().uiLastTab or 1
      BuildConfigTabContent(content, tabIndex, refreshStatus)

      local w = scrollFrame:GetWidth()
      if w and w > 1 then content:SetWidth(w) end
      refreshStatus()
    end

    frame:SetScript("OnShow", function()
      ApplyCfgPosition()
      PanelTemplates_SetTab(frame, GetDB().uiLastTab or 1)
      frame:RefreshTab()
      refreshStatus()
      StopCfgTicker()
      STATE.cfgTicker = C_Timer.NewTicker(1.0, refreshStatus)
      SetCfgLocked(GetDB().uiLocked)
    end)

    frame:SetScript("OnHide", function()
      StopCfgTicker()
      SaveCfgPosition()
    end)

    STATE.cfgFrame = frame
  end

  STATE.cfgFrame:Show()
end

-- ============================================================
-- Slash handlers
-- ============================================================
local function HandleSlash(input)
  EnsureDBs()
  local db = GetDB()
  local charDB = GetCharDB()
  input = trim((input or ""):lower())

  if input == "" or input == "help" then ShowHelp(); return end
  if input == "status" then ShowStatus(); return end
  if input == "debug" then ShowDebug(); return end
  if input == "test" then DryRunReport("slash"); return end
  if input == "ui" then CreateOrShowConfigWindow(); return end

  if input == "on" then
    db.enabled = true
    PrintConfirm("|cff00ff00AutoInstanceLog:|r Enabled.")
    DebouncedApply()
    return
  end

  if input == "off" then
    db.enabled = false
    PrintConfirm("|cffff5555AutoInstanceLog:|r Disabled.")
    CancelRecheck()
    CancelEnableDisableTimers()
    if db.disableWhenLeavingLogged and STATE.addonEnabledLogging and (not STATE.manualOwnedLogging) then
      DisableCombatLogging(db, true)
    end
    return
  end

  if input == "toggle" then
    db.enabled = not db.enabled
    PrintConfirm("|cffffff00AutoInstanceLog:|r Enabled=" .. tostring(db.enabled))
    DebouncedApply()
    return
  end

  if input:match("^preset%s+") then
    local p = input:match("^preset%s+(%S+)$") or ""
    if not ApplyPreset(p) then
      PrintAlways("|cffffff00AutoInstanceLog:|r Usage: /autolog preset raidprog|mplus")
    end
    return
  end

  if input:match("^quiet%s+") then
    local arg = input:match("^quiet%s+(%S+)$")
    if arg == "off" or arg == "auto" or arg == "all" then
      db.quietMode = arg
      PrintConfirm("|cffffff00AutoInstanceLog:|r quietMode=" .. arg)
      return
    end
  end

  if input == "quiet" then
    if db.quietMode == "off" then db.quietMode = "auto"
    elseif db.quietMode == "auto" then db.quietMode = "all"
    else db.quietMode = "off" end
    PrintConfirm("|cffffff00AutoInstanceLog:|r quietMode=" .. db.quietMode)
    return
  end

  if input:match("^quietenable%s+") then
    local arg = input:match("^quietenable%s+(%S+)$")
    db.suppressAutoEnable = (arg == "on" or arg == "1" or arg == "true")
    PrintConfirm("|cffffff00AutoInstanceLog:|r suppressAutoEnable=" .. tostring(db.suppressAutoEnable))
    return
  end

  if input:match("^quietdisable%s+") then
    local arg = input:match("^quietdisable%s+(%S+)$")
    db.suppressAutoDisable = (arg == "on" or arg == "1" or arg == "true")
    PrintConfirm("|cffffff00AutoInstanceLog:|r suppressAutoDisable=" .. tostring(db.suppressAutoDisable))
    return
  end

  if input:match("^output%s+") then
    local arg = input:match("^output%s+(%S+)$")
    if arg == "chat" or arg == "errors" then
      db.output = arg
      PrintConfirm("|cffffff00AutoInstanceLog:|r output=" .. arg)
      return
    end
    PrintAlways("|cffffff00AutoInstanceLog:|r Usage: /autolog output chat|errors")
    return
  end

  if input == "both" or input == "raids" or input == "dungeons" then
    db.mode = input
    PrintConfirm("|cffffff00AutoInstanceLog:|r mode=" .. input)
    DebouncedApply()
    return
  end

  if input:match("^participate%s+") or input == "participate" then
    local arg = input:match("^participate%s+(%S+)$")
    if arg == nil then
      charDB.participate = not charDB.participate
    else
      charDB.participate = (arg == "on" or arg == "1" or arg == "true")
    end
    PrintConfirm("|cffffff00AutoInstanceLog:|r This character participate=" .. tostring(charDB.participate))
    DebouncedApply()
    return
  end

  if input:match("^maxlevel%s+") then
    local arg = input:match("^maxlevel%s+(%S+)$")
    db.onlyMaxLevel = (arg == "on" or arg == "1" or arg == "true")
    PrintConfirm("|cffffff00AutoInstanceLog:|r onlyMaxLevel=" .. tostring(db.onlyMaxLevel))
    DebouncedApply()
    return
  end

  if input:match("^grouped%s+") then
    local arg = input:match("^grouped%s+(%S+)$")
    db.onlyWhenGrouped = (arg == "on" or arg == "1" or arg == "true")
    PrintConfirm("|cffffff00AutoInstanceLog:|r onlyWhenGrouped=" .. tostring(db.onlyWhenGrouped))
    DebouncedApply()
    return
  end

  if input:match("^mplusonly%s+") then
    local arg = input:match("^mplusonly%s+(%S+)$")
    db.mythicPlusOnly = (arg == "on" or arg == "1" or arg == "true")
    PrintConfirm("|cffffff00AutoInstanceLog:|r mythicPlusOnly=" .. tostring(db.mythicPlusOnly))
    DebouncedApply()
    return
  end

  if input:match("^boundarymanual%s+") then
    local arg = input:match("^boundarymanual%s+(%S+)$")
    db.forceBoundaryEvenIfManual = (arg == "on" or arg == "1" or arg == "true")
    PrintConfirm("|cffffff00AutoInstanceLog:|r forceBoundaryEvenIfManual=" .. tostring(db.forceBoundaryEvenIfManual))
    DebouncedApply()
    return
  end

  if input:match("^delays%s+") then
    local which, sec = input:match("^delays%s+(%S+)%s+(%S+)$")
    local v = tonumber(sec or "")
    if not v or v < 0 then v = 0 end
    if which == "enable" then
      db.enableDelaySeconds = v
      PrintConfirm("|cffffff00AutoInstanceLog:|r enableDelaySeconds=" .. tostring(v))
      DebouncedApply()
      return
    elseif which == "disable" then
      db.disableDelaySeconds = v
      PrintConfirm("|cffffff00AutoInstanceLog:|r disableDelaySeconds=" .. tostring(v))
      DebouncedApply()
      return
    end
    PrintAlways("|cffffff00AutoInstanceLog:|r Usage: /autolog delays enable <sec> | disable <sec>")
    return
  end

  if input:match("^raidfilter%s+") then
    local which, arg = input:match("^raidfilter%s+(%S+)%s+(%S+)$")
    local on = (arg == "on" or arg == "1" or arg == "true")
    if which == "lfr" then db.raidAllowLFR = on
    elseif which == "normal" then db.raidAllowNormal = on
    elseif which == "heroic" then db.raidAllowHeroic = on
    elseif which == "mythic" then db.raidAllowMythic = on
    else
      PrintAlways("|cffffff00AutoInstanceLog:|r Usage: /autolog raidfilter lfr|normal|heroic|mythic on|off")
      return
    end
    PrintConfirm("|cffffff00AutoInstanceLog:|r raidfilter " .. which .. "=" .. tostring(on))
    DebouncedApply()
    return
  end

  if input == "reset" then
    ResetToDefaults(db)
    PrintConfirm("|cffffff00AutoInstanceLog:|r Reset defaults (" .. GetScopeName() .. ").")
    DebouncedApply()
    return
  end

  if input == "export" then
    EnsurePopups()
    local s = SerializeDB()
    PrintAlways("|cffffff00AutoInstanceLog:|r Export string created.")
    StaticPopup_Show("AUTOINSTANCELOG_EXPORT", nil, nil, s)
    return
  end

  if input == "import" then
    EnsurePopups()
    StaticPopup_Show("AUTOINSTANCELOG_IMPORT")
    return
  end

  if input:match("^scope%s+") then
    local scope = input:gsub("^scope%s+", "")
    if scope == "account" then
      AutoInstanceLogDB.perCharacter = false
      PrintConfirm("|cffffff00AutoInstanceLog:|r Scope set to ACCOUNT.")
      DebouncedApply()
      return
    elseif scope == "character" or scope == "char" then
      AutoInstanceLogDB.perCharacter = true
      PrintConfirm("|cffffff00AutoInstanceLog:|r Scope set to CHARACTER.")
      DebouncedApply()
      return
    end
    PrintAlways("|cffffff00AutoInstanceLog:|r Usage: /autolog scope account|character")
    return
  end

  PrintAlways("|cffffff00AutoInstanceLog:|r Unknown option. Try /autolog help")
end

SLASH_AUTOINSTANCELOG1 = "/autolog"
SlashCmdList["AUTOINSTANCELOG"] = HandleSlash

SLASH_AUTOINSTANCELOG2 = "/ail"
SlashCmdList["AUTOINSTANCELOG"] = HandleSlash

-- ============================================================
-- Events
-- ============================================================
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
f:RegisterEvent("ZONE_CHANGED")
f:RegisterEvent("CHALLENGE_MODE_START")

f:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
    EnsureDBs()
    EnsurePopups()
    CreateSettingsPanel()
    DebouncedApply()
    return
  end

  EnsureDBs()
  if GetDB().enabled then
    DebouncedApply()
  end
end)
