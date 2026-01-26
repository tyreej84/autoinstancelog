-- AutoInstanceLog.lua (v2.2) - adds a scrollable Options panel

local ADDON_NAME = ...
local f = CreateFrame("Frame")

-- ============================================================
-- Defaults
-- ============================================================
local DEFAULTS = {
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

  -- Level gating (only max level or not)
  onlyMaxLevel = false,

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

  -- Advanced combat logging
  advancedCombatLogging = true,

  -- Recheck insurance
  recheckSeconds = 2.5, -- 0 disables recheck

  -- Debounce
  debounceSeconds = 0.35,
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
}

-- ============================================================
-- DB helpers
-- ============================================================
local function CopyDefaultsInto(tbl, defaults)
  for k, v in pairs(defaults) do
    if tbl[k] == nil then tbl[k] = v end
  end
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
-- Utilities
-- ============================================================
local function trim(s)
  return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

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
-- Difficulty checks
-- ============================================================
local function IsMythicKeystoneDifficulty(difficultyID)
  return difficultyID == 8
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

local function IsDesiredInstance()
  EnsureDBs()
  local db = GetDB()
  local charDB = GetCharDB()

  if not db.enabled then return false end
  if not charDB.participate then return false end
  if not PassesMaxLevelGate(db) then return false end

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
        return IsMythicKeystoneDifficulty(difficultyID)
      end
      return true -- all dungeon difficulties allowed unless M+ only is on
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

local function EnableCombatLogging(db, announce)
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

-- ============================================================
-- Recheck insurance
-- ============================================================
local function CancelRecheck()
  if STATE.recheckTimer and STATE.recheckTimer.Cancel then
    STATE.recheckTimer:Cancel()
  end
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
      EnableCombatLogging(dbNow, false) -- no additional spam
    end
  end)
end

-- ============================================================
-- Instance swap boundary reset
-- ============================================================
local function ResetLoggingForNewInstance(db, shouldLogDestination)
  if not db.resetOnInstanceSwap then
    EstablishOwnershipOnEntry(db)
    if shouldLogDestination and (not STATE.manualOwnedLogging) then
      EnableCombatLogging(db, true)
      ScheduleRecheck()
    end
    return
  end

  -- Respect manual logging unless strict leave-any override OR addon already owned it
  local ownsOrStrict = (STATE.addonEnabledLogging == true) or (db.disableOnLeaveAnyIfEnabled == true)
  if db.respectManualLogging and LoggingCombat() and (not ownsOrStrict) then
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
        if not STATE.manualOwnedLogging then
          EnableCombatLogging(dbNow, true)
          ScheduleRecheck()
        end
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

      if db.disableOnLeaveAnyIfEnabled then
        DisableCombatLoggingQuietly()
        STATE.addonEnabledLogging = false
        STATE.manualOwnedLogging = false
      else
        if db.disableWhenLeavingLogged and STATE.addonEnabledLogging and (not STATE.manualOwnedLogging) then
          DisableCombatLogging(db, true)
        end
      end

      STATE.lastSig = sigNow
      return
    end

    -- Instance -> Instance swap
    if wasInInstance and nowInInstance then
      CancelRecheck()
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

    if not STATE.manualOwnedLogging then
      EnableCombatLogging(db, true)
      ScheduleRecheck()
    end
  else
    CancelRecheck()
    if db.disableWhenLeavingLogged and STATE.addonEnabledLogging and (not STATE.manualOwnedLogging) then
      DisableCombatLogging(db, true)
    end
  end

  STATE.lastSig = sigNow
end

local function DebouncedApply()
  EnsureDBs()
  local db = GetDB()
  local delay = tonumber(db.debounceSeconds) or DEFAULTS.debounceSeconds

  if STATE.pendingTimer and STATE.pendingTimer.Cancel then
    STATE.pendingTimer:Cancel()
  end

  STATE.pendingTimer = C_Timer.NewTimer(delay, function()
    STATE.pendingTimer = nil
    ApplyLoggingStateCore()
  end)
end

-- ============================================================
-- Export / Import (simple key=val; includes participate)
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
-- Dry run tester
-- ============================================================
local function DryRunReport(source)
  EnsureDBs()
  local db = GetDB()
  local charDB = GetCharDB()

  local sigNow = GetInstanceSignature()
  local sigPrev = STATE.lastSig
  local shouldLogHere = IsDesiredInstance()
  local loggingNow = LoggingCombat()
  local info = GetInstanceInfoSafe()

  local action = "No action"
  if not db.enabled then
    action = "Addon disabled"
  elseif not charDB.participate then
    action = "This character participate=OFF"
  elseif db.onlyMaxLevel and not PassesMaxLevelGate(db) then
    action = "Max-level-only gate blocks logging"
  else
    if shouldLogHere then
      action = loggingNow and "No action (already logging / manual-owned possible)" or "Would enable logging"
    else
      action = "No action"
    end
  end

  PrintAlways("|cffffff00AutoInstanceLog TEST (" .. tostring(source) .. "):|r")
  PrintAlways("  Scope=" .. GetScopeName() ..
    " participate=" .. tostring(charDB.participate) ..
    " enabled=" .. tostring(db.enabled) ..
    " onlyMaxLevel=" .. tostring(db.onlyMaxLevel) ..
    " mythicPlusOnly=" .. tostring(db.mythicPlusOnly))
  PrintAlways("  sigPrev=" .. tostring(sigPrev) .. " sigNow=" .. tostring(sigNow))
  PrintAlways("  instanceID=" .. tostring(info.instanceID) ..
    " difficultyID=" .. tostring(info.difficultyID) ..
    " desiredHere=" .. tostring(shouldLogHere))
  PrintAlways("  loggingNow=" .. tostring(loggingNow) ..
    " addonEnabledLogging=" .. tostring(STATE.addonEnabledLogging) ..
    " manualOwnedLogging=" .. tostring(STATE.manualOwnedLogging))
  PrintAlways("  action=" .. action)
end

-- ============================================================
-- Slash commands
-- ============================================================
local function ShowHelp()
  PrintAlways("|cffffff00AutoInstanceLog commands:|r")
  PrintAlways("  /autolog help | status | debug | test")
  PrintAlways("  /autolog on | off")
  PrintAlways("  /autolog quiet [off|auto|all]")
  PrintAlways("  /autolog quietenable on|off")
  PrintAlways("  /autolog quietdisable on|off")
  PrintAlways("  /autolog output chat|errors")
  PrintAlways("  /autolog both | raids | dungeons")
  PrintAlways("  /autolog participate on|off      (this character)")
  PrintAlways("  /autolog maxlevel on|off")
  PrintAlways("  /autolog mplusonly on|off")
  PrintAlways("  /autolog raidfilter lfr|normal|heroic|mythic on|off")
  PrintAlways("  /autolog reset | export | import")
  PrintAlways("  /autolog scope account|character")
end

local function ShowStatus()
  EnsureDBs()
  local db = GetDB()
  local charDB = GetCharDB()
  local info = GetInstanceInfoSafe()

  PrintAlways("|cffffff00AutoInstanceLog:|r " ..
    "Scope=" .. GetScopeName() ..
    " | Participate=" .. (charDB.participate and "ON" or "OFF") ..
    " | Enabled=" .. (db.enabled and "ON" or "OFF") ..
    " | Mode=" .. tostring(db.mode) ..
    " | MaxLevelOnly=" .. (db.onlyMaxLevel and "ON" or "OFF") ..
    " | M+Only=" .. (db.mythicPlusOnly and "ON" or "OFF") ..
    " | RaidDiff(L/N/H/M)=" .. (db.raidAllowLFR and "1" or "0") .. "/" .. (db.raidAllowNormal and "1" or "0") .. "/" .. (db.raidAllowHeroic and "1" or "0") .. "/" .. (db.raidAllowMythic and "1" or "0") ..
    " | Sig=" .. tostring(GetInstanceSignature()) ..
    " | InstID=" .. tostring(info.instanceID) ..
    " | DiffID=" .. tostring(info.difficultyID) ..
    " | Desired=" .. (IsDesiredInstance() and "YES" or "NO") ..
    " | Logging=" .. (LoggingCombat() and "ON" or "OFF"))
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
    " mythicPlusOnly=" .. tostring(db.mythicPlusOnly))
  PrintAlways("  raidAllow(LFR/Normal/Heroic/Mythic)=" ..
    tostring(db.raidAllowLFR) .. "/" .. tostring(db.raidAllowNormal) .. "/" .. tostring(db.raidAllowHeroic) .. "/" .. tostring(db.raidAllowMythic))
  PrintAlways("  respectManualLogging=" .. tostring(db.respectManualLogging) ..
    " disableWhenLeavingLogged=" .. tostring(db.disableWhenLeavingLogged) ..
    " disableOnLeaveAnyIfEnabled=" .. tostring(db.disableOnLeaveAnyIfEnabled) ..
    " resetOnInstanceSwap=" .. tostring(db.resetOnInstanceSwap))
  PrintAlways("  IsInInstance=" .. tostring(inInstance) .. " instanceType=" .. tostring(instanceType))
  PrintAlways("  instanceID=" .. tostring(info.instanceID) ..
    " difficultyID=" .. tostring(info.difficultyID) ..
    " difficultyName=" .. tostring(info.difficultyName))
  PrintAlways("  signature=" .. tostring(GetInstanceSignature()) .. " lastSig=" .. tostring(STATE.lastSig))
  PrintAlways("  desiredHere=" .. tostring(IsDesiredInstance()))
  PrintAlways("  LoggingCombat=" .. tostring(LoggingCombat()))
  PrintAlways("  addonEnabledLogging=" .. tostring(STATE.addonEnabledLogging) ..
    " manualOwnedLogging=" .. tostring(STATE.manualOwnedLogging))
end

SLASH_AUTOINSTANCELOG1 = "/autolog"
SlashCmdList["AUTOINSTANCELOG"] = function(input)
  EnsureDBs()
  local db = GetDB()
  local charDB = GetCharDB()
  input = trim((input or ""):lower())

  if input == "" or input == "help" then ShowHelp(); return end
  if input == "status" then ShowStatus(); return end
  if input == "debug" then ShowDebug(); return end
  if input == "test" then DryRunReport("slash"); return end

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
    if db.disableWhenLeavingLogged and STATE.addonEnabledLogging and (not STATE.manualOwnedLogging) then
      DisableCombatLogging(db, true)
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

  if input:match("^mplusonly%s+") then
    local arg = input:match("^mplusonly%s+(%S+)$")
    db.mythicPlusOnly = (arg == "on" or arg == "1" or arg == "true")
    PrintConfirm("|cffffff00AutoInstanceLog:|r mythicPlusOnly=" .. tostring(db.mythicPlusOnly))
    DebouncedApply()
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

-- ============================================================
-- Options panel (SCROLLING)
-- ============================================================
local function CreateOptionsPanel()
  if not Settings or not Settings.RegisterCanvasLayoutCategory then
    return
  end

  EnsurePopups()

  local panel = CreateFrame("Frame")
  panel.name = "Auto Instance Log"

  -- Scroll frame wrapper (THIS FIXES "runs off the page")
  local scrollFrame = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
  scrollFrame:SetPoint("TOPLEFT", 0, -4)
  scrollFrame:SetPoint("BOTTOMRIGHT", -27, 4)
  scrollFrame:EnableMouseWheel(true)
  scrollFrame:SetScript("OnMouseWheel", function(self, delta)
    local step = 40
    local cur = self:GetVerticalScroll()
    self:SetVerticalScroll(cur - delta * step)
  end)

  -- Content frame: all widgets parent to this
  local content = CreateFrame("Frame", nil, scrollFrame)
  content:SetSize(1, 1)
  scrollFrame:SetScrollChild(content)

  -- Helper: keep content width in sync so anchors behave
  panel:SetScript("OnShow", function()
    local w = scrollFrame:GetWidth()
    if w and w > 1 then
      content:SetWidth(w)
    end
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
    y = y - 28
    return s
  end

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

    dd:SetScript("OnShow", function()
      UIDropDownMenu_SetText(dd, getf())
    end)

    y = y - 62
    return dd
  end

  local function AddButton(text, x, yOffset, onClick)
    local b = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    b:SetSize(140, 22)
    b:SetPoint("TOPLEFT", x, yOffset)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
  end

  local function DB() return GetDB() end
  local function CDB() return GetCharDB() end

  AddTitle("Auto Instance Log")
  AddSub("Auto-enable combat logging in dungeons/raids with Mythic+ and raid difficulty filters. This panel scrolls.")

  AddCheck("Enabled", "Master enable for addon behavior.", function() return DB().enabled end, function(v) DB().enabled = v end)
  AddCheck("Enable for this character (participate)", "If off, this character will never be auto-logged.", function() return CDB().participate end, function(v) CDB().participate = v end)

  AddDropdown("Output:", { "chat", "errors" }, function() return DB().output end, function(v) DB().output = v end)
  AddDropdown("Quiet mode:", { "off", "auto", "all" }, function() return DB().quietMode end, function(v) DB().quietMode = v end)
  AddCheck("Suppress auto ENABLE message", "Hide the automatic 'combat logging enabled' message.", function() return DB().suppressAutoEnable end, function(v) DB().suppressAutoEnable = v end)
  AddCheck("Suppress auto DISABLE message", "Hide the automatic 'combat logging disabled' message.", function() return DB().suppressAutoDisable end, function(v) DB().suppressAutoDisable = v end)

  AddDropdown("Logging Mode:", { "both", "raids", "dungeons" }, function() return DB().mode end, function(v) DB().mode = v end)

  AddCheck("Max level only", "Only enable logging at current max level.", function() return DB().onlyMaxLevel end, function(v) DB().onlyMaxLevel = v end)
  AddCheck("Mythic+ only (dungeons)", "Only enable logging in M+ keystone dungeons.", function() return DB().mythicPlusOnly end, function(v) DB().mythicPlusOnly = v end)

  local raidHeader = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  raidHeader:SetPoint("TOPLEFT", 16, y)
  raidHeader:SetText("Raid difficulties to log:")
  y = y - 24

  AddCheck("LFR", "Enable logging in LFR raids.", function() return DB().raidAllowLFR end, function(v) DB().raidAllowLFR = v end)
  AddCheck("Normal", "Enable logging in Normal raids.", function() return DB().raidAllowNormal end, function(v) DB().raidAllowNormal = v end)
  AddCheck("Heroic", "Enable logging in Heroic raids.", function() return DB().raidAllowHeroic end, function(v) DB().raidAllowHeroic = v end)
  AddCheck("Mythic", "Enable logging in Mythic raids.", function() return DB().raidAllowMythic end, function(v) DB().raidAllowMythic = v end)

  AddCheck("Respect manual logging (ownership)", "If combat logging was already ON when you enter, treat it as manual and never auto-disable it.", function() return DB().respectManualLogging end, function(v) DB().respectManualLogging = v end)
  AddCheck("Disable logging when leaving (addon-owned only)", "Only disable if the addon enabled it.", function() return DB().disableWhenLeavingLogged end, function(v) DB().disableWhenLeavingLogged = v end)
  AddCheck("Disable on leaving ANY instance if logging is ON (quiet)", "Overrides manual ownership and disables logging on leaving any instance.", function() return DB().disableOnLeaveAnyIfEnabled end, function(v) DB().disableOnLeaveAnyIfEnabled = v end)
  AddCheck("Reset logging boundary on instance swap", "On dungeon↔raid swaps, disable then re-enable to ensure clean boundaries.", function() return DB().resetOnInstanceSwap end, function(v) DB().resetOnInstanceSwap = v end)

  AddCheck("Enable Advanced Combat Logging", "Sets AdvancedCombatLogging=1 when enabling logging.", function() return DB().advancedCombatLogging end, function(v) DB().advancedCombatLogging = v end)

  -- Buttons row
  local buttonsY = y - 8
  AddButton("Test (dry run)", 16, buttonsY, function() DryRunReport("options") end)
  AddButton("Export", 166, buttonsY, function()
    local s = SerializeDB()
    PrintAlways("|cffffff00AutoInstanceLog:|r Export string created.")
    StaticPopup_Show("AUTOINSTANCELOG_EXPORT", nil, nil, s)
  end)
  AddButton("Import", 316, buttonsY, function() StaticPopup_Show("AUTOINSTANCELOG_IMPORT") end)
  y = buttonsY - 36

  local syncLabel = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  syncLabel:SetPoint("TOPLEFT", 16, y)
  syncLabel:SetText("Sync settings (account/character scope):")
  y = y - 24

  AddButton("Account → Character", 16, y, function()
    EnsureDBs()
    ShallowCopyDefaults(AutoInstanceLogDB, AutoInstanceLogCharDB)
    PrintConfirm("|cffffff00AutoInstanceLog:|r Synced Account → Character.")
    DebouncedApply()
  end)

  AddButton("Character → Account", 166, y, function()
    EnsureDBs()
    ShallowCopyDefaults(AutoInstanceLogCharDB, AutoInstanceLogDB)
    PrintConfirm("|cffffff00AutoInstanceLog:|r Synced Character → Account.")
    DebouncedApply()
  end)
  y = y - 36

  AddCheck("Per-character settings (instead of account-wide)", "Settings scope selector (account vs character).", function() return AutoInstanceLogDB.perCharacter end, function(v) AutoInstanceLogDB.perCharacter = v end)

  local help = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  help:SetPoint("TOPLEFT", 16, y)
  help:SetJustifyH("LEFT")
  help:SetText("Commands: /autolog help   |   Tip: /autolog debug shows instanceID & difficultyID")
  y = y - 40

  -- IMPORTANT: set the content height so the scroll range is correct
  content:SetHeight(math.abs(y) + 80)

  local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
  Settings.RegisterAddOnCategory(category)
end

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
    CreateOptionsPanel()
    DebouncedApply()
    return
  end

  EnsureDBs()
  if GetDB().enabled then
    DebouncedApply()
  end
end)
