-- EryAddon : habillage « Holo » (variante A choisie par Jérémie, inspiration Star Citizen / mobiGlas).
-- Fond bleu nuit, filets cyan, coins en équerre, titres en capitales espacées, boutons plats.
-- Tout est dessiné avec des aplats de couleur (pas d'images à fournir) ; police du jeu
-- « Arial Narrow » (Fonts\ARIALN.TTF), qui a tous les accents français.
-- Les montants gardent les icônes or / argent / cuivre du jeu (ns.Money).

local ADDON_NAME, ns = ...

local Holo = {}
ns.Holo = Holo

Holo.CYAN = { 0.22, 0.82, 1.00 }
Holo.CYAN_DARK = { 0.016, 0.125, 0.17 }
Holo.TEXT = { 0.81, 0.91, 0.95 }
Holo.DIM = { 0.37, 0.54, 0.60 }
Holo.SOFT = { 0.61, 0.78, 0.83 }
Holo.GREEN = { 0.36, 1.00, 0.69 }
Holo.RED = { 1.00, 0.45, 0.45 }
Holo.ORANGE = { 1.00, 0.60, 0.20 }
Holo.BG = { 0.039, 0.067, 0.094 }
Holo.BG2 = { 0.059, 0.141, 0.188 }
Holo.ROW = { 0.051, 0.106, 0.137 }
Holo.LINE = { 0.114, 0.302, 0.369 }

Holo.FONT = "Fonts\\ARIALN.TTF"

local function Tex(parent, layer, c, a)
    local t = parent:CreateTexture(nil, layer or "BACKGROUND")
    t:SetColorTexture(c[1], c[2], c[3], a or 1)
    return t
end
Holo.Tex = Tex

-- Cadre d'un pixel autour d'un frame.
function Holo.Border(f, c, a, layer)
    local top = Tex(f, layer or "BORDER", c, a); top:SetPoint("TOPLEFT"); top:SetPoint("TOPRIGHT"); top:SetHeight(1)
    local bot = Tex(f, layer or "BORDER", c, a); bot:SetPoint("BOTTOMLEFT"); bot:SetPoint("BOTTOMRIGHT"); bot:SetHeight(1)
    local lef = Tex(f, layer or "BORDER", c, a); lef:SetPoint("TOPLEFT"); lef:SetPoint("BOTTOMLEFT"); lef:SetWidth(1)
    local rig = Tex(f, layer or "BORDER", c, a); rig:SetPoint("TOPRIGHT"); rig:SetPoint("BOTTOMRIGHT"); rig:SetWidth(1)
    return { top, bot, lef, rig }
end

-- Coins en équerre cyan (2 px d'épaisseur, 10 px de long).
function Holo.Corners(f)
    local L, W = 10, 2
    for _, p in ipairs({ { "TOPLEFT", 1, -1 }, { "TOPRIGHT", -1, -1 }, { "BOTTOMLEFT", 1, 1 }, { "BOTTOMRIGHT", -1, 1 } }) do
        local h = Tex(f, "OVERLAY", Holo.CYAN); h:SetSize(L, W); h:SetPoint(p[1], f, p[1], 0, 0)
        local v = Tex(f, "OVERLAY", Holo.CYAN); v:SetSize(W, L); v:SetPoint(p[1], f, p[1], 0, 0)
    end
end

-- Texte dans la police du thème.
function Holo.Text(parent, size, color, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY")
    fs:SetFont(Holo.FONT, size or 13, "")
    local c = color or Holo.TEXT
    fs:SetTextColor(c[1], c[2], c[3])
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    return fs
end

-- Capitales avec les accents français (string.upper ne connaît pas « é », « è »…).
local ACCENTS = { ["é"] = "É", ["è"] = "È", ["ê"] = "Ê", ["à"] = "À", ["â"] = "Â", ["ù"] = "Ù",
    ["û"] = "Û", ["ô"] = "Ô", ["î"] = "Î", ["ï"] = "Ï", ["ç"] = "Ç" }
function Holo.Upper(text)
    text = text or ""
    -- Texte avec codes du jeu (couleurs |c…|r, icônes |T…|t) : on n'y touche pas (ils doivent
    -- rester en minuscules).
    if text:find("|", 1, true) then return text end
    text = string.upper(text)
    for low, up in pairs(ACCENTS) do text = text:gsub(low, up) end
    return text
end

-- Libellé en capitales (« MAINTENANT », « ENSUITE »…).
function Holo.Label(parent, text, size, color)
    local fs = Holo.Text(parent, size or 11, color or Holo.DIM)
    fs:SetText(Holo.Upper(text))
    return fs
end

-- Fenêtre complète : fond, cadre, coins, barre de titre déplaçable, bouton fermer.
function Holo.Window(name, width, height, title, subtitle)
    local w = CreateFrame("Frame", name, UIParent)
    w:SetSize(width, height)
    w:SetFrameStrata("HIGH")
    w:SetClampedToScreen(true)
    w:SetMovable(true)
    w:EnableMouse(true)
    local bg = Tex(w, "BACKGROUND", Holo.BG, 0.97); bg:SetAllPoints()
    Holo.Border(w, Holo.LINE)
    Holo.Corners(w)

    local head = CreateFrame("Frame", nil, w)
    head:SetPoint("TOPLEFT", 1, -1)
    head:SetPoint("TOPRIGHT", -1, -1)
    head:SetHeight(26)
    local hbg = Tex(head, "BACKGROUND", Holo.BG2); hbg:SetAllPoints()
    local hline = Tex(head, "BORDER", Holo.LINE); hline:SetPoint("BOTTOMLEFT"); hline:SetPoint("BOTTOMRIGHT"); hline:SetHeight(1)
    head:EnableMouse(true)
    head:RegisterForDrag("LeftButton")
    head:SetScript("OnDragStart", function() w:StartMoving() end)
    head:SetScript("OnDragStop", function() w:StopMovingOrSizing() end)
    w.title = Holo.Label(head, title, 13, Holo.CYAN)
    w.title:SetPoint("LEFT", 10, 0)

    local close = CreateFrame("Button", nil, head)
    close:SetSize(22, 22)
    close:SetPoint("RIGHT", -4, 0)
    close.text = Holo.Text(close, 16, Holo.DIM)
    close.text:SetPoint("CENTER")
    close.text:SetText("x")
    close:SetScript("OnEnter", function(self) self.text:SetTextColor(unpack(Holo.CYAN)) end)
    close:SetScript("OnLeave", function(self) self.text:SetTextColor(unpack(Holo.DIM)) end)
    close:SetScript("OnClick", function() w:Hide() end)

    if subtitle then
        w.subtitle = Holo.Label(head, subtitle, 11, Holo.DIM)
        w.subtitle:SetPoint("RIGHT", close, "LEFT", -6, 0)
    end
    w.head = head
    if name then tinsert(UISpecialFrames, name) end
    return w
end

-- Bouton plat. style = "outline" (filet cyan) ou "solid" (fond cyan, texte sombre).
function Holo.Button(parent, text, width, height, style)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(width or 80, height or 20)
    b.bg = Tex(b, "BACKGROUND", Holo.CYAN, 0); b.bg:SetAllPoints()
    b.edges = Holo.Border(b, Holo.CYAN)
    b.label = Holo.Text(b, 11, Holo.CYAN)
    b.label:SetPoint("CENTER")
    b.label:SetJustifyH("CENTER")
    function b:SetLabel(t) self.label:SetText(Holo.Upper(t)) end
    function b:SetStyle(st)
        self.style = st
        if st == "solid" then
            self.bg:SetColorTexture(Holo.CYAN[1], Holo.CYAN[2], Holo.CYAN[3], 1)
            self.label:SetTextColor(unpack(Holo.CYAN_DARK))
        elseif st == "muted" then
            self.bg:SetColorTexture(0, 0, 0, 0)
            for _, e in ipairs(self.edges) do e:SetColorTexture(Holo.LINE[1], Holo.LINE[2], Holo.LINE[3], 1) end
            self.label:SetTextColor(unpack(Holo.SOFT))
            return
        else
            self.bg:SetColorTexture(0, 0, 0, 0)
            self.label:SetTextColor(unpack(Holo.CYAN))
        end
        for _, e in ipairs(self.edges) do e:SetColorTexture(Holo.CYAN[1], Holo.CYAN[2], Holo.CYAN[3], 1) end
    end
    b:SetScript("OnEnter", function(self)
        if self.style ~= "solid" then self.bg:SetColorTexture(Holo.CYAN[1], Holo.CYAN[2], Holo.CYAN[3], 0.15) end
    end)
    b:SetScript("OnLeave", function(self) self:SetStyle(self.style) end)
    b:SetStyle(style or "outline")
    b:SetLabel(text)
    -- Compatibilité avec le code écrit pour les boutons du jeu : SetText, et un aspect éteint
    -- quand le bouton est désactivé.
    b.SetText = b.SetLabel
    local rawSetEnabled = b.SetEnabled
    function b:SetEnabled(on)
        rawSetEnabled(self, on)
        self:SetAlpha(on and 1 or 0.45)
    end
    function b:Enable() self:SetEnabled(true) end
    function b:Disable() self:SetEnabled(false) end
    return b
end

-- Remet une FontString existante dans la police et la couleur du thème.
function Holo.Restyle(fs, size, color)
    if not fs then return end
    fs:SetFont(Holo.FONT, size or 12, "")
    if color then fs:SetTextColor(color[1], color[2], color[3]) end
end

-- Habille un cadre existant (onglet de l'HV, panneau) : fond, filet, coins.
function Holo.Skin(f, alpha)
    local bg = Tex(f, "BACKGROUND", Holo.BG, alpha or 0.97)
    bg:SetAllPoints()
    Holo.Border(f, Holo.LINE)
    Holo.Corners(f)
    return bg
end

-- Case à cocher plate : carré à filet cyan, rempli quand cochée. Même usage que celle du jeu
-- (SetChecked / GetChecked / OnClick).
function Holo.Check(parent, text)
    local c = CreateFrame("CheckButton", nil, parent)
    c:SetSize(16, 16)
    local box = Tex(c, "BACKGROUND", Holo.BG2); box:SetAllPoints()
    Holo.Border(c, Holo.CYAN)
    local mark = Tex(c, "ARTWORK", Holo.CYAN); mark:SetPoint("TOPLEFT", 4, -4); mark:SetPoint("BOTTOMRIGHT", -4, 4)
    c:SetCheckedTexture(mark)
    c.label = Holo.Text(c, 12, Holo.TEXT)
    c.label:SetPoint("LEFT", c, "RIGHT", 8, 0)
    c.label:SetText(text or "")
    c:SetHitRectInsets(0, -((c.label:GetStringWidth() or 0) + 10), 0, 0)
    return c
end

-- Fond de survol / de sélection des lignes de liste, dans les tons du thème.
function Holo.RowHighlight(row)
    local h = row:CreateTexture(nil, "HIGHLIGHT")
    h:SetAllPoints()
    h:SetColorTexture(Holo.CYAN[1], Holo.CYAN[2], Holo.CYAN[3], 0.10)
    return h
end

-- Barre de progression.
function Holo.Bar(parent, height)
    local f = CreateFrame("Frame", nil, parent)
    f:SetHeight(height or 6)
    local bg = Tex(f, "BACKGROUND", { 0.071, 0.188, 0.235 }); bg:SetAllPoints()
    f.fill = Tex(f, "ARTWORK", Holo.CYAN)
    f.fill:SetPoint("TOPLEFT"); f.fill:SetPoint("BOTTOMLEFT")
    function f:SetValue(v)
        v = math.max(0, math.min(1, v or 0))
        self.fill:SetWidth(math.max(1, (self:GetWidth() or 0) * v))
        self.fill:SetShown(v > 0)
    end
    return f
end
