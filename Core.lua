-- ProfTracker: Core (data model, passive profession/recipe scans, materials math, skill-up path, slash commands)
-- PASSIVE ONLY: reads what the client already shows (skills, the profession window's recipe list) and saves it.
-- It never crafts, clicks, sends input, or calls protected functions.
local ADDON, PT = ...
_G.ProfTracker = PT

PT.SCHEMA = 2
PT.version = "0.1.5"
local DEBOUNCE = 0.8

local function Print(msg) DEFAULT_CHAT_FRAME:AddMessage("|cffffd100ProfTracker:|r " .. tostring(msg)) end
PT.Print = Print

local function IsSecret(v) return issecretvalue and issecretvalue(v) or false end
local function CleanStr(v) if type(v) == "string" and v ~= "" and not IsSecret(v) then return v end end
local function CleanNum(v) if type(v) == "number" and not IsSecret(v) then return v end end

------------------------------------------------------------------------
-- Difficulty. Enum.TradeskillRelativeDifficulty: 0 Optimal (orange), 1 Medium (yellow), 2 Easy (green), 3 Trivial (shown as "White": gray means junk in WoW)
------------------------------------------------------------------------
PT.DIFF = {
    [0] = { label = "Orange", color = "ff8040" }, [1] = { label = "Yellow", color = "ffff00" },
    [2] = { label = "Green", color = "40c040" },  [3] = { label = "White", color = "e6e6e6" },
}
local DIFF_BY_NAME = { optimal = 0, medium = 1, easy = 2, trivial = 3, orange = 0, yellow = 1, green = 2, white = 3, gray = 3, grey = 3 }
function PT.NormDiff(v)
    if type(v) == "number" then if v >= 0 and v <= 3 then return v end return nil end
    if type(v) == "string" then return DIFF_BY_NAME[v:lower()] end
end
function PT.DiffText(d)
    local e = PT.DIFF[d or -1]
    if not e then return "|cffaaaaaa?|r" end
    return "|cff" .. e.color .. e.label .. "|r"
end

function PT.FormatAge(ts)
    if not ts then return "never" end
    local d = time() - ts
    if d < 0 then d = 0 end
    if d < 60 then return "just now" end
    if d < 3600 then return math.floor(d / 60) .. "m ago" end
    if d < 86400 then return math.floor(d / 3600) .. "h ago" end
    return math.floor(d / 86400) .. "d ago"
end

------------------------------------------------------------------------
-- Character identity (same rules as AltStash: key = UnitGUID("player"); Forever's 2nd UnitName return is the second name)
------------------------------------------------------------------------
function PT.ComputeNames()
    local n1, n2 = UnitName("player")
    local first, second = CleanStr(n1), CleanStr(n2)
    if not first or first == "Unknown" then return nil end
    local display = second and (first .. " " .. second) or first
    local okG, g = pcall(GetUnitName, "player", true)
    g = okG and CleanStr(g) or nil
    if g and g:sub(1, #first) == first and (not second or g:find(second, 1, true)) and not g:find("-", 1, true) then display = g end
    return { name = first, secondName = second, displayName = display }
end

function PT.CurrentKey()
    if type(UnitGUID) ~= "function" then return nil end
    local ok, g = pcall(UnitGUID, "player")
    return ok and CleanStr(g) or nil
end

function PT.Suffix(key) return tostring(key or "?"):sub(-6) end

function PT.CharLabel(rec) return rec.displayName or rec.name or "?" end
function PT.UniqueLabel(key)
    local rec = PT.db.chars[key]
    if not rec then return tostring(key) end
    local label = PT.CharLabel(rec)
    for k, r in pairs(PT.db.chars) do
        if k ~= key and PT.CharLabel(r):lower() == label:lower() then return label .. " [" .. PT.Suffix(key) .. "]" end
    end
    return label
end

function PT.SortedChars()
    local keys = {}
    for k in pairs(PT.db.chars) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        local la, lb = PT.CharLabel(PT.db.chars[a]):lower(), PT.CharLabel(PT.db.chars[b]):lower()
        if la ~= lb then return la < lb end
        return a < b
    end)
    return keys
end

function PT.SortedProfs(rec)
    local names = {}
    for n in pairs(rec.profs or {}) do names[#names + 1] = n end
    table.sort(names, function(a, b)
        local pa, pb = rec.profs[a], rec.profs[b]
        if (pa.primary and true or false) ~= (pb.primary and true or false) then return pa.primary and true or false end
        return a:lower() < b:lower()
    end)
    return names
end

function PT.FindChar(text)
    text = (text or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return nil, "no character given" end
    local matches = {}
    for key, rec in pairs(PT.db.chars) do
        local terms = {}
        local function add(t) if t and t ~= "" then terms[tostring(t):lower()] = true end end
        add(key); add(rec.name); add(rec.secondName); add(rec.displayName); add(PT.Suffix(key))
        if rec.name and rec.secondName then add(rec.name .. " " .. rec.secondName) end
        if rec.realm then add((rec.name or "") .. "-" .. rec.realm); add((rec.displayName or "") .. "-" .. rec.realm) end
        if terms[text] then matches[#matches + 1] = key end
    end
    if #matches == 0 then return nil, "no saved character matches '" .. text .. "'" end
    if #matches > 1 then
        table.sort(matches)
        local parts = {}
        for _, k in ipairs(matches) do parts[#parts + 1] = string.format("%s (%s) [%s]", PT.CharLabel(PT.db.chars[k]), PT.db.chars[k].realm or "?", PT.Suffix(k)) end
        return nil, "'" .. text .. "' matches " .. #matches .. " characters. Use the full name or the [suffix]: " .. table.concat(parts, "; ")
    end
    return matches[1]
end

------------------------------------------------------------------------
-- Saved data (schema versioned)
------------------------------------------------------------------------
-- ProfTrackerDB = { schemaVersion, settings = { last = {key, prof} }, itemNames = { [itemID] = name },
--   chars = { [guid] = { guid, name, secondName, displayName, realm, class, classFile, updated,
--       profs   = { [profName] = { name, level, max, primary, skillLine, updated, recipesScanned, recipeCount } },
--       recipes = { [profName] = { [recipeID] = { id, name, diff (0-3), ups, trivial (maxTrivialLevel: skill at which it turns white; nil until rescanned), out (item id), outN, reagents = { {id=, n=} } } } } } } }
-- Schema 2 (0.1.2) adds recipe.trivial. Schema 1 data is migrated in place (nothing is lost); trivial stays nil until that profession is scanned again.
local function Migrate(db)
    if not db.schemaVersion then
        db.schemaVersion = PT.SCHEMA
        db.chars, db.settings, db.itemNames = {}, {}, {}
        return true
    end
    if db.schemaVersion > PT.SCHEMA then return false end   -- newer data: never touch it
    db.chars = db.chars or {}
    db.settings = db.settings or {}
    db.itemNames = db.itemNames or {}
    if db.schemaVersion < 2 then
        -- 0.1.2: recipes gain an optional "trivial" (maxTrivialLevel). Old data has none: leave nil, it is filled on the next scan.
        db.schemaVersion = 2
    end
    -- always: drop anything that is not a usable skill level (safe against hand-edited / odd data)
    for _, c in pairs(db.chars) do
        for _, recs in pairs((type(c) == "table" and c.recipes) or {}) do
            for _, r in pairs(type(recs) == "table" and recs or {}) do
                if type(r) == "table" and r.trivial ~= nil and not (type(r.trivial) == "number" and r.trivial > 0 and r.trivial < 1000) then r.trivial = nil end
            end
        end
    end
    return true
end
PT._Migrate = Migrate

function PT.CurrentRecord()
    local key = PT.CurrentKey()
    local names = PT.ComputeNames()
    local realm = GetRealmName and GetRealmName() or nil
    if not key or not names then return nil end
    local rec = PT.db.chars[key]
    if not rec then rec = { profs = {}, recipes = {} }; PT.db.chars[key] = rec end
    rec.profs, rec.recipes = rec.profs or {}, rec.recipes or {}
    rec.guid, rec.name, rec.secondName, rec.displayName, rec.realm = key, names.name, names.secondName, names.displayName, CleanStr(realm)
    local className, classFile = UnitClass("player")
    rec.class, rec.classFile = CleanStr(className), CleanStr(classFile)
    return rec, key
end

------------------------------------------------------------------------
-- Item names (client cache first, then what we saved; ask the client to load missing ones)
------------------------------------------------------------------------
local requested = {}
function PT.ItemName(id)
    local name
    if C_Item and C_Item.GetItemNameByID then local ok, n = pcall(C_Item.GetItemNameByID, id); if ok then name = CleanStr(n) end end
    if not name and C_Item and C_Item.GetItemInfo then local ok, n = pcall(C_Item.GetItemInfo, id); if ok then name = CleanStr(n) end end
    if name then
        if PT.db then PT.db.itemNames[id] = name end
        return name
    end
    local saved = PT.db and PT.db.itemNames[id]
    if saved then return saved end
    if not requested[id] and C_Item and C_Item.RequestLoadItemDataByID then
        requested[id] = true
        pcall(C_Item.RequestLoadItemDataByID, id)
    end
    return "Item " .. tostring(id)
end

------------------------------------------------------------------------
-- Skills. VERIFIED (wiki, Forever 1.60.1): GetProfessions(), GetProfessionInfo(index). Legacy fallback: GetNumSkillLines/GetSkillLineInfo.
------------------------------------------------------------------------
-- Profession names used to classify skill lines when the "Professions" / "Secondary Skills" headers can't be matched
-- (header text differs from the TRADE_SKILLS / SECONDARY_SKILLS globals, or a header is collapsed). English client names.
local KNOWN_PRIMARY = { Alchemy = true, Blacksmithing = true, Enchanting = true, Engineering = true, Herbalism = true, Leatherworking = true,
    Mining = true, Skinning = true, Tailoring = true, Jewelcrafting = true, Inscription = true }
local KNOWN_SECONDARY = { Cooking = true, ["First Aid"] = true, Fishing = true, Archaeology = true }
PT.KNOWN_PRIMARY, PT.KNOWN_SECONDARY = KNOWN_PRIMARY, KNOWN_SECONDARY

function PT.ReadSkills()
    local out
    if type(GetProfessions) == "function" and type(GetProfessionInfo) == "function" then
        local r = { pcall(GetProfessions) }
        if r[1] then
            out = {}
            -- returns: prof1, prof2, archaeology, fishing, cooking (any may be nil; a first-aid slot would come after)
            for i = 2, 8 do
                local idx = r[i]
                if type(idx) == "number" then
                    local ok, name, icon, level, max, _, _, skillLine = pcall(GetProfessionInfo, idx)
                    name = ok and CleanStr(name) or nil
                    if name then
                        out[#out + 1] = { name = name, level = CleanNum(level) or 0, max = CleanNum(max) or 0, primary = (i <= 3),
                            skillLine = CleanNum(skillLine), icon = CleanNum(icon) }
                    end
                end
            end
        end
    end
    if (not out or #out == 0) and type(GetNumSkillLines) == "function" and type(GetSkillLineInfo) == "function" then
        out = {}
        local section
        local okN, n = pcall(GetNumSkillLines)
        for i = 1, (okN and tonumber(n)) or 0 do
            local ok, name, header, _, rank, _, _, maxRank = pcall(GetSkillLineInfo, i)
            if ok and name then
                if header then section = (name == TRADE_SKILLS and "primary") or (name == SECONDARY_SKILLS and "secondary") or nil
                elseif section then out[#out + 1] = { name = name, level = tonumber(rank) or 0, max = tonumber(maxRank) or 0, primary = section == "primary" }
                elseif KNOWN_PRIMARY[name] or KNOWN_SECONDARY[name] then   -- header text not recognised: classify by name
                    out[#out + 1] = { name = name, level = tonumber(rank) or 0, max = tonumber(maxRank) or 0, primary = KNOWN_PRIMARY[name] == true }
                end
            end
        end
    end
    return out
end

function PT.ScanSkills()
    local rec = PT.CurrentRecord()
    if not rec then return false end
    local list = PT.ReadSkills()
    if not list then return false end
    local now = time()
    local seen = {}
    for _, s in ipairs(list) do
        seen[s.name] = true
        local p = rec.profs[s.name]
        if not p then p = { name = s.name }; rec.profs[s.name] = p end
        p.level, p.max, p.primary, p.updated = s.level, s.max, s.primary, now
        p.notInSkills = nil
        if s.skillLine then p.skillLine = s.skillLine end
    end
    if #list > 0 then   -- only prune when the client actually returned professions (it may not be ready at login)
        for name, p in pairs(rec.profs) do
            if not seen[name] then
                -- 0.1.3: never throw away scanned recipes because the skill list didn't mention the profession (name
                -- mismatch between the skill list and the profession window, collapsed header, partial list). Professions
                -- with saved recipes are kept and flagged; use /pt reset <name> to forget a character's data.
                local recipes = rec.recipes[name]
                if recipes and next(recipes) then p.notInSkills = true
                else rec.profs[name] = nil; rec.recipes[name] = nil end
            end
        end
    end
    rec.updated = now
    return true
end

------------------------------------------------------------------------
-- Recipe scan (profession window open). Three guarded read paths, chosen by what the client actually has:
--   1. C_TradeSkillUI (Mainline-style; Forever 1.60.1 ships this one per its API docs): GetAllRecipeIDs + GetRecipeInfo.
--      GetAllRecipeIDs ignores the window's filters and collapsed categories, so the scan is always complete.
--   2. Classic GetNumTradeSkills / GetTradeSkillInfo (index based; collapsed headers and filters hide rows).
--   3. Classic Craft API (old Enchanting window): GetNumCrafts / GetCraftInfo / GetCraftDisplaySkillLine.
-- If path 1 exists but returns nothing, path 2 is still tried (0.1.2 stopped at an empty path 1).
-- A scan that may be incomplete (filters / collapsed headers in paths 2-3) is MERGED into the saved list, never replaces it.
------------------------------------------------------------------------
local BASIC = (Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic) or 1

local function AddReagent(list, idx, id, n)
    id, n = CleanNum(id), CleanNum(n)
    if not id or not n or n <= 0 then return end
    local at = idx[id]
    if at then list[at].n = list[at].n + n else list[#list + 1] = { id = id, n = n }; idx[id] = #list end
end

local function ItemIDFromLink(link)
    if type(link) ~= "string" or IsSecret(link) then return nil end
    return tonumber(link:match("item:(%d+)"))
end
local function SpellIDFromLink(link)
    if type(link) ~= "string" or IsSecret(link) then return nil end
    return tonumber(link:match("enchant:(%d+)") or link:match("spell:(%d+)"))
end

local function Call(fn, ...)
    if type(fn) ~= "function" then return false end
    return pcall(fn, ...)
end

function PT.OpenProfessionView(kind)
    -- false when the window shows somebody else's recipes (linked / guild / NPC) or isn't ready
    if kind == "craft" then return true end
    local T = C_TradeSkillUI
    if not T then return true end
    for _, fn in ipairs({ "IsTradeSkillLinked", "IsTradeSkillGuild", "IsNPCCrafting" }) do
        if type(T[fn]) == "function" then
            local ok, v = pcall(T[fn])
            if ok and v == true then return false, fn end
        end
    end
    if type(T.IsTradeSkillReady) == "function" then
        local ok, v = pcall(T.IsTradeSkillReady)
        if ok and v == false then return false, "not ready" end
    end
    return true
end

-- name, level, max, primary, skillLine, source
function PT.ReadOpenProfession(kind)
    if kind == "craft" then
        local ok, name, rank, max = Call(GetCraftDisplaySkillLine)
        if ok and CleanStr(name) and name ~= "UNKNOWN" then return name, CleanNum(rank), CleanNum(max), true, nil, "GetCraftDisplaySkillLine" end
        return nil
    end
    local T = C_TradeSkillUI
    if T then
        for _, fn in ipairs({ "GetBaseProfessionInfo", "GetChildProfessionInfo" }) do
            local ok, info = Call(T[fn])
            if ok and type(info) == "table" then
                local name = (fn == "GetChildProfessionInfo" and CleanStr(info.parentProfessionName)) or CleanStr(info.professionName)
                local line = CleanNum(info.parentProfessionID) or CleanNum(info.professionID)
                if fn == "GetBaseProfessionInfo" then line = CleanNum(info.professionID) or line end
                if not name and line then
                    local okP, pinfo = Call(T.GetProfessionInfoBySkillLineID, line)
                    if okP and type(pinfo) == "table" then name = CleanStr(pinfo.parentProfessionName) or CleanStr(pinfo.professionName) end
                end
                if name then return name, CleanNum(info.skillLevel), CleanNum(info.maxSkillLevel), info.isPrimaryProfession, line, "C_TradeSkillUI." .. fn end
            end
        end
        local ok, name, rank, max = Call(T.GetTradeSkillLine)   -- 7.x-9.x
        if ok and CleanStr(name) and name ~= "UNKNOWN" then return name, CleanNum(rank), CleanNum(max), nil, nil, "C_TradeSkillUI.GetTradeSkillLine" end
    end
    local ok, name, rank, max = Call(GetTradeSkillLine)
    if ok and CleanStr(name) and name ~= "UNKNOWN" then return name, CleanNum(rank), CleanNum(max), nil, nil, "GetTradeSkillLine" end
end

-- Reagents from C_TradeSkillUI.GetRecipeSchematic (modern layout). Returns list (maybe empty), schematic table (or nil)
local function SchematicReagents(rid)
    local T = C_TradeSkillUI
    local list, idx = {}, {}
    if not (T and type(T.GetRecipeSchematic) == "function") then return list, nil end
    local ok, sch = pcall(T.GetRecipeSchematic, rid, false)
    if not ok or type(sch) ~= "table" then return list, nil end
    for _, slot in ipairs(sch.reagentSlotSchematics or {}) do
        if type(slot) == "table" and (slot.reagentType == nil or slot.reagentType == BASIC) then
            local r1 = slot.reagents and slot.reagents[1]
            if r1 then AddReagent(list, idx, r1.itemID, slot.quantityRequired) end
        end
    end
    return list, sch
end

-- Older C_TradeSkillUI reagent calls (7.0.3 - 10.0.0)
local function OldReagents(rid)
    local T = C_TradeSkillUI
    local list, idx = {}, {}
    if not (T and type(T.GetRecipeNumReagents) == "function" and type(T.GetRecipeReagentItemLink) == "function" and type(T.GetRecipeReagentInfo) == "function") then return list end
    local okN, num = pcall(T.GetRecipeNumReagents, rid)
    for i = 1, (okN and tonumber(num)) or 0 do
        local okR, _, _, count = pcall(T.GetRecipeReagentInfo, rid, i)
        local okL, link = pcall(T.GetRecipeReagentItemLink, rid, i)
        AddReagent(list, idx, okL and ItemIDFromLink(link) or nil, okR and count or nil)
    end
    return list
end

-- Legacy GetTradeSkill* reagents; those calls are index based, so the recipe is found by name.
local function LegacyIndexMap()
    if not (type(GetNumTradeSkills) == "function" and type(GetTradeSkillInfo) == "function" and type(GetTradeSkillNumReagents) == "function") then return nil end
    local okN, n = pcall(GetNumTradeSkills)
    if not okN then return nil end
    local map = {}
    for i = 1, tonumber(n) or 0 do
        local ok, name, skillType = pcall(GetTradeSkillInfo, i)
        if ok and CleanStr(name) and skillType ~= "header" and skillType ~= "subheader" and not map[name] then map[name] = i end
    end
    return map
end
local function LegacyReagentsByName(map, name)
    local list, idx = {}, {}
    local i = map and name and map[name]
    if not i then return list end
    local okR, nr = pcall(GetTradeSkillNumReagents, i)
    for j = 1, (okR and tonumber(nr)) or 0 do
        local okI, _, _, cnt = pcall(GetTradeSkillReagentInfo, i, j)
        local okL, link = pcall(GetTradeSkillReagentItemLink, i, j)
        AddReagent(list, idx, okL and ItemIDFromLink(link) or nil, okI and cnt or nil)
    end
    return list
end

-- learned == true, or (field missing) the player knows the recipe spell
local function IsLearned(rid, info)
    if info.learned == true then return true end
    if info.learned == nil and type(IsPlayerSpell) == "function" then
        local ok, v = pcall(IsPlayerSpell, rid)
        return ok and v == true
    end
    return false
end

-- Returns list of learned recipes, stats { schematic, old, legacy, none }, total ids (learned or not).
-- nil when C_TradeSkillUI (or its recipe calls) is missing or errors.
local function ModernRecipes()
    local T = C_TradeSkillUI
    if not (T and type(T.GetAllRecipeIDs) == "function" and type(T.GetRecipeInfo) == "function") then return nil end
    local ok, ids = pcall(T.GetAllRecipeIDs)
    if not ok or type(ids) ~= "table" then return nil end
    local out, stats, legacyMap = {}, { schematic = 0, old = 0, legacy = 0, none = 0 }, nil
    for _, rid in ipairs(ids) do
        local okI, info = pcall(T.GetRecipeInfo, rid)
        if okI and type(info) == "table" and not info.isDummyRecipe and IsLearned(rid, info) then
            local rec = { id = rid, name = CleanStr(info.name), diff = PT.NormDiff(info.relativeDifficulty), ups = CleanNum(info.numSkillUps) }
            -- maxTrivialLevel: skill at which this LEARNED recipe turns trivial (white). Unlearned recipes report a placeholder (300) but are never saved.
            local triv = CleanNum(info.maxTrivialLevel)
            if triv and triv > 0 and triv < 1000 then rec.trivial = triv end
            local reagents, sch = SchematicReagents(rid)
            local src = "schematic"
            if sch then
                rec.name = rec.name or CleanStr(sch.name)
                rec.out = CleanNum(sch.outputItemID)
                local qmin, qmax = CleanNum(sch.quantityMin), CleanNum(sch.quantityMax)
                rec.outN, rec.outMax = qmin or qmax, qmax or qmin
            end
            if #reagents == 0 then reagents = OldReagents(rid); src = "old" end
            if #reagents == 0 then
                if legacyMap == nil then legacyMap = LegacyIndexMap() or false end
                reagents = LegacyReagentsByName(legacyMap, rec.name); src = "legacy"
            end
            if #reagents == 0 then src = "none" end
            stats[src] = stats[src] + 1
            if not rec.out and type(T.GetRecipeItemLink) == "function" then
                local okL, link = pcall(T.GetRecipeItemLink, rid)
                if okL then rec.out = ItemIDFromLink(link) end
            end
            rec.reagents = reagents
            if rec.name then out[#out + 1] = rec end
        end
    end
    return out, stats, #ids
end

-- Classic trade skill window: expand collapsed headers (harmless, the client re-fires TRADE_SKILL_UPDATE) and report
-- whether a filter may still hide rows (then the scan is merged instead of replacing the saved list).
local function LegacyPrepare()
    local partial = {}
    local okN, n = Call(GetNumTradeSkills)
    local collapsed = false
    for i = 1, (okN and tonumber(n)) or 0 do
        local ok, _, skillType, _, isExpanded = pcall(GetTradeSkillInfo, i)
        if ok and (skillType == "header" or skillType == "subheader") and isExpanded == false then collapsed = true end
    end
    if collapsed then
        if Call(ExpandTradeSkillSubClass, 0) then
            -- re-check: some clients need the update event before rows appear
            collapsed = false
            local okN2, n2 = Call(GetNumTradeSkills)
            for i = 1, (okN2 and tonumber(n2)) or 0 do
                local ok, _, skillType, _, isExpanded = pcall(GetTradeSkillInfo, i)
                if ok and (skillType == "header" or skillType == "subheader") and isExpanded == false then collapsed = true end
            end
        end
        if collapsed then partial[#partial + 1] = "collapsed headers" end
    end
    local okF, nameFilter = Call(GetTradeSkillItemNameFilter)
    if okF and type(nameFilter) == "string" and nameFilter ~= "" then partial[#partial + 1] = "search text" end
    local okS, allSub = Call(GetTradeSkillSubClassFilter, 0)
    if okS and allSub ~= nil and not allSub then partial[#partial + 1] = "subclass filter" end
    local okI, allSlot = Call(GetTradeSkillInvSlotFilter, 0)
    if okI and allSlot ~= nil and not allSlot then partial[#partial + 1] = "slot filter" end
    local cb = _G.TradeSkillFrameAvailableFilterCheckButton
    if cb and type(cb.GetChecked) == "function" then
        local okC, on = pcall(cb.GetChecked, cb)
        if okC and on then partial[#partial + 1] = "'Have Materials'" end
    elseif _G.TradeSkillFrame and type(_G.TradeSkillFrame.filterTbl) == "table" and _G.TradeSkillFrame.filterTbl.hasMaterials then
        partial[#partial + 1] = "'Have Materials'"
    end
    return partial
end

PT._legacyCd = {}   -- recipeID -> seconds remaining from GetTradeSkillCooldown during the last classic scan (not saved)
local function LegacyRecipes()
    if not (type(GetNumTradeSkills) == "function" and type(GetTradeSkillInfo) == "function") then return nil end
    PT._legacyCd = {}
    local partial = LegacyPrepare()
    local okN, n = pcall(GetNumTradeSkills)
    if not okN then return nil end
    local out = {}
    for i = 1, tonumber(n) or 0 do
        local ok, name, skillType = pcall(GetTradeSkillInfo, i)
        if ok and CleanStr(name) and skillType ~= "header" and skillType ~= "subheader" then
            local rec = { id = nil, name = name, diff = PT.NormDiff(skillType) }
            local okR, rlink = Call(GetTradeSkillRecipeLink, i)
            rec.id = okR and SpellIDFromLink(rlink) or nil
            local okL, link = Call(GetTradeSkillItemLink, i)
            if okL then rec.out = ItemIDFromLink(link); rec.id = rec.id or SpellIDFromLink(link) end
            rec.id = rec.id or (rec.out and -rec.out) or -i   -- stable key when the client gives no recipe link
            local okC, cd = Call(GetTradeSkillCooldown, i)       -- classic: seconds remaining, nil when none
            if okC and type(cd) == "number" and not IsSecret(cd) and cd > 0 then PT._legacyCd[rec.id] = cd end
            local reagents, idx = {}, {}
            local okRN, nr = Call(GetTradeSkillNumReagents, i)
            for j = 1, (okRN and tonumber(nr)) or 0 do
                local okI, _, _, cnt = pcall(GetTradeSkillReagentInfo, i, j)
                local okRL, rl = pcall(GetTradeSkillReagentItemLink, i, j)
                AddReagent(reagents, idx, okRL and ItemIDFromLink(rl) or nil, okI and cnt or nil)
            end
            rec.reagents = reagents
            out[#out + 1] = rec
        end
    end
    local stats = { schematic = 0, old = 0, legacy = 0, none = 0 }
    for _, r in ipairs(out) do if #r.reagents > 0 then stats.legacy = stats.legacy + 1 else stats.none = stats.none + 1 end end
    return out, stats, #out, partial
end

-- Classic Craft window (old-style Enchanting). Beast Training also uses this window: it has no skill line and is ignored.
local function CraftRecipes()
    if not (type(GetNumCrafts) == "function" and type(GetCraftInfo) == "function") then return nil end
    local partial = {}
    local okN, n = pcall(GetNumCrafts)
    if not okN then return nil end
    local collapsed = false
    for i = 1, tonumber(n) or 0 do
        local ok, _, _, craftType, _, isExpanded = pcall(GetCraftInfo, i)
        if ok and craftType == "header" and isExpanded == false then collapsed = true end
    end
    if collapsed and Call(ExpandCraftSkillLine, 0) then okN, n = pcall(GetNumCrafts) end
    local out = {}
    for i = 1, (okN and tonumber(n)) or 0 do
        local ok, name, _, craftType, _, isExpanded = pcall(GetCraftInfo, i)
        if ok and craftType == "header" and isExpanded == false then partial[1] = "collapsed headers" end
        if ok and CleanStr(name) and craftType ~= "header" and craftType ~= "subheader" then
            local rec = { name = name, diff = PT.NormDiff(craftType) }
            local okR, rlink = Call(GetCraftRecipeLink, i)
            rec.id = okR and SpellIDFromLink(rlink) or nil
            local okL, link = Call(GetCraftItemLink, i)
            if okL then rec.id = rec.id or SpellIDFromLink(link); rec.out = ItemIDFromLink(link) end
            rec.id = rec.id or (rec.out and -rec.out) or -(10000 + i)
            local reagents, idx = {}, {}
            local okRN, nr = Call(GetCraftNumReagents, i)
            for j = 1, (okRN and tonumber(nr)) or 0 do
                local okI, _, _, cnt = pcall(GetCraftReagentInfo, i, j)
                local okRL, rl = Call(GetCraftReagentItemLink, i, j)
                AddReagent(reagents, idx, okRL and ItemIDFromLink(rl) or nil, okI and cnt or nil)
            end
            rec.reagents = reagents
            out[#out + 1] = rec
        end
    end
    local stats = { schematic = 0, old = 0, legacy = 0, none = 0 }
    for _, r in ipairs(out) do if #r.reagents > 0 then stats.legacy = stats.legacy + 1 else stats.none = stats.none + 1 end end
    return out, stats, #out, partial
end
PT._ModernRecipes, PT._LegacyRecipes, PT._CraftRecipes = ModernRecipes, LegacyRecipes, CraftRecipes

-- Which read path would be used right now (for /pt debug)
function PT.ApiPath()
    local T = C_TradeSkillUI
    local parts = {}
    if T and type(T.GetAllRecipeIDs) == "function" and type(T.GetRecipeInfo) == "function" then parts[#parts + 1] = "C_TradeSkillUI" end
    if type(GetNumTradeSkills) == "function" and type(GetTradeSkillInfo) == "function" then parts[#parts + 1] = "GetTradeSkillInfo (classic)" end
    if type(GetNumCrafts) == "function" and type(GetCraftInfo) == "function" then parts[#parts + 1] = "GetCraftInfo (classic Enchanting)" end
    return #parts > 0 and table.concat(parts, " + ") or "none"
end

-- Saved name for the open profession: an existing entry with the same skill line id (or same name, any case) wins,
-- so the skill list and the profession window never split one profession into two entries.
local function CanonicalProf(rec, name, skillLine)
    if rec.profs[name] then return name end
    for n, p in pairs(rec.profs) do
        if skillLine and p.skillLine == skillLine then return n end
    end
    for n in pairs(rec.profs) do if n:lower() == name:lower() then return n end end
    return name
end

-- Scan one open window ("trade" default, or "craft"). Returns number of recipes saved, or nil + reason (+ retry flag).
-- Also stores PT.lastScan = { kind, ok, count, reason, api, prof, total, partial, when } for /pt debug.
function PT.ScanRecipes(kind)
    kind = kind or "trade"
    local function Done(n, reason, retry, extra)
        local ls = extra or {}
        ls.kind, ls.ok, ls.count, ls.reason, ls.when = kind, n ~= nil, n, reason, time()
        PT.lastScan = ls
        return n, reason, retry
    end
    local rec = PT.CurrentRecord()
    if not rec then return Done(nil, "character not known yet (UnitGUID / UnitName unavailable)", true) end
    local viewOk, why = PT.OpenProfessionView(kind)
    if not viewOk then return Done(nil, "skipped (" .. tostring(why) .. ")", why == "not ready") end
    local prof, level, max, primary, skillLine, nameSrc = PT.ReadOpenProfession(kind)
    if not prof then return Done(nil, "profession name unavailable (no profession window open?)", true) end
    local list, stats, total, partial, api
    if kind == "craft" then
        list, stats, total, partial = CraftRecipes(); api = "GetCraftInfo"
    else
        list, stats, total = ModernRecipes(); api = "C_TradeSkillUI"
        if not list or #list == 0 then
            local l2, s2, t2, p2 = LegacyRecipes()
            if l2 and (#l2 > 0 or not list) then list, stats, total, partial, api = l2, s2, t2, p2, "GetTradeSkillInfo"
            elseif not list then api = "none" end
        end
    end
    local info = { api = api, prof = prof, total = total, nameSrc = nameSrc }
    if not list then return Done(nil, "no recipe API available in this client", false, info) end
    if #list == 0 then
        return Done(nil, string.format("no learned recipes returned (%s: %s ids%s) - data not loaded yet?", api, tostring(total or 0),
            (api == "C_TradeSkillUI" and (total or 0) > 0) and ", none with learned == true" or ""), true, info)
    end
    prof = CanonicalProf(rec, prof, skillLine)
    info.prof = prof
    local old = rec.recipes[prof]
    local map = {}
    local isPartial = partial and #partial > 0
    if isPartial and type(old) == "table" then for id, r in pairs(old) do map[id] = r end end
    for _, r in ipairs(list) do
        for _, rg in ipairs(r.reagents or {}) do PT.ItemName(rg.id) end   -- remember reagent names for offline use
        local o = type(old) == "table" and old[r.id]
        if type(o) == "table" and o.cd then r.cd = true end          -- 0.1.4: "has a cooldown" is sticky across rescans
        map[r.id] = r
    end
    local count = 0
    for _ in pairs(map) do count = count + 1 end
    rec.recipes[prof] = map
    local p = rec.profs[prof]
    if not p then p = { name = prof, primary = primary and true or false }; rec.profs[prof] = p end
    if level then p.level = level end
    if max then p.max = max end
    if skillLine and not p.skillLine then p.skillLine = skillLine end
    p.notInSkills = nil
    p.recipesScanned, p.recipeCount, p.updated = time(), count, time()
    p.recipeTotal = (api == "C_TradeSkillUI") and total or nil
    p.reagentSources = stats
    p.scanApi = api
    local without = 0
    for _, r in pairs(map) do if not (r.reagents and #r.reagents > 0) then without = without + 1 end end
    p.noReagents, p.withReagents = without, count - without
    info.partial = isPartial and table.concat(partial, ", ") or nil
    pcall(PT.CaptureCooldowns, { window = (kind ~= "craft"), legacy = (api == "GetTradeSkillInfo") and PT._legacyCd or nil, all = true })
    return Done(count, nil, false, info)
end

------------------------------------------------------------------------
-- Materials: AltStash.API when loaded; otherwise only this character's bags
------------------------------------------------------------------------
local memo = {}
function PT.ResetMemo() memo = {} end

function PT.AltStashAPI()
    local AS = _G.AltStash
    local api = AS and AS.API
    if type(api) == "table" and type(api.apiVersion) == "number" and api.apiVersion >= 1 then return api end
end

-- AltStash's key for one of our characters (GUID normally; a not-yet-migrated "Name-Realm" entry otherwise)
function PT.AltStashKeyFor(ckey)
    local api = PT.AltStashAPI()
    if not api then return nil end
    local m = memo.askeys
    if not m then
        m = {}
        memo.askeys = m
        m.list = api.GetCharacters()
    end
    if m[ckey] ~= nil then return m[ckey] or nil end
    local found
    for _, c in ipairs(m.list) do if c.key == ckey then found = c.key break end end
    if not found then
        local rec = PT.db.chars[ckey]
        if rec then
            for _, c in ipairs(m.list) do
                if not (c.guid) and c.name == rec.name and (c.realm == rec.realm) then found = c.key break end
            end
        end
    end
    m[ckey] = found or false
    return found
end

local function BagCount(id)
    if C_Item and C_Item.GetItemCount then
        local ok, n = pcall(C_Item.GetItemCount, id, false)
        if ok and type(n) == "number" and not IsSecret(n) then return n end
    end
    if GetItemCount then
        local ok, n = pcall(GetItemCount, id, false)
        if ok and type(n) == "number" then return n end
    end
    return 0
end

-- Where does an item live?  { own = {bag,bank,mail}, ownTotal, others = { {key,label,bag,bank,mail,total}... }, othersTotal, noData }
-- own = the crafting character (everything it holds, soulbound included); others = every other character (tradeable units only,
-- because only those can be moved to the crafter).
function PT.Sources(itemID, ckey)
    local mk = tostring(itemID) .. "|" .. tostring(ckey)
    if memo[mk] then return memo[mk] end
    local S = { own = { bag = 0, bank = 0, mail = 0 }, ownTotal = 0, others = {}, othersTotal = 0 }
    local api = PT.AltStashAPI()
    if api then
        local akey = PT.AltStashKeyFor(ckey)
        if akey then
            local b, k, m = api.GetItemCount(akey, itemID, false)   -- the crafter's own items count even if soulbound
            S.own = { bag = b or 0, bank = k or 0, mail = m or 0 }
        end
        -- other characters: ALWAYS tradeable-only counts (soulbound units can't be moved), whatever AltStash's setting is.
        -- AltStash >= 0.2.1 (API minorVersion 1) supports "always"; an older AltStash falls back to its own setting.
        local mode = ((api.minorVersion or 0) >= 1) and "always" or true
        for _, e in ipairs(api.GetCharacterCounts(itemID, mode)) do
            if e.key ~= akey then
                S.others[#S.others + 1] = { key = e.key, label = e.uniqueLabel or e.displayName or e.name, bag = e.bag, bank = e.bank, mail = e.mail, total = e.total }
                S.othersTotal = S.othersTotal + e.total
            end
        end
        table.sort(S.others, function(a, b) if a.total ~= b.total then return a.total > b.total end return tostring(a.label) < tostring(b.label) end)
    else
        if ckey == PT.CurrentKey() then S.own.bag = BagCount(itemID) else S.noData = true end
    end
    S.ownTotal = S.own.bag + S.own.bank + S.own.mail
    memo[mk] = S
    return S
end

function PT.LocText(e)
    local p = {}
    if (e.bag or 0) > 0 then p[#p + 1] = "bags " .. e.bag end
    if (e.bank or 0) > 0 then p[#p + 1] = "bank " .. e.bank end
    if (e.mail or 0) > 0 then p[#p + 1] = "mail " .. e.mail end
    return table.concat(p, ", ")
end

-- Analyse one recipe for `crafts` crafts by crafter `ckey`.
-- Returns { known, canAll, canOwn, reagents = { {id,name,need,needTotal,own,haveAll,short,shortOwn,others,noData} }, missing = {...}, noData }
function PT.Analyze(recipe, ckey, crafts)
    crafts = math.max(1, tonumber(crafts) or 1)
    local a = { known = false, reagents = {}, missing = {}, crafts = crafts }
    if not recipe or not recipe.reagents or #recipe.reagents == 0 then return a end
    a.known = true
    local canAll, canOwn = math.huge, math.huge
    for _, rg in ipairs(recipe.reagents) do
        local S = PT.Sources(rg.id, ckey)
        local haveAll = S.ownTotal + S.othersTotal
        local needTotal = rg.n * crafts
        canAll = math.min(canAll, math.floor(haveAll / rg.n))
        canOwn = math.min(canOwn, math.floor(S.ownTotal / rg.n))
        local e = { id = rg.id, name = PT.ItemName(rg.id), need = rg.n, needTotal = needTotal, own = S.own, ownTotal = S.ownTotal,
            haveAll = haveAll, short = math.max(0, needTotal - haveAll), shortOwn = math.max(0, needTotal - S.ownTotal),
            others = S.others, othersTotal = S.othersTotal, noData = S.noData }
        a.reagents[#a.reagents + 1] = e
        if e.short > 0 then a.missing[#a.missing + 1] = e end
        if S.noData then a.noData = true end
    end
    a.canAll, a.canOwn = canAll, canOwn
    return a
end

-- "Item", "Item x2" or "Item x2-3" (recipes that make several items per craft)
function PT.MakesText(r)
    if not r.out then return nil end
    local lo, hi = r.outN, r.outMax
    local q = ""
    if lo and hi and hi > lo then q = " x" .. lo .. "-" .. hi
    elseif (lo or hi or 1) > 1 then q = " x" .. (lo or hi) end
    return PT.ItemName(r.out) .. q
end

function PT.CanText(a)
    if not a.known then return "|cff888888reagents unknown|r" end
    local own = a.noData and "n/a" or tostring(a.canOwn)
    return string.format("Can make: |cffffff00%d|r all  |cff999999(%s this char)|r", a.canAll, own)
end

------------------------------------------------------------------------
-- Recipe list (sorted: orange first, then craftable now)
------------------------------------------------------------------------
function PT.RecipeMatches(r, text)
    if not text or text == "" then return true end
    local t = text:lower()
    local id = t:match("^%d+$") and tonumber(t)
    if id and (r.id == id or r.out == id) then return true end
    if r.name and r.name:lower():find(t, 1, true) then return true end
    for _, rg in ipairs(r.reagents or {}) do
        if (id and rg.id == id) or PT.ItemName(rg.id):lower():find(t, 1, true) then return true end
    end
    return false
end

function PT.RecipeRows(ckey, prof, search, crafts)
    local rec = PT.db.chars[ckey]
    local rows = {}
    local map = rec and rec.recipes and rec.recipes[prof]
    if not map then return rows end
    for _, r in pairs(map) do
        if PT.RecipeMatches(r, search) then rows[#rows + 1] = { recipe = r, a = PT.Analyze(r, ckey, crafts) } end
    end
    table.sort(rows, function(x, y)
        local dx, dy = x.recipe.diff or 4, y.recipe.diff or 4
        if dx ~= dy then return dx < dy end
        local ox, oy = (x.a.known and x.a.canOwn or 0) > 0, (y.a.known and y.a.canOwn or 0) > 0
        if ox ~= oy then return ox end
        local ax, ay = (x.a.known and x.a.canAll or 0) > 0, (y.a.known and y.a.canAll or 0) > 0
        if ax ~= ay then return ax end
        local nx, ny = (x.recipe.name or ""):lower(), (y.recipe.name or ""):lower()
        if nx ~= ny then return nx < ny end
        return x.recipe.id < y.recipe.id
    end)
    return rows
end

-- Detail text lines for one recipe (what you have, what is missing, and which alt holds it where)
function PT.DetailLines(ckey, prof, recipeID, crafts)
    local rec = PT.db.chars[ckey]
    local r = rec and rec.recipes and rec.recipes[prof] and rec.recipes[prof][recipeID]
    if not r then return { "|cff888888Select a recipe.|r" } end
    crafts = math.max(1, tonumber(crafts) or 1)
    local a = PT.Analyze(r, ckey, crafts)
    local L = {}
    L[#L + 1] = string.format("|cffffffff%s|r  %s%s", r.name or "?", PT.DiffText(r.diff), r.ups and r.ups > 1 and (" |cff999999(" .. r.ups .. " skill-ups)|r") or "")
    local makes = PT.MakesText(r)
    if makes then L[#L + 1] = "|cff999999Makes:|r " .. makes end
    if type(r.trivial) == "number" then L[#L + 1] = "|cff999999Turns white at skill:|r " .. r.trivial .. " |cff999999(from the game; the other colour changes are only estimated)|r" end
    local cdi = PT.CooldownInfo and PT.CooldownInfo(rec, r)
    if cdi then
        if cdi.remaining > 0 then
            L[#L + 1] = string.format("|cffff6040Cooldown: %s left|r |cff999999(ready %s%s)|r", PT.FormatRemaining(cdi.remaining),
                (type(date) == "function" and date("%a %H:%M", cdi.ready)) or "", cdi.group and ", shared with all " .. cdi.group .. "s" or "")
        else
            L[#L + 1] = "|cff40ff40Cooldown: Ready|r" .. (cdi.known and "" or " |cff999999(not read yet: log in on this character)|r")
        end
    end
    if not a.known then
        L[#L + 1] = "|cff888888Reagent list not saved for this recipe (open the profession window again).|r"
        return L
    end
    L[#L + 1] = PT.CanText(a)
    if r.outN and r.outN > 1 and a.canAll then
        local hi = (r.outMax and r.outMax > r.outN) and r.outMax or r.outN
        L[#L + 1] = string.format("|cff999999Each craft makes %s: %d crafts = %s items (all chars).|r", (hi > r.outN) and (r.outN .. "-" .. hi) or r.outN, a.canAll,
            (hi > r.outN) and (a.canAll * r.outN .. "-" .. a.canAll * hi) or (a.canAll * r.outN))
    end
    L[#L + 1] = string.format("|cff33ccffMaterials for %d craft%s:|r", crafts, crafts == 1 and "" or "s")
    for _, e in ipairs(a.reagents) do
        local state
        if e.short > 0 then state = string.format("|cffff4040MISSING %d|r", e.short)
        elseif e.shortOwn > 0 then state = "|cffffff00on alts|r"
        else state = "|cff40ff40OK|r" end
        L[#L + 1] = string.format("  %s  need %d | this char %d | all chars %d  %s", e.name, e.needTotal, e.ownTotal, e.haveAll, state)
        if e.shortOwn > 0 and #e.others > 0 then
            for _, o in ipairs(e.others) do L[#L + 1] = string.format("      |cff999999from|r %s: %s", o.label, PT.LocText(o)) end
        end
    end
    if a.noData then L[#L + 1] = "|cff888888(AltStash not loaded: only the logged-in character's bags are known.)|r" end
    if #a.missing == 0 then
        L[#L + 1] = "|cff40ff40Nothing missing across all your characters.|r"
    else
        local parts = {}
        for _, e in ipairs(a.missing) do parts[#parts + 1] = e.name .. " x" .. e.short end
        L[#L + 1] = "|cffff4040Missing from every character:|r " .. table.concat(parts, ", ")
    end
    return L
end

------------------------------------------------------------------------
-- Skill-up path: "next steps", planned in stages of ~12 skill points, only with recipes this character knows.
-- Colours are the ones saved at the last scan. Stage 1 uses them as saved; each later stage assumes every recipe has dropped one
-- colour (orange -> yellow -> green -> white). Expected points per craft: orange 1, yellow 0.5, green 0.25, white 0 (estimates).
-- Real colour thresholds aren't exposed, so reopen the profession window after crafting and ask again.
-- 0.1.2: if the recipe has a saved maxTrivialLevel (the REAL skill at which it turns white), the recipe is dropped from the plan at that
-- skill (it is capped inside the stage where it turns white and never used afterwards), and it is never guessed to be white before then
-- (colour guesses stop at green). Recipes without a saved value (not rescanned yet) keep the old stage-based guess.
-- The orange->yellow and yellow->green steps stay ESTIMATES.
------------------------------------------------------------------------
local GAIN = { [0] = 1, [1] = 0.5, [2] = 0.25 }
PT.GAIN = GAIN
PT.STAGE = 12
PT.MAX_STAGES = 6
PT.DEFAULT_STAGES = 3

function PT.SkillPath(ckey, prof, target, stageSize)
    local rec = PT.db.chars[ckey]
    local p = rec and rec.profs and rec.profs[prof]
    local res = { stages = {}, steps = {}, materials = {}, cur = 0, target = 0, points = 0, remaining = 0, covered = 0 }
    if not p then res.err = "no such profession saved"; return res end
    stageSize = tonumber(stageSize) or PT.STAGE
    if stageSize < 1 then stageSize = PT.STAGE end
    res.stageSize = stageSize
    res.cur = p.level or 0
    target = tonumber(target) or (res.cur + PT.DEFAULT_STAGES * stageSize)
    if p.max and p.max > 0 and target > p.max then target = p.max end
    if target > res.cur + PT.MAX_STAGES * stageSize then target = res.cur + PT.MAX_STAGES * stageSize; res.capped = true end
    res.target = target
    res.points = math.max(0, target - res.cur)
    if res.points == 0 then res.complete = true; return res end
    local cands = {}
    for _, r in pairs((rec.recipes and rec.recipes[prof]) or {}) do
        if r.diff and r.reagents and #r.reagents > 0 then
            local units = 0
            for _, rg in ipairs(r.reagents) do units = units + rg.n end
            cands[#cands + 1] = { r = r, units = units }
        end
    end
    if #cands == 0 then res.err = "no recipes with saved reagents (open the profession window on this character)"; res.remaining = res.points; return res end
    local pool, initial, need = {}, {}, {}
    local function avail(id)
        if pool[id] == nil then local S = PT.Sources(id, ckey); pool[id] = S.ownTotal + S.othersTotal; initial[id] = pool[id] end
        return pool[id]
    end
    local from, left, s = res.cur, res.points, 0
    local uncovered = 0
    while left > 0 and s < PT.MAX_STAGES do
        local goal = math.min(stageSize, left)
        local list = {}
        for _, c in ipairs(cands) do
            local triv = c.r.trivial
            local eff
            if type(triv) == "number" then
                if from >= triv then eff = 3 else eff = math.min(2, c.r.diff + s) end   -- real white threshold; other colours estimated
            else
                eff = math.min(3, c.r.diff + s)
            end
            if GAIN[eff] then
                -- skill points this recipe can still give inside this stage before it turns white (known threshold only)
                local cap = (type(triv) == "number") and math.max(0, math.min(goal, triv - from)) or math.huge
                list[#list + 1] = { r = c.r, units = c.units, eff = eff, gain = GAIN[eff], trivial = type(triv) == "number" and triv or nil, cap = cap }
            end
        end
        table.sort(list, function(x, y)
            if x.eff ~= y.eff then return x.eff < y.eff end
            if x.units ~= y.units then return x.units < y.units end
            local nx, ny = (x.r.name or ""):lower(), (y.r.name or ""):lower()
            if nx ~= ny then return nx < ny end
            return x.r.id < y.r.id
        end)
        local st = { index = s + 1, from = from, to = from + goal, points = goal, steps = {}, shift = s }
        local remaining = goal
        for _, c in ipairs(list) do
            if remaining <= 0 then break end
            local maxc = math.huge
            for _, rg in ipairs(c.r.reagents) do maxc = math.min(maxc, math.floor(avail(rg.id) / rg.n)) end
            local crafts = math.min(maxc, math.ceil(math.min(remaining, c.cap) / c.gain))
            if crafts > 0 then
                for _, rg in ipairs(c.r.reagents) do pool[rg.id] = pool[rg.id] - rg.n * crafts; need[rg.id] = (need[rg.id] or 0) + rg.n * crafts end
                st.steps[#st.steps + 1] = { recipe = c.r, crafts = crafts, gain = c.gain, points = crafts * c.gain, eff = c.eff, stage = s + 1, trivial = c.trivial }
                remaining = remaining - crafts * c.gain
                c.cap = c.cap - crafts * c.gain
            end
        end
        if remaining > 0 then
            -- shortfall: cheapest recipes of the best colour, each limited to the points it can still give before it turns white
            local left2 = remaining
            for _, c in ipairs(list) do
                if left2 <= 0 then break end
                local pts = math.min(left2, c.cap)
                if pts > 0 then
                    local crafts = math.ceil(pts / c.gain)
                    for _, rg in ipairs(c.r.reagents) do avail(rg.id); need[rg.id] = (need[rg.id] or 0) + rg.n * crafts end
                    st.steps[#st.steps + 1] = { recipe = c.r, crafts = crafts, gain = c.gain, points = crafts * c.gain, eff = c.eff, stage = s + 1, short = true, trivial = c.trivial }
                    st.short = true
                    left2 = left2 - crafts * c.gain
                    c.cap = c.cap - crafts * c.gain
                end
            end
            if not st.short then
                st.err = "no known recipe still gives skill-ups at this stage (all would be white)"
            end
            uncovered = uncovered + remaining
        end
        st.remaining = math.max(0, remaining)
        res.stages[#res.stages + 1] = st
        for _, step in ipairs(st.steps) do res.steps[#res.steps + 1] = step end
        from, left, s = from + goal, left - goal, s + 1
        if st.err then break end
    end
    if #res.steps == 0 and res.stages[1] and res.stages[1].err then res.err = res.stages[1].err end
    res.remaining = uncovered
    res.covered = res.points - uncovered
    res.complete = (uncovered <= 0)
    for id, n in pairs(need) do
        local owned = initial[id] or avail(id)
        local S = PT.Sources(id, ckey)
        res.materials[#res.materials + 1] = { id = id, name = PT.ItemName(id), need = n, owned = owned, missing = math.max(0, n - owned), own = S.ownTotal, others = S.others }
    end
    table.sort(res.materials, function(a, b)
        if (a.missing > 0) ~= (b.missing > 0) then return a.missing > 0 end
        return a.name:lower() < b.name:lower()
    end)
    return res
end

local function Num(x) if x == math.floor(x) then return tostring(x) end return string.format("%.1f", x) end

function PT.PathLines(res, prof)
    local L = {}
    if res.err then L[#L + 1] = "|cffff4040" .. res.err .. "|r"; return L end
    if res.complete and #res.steps == 0 then
        L[#L + 1] = string.format("|cff40ff40%s: already at %d (target %d).|r", prof or "", res.cur, res.target)
        return L
    end
    L[#L + 1] = string.format("|cff33ccffNext steps: %s %d -> %d (%d points, stages of ~%d)|r", prof or "", res.cur, res.target, res.points, res.stageSize or PT.STAGE)
    L[#L + 1] = "|cff999999Estimated: orange ~1 point per craft, yellow ~0.5, green ~0.25, white 0; the orange->yellow and yellow->green changes are guesses. Where shown, \"white at N\" is the real skill at which the recipe turns white (from the game) and the plan drops it there. Reopen the profession window after crafting - colours and this plan refresh from your new skill.|r"
    for _, st in ipairs(res.stages) do
        L[#L + 1] = string.format("|cffffd100Stage %d: skill %d-%d|r%s", st.index, st.from, st.to,
            st.shift > 0 and string.format(" |cff999999(estimated: recipes assumed %d colour step%s lower, white only at its real skill where known)|r", st.shift, st.shift == 1 and "" or "s") or " |cff999999(colours as saved)|r")
        for i, s in ipairs(st.steps) do
            local saved = s.recipe.diff
            L[#L + 1] = string.format("  %d. %s x%d  %s%s%s  ~+%s%s", i, s.recipe.name or "?", s.crafts, PT.DiffText(s.eff),
                (s.eff ~= saved) and (" |cff999999(saved " .. (PT.DIFF[saved] and PT.DIFF[saved].label or "?") .. ", estimated now)|r") or "",
                s.trivial and (" |cff999999(white at " .. s.trivial .. ")|r") or "", Num(s.points),
                s.short and "  |cffff8040(needs materials you don't have yet)|r" or "  |cff40ff40(materials owned)|r")
        end
        if st.err then L[#L + 1] = "  |cffff4040" .. st.err .. "|r" end
    end
    if res.complete then
        L[#L + 1] = "|cff40ff40All of it can be crafted from materials your characters hold.|r"
    else
        L[#L + 1] = string.format("|cffffff00Materials you hold cover ~%s of %d points; the rest needs more materials.|r", Num(res.covered), res.points)
    end
    if res.capped then L[#L + 1] = "|cff999999(Planning is limited to " .. PT.MAX_STAGES .. " stages; ask again later for more.)|r" end
    L[#L + 1] = "|cff33ccffMaterials (needed / owned on all characters):|r"
    for _, m in ipairs(res.materials) do
        local line = string.format("  %s  %d / %d", m.name, m.need, m.owned)
        if m.missing > 0 then line = line .. string.format("  |cffff4040missing %d|r", m.missing) end
        L[#L + 1] = line
        if m.owned > 0 then
            local parts = {}
            if m.own > 0 then parts[#parts + 1] = "this char " .. m.own end
            for _, o in ipairs(m.others) do parts[#parts + 1] = o.label .. " (" .. PT.LocText(o) .. ")" end
            L[#L + 1] = "      |cff999999held by:|r " .. table.concat(parts, "; ")
        end
    end
    return L
end

------------------------------------------------------------------------
-- Selection state + character/profession summary lines
------------------------------------------------------------------------
function PT.Selection()
    local s = PT.sel
    if s and PT.db.chars[s.key] and (not s.prof or PT.db.chars[s.key].profs[s.prof]) then return s end
    local key = PT.CurrentKey()
    if not (key and PT.db.chars[key]) then key = PT.SortedChars()[1] end
    local rec = key and PT.db.chars[key]
    local prof = rec and PT.SortedProfs(rec)[1]
    PT.sel = { key = key, prof = prof }
    return PT.sel
end
function PT.Select(key, prof, recipeID)
    PT.sel = { key = key, prof = prof, recipe = recipeID }
    PT.pathText = nil
    if PT.db and PT.db.settings then PT.db.settings.last = { key = key, prof = prof } end
end

function PT.ListChars()
    local keys = PT.SortedChars()
    if #keys == 0 then Print("nothing saved yet. Log in on each character (and open each profession window once).") return end
    for _, k in ipairs(keys) do
        local rec = PT.db.chars[k]
        Print(string.format("%s |cff888888(%s)|r", PT.UniqueLabel(k), rec.realm or "?"))
        local names = PT.SortedProfs(rec)
        if #names == 0 then DEFAULT_CHAT_FRAME:AddMessage("    no professions saved") end
        for _, n in ipairs(names) do
            local p = rec.profs[n]
            DEFAULT_CHAT_FRAME:AddMessage(string.format("    %s%s %d/%d  |cff888888recipes: %s, skill %s|r", n, p.primary and "" or " (secondary)", p.level or 0, p.max or 0,
                p.recipesScanned and ((p.recipeCount or 0) .. (p.recipeTotal and (" learned of " .. p.recipeTotal) or "") .. ", scanned " .. PT.FormatAge(p.recipesScanned)) or "not scanned - open the profession window", PT.FormatAge(p.updated)))
        end
    end
end

function PT.Reset(text)
    local key, why = PT.FindChar(text)
    if not key then Print(why) return end
    local label = PT.UniqueLabel(key)
    PT.db.chars[key] = nil
    if PT.sel and PT.sel.key == key then PT.sel = nil end
    Print("forgot " .. label .. " (it is saved again the next time you log in on it)")
    if PT.RefreshUI then PT.RefreshUI() end
end

-- /pt debug: report which APIs exist in this client (paste the output to confirm what Forever provides)
function PT.Debug()
    local function has(label, v) Print(label .. ": " .. (v and "yes" or "NO")) end
    -- summary first (0.1.3): what was detected and what the last scan did
    do
        local okB, bv, bb, _, iface = Call(GetBuildInfo)
        Print(string.format("ProfTracker %s, client %s (%s), interface %s", PT.version, okB and tostring(bv) or "?", okB and tostring(bb) or "?", okB and tostring(iface) or "?"))
        Print("recipe API path: " .. PT.ApiPath())
        local trade, craft = PT.OpenKinds()
        local st = PT._state or {}
        local oname, olvl, omax, _, oline, osrc = PT.ReadOpenProfession(craft and not trade and "craft" or nil)
        Print(string.format("window open: trade %s, craft %s (events: %s/%s); open profession: %s %s/%s, skill line %s via %s",
            tostring(trade), tostring(craft), tostring(st.trade), tostring(st.craft), tostring(oname), tostring(olvl), tostring(omax), tostring(oline), tostring(osrc)))
        local ls = PT.lastScan
        if ls then
            Print(string.format("last scan (%s, %s): %s%s%s", tostring(ls.kind), PT.FormatAge(ls.when),
                ls.ok and ("saved " .. tostring(ls.count) .. " " .. tostring(ls.prof) .. " recipes via " .. tostring(ls.api)) or ("FAILED - " .. tostring(ls.reason)),
                ls.total and (", " .. tostring(ls.total) .. " ids") or "", ls.partial and (", filter: " .. ls.partial) or ""))
        else Print("last scan: none this session (open a profession window, or /pt scan with it open)") end
        local key = PT.CurrentKey()
        local crec = key and PT.db.chars[key]
        if not crec then Print("this character: not saved yet (key " .. tostring(key) .. ")")
        else
            local parts = {}
            for _, n in ipairs(PT.SortedProfs(crec)) do
                local p, cnt = crec.profs[n], 0
                for _ in pairs((crec.recipes and crec.recipes[n]) or {}) do cnt = cnt + 1 end
                parts[#parts + 1] = string.format("%s %s/%s: %d recipes", n, tostring(p.level), tostring(p.max), cnt)
            end
            Print("this character: " .. (#parts > 0 and table.concat(parts, "; ") or "no professions saved"))
        end
    end
    has("GetProfessions", type(GetProfessions) == "function"); has("GetProfessionInfo", type(GetProfessionInfo) == "function")
    has("GetNumSkillLines (legacy)", type(GetNumSkillLines) == "function")
    local T = C_TradeSkillUI
    has("C_TradeSkillUI", T ~= nil)
    for _, f in ipairs({ "GetAllRecipeIDs", "GetRecipeInfo", "GetRecipeSchematic", "GetBaseProfessionInfo", "IsTradeSkillReady", "IsTradeSkillLinked", "GetRecipeItemLink" }) do
        has("  C_TradeSkillUI." .. f, T and type(T[f]) == "function")
    end
    has("GetNumTradeSkills (legacy)", type(GetNumTradeSkills) == "function")
    has("C_Item.GetItemCount", C_Item and type(C_Item.GetItemCount) == "function")
    Print("AltStash.API: " .. (PT.AltStashAPI() and ("yes, AltStash " .. tostring(_G.AltStash.version) .. " api " .. tostring(PT.AltStashAPI().apiVersion)) or "not loaded (own bags only)"))
    if type(GetProfessions) == "function" then
        local r = { pcall(GetProfessions) }
        local parts = {}
        for i = 2, 8 do parts[#parts + 1] = tostring(r[i]) end
        Print("GetProfessions() -> " .. table.concat(parts, ", "))
        for i = 2, 8 do
            if type(r[i]) == "number" then Print("  GetProfessionInfo(" .. r[i] .. ") -> " .. tostring(select(2, pcall(GetProfessionInfo, r[i]))) .. ", level " .. tostring(select(4, pcall(GetProfessionInfo, r[i]))) .. "/" .. tostring(select(5, pcall(GetProfessionInfo, r[i])))) end
        end
    end
    if T and type(T.GetAllRecipeIDs) == "function" then
        local ok, ids = pcall(T.GetAllRecipeIDs)
        if not (ok and type(ids) == "table") then
            Print("GetAllRecipeIDs: failed (needs the profession window open)")
        else
            local learned, unlearned, nilinfo, firstLearned = 0, 0, 0, nil
            local unlearnedDiff0 = 0
            for _, rid in ipairs(ids) do
                local okI, info = pcall(T.GetRecipeInfo, rid)
                if okI and type(info) == "table" then
                    if info.learned == true then learned = learned + 1; if not firstLearned then firstLearned = { id = rid, info = info } end
                    else unlearned = unlearned + 1; if info.relativeDifficulty == 0 then unlearnedDiff0 = unlearnedDiff0 + 1 end end
                else nilinfo = nilinfo + 1 end
            end
            -- maxTrivialLevel of learned recipes (unlearned ones report a placeholder such as 300 and are ignored)
            do
                local withT, minT, maxT = 0, nil, nil
                for _, rid in ipairs(ids) do
                    local okI, info = pcall(T.GetRecipeInfo, rid)
                    if okI and type(info) == "table" and info.learned == true then
                        local t = CleanNum(info.maxTrivialLevel)
                        if t and t > 0 and t < 1000 then withT = withT + 1; minT = math.min(minT or t, t); maxT = math.max(maxT or t, t) end
                    end
                end
                Print(string.format("learned recipes with maxTrivialLevel: %d of %d (range %s-%s)", withT, learned, tostring(minT), tostring(maxT)))
            end
            Print(string.format("learned %d of %d recipes (GetAllRecipeIDs lists all; %d not learned, %d without info). Only learned == true are saved.", learned, #ids, unlearned, nilinfo))
            Print(string.format("  not-learned recipes reporting difficulty 0 (ignored): %d", unlearnedDiff0))
            if firstLearned then
                local keys = {}
                for k, v in pairs(firstLearned.info) do if not IsSecret(v) then keys[#keys + 1] = k .. "=" .. tostring(v) end end
                table.sort(keys)
                Print("GetRecipeInfo(first learned " .. firstLearned.id .. "): " .. table.concat(keys, ", "))
                Print("  maxTrivialLevel (white at skill): " .. tostring(firstLearned.info.maxTrivialLevel) .. " -> saved as trivial = " .. tostring((function() local t = CleanNum(firstLearned.info.maxTrivialLevel); return (t and t > 0 and t < 1000) and t or nil end)()))
                -- schematic layout dump, so layout problems are visible
                local function Keys(t)
                    local k = {}
                    for key, v in pairs(t) do k[#k + 1] = tostring(key) .. ":" .. (type(v) == "table" and "table" or ((IsSecret(v) and "secret") or tostring(v))) end
                    table.sort(k)
                    return table.concat(k, ", ")
                end
                if type(T.GetRecipeSchematic) ~= "function" then
                    Print("GetRecipeSchematic: missing")
                else
                    local okS, sch = pcall(T.GetRecipeSchematic, firstLearned.id, false)
                    if not okS then Print("GetRecipeSchematic ERROR: " .. tostring(sch))
                    elseif type(sch) ~= "table" then Print("GetRecipeSchematic returned " .. type(sch))
                    else
                        Print("schematic keys: " .. Keys(sch))
                        local slots = sch.reagentSlotSchematics
                        Print("  reagentSlotSchematics: " .. (type(slots) == "table" and (#slots .. " slots") or tostring(slots)))
                        if type(slots) == "table" and slots[1] then
                            Print("  slot[1] keys: " .. Keys(slots[1]))
                            Print("  slot[1].quantityRequired = " .. tostring(slots[1].quantityRequired) .. ", reagentType = " .. tostring(slots[1].reagentType))
                            local r1 = type(slots[1].reagents) == "table" and slots[1].reagents[1]
                            Print("  slot[1].reagents[1] keys: " .. (type(r1) == "table" and Keys(r1) or tostring(r1)))
                        end
                        local parsed = SchematicReagents(firstLearned.id)
                        Print("  parsed reagents: " .. #parsed .. " (" .. (function() local p = {} for _, r in ipairs(parsed) do p[#p + 1] = r.id .. "x" .. r.n end return table.concat(p, ", ") end)() .. ")")
                    end
                end
                local old = OldReagents(firstLearned.id)
                Print("  old C_TradeSkillUI reagent calls: " .. #old .. " reagents; legacy GetTradeSkill*: " .. (LegacyIndexMap() and "present" or "absent"))
            end
        end
    end
    do
        local name = PT.ReadOpenProfession()
        local rec = PT.CurrentRecord()
        local p = rec and name and rec.profs[name]
        if p and p.recipesScanned then
            local src = p.reagentSources or {}
            Print(string.format("saved %s: %d recipes (of %s ids); with reagents %d, without %d; sources: schematic %d, old %d, legacy %d, none %d",
                name, p.recipeCount or 0, tostring(p.recipeTotal), p.withReagents or 0, p.noReagents or 0, src.schematic or 0, src.old or 0, src.legacy or 0, src.none or 0))
            local nT, nR, lo, hi = 0, 0, nil, nil
            for _, r in pairs((rec.recipes and rec.recipes[name]) or {}) do
                nR = nR + 1
                if type(r.trivial) == "number" then nT = nT + 1; lo = math.min(lo or r.trivial, r.trivial); hi = math.max(hi or r.trivial, r.trivial) end
            end
            Print(string.format("  saved recipes with trivial (white-at) level: %d of %d%s%s", nT, nR, nT > 0 and string.format(" (range %d-%d)", lo, hi) or "",
                (nT < nR) and " - open the profession window again to rescan the rest" or ""))
        elseif name then Print("saved " .. name .. ": nothing scanned yet (close and reopen the window)") end
    end
    local view, why = PT.OpenProfessionView()
    Print("profession view: " .. (view and "own/ready" or ("skipped: " .. tostring(why))) .. ", open profession: " .. tostring((PT.ReadOpenProfession())))
end


------------------------------------------------------------------------
-- Cooldowns (0.1.4, sanity fix 0.1.5). Optional saved fields (schema stays 2; older versions ignore them):
--   recipe.cd = true          this recipe has a cooldown (seen on cooldown once, or a known cooldown craft by name); sticky
--   recipe.cdGroup = "transmute"  shared cooldown group (all Classic transmutes share one cooldown)
--   char.cooldowns[recipeID] = { ready = epoch seconds (0 = ready when read), at = time() of the read, src = API, dur = total seconds if known, day = bool }
-- Readers, in order (all feature-detected + pcall): classic GetTradeSkillCooldown (scan only), C_TradeSkillUI.GetRecipeCooldown
-- (profession window open), C_Spell.GetSpellCooldown / GetSpellCooldown (recipe spell, works any time), and the tool item's
-- cooldown (C_Container.GetItemCooldown / GetItemCooldown) for crafts gated by an item (Salt Shaker). GetTime()-relative values
-- are converted to epoch seconds with time(), so offline alts show the right remaining time later.
------------------------------------------------------------------------
local CD_HINTS = { { pat = "^Transmute", group = "transmute" }, { pat = "Mooncloth" }, { pat = "Refined Deeprock Salt" } }   -- English names
local TOOL_ITEM_CD = { [15409] = 15846 }   -- Refined Deeprock Salt (output) -> Salt Shaker (item with the cooldown)
PT.CD_HINTS, PT.TOOL_ITEM_CD = CD_HINTS, TOOL_ITEM_CD

function PT.CooldownHint(r)
    if type(r) ~= "table" or type(r.name) ~= "string" then return false, nil end
    for _, h in ipairs(CD_HINTS) do
        if r.name:find(h.pat) then return true, h.group end
    end
    return false, nil
end

-- 0.1.5: sanity limits. No profession cooldown is longer than a few days (Classic transmutes: 2 days at most), so any
-- remaining / duration above CD_MAX is a bad read and is ignored (and bad saved values are repaired or dropped).
local CD_MAX = 7 * 86400
local WRAP = 4294967.296        -- 2^32 ms in seconds
PT.CD_MAX, PT.CD_WRAP = CD_MAX, WRAP

-- start/duration are GetTime()-based (seconds since the client machine booted). A cooldown that started before the
-- machine booted (you crafted, logged off, rebooted) would have a negative start; the client reports it wrapped as an
-- unsigned 32-bit millisecond value, i.e. start + 2^32 ms (~49.7 days) in the future. That is the "50d 22h" bug:
-- remaining = start + dur - GetTime() came out ~49d 17h too high. Unwrap such starts and never trust remaining > dur.
local function FromStartDur(start, dur)
    if type(start) ~= "number" or type(dur) ~= "number" or IsSecret(start) or IsSecret(dur) then return nil end
    if start == 0 or (start > 0 and dur <= 2) then return 0, nil end   -- not on cooldown (or only the global cooldown)
    if dur > CD_MAX or dur < 0 then return nil end
    if start > 0 and type(GetTime) == "function" then
        local okT, nowT = pcall(GetTime)
        if not (okT and type(nowT) == "number") then return nil end
        if start > nowT + 1 then                          -- start in the future: 32-bit ms wrap (cooldown began before boot)
            local fixed = start - WRAP
            if fixed <= nowT + 1 and fixed + dur >= nowT - 1 then start = fixed else return nil end   -- must still be running
        end
        local rem = start + dur - nowT
        if rem > dur + 1 then return nil end              -- can't have more left than the whole cooldown
        return math.max(0, rem), dur
    end
    return nil
end
PT._FromStartDur = FromStartDur

-- Seconds remaining from a "remaining" style API (GetRecipeCooldown, GetTradeSkillCooldown). nil when insane.
local function SaneRemaining(v)
    if type(v) ~= "number" or IsSecret(v) or v ~= v then return nil end
    if v <= 0 then return 0 end
    if v > CD_MAX then return nil end
    return v
end

-- Remaining seconds (0 = ready), source, total duration, isDay.  nil when nothing could be read.
function PT.ReadCooldown(r, opts)
    opts = opts or {}
    local rid = type(r) == "table" and r.id
    if type(rid) ~= "number" then return nil end
    if opts.legacy then
        local v = opts.legacy[rid]
        local sv = SaneRemaining(v)
        if sv then return sv, "GetTradeSkillCooldown" end
        if rid < 0 then return 0, "GetTradeSkillCooldown" end   -- classic row without a spell id: nil cooldown = ready
    end
    local T = C_TradeSkillUI
    if opts.window and rid > 0 and T and type(T.GetRecipeCooldown) == "function" then
        local ok, cd, isDay = pcall(T.GetRecipeCooldown, rid)
        -- returns seconds REMAINING (retail style: cooldown, isDayCooldown, charges, maxCharges), not a start time
        local sv = ok and SaneRemaining(cd)
        if sv then return sv, "GetRecipeCooldown", nil, isDay and true or nil end
    end
    local spellReady = false
    if rid > 0 then
        local start, dur
        if C_Spell and type(C_Spell.GetSpellCooldown) == "function" then
            local ok, info = pcall(C_Spell.GetSpellCooldown, rid)
            if ok and type(info) == "table" then start, dur = info.startTime, info.duration end
        end
        if start == nil and type(GetSpellCooldown) == "function" then
            local ok, st, du = pcall(GetSpellCooldown, rid)
            if ok then start, dur = st, du end
        end
        local rem, total = FromStartDur(start, dur)
        if rem and rem > 0 then return rem, "GetSpellCooldown", total end
        if rem == 0 then spellReady = true end
    end
    local tool = r.out and TOOL_ITEM_CD[r.out]
    if tool then
        local fn = (C_Container and C_Container.GetItemCooldown) or GetItemCooldown
        if type(fn) == "function" then
            local ok, st, du = pcall(fn, tool)
            if ok then
                local rem, total = FromStartDur(st, du)
                if rem then return rem, "GetItemCooldown", total end
            end
        end
    end
    if spellReady then return 0, "GetSpellCooldown" end
    return nil
end

-- 0.1.5 self-heal for values saved by 0.1.4: a ready time more than CD_MAX ahead is a wrapped GetTime() read. If taking
-- the 2^32 ms wrap off gives a sane time, keep that (it is the real one); otherwise drop the entry. Returns entries fixed.
function PT.SanitizeCooldowns(charRec, now)
    if type(charRec) ~= "table" or type(charRec.cooldowns) ~= "table" then return 0 end
    now = now or time()
    local fixed = 0
    for id, c in pairs(charRec.cooldowns) do
        if type(c) ~= "table" then
            charRec.cooldowns[id] = nil; fixed = fixed + 1
        else
            if type(c.dur) == "number" and (c.dur > CD_MAX or c.dur < 0) then c.dur = nil; fixed = fixed + 1 end
            local ready = tonumber(c.ready)
            if ready == nil or ready ~= ready then
                charRec.cooldowns[id] = nil; fixed = fixed + 1
            elseif ready > 0 then
                local base = math.max(now, tonumber(c.at) or 0)
                local limit = math.min(CD_MAX, c.dur or CD_MAX) + 60
                if ready - base > limit then
                    local r2 = math.floor(ready - WRAP + 0.5)
                    if r2 - base <= limit and r2 - base >= -CD_MAX then
                        c.ready = r2 <= now and 0 or r2; c.healed = true
                    else
                        charRec.cooldowns[id] = nil
                    end
                    fixed = fixed + 1
                end
            end
        end
    end
    return fixed
end

function PT.SanitizeAllCooldowns()
    local n = 0
    if type(PT.db) == "table" and type(PT.db.chars) == "table" then
        for _, rec in pairs(PT.db.chars) do n = n + PT.SanitizeCooldowns(rec) end
    end
    return n
end

-- Read cooldowns for the logged-in character. opts: window (profession window open), legacy (classic map), all (check every
-- recipe, not only the ones known to have a cooldown), spells (set of recipe spell ids just cast). Returns number stored.
function PT.CaptureCooldowns(opts)
    opts = opts or {}
    if not PT.db then return 0 end
    local rec = PT.CurrentRecord()
    if not rec then return 0 end
    rec.cooldowns = type(rec.cooldowns) == "table" and rec.cooldowns or {}
    local now = time()
    PT.SanitizeCooldowns(rec, now)
    local n, groupReady, groupDur, groupMembers = 0, {}, {}, {}
    for _, map in pairs(rec.recipes or {}) do
        for id, r in pairs(type(map) == "table" and map or {}) do
            if type(r) == "table" then
                local hint, group = PT.CooldownHint(r)
                if group then r.cdGroup = group end
                local want = opts.all or r.cd or hint or (opts.spells and opts.spells[id])
                if want then
                    local rem, src, dur, day = PT.ReadCooldown(r, opts)
                    if rem and rem > 0 then r.cd = true end
                    if group then groupMembers[#groupMembers + 1] = r end
                    if rem and (r.cd or hint) then
                        local e = { ready = rem > 0 and math.floor(now + rem + 0.5) or 0, at = now, src = src, day = day }
                        local old = rec.cooldowns[id]
                        e.dur = dur or (type(old) == "table" and old.dur) or nil
                        rec.cooldowns[id] = e
                        n = n + 1
                        if group then
                            if e.ready > (groupReady[group] or -1) then groupReady[group] = e.ready end
                            if e.dur then groupDur[group] = e.dur end
                        end
                    elseif not rem and opts.spells and opts.spells[id] and group == nil then
                        -- just cast, nothing readable: use the last known duration
                        local old = rec.cooldowns[id]
                        if type(old) == "table" and old.dur then rec.cooldowns[id] = { ready = now + old.dur, at = now, src = "cast+dur", dur = old.dur }; n = n + 1 end
                    end
                end
            end
        end
    end
    -- shared groups: every member shows the latest ready time read for the group (or cast + known duration)
    for _, r in ipairs(groupMembers) do
        local g = r.cdGroup
        local ready = groupReady[g]
        if not ready and opts.spells then
            for sid in pairs(opts.spells) do
                for _, m in ipairs(groupMembers) do
                    if m.id == sid and m.cdGroup == g then
                        local dur = groupDur[g]
                        for _, x in ipairs(groupMembers) do local c = rec.cooldowns[x.id]; if type(c) == "table" and c.dur then dur = dur or c.dur end end
                        if dur then ready = now + dur end
                    end
                end
            end
        end
        if ready then
            local c = rec.cooldowns[r.id]
            if type(c) ~= "table" or (c.ready or 0) < ready then
                rec.cooldowns[r.id] = { ready = ready, at = now, src = (type(c) == "table" and c.src) or "group", dur = (type(c) == "table" and c.dur) or groupDur[g], day = type(c) == "table" and c.day or nil }
            end
        end
    end
    for id in pairs(rec.cooldowns) do   -- drop entries for recipes no longer saved
        local found = false
        for _, map in pairs(rec.recipes or {}) do if type(map) == "table" and map[id] then found = true break end end
        if not found then rec.cooldowns[id] = nil end
    end
    return n
end

-- For displays (ProfTracker + AltStash): nil when the recipe has no known cooldown, else
-- { ready = epoch (0 = ready), remaining = seconds (0 = ready now), at = time of the read, src, group, shared = bool }
function PT.CooldownInfo(charRec, r)
    if type(charRec) ~= "table" or type(r) ~= "table" then return nil end
    local cds = type(charRec.cooldowns) == "table" and charRec.cooldowns or {}
    local hint, group = PT.CooldownHint(r)
    group = r.cdGroup or group
    PT.SanitizeCooldowns(charRec)          -- 0.1.5: repair/drop wrapped values saved by 0.1.4 (offline alts too)
    local c = cds[r.id]
    local ready, at, src = type(c) == "table" and c.ready or nil, type(c) == "table" and c.at or nil, type(c) == "table" and c.src or nil
    if group then
        for _, map in pairs(charRec.recipes or {}) do
            for id, x in pairs(type(map) == "table" and map or {}) do
                if type(x) == "table" and id ~= r.id and (x.cdGroup or select(2, PT.CooldownHint(x))) == group then
                    local cx = cds[id]
                    if type(cx) == "table" and type(cx.ready) == "number" and cx.ready > (ready or -1) then ready, at, src = cx.ready, cx.at, cx.src end
                end
            end
        end
    end
    if not (r.cd or hint or c) then return nil end
    local now = time()
    local remaining = (type(ready) == "number" and ready > now) and (ready - now) or 0
    return { ready = ready or 0, remaining = remaining, at = at, src = src, group = group, known = ready ~= nil }
end

function PT.FormatRemaining(secs)
    secs = math.max(0, math.floor(tonumber(secs) or 0))
    if secs < 60 then return "<1m" end
    local d, h, m = math.floor(secs / 86400), math.floor(secs % 86400 / 3600), math.floor(secs % 3600 / 60)
    if d > 0 then return string.format("%dd %dh", d, h) end
    if h > 0 then return string.format("%dh %dm", h, m) end
    return string.format("%dm", m)
end

-- recipe spell ids of the logged-in character (for UNIT_SPELLCAST_SUCCEEDED)
function PT.IsOwnRecipeSpell(spellID)
    if type(spellID) ~= "number" or not PT.db then return false end
    local key = PT.CurrentKey()
    local rec = key and PT.db.chars[key]
    for _, map in pairs((rec and rec.recipes) or {}) do if type(map) == "table" and map[spellID] then return true end end
    return false
end

------------------------------------------------------------------------
-- Events. Scans are debounced (DEBOUNCE after the last event) but never delayed more than MAXWAIT, so a stream of
-- update events can't starve them. While a profession window is open a failed recipe scan (data not ready yet) is
-- retried a few times; the result is reported in chat once per window open.
------------------------------------------------------------------------
local MAXWAIT, RETRY_DELAY, MAX_RETRIES = 2.0, 1.0, 6
local f = CreateFrame("Frame")
PT.frame = f
local pending, timer, age, state = {}, 0, 0, { trade = false, craft = false, retries = 0, reported = false }
PT._state = state
local function Queue(what, delay)
    local first = timer <= 0
    pending[what] = true
    if first then age = 0 end
    local want = delay or DEBOUNCE
    timer = math.max(0.01, math.min(want, MAXWAIT - age))
    f:Show()
end
PT._Queue = Queue

local function WindowShown(name)
    local w = _G[name]
    if type(w) == "table" and type(w.IsShown) == "function" then local ok, v = pcall(w.IsShown, w); return ok and v == true end
    return false
end
-- Is a (own) profession window open?  Events first; the frames are a fallback (e.g. after /reload with the window open).
function PT.OpenKinds()
    local trade = state.trade or WindowShown("ProfessionsFrame") or WindowShown("TradeSkillFrame")
    local craft = state.craft or WindowShown("CraftFrame")
    return trade, craft
end

local scanned = {}   -- [prof] = count reported this session
local function ReportScan(n, reason, retry)
    local ls = PT.lastScan or {}
    if n then
        local key, val = tostring(ls.prof), tostring(n) .. "|" .. tostring(ls.api)
        if scanned[key] ~= val or ls.partial then
            scanned[key] = val
            Print(string.format("saved %d %s recipe%s (%s)%s.", n, tostring(ls.prof), n == 1 and "" or "s", tostring(ls.api),
                ls.partial and (" - |cffff8040a filter may hide some (" .. ls.partial .. "); clear it to save the rest|r") or ""))
        end
        state.reported = true
    elseif not retry and not state.reported and not (reason or ""):find("^skipped") then
        state.reported = true
        Print("|cffff5050couldn't read recipes:|r " .. tostring(reason) .. ". Type /pt debug and send the output.")
    end
end

local function ScanOpen()
    local trade, craft = PT.OpenKinds()
    local retryAny = false
    for _, kind in ipairs({ "trade", "craft" }) do
        if (kind == "trade" and trade) or (kind == "craft" and craft) then
            local ok, n, reason, retry = pcall(PT.ScanRecipes, kind)
            if not ok then
                PT.lastScan = { kind = kind, ok = false, reason = "Lua error: " .. tostring(n), when = time() }
                n, reason, retry = nil, PT.lastScan.reason, false
            end
            if not n and retry and state.retries < MAX_RETRIES then
                retryAny = true
            elseif not n and retry then
                retry = false   -- out of retries: report it
            end
            ReportScan(n, reason, retry)
        end
    end
    if retryAny then state.retries = state.retries + 1; Queue("recipes", RETRY_DELAY) end
end

local function Flush()
    if not PT.db then return end
    PT.ResetMemo()
    local did = false
    if pending.skills then pending.skills = false; pcall(PT.ScanSkills); did = true end
    if pending.recipes then pending.recipes = false; ScanOpen(); did = true end
    if pending.cd then
        pending.cd = false
        local spells, full = PT._castSpells, PT._cdFull
        PT._castSpells, PT._cdFull = nil, nil
        local trade = PT.OpenKinds()
        pcall(PT.CaptureCooldowns, { window = trade and true or false, all = full, spells = spells })
        -- refresh displays after login / a craft (SPELL_UPDATE_COOLDOWN alone fires constantly in combat: no UI work then)
        if spells or full then
            did = true
            local AS = _G.AltStash
            if type(AS) == "table" and type(AS.RefreshUI) == "function" then pcall(AS.RefreshUI) end
        end
    end
    if pending.ui then pending.ui = false; did = true end
    if did and PT.RefreshUI then pcall(PT.RefreshUI) end
end
f:SetScript("OnUpdate", function(self, elapsed)
    if timer > 0 then
        age = age + elapsed
        timer = timer - elapsed
        if timer <= 0 then
            Flush()
            local any = false
            for _, v in pairs(pending) do if v then any = true end end
            if not any then self:Hide() end
        end
    end
end)
f:Hide()

f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
-- every event is guarded: unknown events error on RegisterEvent in modern clients
-- Mainline/Forever: TRADE_SKILL_SHOW/CLOSE, TRADE_SKILL_LIST_UPDATE, TRADE_SKILL_DATA_SOURCE_CHANGED
-- Classic: TRADE_SKILL_SHOW/CLOSE, TRADE_SKILL_UPDATE, CRAFT_SHOW/CLOSE, CRAFT_UPDATE (Enchanting)
for _, ev in ipairs({ "SKILL_LINES_CHANGED", "CHAT_MSG_SKILL", "TRADE_SKILL_SHOW", "TRADE_SKILL_CLOSE", "TRADE_SKILL_LIST_UPDATE",
    "TRADE_SKILL_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED", "TRADE_SKILL_FILTER_UPDATE", "NEW_RECIPE_LEARNED", "LEARNED_SPELL_IN_TAB",
    "CRAFT_SHOW", "CRAFT_CLOSE", "CRAFT_UPDATE", "BAG_UPDATE_DELAYED", "GET_ITEM_INFO_RECEIVED",
    "SPELL_UPDATE_COOLDOWN", "BAG_UPDATE_COOLDOWN" }) do pcall(f.RegisterEvent, f, ev) end
-- 0.1.4: crafting a recipe (player only) -> re-read cooldowns
if type(f.RegisterUnitEvent) == "function" then
    if not pcall(f.RegisterUnitEvent, f, "UNIT_SPELLCAST_SUCCEEDED", "player") then pcall(f.RegisterEvent, f, "UNIT_SPELLCAST_SUCCEEDED") end
else pcall(f.RegisterEvent, f, "UNIT_SPELLCAST_SUCCEEDED") end

local function Opened(kind)
    state[kind] = true; state.retries = 0; state.reported = false
    Queue("skills"); Queue("recipes")
end

f:SetScript("OnEvent", function(self, event, a1, a2, a3)
    if event == "ADDON_LOADED" then
        if a1 ~= ADDON then return end
        ProfTrackerDB = ProfTrackerDB or {}
        PT.db = ProfTrackerDB
        if not Migrate(PT.db) then
            Print("Saved data is from a newer ProfTracker (schema " .. tostring(PT.db.schemaVersion) .. "); running read-only without saving.")
            PT.db = { schemaVersion = PT.SCHEMA, chars = {}, settings = {}, itemNames = {} }
        end
        pcall(PT.SanitizeAllCooldowns)              -- 0.1.5: heal wrapped cooldown times saved by 0.1.4
        if PT.InitUI then PT.InitUI() end
    elseif event == "PLAYER_LOGIN" then
        pcall(PT.CurrentRecord)
        Queue("skills")
        PT._cdFull = true; Queue("cd")               -- spell cooldowns of all saved recipes (no window needed)
        local last = PT.db and PT.db.settings and PT.db.settings.last
        if last and PT.db.chars[last.key] then PT.sel = { key = last.key, prof = last.prof } end
        Print("loaded " .. PT.version .. ". /pt for the window, /pt help for commands." .. (PT.AltStashAPI() and "" or " (AltStash not loaded: materials = this character's bags only.)"))
    elseif event == "TRADE_SKILL_SHOW" then Opened("trade")
    elseif event == "CRAFT_SHOW" then Opened("craft")
    elseif event == "TRADE_SKILL_CLOSE" or event == "CRAFT_CLOSE" then
        state[event == "CRAFT_CLOSE" and "craft" or "trade"] = false
        if not (state.trade or state.craft) then pending.recipes = false end
    elseif event == "TRADE_SKILL_LIST_UPDATE" or event == "TRADE_SKILL_UPDATE" or event == "TRADE_SKILL_DATA_SOURCE_CHANGED"
        or event == "TRADE_SKILL_FILTER_UPDATE" or event == "CRAFT_UPDATE" then
        if state.trade or state.craft then Queue("recipes") end
    elseif event == "NEW_RECIPE_LEARNED" or event == "LEARNED_SPELL_IN_TAB" then
        if state.trade or state.craft then Queue("recipes") end
        Queue("skills")
    elseif event == "SKILL_LINES_CHANGED" or event == "CHAT_MSG_SKILL" then
        Queue("skills")
    elseif event == "SPELL_UPDATE_COOLDOWN" or event == "BAG_UPDATE_COOLDOWN" then
        Queue("cd")                                      -- cheap: only recipes known to have a cooldown are re-read
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        if a1 == "player" and PT.IsOwnRecipeSpell(a3) then
            PT._castSpells = PT._castSpells or {}
            PT._castSpells[a3] = true
            Queue("cd")
        end
    elseif event == "BAG_UPDATE_DELAYED" or event == "GET_ITEM_INFO_RECEIVED" then
        if PT.IsShown and PT.IsShown() then Queue("ui") end
    end
end)

-- /pt scan: scan whatever profession window is open right now and say what happened (no retries, no debounce)
function PT.ManualScan()
    if not PT.db then return end
    PT.ResetMemo()
    pcall(PT.ScanSkills)
    local trade, craft = PT.OpenKinds()
    local kinds = {}
    if trade then kinds[#kinds + 1] = "trade" end
    if craft then kinds[#kinds + 1] = "craft" end
    if #kinds == 0 then kinds[1] = "trade"; Print("no profession window detected as open - trying anyway (open Alchemy etc. first).") end
    for _, kind in ipairs(kinds) do
        local ok, n, reason = pcall(PT.ScanRecipes, kind)
        if not ok then Print("|cffff5050scan error:|r " .. tostring(n))
        elseif n then
            local ls = PT.lastScan or {}
            Print(string.format("scan OK: %s, %d recipes saved via %s%s.", tostring(ls.prof), n, tostring(ls.api), ls.partial and (" (filter active: " .. ls.partial .. ")") or ""))
        else Print("|cffff5050scan saved nothing:|r " .. tostring(reason)) end
    end
    if PT.RefreshUI then pcall(PT.RefreshUI) end
end

------------------------------------------------------------------------
-- Slash commands
------------------------------------------------------------------------
local function Help()
    Print("commands (/pt or /proftracker):")
    print("  /pt                     - toggle the window (characters, professions, recipes, 'can make')")
    print("  /pt list                - saved characters, professions and skill levels")
    print("  /pt char <name>         - open the window on a character (first/second/full name or [suffix])")
    print("  /pt path [target]       - next-steps skill-up plan for the selected profession (stages of ~12 points; default: next 3 stages)")
    print("  /pt search <text>       - filter the recipe list by recipe or reagent name")
    print("  /pt reset <name>        - forget a character")
    print("  /pt scan                - scan the open profession window now and say what was saved (or why not)")
    print("  /pt debug               - what ProfTracker detected: API path, open profession, recipe counts, last scan")
    print("  /pt help")
end

function PT.RunPath(target)
    local s = PT.Selection()
    if not (s.key and s.prof) then Print("select a character and profession first (nothing saved yet).") return end
    local res = PT.SkillPath(s.key, s.prof, target)
    local lines = PT.PathLines(res, s.prof)
    PT.pathText = table.concat(lines, "\n")
    if PT.IsShown and PT.IsShown() then PT.RefreshUI() end
    return lines
end

SLASH_PROFTRACKER1, SLASH_PROFTRACKER2 = "/pt", "/proftracker"
SlashCmdList["PROFTRACKER"] = function(msg)
    msg = msg or ""
    local cmd, arg = msg:match("^%s*(%S*)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()
    if not PT.db then return end
    if cmd == "" then
        if PT.IsShown and PT.IsShown() then PT.SetShown(false) else PT.SetShown(true) end
    elseif cmd == "show" then PT.SetShown(true)
    elseif cmd == "hide" then PT.SetShown(false)
    elseif cmd == "help" or cmd == "?" then Help()
    elseif cmd == "list" then PT.ListChars()
    elseif cmd == "char" or cmd == "character" then
        local key, why = PT.FindChar(arg)
        if not key then Print(why) return end
        local prof = PT.SortedProfs(PT.db.chars[key])[1]
        PT.Select(key, prof)
        PT.SetShown(true)
    elseif cmd == "path" then
        local lines = PT.RunPath(tonumber(arg))
        if lines then for _, l in ipairs(lines) do DEFAULT_CHAT_FRAME:AddMessage(l) end end
        PT.SetShown(true)
    elseif cmd == "search" then
        if PT.SetSearch then PT.SetSearch(arg) end
        PT.SetShown(true)
    elseif cmd == "reset" then PT.Reset(arg)
    elseif cmd == "debug" then PT.Debug()
    elseif cmd == "scan" then PT.ManualScan()
    else Print("unknown command '" .. cmd .. "'"); Help() end
end
