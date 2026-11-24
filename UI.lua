-- ProfTracker: window. Left: characters + professions with skill bars. Top right: recipe list (difficulty, name, can make).
-- Bottom right: recipe details / skill-up path. Display only - nothing here crafts, clicks or sends anything.
local ADDON, PT = ...

local win, edit, craftsEdit, leftScroll, leftHolder, recScroll, recHolder, detailScroll, detailText, pathBtn
local leftRows, recRows = {}, {}
local ROW_H, MAX_RECIPES = 18, 400
local search = ""

local function SetupRowHighlight(btn)
    local hl = btn:CreateTexture(nil, "BACKGROUND")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.12)
    hl:Hide()
    btn.hl = hl
    btn:SetScript("OnEnter", function(self) self.hl:Show() end)
    btn:SetScript("OnLeave", function(self) if not self.selected then self.hl:Hide() end end)
end
local function SetSelected(btn, on)
    btn.selected = on
    if on then btn.hl:SetColorTexture(0.3, 0.6, 1, 0.25); btn.hl:Show() else btn.hl:SetColorTexture(1, 1, 1, 0.12); btn.hl:Hide() end
end

local function LeftRow(i)
    local r = leftRows[i]
    if r then return r end
    r = CreateFrame("Button", nil, leftHolder)
    r:SetSize(175, 30)
    SetupRowHighlight(r)
    r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.text:SetPoint("TOPLEFT", 4, -2)
    r.text:SetJustifyH("LEFT")
    r.barBg = r:CreateTexture(nil, "ARTWORK"); r.barBg:SetColorTexture(0.15, 0.15, 0.15, 0.9)
    r.barBg:SetPoint("BOTTOMLEFT", 4, 3); r.barBg:SetSize(160, 7)
    r.bar = r:CreateTexture(nil, "OVERLAY"); r.bar:SetColorTexture(0.2, 0.7, 0.3, 1)
    r.bar:SetPoint("BOTTOMLEFT", 4, 3); r.bar:SetSize(1, 7)
    r:SetScript("OnClick", function(self) if self.key and self.prof then PT.Select(self.key, self.prof); PT.RefreshUI() end end)
    leftRows[i] = r
    return r
end

local function RecRow(i)
    local r = recRows[i]
    if r then return r end
    r = CreateFrame("Button", nil, recHolder)
    r:SetSize(450, ROW_H)
    SetupRowHighlight(r)
    r.diff = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.diff:SetPoint("LEFT", 2, 0); r.diff:SetWidth(46); r.diff:SetJustifyH("LEFT")
    r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.name:SetPoint("LEFT", 52, 0); r.name:SetWidth(220); r.name:SetJustifyH("LEFT")
    r.can = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.can:SetPoint("LEFT", 276, 0); r.can:SetWidth(172); r.can:SetJustifyH("LEFT")
    r:SetScript("OnClick", function(self)
        if self.recipeID then PT.sel.recipe = self.recipeID; PT.pathText = nil; PT.RefreshUI() end
    end)
    recRows[i] = r
    return r
end

local function CraftsValue()
    local n = craftsEdit and tonumber(craftsEdit:GetText()) or 1
    if not n or n < 1 then n = 1 end
    return math.floor(n)
end

function PT.IsShown() return win and win:IsShown() end

function PT.RefreshUI()
    if not (win and win:IsShown()) or not PT.db then return end
    PT.ResetMemo()
    local sel = PT.Selection()

    -- left: characters and professions
    local n = 0
    local keys = PT.SortedChars()
    local y = 0
    for _, key in ipairs(keys) do
        local rec = PT.db.chars[key]
        local names = PT.SortedProfs(rec)
        n = n + 1
        local h = LeftRow(n)
        h:Show(); h:ClearAllPoints(); h:SetPoint("TOPLEFT", 0, -y); h:SetHeight(18)
        h.key, h.prof = nil, nil
        h.text:SetText(string.format("|cffffd100%s|r |cff777777%s|r", PT.UniqueLabel(key), rec.realm or ""))
        h.barBg:Hide(); h.bar:Hide(); SetSelected(h, false)
        y = y + 18
        for _, pn in ipairs(names) do
            n = n + 1
            local r = LeftRow(n)
            local p = rec.profs[pn]
            r:Show(); r:ClearAllPoints(); r:SetPoint("TOPLEFT", 0, -y); r:SetHeight(26)
            r.key, r.prof = key, pn
            r.text:SetText(string.format("  %s%s  |cffffff00%d|r/%d", pn, p.primary and "" or " |cff777777(2nd)|r", p.level or 0, p.max or 0))
            local frac = (p.max and p.max > 0) and math.min(1, (p.level or 0) / p.max) or 0
            r.barBg:Show(); r.bar:Show(); r.bar:SetWidth(math.max(1, 160 * frac))
            SetSelected(r, sel.key == key and sel.prof == pn)
            y = y + 26
        end
        if #names == 0 then
            n = n + 1
            local r = LeftRow(n)
            r:Show(); r:ClearAllPoints(); r:SetPoint("TOPLEFT", 0, -y); r:SetHeight(16)
            r.key, r.prof = nil, nil
            r.text:SetText("  |cff777777no professions saved|r")
            r.barBg:Hide(); r.bar:Hide(); SetSelected(r, false)
            y = y + 16
        end
        y = y + 4
    end
    for i = n + 1, #leftRows do leftRows[i]:Hide() end
    leftHolder:SetHeight(math.max(y, 10))

    -- recipes
    local rows = {}
    if sel.key and sel.prof then rows = PT.RecipeRows(sel.key, sel.prof, search, CraftsValue()) end
    local shown = math.min(#rows, MAX_RECIPES)
    for i = 1, shown do
        local row, d = RecRow(i), rows[i]
        row:Show(); row:ClearAllPoints(); row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
        row.recipeID = d.recipe.id
        row.diff:SetText(PT.DiffText(d.recipe.diff))
        row.name:SetText(d.recipe.name or "?")
        row.can:SetText(PT.CanText(d.a))
        SetSelected(row, sel.recipe == d.recipe.id)
    end
    for i = shown + 1, #recRows do recRows[i]:Hide() end
    recHolder:SetHeight(math.max(shown * ROW_H, 10))
    if win.recipeInfo then
        local rec = sel.key and PT.db.chars[sel.key]
        local p = rec and sel.prof and rec.profs[sel.prof]
        local head
        if not p then head = "|cff888888Log in on a character with professions, then open each profession window once.|r"
        elseif not p.recipesScanned then head = "|cffff8040Recipes not scanned yet: log in on that character and open the profession window.|r"
        else head = string.format("%d recipes%s  |cff888888(learned%s; scanned %s; colours as of then)|r", #rows, search ~= "" and " match" or "", p.recipeTotal and (" " .. (p.recipeCount or 0) .. " of " .. p.recipeTotal) or "", PT.FormatAge(p.recipesScanned)) end
        if #rows > MAX_RECIPES then head = head .. string.format("  |cff888888(showing first %d)|r", MAX_RECIPES) end
        win.recipeInfo:SetText(head)
    end

    -- detail / path
    local text
    if PT.pathText then text = PT.pathText
    elseif sel.key and sel.prof and sel.recipe then text = table.concat(PT.DetailLines(sel.key, sel.prof, sel.recipe, CraftsValue()), "\n")
    else text = "|cff888888Click a recipe to see its materials and what is missing, or press 'Skill-up path'.|r" end
    detailText:SetText(text)
    detailScroll:GetScrollChild():SetHeight(math.max(detailText:GetStringHeight() + 8, 10))
end

function PT.SetShown(show) if not win then return end; win:SetShown(show); if show then PT.RefreshUI() end end
function PT.SetSearch(text) search = text or ""; if edit then edit:SetText(search) end; PT.RefreshUI() end

local function SavePos()
    local p, _, rp, x, y = win:GetPoint(1)
    PT.db.settings.pos = { p, rp, x, y }
end

local function Scroll(name, parent, w, h)
    local s = CreateFrame("ScrollFrame", name, parent, "UIPanelScrollFrameTemplate")
    local holder = CreateFrame("Frame", nil, s)
    holder:SetSize(w, 10)
    s:SetScrollChild(holder)
    return s, holder
end

function PT.InitUI()
    win = CreateFrame("Frame", "ProfTrackerFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    win:SetSize(720, 540)
    win:SetClampedToScreen(true)
    win:SetMovable(true)
    win:EnableMouse(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", function(self) self:StartMoving() end)
    win:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePos() end)
    if win.SetBackdrop then
        win:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        win:SetBackdropColor(0, 0, 0, 0.88)
        win:SetBackdropBorderColor(1, 0.8, 0.2, 1)
    end
    local pos = PT.db.settings.pos
    if pos then win:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4]) else win:SetPoint("CENTER", UIParent, "CENTER", 120, 0) end

    local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 10, -12)
    title:SetText("ProfTracker")
    local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2); close:SetScale(0.8)
    close:SetScript("OnClick", function() win:Hide() end)

    local sl = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sl:SetPoint("TOPLEFT", 215, -13); sl:SetText("Search:")
    edit = CreateFrame("EditBox", "ProfTrackerSearchBox", win, "InputBoxTemplate")
    edit:SetSize(140, 20); edit:SetPoint("TOPLEFT", 262, -8)
    edit:SetAutoFocus(false); edit:SetMaxLetters(40)
    edit:SetScript("OnTextChanged", function(self) search = self:GetText() or ""; PT.RefreshUI() end)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    edit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    local cl = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cl:SetPoint("TOPLEFT", 415, -13); cl:SetText("Crafts:")
    craftsEdit = CreateFrame("EditBox", "ProfTrackerCraftsBox", win, "InputBoxTemplate")
    craftsEdit:SetSize(34, 20); craftsEdit:SetPoint("TOPLEFT", 455, -8)
    craftsEdit:SetAutoFocus(false); craftsEdit:SetMaxLetters(4); craftsEdit:SetNumeric(true)
    craftsEdit:SetText("1")
    craftsEdit:SetScript("OnTextChanged", function() PT.RefreshUI() end)
    craftsEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    craftsEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    pathBtn = CreateFrame("Button", "ProfTrackerPathButton", win, "UIPanelButtonTemplate")
    pathBtn:SetSize(120, 22); pathBtn:SetPoint("TOPLEFT", 500, -7)
    pathBtn:SetText("Skill-up path")
    pathBtn:SetScript("OnClick", function() PT.RunPath(nil) end)

    leftScroll, leftHolder = Scroll("ProfTrackerLeftScroll", win, 175, 10)
    leftScroll:SetPoint("TOPLEFT", 10, -36); leftScroll:SetPoint("BOTTOMLEFT", 10, 12); leftScroll:SetWidth(180)

    win.recipeInfo = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    win.recipeInfo:SetPoint("TOPLEFT", 215, -36)
    win.recipeInfo:SetWidth(480); win.recipeInfo:SetJustifyH("LEFT")

    recScroll, recHolder = Scroll("ProfTrackerRecipeScroll", win, 450, 10)
    recScroll:SetPoint("TOPLEFT", 215, -52); recScroll:SetSize(455, 225)

    local dHolder
    detailScroll, dHolder = Scroll("ProfTrackerDetailScroll", win, 450, 10)
    detailScroll:SetPoint("TOPLEFT", 215, -290); detailScroll:SetPoint("BOTTOMRIGHT", -30, 12)
    detailText = detailScroll:GetScrollChild():CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    detailText:SetPoint("TOPLEFT", 0, 0); detailText:SetWidth(450)
    detailText:SetJustifyH("LEFT"); detailText:SetJustifyV("TOP")

    if UISpecialFrames then tinsert(UISpecialFrames, "ProfTrackerFrame") end
    win:Hide()
end
