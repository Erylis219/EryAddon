-- EryAddon : NOUVELLE FENÊTRE DE L'HÔTEL DES VENTES (refonte, 08/11/2026, maquette validée par Jérémie :
-- Artifact « EryAddon HV refonte »). Une grande fenêtre « Holo » qui passe par-dessus celle de Blizzard
-- (même méthode que TSM : la fenêtre du jeu reste ouverte mais réduite à presque rien, sinon l'HV se ferme).
--   - barre du haut : état des données (scan, TSM, ventes au courrier), bourse, « Interface du jeu », fermer ;
--   - barre de gauche : ACHETER (Acheter, Opportunités), VENDRE (Vendre, Mes enchères, Mes ventes),
--     PRODUIRE (Métiers). 1re étape : seul l'écran VENDRE est fait ; les autres boutons rouvrent l'écran
--     correspondant dans l'interface du jeu (onglets d'EryAddon / de Blizzard) en attendant.
-- Écran VENDRE (inspiré d'Auctionator, que Jérémie adore) : ses objets vendables à gauche (pastilles « mieux à
-- l'HV / au marchand »), un clic choisit l'objet, cherche ses annonces et pose le prix tout seul (1 pa sous le
-- moins cher des AUTRES vendeurs) ; quantité, prix, durée, résumé (dépôt, net, coût, bénéfice), bouton Vendre ;
-- à droite les annonces actuelles avec la tienne en vert. Jamais sous le prix marchand (bloqué).
-- Règles du jeu respectées : un clic par mise en vente ; le jeu cache les vendeurs des objets empilables ;
-- dépôt rendu si vendu, perdu si invendu ; commission 5 %.

local ADDON_NAME, ns = ...
local Msg = ns.Msg

local F = {}
ns.Fenetre = F

local DESIGN_W, DESIGN_H = 1440, 860
local TOP_H, RAIL_W, PAD = 56, 200, 16
local COMMISSION = 0.05
-- Durées de Forever (index de l'API → libellé), comme Auctionator : 2 h, 8 h, 24 h.
local DURATIONS = { { idx = 1, label = "2 h", hours = 2 }, { idx = 2, label = "8 h", hours = 8 }, { idx = 3, label = "24 h", hours = 24 } }
local SLOT, SLOT_GAP, SLOT_COLS = 52, 6, 5
local LIST_ROWS = 18

local win               -- la fenêtre
local switchingToGame   -- vrai pendant le passage à l'interface du jeu (la fermeture ne ferme pas l'HV)
local V = {}            -- écran Vendre (cadres)
local sel               -- objet choisi { key, id, link, name, icon, quality, count, locs, commodity, itemKey, vendor }
local listings          -- annonces { { p, q, own } } triées, ou nil (recherche en cours)
local listingsTime
local price, qty, durIdx, choice = 0, 1, 3, nil
local lastPostTime = 0

local function H() return ns.Holo end
local function Money(c) return ns.Money and ns.Money(c) or tostring(c) end

local function Num(v)
    if v >= 10 then return string.format("%d", math.floor(v + 0.5)) end
    return (string.format("%.1f", v):gsub("%.", ","))
end

local function ItemInfo(id)
    local get = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    local name, link, quality, _, _, _, _, maxStack, _, texture, sellPrice, classID = get(id)
    return name, link, quality, maxStack, texture, sellPrice, classID
end

local function QualityColor(q)
    local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q or 1]
    if c then return c.r, c.g, c.b end
    return 1, 1, 1
end

---------------------------------------------------------------------------
-- Petits éléments d'interface
---------------------------------------------------------------------------
local function Panel(parent)
    local f = CreateFrame("Frame", nil, parent)
    local bg = H().Tex(f, "BACKGROUND", { 0.043, 0.086, 0.133 }, 1); bg:SetAllPoints()
    H().Border(f, H().LINE)
    return f
end

local function Box(parent, w, h)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(w, h)
    local bg = H().Tex(f, "BACKGROUND", { 0.024, 0.067, 0.102 }, 1); bg:SetAllPoints()
    f.edges = H().Border(f, { 0.165, 0.31, 0.388 })
    return f
end

local function SetEdges(f, c)
    for _, e in ipairs(f.edges or {}) do e:SetColorTexture(c[1], c[2], c[3], 1) end
end

-- Champ de saisie de nombres (quantité, po / pa / pc).
local function NumberBox(parent, w, h, size, onChange)
    local box = Box(parent, w, h)
    local e = CreateFrame("EditBox", nil, box)
    e:SetPoint("TOPLEFT", 8, 0); e:SetPoint("BOTTOMRIGHT", -8, 0)
    e:SetFont(H().FONT, size or 20, "")
    e:SetTextColor(unpack(H().TEXT))
    e:SetAutoFocus(false)
    e:SetNumeric(true)
    e:SetMaxLetters(7)
    e:SetJustifyH("RIGHT")
    e:SetScript("OnEnterPressed", e.ClearFocus)
    e:SetScript("OnEscapePressed", e.ClearFocus)
    e:SetScript("OnEditFocusGained", function() SetEdges(box, H().CYAN) end)
    e:SetScript("OnEditFocusLost", function() SetEdges(box, { 0.165, 0.31, 0.388 }) end)
    e:SetScript("OnTextChanged", function(self, user) if user and onChange then onChange() end end)
    box.edit = e
    return box
end

-- Bouton vert (action principale).
local function GoButton(parent, w, h)
    local b = H().Button(parent, "", w, h, "solid")
    local GREEN = H().GREEN
    function b:SetStyle(st)
        self.style = st
        self.bg:SetColorTexture(GREEN[1], GREEN[2], GREEN[3], 1)
        for _, e in ipairs(self.edges) do e:SetColorTexture(GREEN[1], GREEN[2], GREEN[3], 1) end
        self.label:SetTextColor(0.01, 0.09, 0.05)
    end
    b:SetStyle("solid")
    b:SetScript("OnLeave", nil)
    b:SetScript("OnEnter", nil)
    b.label:SetFont(H().FONT, 16, "")
    return b
end

---------------------------------------------------------------------------
-- Fenêtre du jeu : réduite à presque rien (pas cachée : la cacher fermerait l'HV)
---------------------------------------------------------------------------
local function ShrinkGameUI()
    if not AuctionHouseFrame then return end
    AuctionHouseFrame:SetScale(0.001)
    AuctionHouseFrame:SetAlpha(0)
end

local function RestoreGameUI()
    if not AuctionHouseFrame then return end
    AuctionHouseFrame:SetScale(1)
    AuctionHouseFrame:SetAlpha(1)
    -- Nos cadres dans la fenêtre du jeu (colonne de droite, Anomalies…) : traits remis à 1 (réparation du bug
    -- des bandes cyan, 08/11).
    if H().ResetBorders then H().ResetBorders(AuctionHouseFrame) end
end

-- Revient à l'interface du jeu, éventuellement sur un écran donné (onglet EryAddon ou de Blizzard).
function F.ShowGameUI(target)
    switchingToGame = true
    if win then win:Hide() end
    switchingToGame = false
    RestoreGameUI()
    if not AuctionHouseFrame then return end
    local lib = LibStub and LibStub("LibAHTab-1-0", true)
    local modes = AuctionHouseFrameDisplayMode or {}
    if target == "acheter" and modes.Buy then
        AuctionHouseFrame:SetDisplayMode(modes.Buy)
    elseif target == "encheres" and modes.Auctions then
        AuctionHouseFrame:SetDisplayMode(modes.Auctions)
    elseif lib and target then
        local ids = { opportunites = "EryAddon_Anomalies", metiers = "EryAddon_Jobs", mesventes = "EryAddon_MesVentes" }
        if ids[target] and lib:DoesIDExist(ids[target]) then lib:SetSelected(ids[target]) end
    end
end

---------------------------------------------------------------------------
-- Barre du haut et barre de gauche
---------------------------------------------------------------------------
local function UpdateTop()
    if not win then return end
    local s = EryAddonDB and EryAddonDB.hvScan
    -- Scan / vérification / étude en cours : son état court (« Scan : 1200 objets », « Vérif. 3/12 »…).
    local short = ns.AnoAPI and ns.AnoAPI.ShortStatus and ns.AnoAPI.ShortStatus() or ""
    if short ~= "" then
        win.scanChip:SetText((short:gsub("\n", " ")))
    elseif type(s) == "table" and s.time then
        win.scanChip:SetText(string.format("Scan il y a %d min", math.floor((time() - s.time) / 60)))
    else
        win.scanChip:SetText("Aucun scan")
    end
    local tsm = type(TSM_API) == "table"
    win.tsmChip:SetText(tsm and "TSM actif" or "Sans TSM")
    win.tsmDot:SetColorTexture(tsm and 0.36 or 1, tsm and 1 or 0.69, tsm and 0.69 or 0.33, 1)
    local mv = EryAddonDB and EryAddonDB.mesVentes
    local n = mv and mv.ventesSansCourrier and #mv.ventesSansCourrier or 0
    win.mailChip:SetText(n > 0 and string.format("%d vente%s au courrier", n, n > 1 and "s" or "") or "Courrier à jour")
    win.mailDot:SetColorTexture(n > 0 and 1 or 0.36, n > 0 and 0.69 or 1, n > 0 and 0.33 or 0.69, 1)
    win.gold:SetText(Money(GetMoney()))
end

local function Chip(parent, anchor, x)
    local f = CreateFrame("Frame", nil, parent)
    f:SetHeight(28)
    local bg = H().Tex(f, "BACKGROUND", { 0.051, 0.106, 0.157 }, 1); bg:SetAllPoints()
    H().Border(f, H().LINE)
    local dot = H().Tex(f, "ARTWORK", H().GREEN); dot:SetSize(8, 8); dot:SetPoint("LEFT", 10, 0)
    local t = H().Text(f, 13, H().SOFT); t:SetPoint("LEFT", dot, "RIGHT", 7, 0)
    f:SetPoint("LEFT", anchor, "RIGHT", x or 12, 0)
    f.SetText = function(self, s) t:SetText(s); self:SetWidth(t:GetStringWidth() + 36) end
    return f, t, dot
end

local NAV = {
    { group = "ACHETER" },
    { key = "acheter", label = "Acheter" },
    { key = "opportunites", label = "Opportunités" },
    { group = "VENDRE" },
    { key = "vendre", label = "Vendre" },
    { key = "encheres", label = "Mes enchères" },
    { key = "mesventes", label = "Mes ventes" },
    { group = "PRODUIRE" },
    { key = "metiers", label = "Métiers" },
}

-- Écrans déjà refaits dans la nouvelle fenêtre (les autres s'ouvrent dans l'interface du jeu).
local SCREENS = { acheter = true, vendre = true, metiers = true, encheres = true, opportunites = true, mesventes = true }
local railButtons, screenFrames = {}, {}
local currentScreen = "vendre"

local function MarkRail()
    for key, b in pairs(railButtons) do
        local on = key == currentScreen
        b.bg:SetColorTexture(0.059, 0.141, 0.2, on and 1 or 0)
        for _, e in ipairs(b.edges) do e:SetColorTexture(H().CYAN[1], H().CYAN[2], H().CYAN[3], on and 1 or 0) end
        if on then b.text:SetTextColor(1, 1, 1) else b.text:SetTextColor(0.71, 0.83, 0.87) end
        if b.icon then
            if on then b.icon:SetVertexColor(1, 1, 1, 1) else b.icon:SetVertexColor(H().CYAN[1], H().CYAN[2], H().CYAN[3], 1) end
        end
    end
end

local function CreateRail(parent)
    local rail = CreateFrame("Frame", nil, parent)
    rail:SetPoint("TOPLEFT", 1, -(TOP_H + 1))
    rail:SetPoint("BOTTOMLEFT", 1, 1)
    rail:SetWidth(RAIL_W)
    local bg = H().Tex(rail, "BACKGROUND", { 0.035, 0.078, 0.125 }, 1); bg:SetAllPoints()
    local line = H().Tex(rail, "BORDER", H().LINE); line:SetPoint("TOPRIGHT"); line:SetPoint("BOTTOMRIGHT"); line:SetWidth(1)
    local y = -10
    for _, n in ipairs(NAV) do
        if n.group then
            local g = H().Label(rail, n.group, 11, { 0.435, 0.592, 0.659 })
            g:SetPoint("TOPLEFT", 20, y - 14)
            y = y - 34
        else
            local b = CreateFrame("Button", nil, rail)
            b:SetSize(RAIL_W - 20, 42)
            b:SetPoint("TOPLEFT", 10, y)
            b.bg = H().Tex(b, "BACKGROUND", { 0.059, 0.141, 0.2 }, 0); b.bg:SetAllPoints()
            b.edges = H().Border(b, H().CYAN, 0)
            -- Icône au trait (dessinée comme sur la maquette : outils/make_icones.py → media/icones/*.tga),
            -- blanche dans le fichier et teintée ici : cyan au repos, blanche pour l'écran affiché.
            b.icon = b:CreateTexture(nil, "ARTWORK")
            b.icon:SetSize(18, 18)
            b.icon:SetPoint("LEFT", 12, 0)
            b.icon:SetTexture("Interface\\AddOns\\EryAddon\\media\\icones\\" .. n.key)
            b.icon:SetVertexColor(H().CYAN[1], H().CYAN[2], H().CYAN[3], 1)
            b.text = H().Text(b, 16, { 0.71, 0.83, 0.87 })
            b.text:SetPoint("LEFT", 40, 0)
            b.text:SetText(n.label)
            H().RowHighlight(b)
            railButtons[n.key] = b
            if SCREENS[n.key] then
                b:SetScript("OnClick", function() F.ShowScreen(n.key) end)
            else
                -- Pas encore refait : ouvre l'écran correspondant dans l'interface du jeu.
                b:SetScript("OnClick", function() F.ShowGameUI(n.key) end)
                b:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:AddLine(n.label)
                    GameTooltip:AddLine("Pas encore dans la nouvelle fenêtre : s'ouvre dans l'interface du jeu.", 1, 1, 1, true)
                    GameTooltip:Show()
                end)
                b:SetScript("OnLeave", function() GameTooltip:Hide() end)
            end
            y = y - 44
        end
    end
    return rail
end

---------------------------------------------------------------------------
-- Écran VENDRE : sacs
---------------------------------------------------------------------------
local CLASS_ORDER = { [0] = 1, [7] = 2, [9] = 3, [2] = 4, [4] = 5, [1] = 6, [3] = 7, [5] = 8, [12] = 9, [15] = 10 }

local function BagItems()
    local items, byKey = {}, {}
    if not (C_Container and C_Container.GetContainerNumSlots) then return items end
    local lastBag = (NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4)
    for bag = 0, lastBag do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID and not info.isBound then
                local loc = ItemLocation:CreateFromBagAndSlot(bag, slot)
                local okV, valid = pcall(C_AuctionHouse.IsSellItemValid, loc, false)
                if okV and valid then
                    local name, _, quality, maxStack, texture, sellPrice, classID = ItemInfo(info.itemID)
                    local key = ((maxStack or 1) > 1) and info.itemID or (info.hyperlink or info.itemID)
                    local e = byKey[key]
                    if not e then
                        -- Empilable (« marchandise ») ou non : d'après le jeu, sinon d'après la taille de pile.
                        -- (Toujours un vrai booléen : un nil faisait ignorer les résultats de recherche, 08/11.)
                        local okC, status = pcall(C_AuctionHouse.GetItemCommodityStatus, loc)
                        local kinds = Enum.ItemCommodityStatus
                        local commodity = (maxStack or 1) > 1
                        if okC and kinds and status == kinds.Commodity then commodity = true
                        elseif okC and kinds and status == kinds.Item then commodity = false end
                        e = { key = key, id = info.itemID, link = info.hyperlink, name = name or ("objet " .. info.itemID),
                            icon = info.iconFileID or texture, quality = info.quality or quality, count = 0, locs = {},
                            vendor = sellPrice or 0, classID = classID, commodity = commodity }
                        byKey[key] = e
                        items[#items + 1] = e
                    end
                    e.count = e.count + (info.stackCount or 1)
                    e.locs[#e.locs + 1] = { bag = bag, slot = slot, n = info.stackCount or 1 }
                end
            end
        end
    end
    table.sort(items, function(a, b)
        local ca, cb = CLASS_ORDER[a.classID or 99] or 50, CLASS_ORDER[b.classID or 99] or 50
        if ca ~= cb then return ca < cb end
        return a.name < b.name
    end)
    return items
end

local slotPool, headerPool = {}, {}

local function SlotButton(i)
    local b = slotPool[i]
    if b then return b end
    b = CreateFrame("Button", nil, V.bagChild)
    b:SetSize(SLOT, SLOT)
    b.icon = b:CreateTexture(nil, "ARTWORK"); b.icon:SetAllPoints()
    b.edges = H().Border(b, { 0.165, 0.31, 0.388 }, 1, "OVERLAY")
    b.count = H().Text(b, 13, { 1, 1, 1 }, "OVERLAY"); b.count:SetPoint("BOTTOMRIGHT", -3, 2)
    b.count:SetShadowOffset(1, -1)
    -- Pastilles : carré vert = mieux à l'HV, rond rouge = mieux au marchand (comme les sacs).
    b.hv = b:CreateTexture(nil, "OVERLAY", nil, 2); b.hv:SetSize(12, 12); b.hv:SetPoint("TOPLEFT", 1, -1)
    b.hv:SetColorTexture(H().GREEN[1], H().GREEN[2], H().GREEN[3], 1)
    b.pnj = b:CreateTexture(nil, "OVERLAY", nil, 2); b.pnj:SetSize(14, 14); b.pnj:SetPoint("TOPLEFT", -1, 1)
    b.pnj:SetTexture("Interface\\Common\\Indicator-Red")
    b:SetScript("OnClick", function(self) if self.entry then F.Select(self.entry) end end)
    b:SetScript("OnEnter", function(self)
        local e, l = self.entry, self.entry and self.entry.locs[1]
        if not l then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetBagItem(l.bag, l.slot)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    slotPool[i] = b
    return b
end

local function Header(i)
    local h = headerPool[i]
    if h then return h end
    h = H().Text(V.bagChild, 13, { 0.71, 0.83, 0.87 })
    headerPool[i] = h
    return h
end

function F.RefreshBags()
    if not (win and win:IsShown()) then return end
    local items = BagItems()
    V.items = items
    for _, b in ipairs(slotPool) do b:Hide() end
    for _, h in ipairs(headerPool) do h:Hide() end
    local y, col, nSlot, nHead, lastClass = 0, 0, 0, 0, false
    for _, e in ipairs(items) do
        if e.classID ~= lastClass then
            if col > 0 then y = y - SLOT - SLOT_GAP; col = 0 end
            nHead = nHead + 1
            local h = Header(nHead)
            h:ClearAllPoints(); h:SetPoint("TOPLEFT", 0, y - 4)
            local classInfo = (C_Item and C_Item.GetItemClassInfo) or GetItemClassInfo
            local typeName = e.classID and classInfo and classInfo(e.classID) or "Divers"
            h:SetText(typeName or "Divers")
            h:Show()
            y = y - 24
            lastClass = e.classID
        end
        nSlot = nSlot + 1
        local b = SlotButton(nSlot)
        b.entry = e
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", col * (SLOT + SLOT_GAP), y)
        b.icon:SetTexture(e.icon)
        b.count:SetText(e.count > 1 and e.count or "")
        -- Seulement l'alerte « mieux au marchand » (rond rouge) : ici tout est à vendre à l'HV, un repère
        -- « mieux à l'HV » n'apprenait rien (Jérémie ne comprenait pas le carré vert).
        local verdict = ns.BagVerdict and select(1, ns.BagVerdict(e.link, e.id, e.count))
        b.hv:Hide()
        b.pnj:SetShown(verdict == "pnj")
        local on = sel and sel.key == e.key
        local c = on and H().CYAN or { 0.165, 0.31, 0.388 }
        for _, ed in ipairs(b.edges) do ed:SetColorTexture(c[1], c[2], c[3], 1) end
        b:Show()
        col = col + 1
        if col >= SLOT_COLS then col = 0; y = y - SLOT - SLOT_GAP end
    end
    if col > 0 then y = y - SLOT end
    V.bagChild:SetHeight(math.max(1, -y))
    V.bagCount:SetText(string.format("%d objet%s", #items, #items > 1 and "s" or ""))
    -- L'objet choisi : quantité à jour (après une mise en vente) ou disparu.
    if sel then
        local still
        for _, e in ipairs(items) do if e.key == sel.key then still = e end end
        if still then
            still.itemKey = sel.itemKey
            sel = still
            if qty > sel.count then qty = sel.count; V.qty.edit:SetText(qty) end
        else
            sel = nil
        end
        F.UpdateSell()
    end
end

---------------------------------------------------------------------------
-- Écran VENDRE : annonces, prix conseillé
---------------------------------------------------------------------------
local function ReadListings(isCommodity, arg)
    local list = {}
    if isCommodity then
        for i = 1, C_AuctionHouse.GetNumCommoditySearchResults(arg) do
            local r = C_AuctionHouse.GetCommoditySearchResultInfo(arg, i)
            if r and r.unitPrice then
                local own = r.numOwnerItems or 0
                list[#list + 1] = { p = r.unitPrice, q = r.quantity or 0, own = own }
            end
        end
    else
        for i = 1, C_AuctionHouse.GetNumItemSearchResults(arg) do
            local r = C_AuctionHouse.GetItemSearchResultInfo(arg, i)
            local p = r and (r.buyoutAmount or r.bidAmount)
            if p and p > 0 then
                list[#list + 1] = { p = p, q = r.quantity or 1, own = r.containsOwnerItem and (r.quantity or 1) or 0 }
            end
        end
    end
    table.sort(list, function(a, b) return a.p < b.p end)
    return list
end

local function LowestOther()
    for _, l in ipairs(listings or {}) do
        if l.q - l.own > 0 then return l.p end
    end
end

-- Les prix proposés (boutons au-dessus de la durée).
-- Objets NON EMPILABLES : le jeu n'accepte que des prix en PIÈCES D'ARGENT ENTIÈRES (Anciens gants : 67 pa 99
-- refusé, 68 pa accepté), 1 pa au minimum → « passer dessous » = 1 pa de moins. Objets EMPILABLES : le cuivre passe
-- (potions en vente à 19 pa 84) → 1 pc de moins.
local function SilverOnly() return not (sel and sel.commodity) end
local function Silver(p)
    p = math.floor((p or 0) + 0.5)
    if not SilverOnly() then return math.max(1, p) end
    return math.max(100, math.floor(p / 100 + 0.5) * 100)
end

local function Proposals()
    local out = {}
    local low = LowestOther()
    if low then
        -- (Pas de bouton « Aligner » : RÈGLE DE JÉRÉMIE, on ne met jamais en vente sans être le moins cher.)
        if SilverOnly() then
            out[#out + 1] = { key = "under", label = "1 pa sous le moins cher", value = math.max(100, math.ceil(low / 100) * 100 - 100) }
        else
            out[#out + 1] = { key = "under", label = "1 pc sous le moins cher", value = math.max(1, low - 1) }
        end
    end
    -- Prix du marché / vente moyenne : proposés seulement s'ils restent sous le moins cher des autres.
    if sel and ns.TSM then
        local m = ns.TSM("DBMarket", sel.id)
        if m and m > 0 and (not low or Silver(m) < low) then out[#out + 1] = { key = "market", label = "Prix du marché", value = Silver(m) } end
        local a = ns.TSM("DBRegionSaleAvg", sel.id)
        if a and a > 0 and (not low or Silver(a) < low) then out[#out + 1] = { key = "avg", label = "Vente moyenne", value = Silver(a) } end
    end
    return out
end

local function SetPrice(p)
    price = (p and p > 0) and Silver(p) or 0
    V.manual = nil -- prix posé par FDC (ou un bouton), pas tapé à la main
    V.po.edit:SetText(math.floor(price / 10000))
    V.pa.edit:SetText(math.floor(price / 100) % 100)
    V.pc.edit:SetText(price % 100)
end

local function ReadPrice()
    local po = tonumber(V.po.edit:GetText()) or 0
    local pa = tonumber(V.pa.edit:GetText()) or 0
    local pc = SilverOnly() and 0 or (tonumber(V.pc.edit:GetText()) or 0) -- (non empilable : pas de cuivre, voir Silver)
    price = po * 10000 + pa * 100 + pc
    choice = nil
    for _, p in ipairs(Proposals()) do if p.value == price then choice = p.key break end end
end

-- Durée conseillée : 24 h si ce que tu vends met plus de 8 h à partir (sinon une partie expire et le dépôt est
-- perdu), 8 h sinon.
-- Durée proposée : 2 h, toujours (choix de Jérémie, 09/11) ; il change à la main s'il veut 8 h ou 24 h.
local function DefaultDuration()
    return 1
end

function F.Search()
    if not sel or not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then return end
    if C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then
        C_Timer.After(0.3, F.Search)
        return
    end
    if not sel.itemKey then
        local l = sel.locs[1]
        local ok, key = pcall(C_AuctionHouse.GetItemKeyFromItem, ItemLocation:CreateFromBagAndSlot(l.bag, l.slot))
        sel.itemKey = ok and key or nil
    end
    if not sel.itemKey then return end
    listings = nil
    -- Comme TSM (AuctionHouseWrapper) : SANS tri, et pour la recherche de vente, niveau d'objet à 0 (« bug du jeu :
    -- MakeItemKey ajoute un niveau d'objet qui casse la recherche »).
    local sorts = {}
    -- 1er essai : la recherche « de vente » (celle de Blizzard / Auctionator) ; si elle ne répond pas, la
    -- recherche normale, celle qu'utilise déjà Anomalies.
    if sel.retried then
        C_AuctionHouse.SendSearchQuery(sel.itemKey, sorts, true)
    else
        local k = {}
        for f, v in pairs(sel.itemKey) do k[f] = v end
        k.itemLevel = 0
        C_AuctionHouse.SendSellSearchQuery(k, sorts, true)
    end
    -- Pas de réponse en 4 s (le serveur a pu jeter la demande) : on redemande une fois.
    local asked = sel
    C_Timer.After(4, function()
        if sel == asked and listings == nil and not asked.retried then asked.retried = true; F.Search() end
    end)
    F.UpdateSell()
end

function F.IsOpen() return win ~= nil and win:IsShown() end
F._Test = function() return V, sel, price, qty, durIdx, listings end -- pour le test hors jeu

function F.Select(entry)
    if ns.HVUserAction then ns.HVUserAction() end -- scan / vérification en pause, ils reprennent après
    sel = entry
    listings, choice = nil, nil
    qty = entry.count
    V.qty.edit:SetText(qty)
    SetPrice(0)
    durIdx = DefaultDuration()
    F.RefreshBags()
    F.Search()
end

local function OnResults(isCommodity, arg)
    if not sel then return end
    if isCommodity and arg ~= sel.id then return end
    if not isCommodity and (type(arg) ~= "table" or arg.itemID ~= sel.id) then return end
    sel.commodity = isCommodity -- c'est la réponse du serveur qui dit si l'objet est empilable
    listings, listingsTime = ReadListings(isCommodity, arg), time()
    -- Prix posé tout seul à l'arrivée des annonces : 1 pa sous le moins cher des autres vendeurs, sinon le
    -- prix du marché. (Pas si Jérémie a déjà tapé un prix.)
    if price == 0 then
        local props = Proposals()
        if props[1] then SetPrice(props[1].value); choice = props[1].key end
    end
    F.UpdateSell()
end

---------------------------------------------------------------------------
-- Écran VENDRE : calculs et affichage du centre / de la droite
---------------------------------------------------------------------------
local function Deposit()
    if not sel or qty < 1 then return nil end
    local l = sel.locs[1]
    local loc = ItemLocation:CreateFromBagAndSlot(l.bag, l.slot)
    local ok, d
    if sel.commodity then
        ok, d = pcall(C_AuctionHouse.CalculateCommodityDeposit, sel.id, DURATIONS[durIdx].idx, qty)
    else
        ok, d = pcall(C_AuctionHouse.CalculateItemDeposit, loc, DURATIONS[durIdx].idx, qty)
    end
    return ok and d or nil
end

local function Blocked()
    if not sel then return "Choisis un objet à gauche" end
    if qty < 1 then return "Quantité ?" end
    if price < 1 then return "Prix ?" end
    if sel.vendor > 0 and price * (1 - COMMISSION) < sel.vendor then
        return "Bloqué sous " .. Money(math.ceil(sel.vendor / (1 - COMMISSION))) .. " (prix marchand)"
    end
    -- RÈGLE DE JÉRÉMIE (09/11) : jamais en vente sans être le moins cher (égalité comprise)...
    if listings == nil then return "Lecture des annonces…" end
    local low = LowestOther()
    if low and price >= low then
        -- ... SAUF prix tapé à la main (14/11 : annonce d'un autre à 88 pc au lieu de 1 pa 88, pas rentable à
        -- racheter) : on laisse vendre, avec un avertissement (2e valeur).
        if not V.manual then return "Plus cher que " .. Money(low) .. " : passe dessous" end
        local n = 0
        for _, l in ipairs(listings) do if l.p < price then n = n + (l.q - l.own) end end
        return nil, n > 0 and string.format("%d moins chère%s devant toi (dès %s)", n, n > 1 and "s" or "", Money(low))
            or ("À égalité avec " .. Money(low))
    end
end

local function LockCopper()
    local lock = SilverOnly()
    V.pc.edit:EnableMouse(not lock)
    if lock and V.pc.edit:HasFocus() then V.pc.edit:ClearFocus() end
    if lock then V.pc.edit:SetTextColor(0.37, 0.5, 0.56) else V.pc.edit:SetTextColor(unpack(H().TEXT)) end
    V.pc:SetAlpha(lock and 0.6 or 1)
end

function F.UpdateSell()
    LockCopper()
    if not (win and win:IsShown()) then return end
    local Hc = H()
    -- En-tête de l'objet.
    V.center:SetShown(sel ~= nil)
    V.empty:SetShown(sel == nil)
    if not sel then
        V.listTitleRight:SetText("")
        for _, r in ipairs(V.rows) do r:Hide() end
        V.rate:SetText("")
        return
    end
    V.icon:SetTexture(sel.icon)
    V.name:SetText(sel.name)
    V.name:SetTextColor(QualityColor(sel.quality))
    V.have:SetText(string.format("%d dans tes sacs", sel.count))
    local perDay = ns.HVSalesPerDay and ns.HVSalesPerDay(sel.id)
    if perDay then
        V.sells:SetText(Num(perDay) .. " / jour")
        V.sells:SetTextColor(unpack(perDay >= 1 and Hc.GREEN or (perDay >= 0.2 and Hc.ORANGE or Hc.RED)))
        if perDay > 0 then
            local h = qty / perDay * 24
            V.sellsTime:SetText(h < 1 and string.format("tes %d en moins d'1 h", qty)
                or string.format("tes %d en ~ %s", qty, h < 48 and (math.floor(h + 0.5) .. " h") or (math.floor(h / 24 + 0.5) .. " jours")))
        else
            V.sellsTime:SetText("ne se vend pas")
        end
    else
        V.sells:SetText("?")
        V.sells:SetTextColor(unpack(Hc.SOFT))
        V.sellsTime:SetText("ventes inconnues")
    end

    -- Boutons de prix.
    local props = Proposals()
    local x, y, maxW = 0, 0, V.propArea:GetWidth()
    for i, b in ipairs(V.props) do
        local p = props[i]
        if p then
            b.value, b.key = p.value, p.key
            b:SetLabel(p.label .. "  " .. Money(p.value))
            b:SetWidth(b.label:GetStringWidth() + 26)
            if x > 0 and x + b:GetWidth() > maxW then x = 0; y = y - 42 end
            b:ClearAllPoints(); b:SetPoint("TOPLEFT", V.propArea, "TOPLEFT", x, y)
            x = x + b:GetWidth() + 8
            b:SetStyle(choice == p.key and "solid" or "outline")
            b:Show()
        else
            b:Hide()
        end
    end

    -- Durée.
    for i, b in ipairs(V.durs) do b:SetStyle(i == durIdx and "solid" or "muted") end

    -- Résumé.
    local total = price * qty
    local net = math.floor(total * (1 - COMMISSION))
    local dep = Deposit()
    -- Coût : payé (achat noté), fabriqué (composants), sinon ramassé = 0 ; jamais un prix du marché inventé
    -- (ns.CostBasis, EryAddon_Jobs.lua ; Jérémie : « imagine j'ai looté ces cuirs moyens dans la nature »).
    V.total:SetText(Money(total))
    V.net:SetText(Money(net))
    V.dep:SetText(dep and ("-" .. Money(dep)) or "?")
    local cost, origin = 0, "ramassé"
    if ns.CostBasis then cost, origin = ns.CostBasis(sel.id) end
    cost = cost or 0
    if cost > 0 then
        V.cost:SetText(string.format("|cff9fbfcc%s|r  -%s", origin or "", Money(cost * qty)))
    else
        V.cost:SetText("|cff9fbfccramassé|r  0")
    end
    local profit = net - cost * qty
    V.profit:SetText((profit >= 0 and "+" or "-") .. Money(math.abs(profit)))
    V.profit:SetTextColor(unpack(profit >= 0 and Hc.GREEN or Hc.RED))

    -- Bouton et message.
    local block, warn = Blocked()
    if V.pending then
        V.go:SetLabel("Confirmer")
        V.go:SetEnabled(true)
        V.note:SetText("Le jeu demande une confirmation : reclique.")
        V.note:SetTextColor(unpack(Hc.ORANGE))
    elseif block then
        V.go:SetLabel("Vendre")
        V.go:SetEnabled(false)
        V.note:SetText(block)
        V.note:SetTextColor(unpack(sel and price > 0 and Hc.ORANGE or Hc.SOFT))
    else
        V.go:SetLabel(string.format("Vendre %d à %s", qty, Money(price)))
        V.go:SetEnabled(true)
        if V.error and time() - V.error.t < 15 then
            V.note:SetText(V.error.text)
            V.note:SetTextColor(unpack(Hc.RED))
        elseif warn then
            V.note:SetText(warn)
            V.note:SetTextColor(unpack(Hc.ORANGE))
        else
            V.note:SetText("")
        end
    end

    -- Annonces actuelles (à droite), avec ta future annonce en vert.
    if not listings then
        V.listTitleRight:SetText("recherche…")
        for _, r in ipairs(V.rows) do r:Hide() end
    else
        V.listTitleRight:SetText(#listings == 0 and "aucune annonce" or "")
        local shown, placed, cum = 0, false, 0
        local function Row(p, q, kind)
            shown = shown + 1
            local r = V.rows[shown]
            if not r then return end
            cum = cum + q
            r.price:SetText(Money(p))
            r.qty:SetText(q)
            r.cum:SetText(cum)
            r.who:SetText(kind == "me" and "toi" or (kind == "own" and "à toi" or ""))
            r.mine:SetShown(kind == "me")
            local c = kind == "me" and Hc.GREEN or (kind == "own" and Hc.CYAN or Hc.TEXT)
            r.price:SetTextColor(unpack(c)); r.qty:SetTextColor(unpack(c))
            r:Show()
        end
        for _, l in ipairs(listings) do
            if not placed and price > 0 and not block and price <= l.p then Row(price, qty, "me"); placed = true end
            Row(l.p, l.q, l.own > 0 and "own" or nil)
        end
        if not placed and price > 0 and not block then Row(price, qty, "me") end
        for i = shown + 1, #V.rows do V.rows[i]:Hide() end
    end
    local rate = ns.TSM and ns.TSM("DBRegionSaleRate", sel.id)
    V.rate:SetText(rate and string.format("%d %% des annonces partent", math.floor(rate * 100 + 0.5)) or "")
end

---------------------------------------------------------------------------
-- Mise en vente (un clic = une mise en vente ; le jeu peut demander une confirmation)
---------------------------------------------------------------------------
local function CurrentLocation()
    for _, l in ipairs(sel.locs) do
        local loc = ItemLocation:CreateFromBagAndSlot(l.bag, l.slot)
        local ok, exists = pcall(C_Item.DoesItemExist, loc)
        if ok and exists and C_Item.GetItemID(loc) == sel.id then return loc end
    end
end

function F.Post()
    if V.pending then
        local p = V.pending
        V.pending = nil
        if p.commodity and C_AuctionHouse.ConfirmPostCommodity then
            pcall(C_AuctionHouse.ConfirmPostCommodity, p.loc, p.dur, p.qty, p.price)
        elseif C_AuctionHouse.ConfirmPostItem then
            pcall(C_AuctionHouse.ConfirmPostItem, p.loc, p.dur, p.qty, nil, p.price)
        end
        lastPostTime = GetTime()
        F.UpdateSell()
        return
    end
    if Blocked() then return end
    local loc = CurrentLocation()
    if not loc then V.error = { text = "Objet introuvable dans tes sacs.", t = time() }; F.UpdateSell(); return end
    local dur = DURATIONS[durIdx].idx
    V.error = nil
    lastPostTime = GetTime()
    local ok, needConfirm
    if sel.commodity then
        ok, needConfirm = pcall(C_AuctionHouse.PostCommodity, loc, dur, qty, price)
    else
        ok, needConfirm = pcall(C_AuctionHouse.PostItem, loc, dur, qty, nil, price)
    end
    if not ok then
        V.error = { text = "Mise en vente refusée : " .. tostring(needConfirm), t = time() }
    elseif needConfirm then
        -- Le jeu veut une confirmation : 2e clic sur le même bouton.
        V.pending = { commodity = sel.commodity, loc = loc, dur = dur, qty = qty, price = price }
    end
    F.UpdateSell()
end

---------------------------------------------------------------------------
-- Construction de l'écran Vendre
---------------------------------------------------------------------------
local function CreateSellScreen(content)
    local Hc = H()
    local cw = DESIGN_W - 2 - RAIL_W - 1
    local ch = DESIGN_H - 2 - TOP_H
    local innerW = cw - 2 * PAD
    local bagW, listW = 330, 380
    local centerW = innerW - bagW - listW - 2 * PAD

    -- Gauche : tes objets vendables.
    local bags = Panel(content)
    bags:SetPoint("TOPLEFT", PAD, -PAD)
    bags:SetSize(bagW, ch - 2 * PAD)
    local t = Hc.Label(bags, "Tes objets vendables", 12, { 0.5, 0.64, 0.7 }); t:SetPoint("TOPLEFT", 14, -14)
    V.bagCount = Hc.Text(bags, 12, Hc.SOFT); V.bagCount:SetPoint("TOPRIGHT", -14, -14)
    local scroll = CreateFrame("ScrollFrame", nil, bags)
    scroll:SetPoint("TOPLEFT", 14, -38)
    scroll:SetPoint("BOTTOMRIGHT", -14, 44)
    V.bagChild = CreateFrame("Frame", nil, scroll)
    V.bagChild:SetSize(bagW - 28, 1)
    scroll:SetScrollChild(V.bagChild)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local max = math.max(0, V.bagChild:GetHeight() - self:GetHeight())
        self:SetVerticalScroll(math.max(0, math.min(max, self:GetVerticalScroll() - delta * (SLOT + SLOT_GAP))))
    end)
    local legP = bags:CreateTexture(nil, "ARTWORK"); legP:SetSize(14, 14); legP:SetTexture("Interface\\Common\\Indicator-Red")
    legP:SetPoint("BOTTOMLEFT", 12, 16)
    local legPt = Hc.Text(bags, 12, Hc.SOFT); legPt:SetPoint("LEFT", legP, "RIGHT", 4, 0)
    legPt:SetText("rapporte plus chez un marchand")

    -- Centre : mise en vente.
    local center = Panel(content)
    center:SetPoint("TOPLEFT", bags, "TOPRIGHT", PAD, 0)
    center:SetSize(centerW, ch - 2 * PAD)
    V.centerPanel = center
    V.empty = Hc.Text(center, 16, Hc.SOFT); V.empty:SetPoint("CENTER"); V.empty:SetText("Choisis un objet à gauche")
    V.center = CreateFrame("Frame", nil, center); V.center:SetAllPoints()
    local c = V.center
    local IN = 20
    V.icon = c:CreateTexture(nil, "ARTWORK"); V.icon:SetSize(56, 56); V.icon:SetPoint("TOPLEFT", IN, -IN)
    V.name = Hc.Text(c, 22, Hc.TEXT); V.name:SetPoint("TOPLEFT", V.icon, "TOPRIGHT", 14, -4); V.name:SetWidth(centerW - 2 * IN - 70 - 120)
    V.have = Hc.Text(c, 14, Hc.SOFT); V.have:SetPoint("TOPLEFT", V.name, "BOTTOMLEFT", 0, -6)
    local sl = Hc.Label(c, "Se vend", 11, { 0.5, 0.64, 0.7 }); sl:SetPoint("TOPRIGHT", -IN, -IN - 2); sl:SetJustifyH("RIGHT")
    V.sells = Hc.Text(c, 20, Hc.GREEN); V.sells:SetPoint("TOPRIGHT", sl, "BOTTOMRIGHT", 0, -4); V.sells:SetJustifyH("RIGHT")
    V.sellsTime = Hc.Text(c, 12, Hc.SOFT); V.sellsTime:SetPoint("TOPRIGHT", V.sells, "BOTTOMRIGHT", 0, -4); V.sellsTime:SetJustifyH("RIGHT")

    local half = math.floor((centerW - 2 * IN - 16) / 2)
    local ql = Hc.Label(c, "Quantité", 11, { 0.5, 0.64, 0.7 }); ql:SetPoint("TOPLEFT", IN, -100)
    V.qty = NumberBox(c, half - 70, 44, 22, function()
        qty = math.max(0, math.min(sel and sel.count or 0, tonumber(V.qty.edit:GetText()) or 0))
        F.UpdateSell()
    end)
    V.qty:SetPoint("TOPLEFT", ql, "BOTTOMLEFT", 0, -6)
    local maxB = Hc.Button(c, "Max", 62, 44, "muted")
    maxB:SetPoint("LEFT", V.qty, "RIGHT", 8, 0)
    maxB:SetScript("OnClick", function() if sel then qty = sel.count; V.qty.edit:SetText(qty); F.UpdateSell() end end)
    local pl = Hc.Label(c, "Prix à l'unité", 11, { 0.5, 0.64, 0.7 }); pl:SetPoint("TOPLEFT", IN + half + 16, -100)
    local function OnPrice() ReadPrice(); V.manual = true; F.UpdateSell() end
    local pw = math.floor((half - 16) / 3)
    V.po = NumberBox(c, pw, 44, 20, OnPrice); V.po:SetPoint("TOPLEFT", pl, "BOTTOMLEFT", 0, -6)
    V.pa = NumberBox(c, pw, 44, 20, OnPrice); V.pa:SetPoint("LEFT", V.po, "RIGHT", 8, 0)
    V.pc = NumberBox(c, pw, 44, 20, OnPrice); V.pc:SetPoint("LEFT", V.pa, "RIGHT", 8, 0)
    V.po.edit:SetMaxLetters(5); V.pa.edit:SetMaxLetters(2); V.pc.edit:SetMaxLetters(2)
    -- Case du cuivre : bloquée à 0 pour un objet non empilable (voir Silver), libre sinon (LockCopper).
    for _, pair in ipairs({ { V.po, "|TInterface\\MoneyFrame\\UI-GoldIcon:0|t" }, { V.pa, "|TInterface\\MoneyFrame\\UI-SilverIcon:0|t" },
        { V.pc, "|TInterface\\MoneyFrame\\UI-CopperIcon:0|t" } }) do
        local ic = Hc.Text(pair[1], 14, Hc.TEXT); ic:SetPoint("RIGHT", -6, 0); ic:SetText(pair[2])
        pair[1].edit:SetPoint("BOTTOMRIGHT", -24, 0)
    end

    V.propArea = CreateFrame("Frame", nil, c)
    V.propArea:SetPoint("TOPLEFT", IN, -176)
    V.propArea:SetSize(centerW - 2 * IN, 80)
    V.props = {}
    for i = 1, 4 do
        local b = Hc.Button(V.propArea, "", 100, 34, "outline")
        b.label:SetFont(Hc.FONT, 13, "")
        b:SetScript("OnClick", function(self) SetPrice(self.value); choice = self.key; F.UpdateSell() end)
        V.props[i] = b
    end

    local dl = Hc.Label(c, "Durée", 11, { 0.5, 0.64, 0.7 }); dl:SetPoint("TOPLEFT", IN, -268)
    V.durs = {}
    local dw = math.floor((centerW - 2 * IN - 16) / 3)
    for i, d in ipairs(DURATIONS) do
        local b = Hc.Button(c, d.label, dw, 40, "muted")
        b.label:SetFont(Hc.FONT, 16, "")
        b:SetPoint("TOPLEFT", dl, "BOTTOMLEFT", (i - 1) * (dw + 8), -6)
        b:SetScript("OnClick", function() durIdx = i; F.UpdateSell() end)
        V.durs[i] = b
    end

    local sum = Box(c, centerW - 2 * IN, 5 * 30 + 16)
    sum:SetPoint("TOPLEFT", IN, -344)
    local function Line(i, label, color)
        local l = Hc.Text(sum, 14, Hc.SOFT); l:SetPoint("TOPLEFT", 14, -8 - (i - 1) * 30); l:SetText(label)
        local v = Hc.Text(sum, i == 5 and 20 or 14, color or Hc.TEXT); v:SetPoint("TOPRIGHT", -14, -8 - (i - 1) * 30 + (i == 5 and 3 or 0))
        v:SetJustifyH("RIGHT")
        if i < 5 then
            local ln = Hc.Tex(sum, "BORDER", { 0.071, 0.161, 0.227 }); ln:SetHeight(1)
            ln:SetPoint("TOPLEFT", 10, -8 - i * 30 + 6); ln:SetPoint("TOPRIGHT", -10, -8 - i * 30 + 6)
        end
        return v, l
    end
    V.total = Line(1, "Total")
    V.net = Line(2, "Tu touches (−5 %)")
    V.dep = Line(3, "Dépôt, perdu si invendu", Hc.ORANGE)
    V.cost = Line(4, "Ton coût")
    local pl5
    V.profit, pl5 = Line(5, "Bénéfice si tout part", Hc.GREEN)
    pl5:SetFont(Hc.FONT, 16, ""); pl5:SetTextColor(unpack(Hc.TEXT))

    V.go = GoButton(c, centerW - 2 * IN, 54)
    V.go:SetPoint("BOTTOMLEFT", IN, 44)
    V.go:SetScript("OnClick", F.Post)
    V.note = Hc.Text(c, 13, Hc.SOFT)
    V.note:SetPoint("TOP", V.go, "BOTTOM", 0, -10)
    V.note:SetWidth(centerW - 2 * IN)
    V.note:SetJustifyH("CENTER")

    -- Droite : annonces actuelles.
    local list = Panel(content)
    list:SetPoint("TOPLEFT", center, "TOPRIGHT", PAD, 0)
    list:SetSize(listW, ch - 2 * PAD)
    local lt = Hc.Label(list, "Annonces actuelles", 12, { 0.5, 0.64, 0.7 }); lt:SetPoint("TOPLEFT", 14, -14)
    V.listTitleRight = Hc.Text(list, 12, Hc.SOFT); V.listTitleRight:SetPoint("TOPRIGHT", -14, -14)
    local head = CreateFrame("Frame", nil, list)
    head:SetPoint("TOPLEFT", 1, -38); head:SetPoint("TOPRIGHT", -1, -38); head:SetHeight(30)
    local hb = Hc.Tex(head, "BACKGROUND", { 0.039, 0.082, 0.125 }, 1); hb:SetAllPoints()
    local cols = { { "Prix", 150 }, { "Dispo", 70 }, { "Cumul", 70 } }
    local hx = 10
    for _, col in ipairs(cols) do
        local h = Hc.Label(head, col[1], 11, { 0.5, 0.64, 0.7 })
        h:SetPoint("RIGHT", head, "LEFT", hx + col[2], 0)
        h:SetJustifyH("RIGHT")
        hx = hx + col[2] + 10
    end
    V.rows = {}
    for i = 1, LIST_ROWS do
        local r = CreateFrame("Frame", nil, list)
        r:SetPoint("TOPLEFT", 1, -68 - (i - 1) * 34)
        r:SetPoint("TOPRIGHT", -1, -68 - (i - 1) * 34)
        r:SetHeight(34)
        local ln = Hc.Tex(r, "BORDER", { 0.071, 0.161, 0.227 }); ln:SetHeight(1); ln:SetPoint("BOTTOMLEFT"); ln:SetPoint("BOTTOMRIGHT")
        r.mine = Hc.Tex(r, "BACKGROUND", { 0.043, 0.133, 0.098 }, 1); r.mine:SetAllPoints()
        r.price = Hc.Text(r, 14, Hc.TEXT); r.price:SetPoint("RIGHT", r, "LEFT", 160, 0); r.price:SetJustifyH("RIGHT")
        r.qty = Hc.Text(r, 14, Hc.TEXT); r.qty:SetPoint("RIGHT", r, "LEFT", 240, 0); r.qty:SetJustifyH("RIGHT")
        r.cum = Hc.Text(r, 14, Hc.SOFT); r.cum:SetPoint("RIGHT", r, "LEFT", 320, 0); r.cum:SetJustifyH("RIGHT")
        r.who = Hc.Text(r, 12, Hc.GREEN); r.who:SetPoint("LEFT", r, "LEFT", 330, 0)
        r:Hide()
        V.rows[i] = r
    end
    V.rate = Hc.Text(list, 13, Hc.SOFT); V.rate:SetPoint("BOTTOMLEFT", 14, 14)
end

---------------------------------------------------------------------------
-- Écran MÉTIERS (maquette validée, 08/11) : recherche d'un objet à fabriquer (tous métiers), onglets des
-- métiers, liste des recettes rentables à gauche, fiche à droite avec « Combien en fabriquer ? »
-- (1 / 5 / 10 / pour monter / max avec ta bourse), les composants (pour N, sur toi, manque, prix), un
-- bouton « Pour 1 (+k) » (seulement ce qui manque, une fabrication à la fois : choix de Jérémie) et
-- « Tout » par composant, et « Tout acheter » (un clic par composant : le jeu exige un clic par achat).
-- Tous les calculs viennent de l'onglet Métiers (ns.JobsAPI, EryAddon_Jobs.lua) : mêmes règles partout.
---------------------------------------------------------------------------
local Mt = {}          -- cadres de l'écran Métiers
local mProf            -- métier affiché { id, name, learned }
local mSel             -- recette choisie (entrée de Compute)
local mWant = 1        -- nombre de fabrications voulu
local mList = {}       -- recettes de la liste
local mOffset = 0      -- défilement de la liste
local mLevel           -- niveau SIMULÉ (champ « Niv. ») ; nil = ton vrai niveau (demande de Jérémie, 09/11 :
                       -- voir les recettes d'un métier pas appris, ou d'un niveau pas encore atteint)
local mFiche           -- résultat de Needs pour la recette choisie
local MLIST_ROWS = 17
-- Arbre de la recette (maquette « 6b » validée par Jérémie, 09/11) et colonne « TOTAL (SACS + BANQUE) ».
local TREE_ROWS, TREE_GUIDES, NEED_ROWS, TREE_STEP = 14, 6, 9, 18
local mFolded, mTreeOffset, mNeedOffset = {}, 0, 0
local mTreeRows, mNeeds = {}, {}

local COLOR_INFO = {
    optimal = { "orange", { 1, 0.6, 0.24 } }, medium = { "jaune", { 1, 0.88, 0.3 } },
    easy = { "vert", { 0.3, 1, 0.42 } }, trivial = { "gris", { 0.6, 0.6, 0.6 } },
}

local function API() return ns.JobsAPI end
local metiersFrame     -- le cadre de l'écran Métiers (créé une fois, accroché à la grande fenêtre ou à la fenêtre K)

-- Coût d'achat de N fabrications (recette comprise si elle s'achète) : pour « Max avec ta bourse ».
local function PurchaseCost(e, n)
    local list = API().Needs(e, n)
    local total = 0
    for _, l in ipairs(list) do
        if l.buy and (l.missing or 0) > 0 then total = total + (l.cost or 0) end
    end
    return total
end

local function MaxAffordable(e)
    local money = GetMoney()
    if PurchaseCost(e, 1) > money then return 0 end
    local lo, hi = 1, 200
    if PurchaseCost(e, hi) <= money then return hi end
    while hi - lo > 1 do
        local mid = math.floor((lo + hi) / 2)
        if PurchaseCost(e, mid) <= money then lo = mid else hi = mid end
    end
    return lo
end

-- Modes de tri de la liste (clé → valeur d'une recette) et sens du 1er clic (vrai = du plus grand au plus petit).
local SORT_KEYS = {
    niveau = function(e) return e.learn end,
    chance = function(e) return e.chance end,
    vente = function(e) return e.rate end,
    gain = function(e) return e.gain end,
    recette = function(e) return e.learnCost end,
}
local SORT_FIRST_DESC = { niveau = false, chance = true, vente = true, gain = true, recette = false }
local SORT_TIPS = { niveau = "niveau de la recette", chance = "chance de gagner un point",
    vente = "% des annonces qui se vendent (TSM)", gain = "gain par fabrication", recette = "prix de la recette à apprendre" }

local function MetiersSort()
    local t = EryAddonDB.metiersTri
    if type(t) ~= "table" or not SORT_KEYS[t.k] then
        t = { k = "gain", desc = true }
        EryAddonDB.metiersTri = t
    end
    return t
end

local function BuildList()
    mList = {}
    if not (mProf and API()) then return end
    local skill = mLevel or API().LevelOf(mProf)
    local all = API().Compute(mProf.id, skill)
    local monter = EryAddonDB.jobsMonter
    for _, e in ipairs(all) do
        if monter then
            if e.chance > 0 and (e.color ~= "easy" or (e.gain and e.gain > 0)) then mList[#mList + 1] = e end
        elseif e.gain and e.gain > 0 then
            mList[#mList + 1] = e
        end
    end
    -- % des annonces qui se vendent (TSM, DBRegionSaleRate, 0 à 1) ; nil sans TSM ou objet inconnu.
    for _, e in ipairs(mList) do e.rate = ns.TSM and ns.TSM("DBRegionSaleRate", e.out) or nil end
    for _, e in ipairs(mList) do e.learnCost = (not e.known) and API().LearnCost(e) or 0 end
    -- Tri choisi en cliquant sur un titre de colonne (demande de Jérémie, 14/11) : niveau, chance, % vente, gain,
    -- prix de la recette ; 2e clic sur le même titre = ordre inversé. Valeur inconnue (nil) toujours en bas ;
    -- à égalité : gain, puis chance.
    local t = MetiersSort()
    local get = SORT_KEYS[t.k] or SORT_KEYS.gain
    local function Cmp(va, vb, desc)
        if (va ~= nil) ~= (vb ~= nil) then return va ~= nil end
        if va ~= nil and va ~= vb then if desc then return va > vb else return va < vb end end
    end
    table.sort(mList, function(a, b)
        local r = Cmp(get(a), get(b), t.desc)
        if r ~= nil then return r end
        r = Cmp(a.gain, b.gain, true)
        if r ~= nil then return r end
        if (a.chance or 0) ~= (b.chance or 0) then return (a.chance or 0) > (b.chance or 0) end
        return (a.name or "") < (b.name or "")
    end)
end

local function DrawList()
    for i, row in ipairs(Mt.rows) do
        local e = mList[mOffset + i]
        row.entry = e
        if e then
            local _, _, _, _, icon = ItemInfo(e.out)
            row.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            local ci = COLOR_INFO[e.color]
            row.name:SetText(e.name)
            if ci then row.name:SetTextColor(unpack(ci[2])) else row.name:SetTextColor(unpack(H().TEXT)) end
            row.level:SetText(e.learn or "")
            row.chance:SetText(string.format("%d %%", math.floor((e.chance or 0) * 100 + 0.5)))
            if e.rate then
                row.rate:SetText(string.format("%d %%", math.floor(e.rate * 100 + 0.5)))
                row.rate:SetTextColor(unpack(e.rate >= 0.5 and H().GREEN or (e.rate >= 0.2 and H().ORANGE or H().RED)))
            else
                row.rate:SetText("?")
                row.rate:SetTextColor(unpack(H().SOFT))
            end
            if e.gain then
                row.gain:SetText((e.gain >= 0 and "+" or "-") .. Money(math.abs(e.gain)))
                row.gain:SetTextColor(unpack(e.gain >= 0 and H().GREEN or H().RED))
            else
                row.gain:SetText("?")
                row.gain:SetTextColor(unpack(H().SOFT))
            end
            local learn = e.learnCost or 0
            row.recipe:SetText(learn > 0 and Money(learn) or "")
            row.sel:SetShown(mSel and mSel.spell == e.spell)
            row:Show()
        else
            row:Hide()
        end
    end
end

local function DrawTabs()
    local profs = API() and API().Professions() or {}
    for i, b in ipairs(Mt.tabs) do
        local pr = profs[i]
        if pr then
            b.prof = pr
            b:SetLabel(API().TabLabel(pr))
            b:SetStyle(mProf and mProf.id == pr.id and "solid" or (pr.learned and "outline" or "muted"))
            b:Show()
        else
            b:Hide()
        end
    end
    if Mt.level and mProf and not Mt.level.edit:HasFocus() then
        local real = API().LevelOf(mProf)
        Mt.level.edit:SetText(mLevel or real)
        Mt.level.edit:SetTextColor(unpack(mLevel and mLevel ~= real and H().ORANGE or H().TEXT))
    end
end

-- La fiche de la recette choisie.
local function DrawFiche()
    local Hc = H()
    local f = Mt.fiche
    f.empty:SetShown(mSel == nil)
    f.body:SetShown(mSel ~= nil)
    if not mSel then return end
    local e = mSel
    local _, _, quality, _, icon = ItemInfo(e.out)
    f.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    f.name:SetText(e.name)
    local ci = COLOR_INFO[e.color]
    if ci then f.name:SetTextColor(unpack(ci[2])) else f.name:SetTextColor(QualityColor(quality)) end
    if e.known then
        f.sub:SetText(string.format("%s · %d %%", ci and ci[1] or "?", math.floor((e.chance or 0) * 100 + 0.5)))
        f.sub:SetTextColor(unpack(Hc.SOFT))
    else
        f.sub:SetText("À apprendre : " .. (e.learnLabel or "?"))
        f.sub:SetTextColor(unpack(Hc.ORANGE))
    end
    if e.gain then
        f.gain:SetText((e.gain >= 0 and "+" or "-") .. Money(math.abs(e.gain)))
        f.gain:SetTextColor(unpack(e.gain >= 0 and Hc.GREEN or Hc.RED))
    else
        f.gain:SetText("?")
        f.gain:SetTextColor(unpack(Hc.SOFT))
    end
    f.sales:SetText(API().SalesText(e.out, mWant) or "")
    f.reuse:SetText(API().ReuseText(e) or "")

    -- Combien en fabriquer ?
    if not f.qtyEdit:HasFocus() then f.qtyEdit:SetText(mWant) end
    local up = API().CraftsPlanned(e)
    f.presets[4].value = up
    f.presets[4]:SetLabel("Pour monter : " .. up)
    local maxN = MaxAffordable(e)
    f.presets[5].value = math.max(1, maxN)
    f.presets[5]:SetLabel("Max bourse : " .. maxN)
    local x = 0
    for _, b in ipairs(f.presets) do
        b:SetWidth(b.label:GetStringWidth() + 24)
        b:ClearAllPoints(); b:SetPoint("LEFT", f.presetArea, "LEFT", x, 0)
        x = x + b:GetWidth() + 6
        b:SetStyle(b.value == mWant and "solid" or "outline")
    end
    local learnCost = (not e.known) and API().LearnCost(e) or 0
    if e.gain then
        local g = e.gain * mWant - learnCost
        f.gainN:SetText((g >= 0 and "+" or "-") .. Money(math.abs(g)))
        f.gainN:SetTextColor(unpack(g >= 0 and Hc.GREEN or Hc.RED))
    else
        f.gainN:SetText("?")
    end
    f.gainNLabel:SetText(H().Upper("Gain pour " .. mWant))

    -- Arbre (à gauche) et totaux à réunir (à droite).
    local list = API().Needs(e, mWant)
    mFiche = list
    local root, where = API().Tree(e, mWant)
    -- Arbre aplati, en sautant les branches repliées ; guides = traits de chaque niveau.
    mTreeRows = {}
    local function Walk(node, prefix, last)
        local guides = {}
        if node.depth > 0 then
            for _, g in ipairs(prefix) do guides[#guides + 1] = g end
            guides[#guides + 1] = last and "l" or "t"
        end
        mTreeRows[#mTreeRows + 1] = { node = node, guides = guides }
        if mFolded[node.key] then return end
        local next = {}
        if node.depth > 0 then
            for _, g in ipairs(prefix) do next[#next + 1] = g end
            next[#next + 1] = last and "e" or "v"
        end
        for i, k in ipairs(node.kids) do Walk(k, next, i == #node.kids) end
    end
    Walk(root, {}, true)
    Mt.treeRoot = root
    mTreeOffset = math.max(0, math.min(mTreeOffset, #mTreeRows - TREE_ROWS))
    local cyan = Hc.CYAN
    for i, row in ipairs(f.tree) do
        local t = mTreeRows[mTreeOffset + i]
        row.t = t
        if t then
            local nd = t.node
            for gi, g in ipairs(row.g) do
                local k = t.guides[gi]
                g.v:SetShown(k == "v" or k == "t" or k == "l")
                g.v:ClearAllPoints()
                if k == "l" then
                    g.v:SetPoint("TOPLEFT", row, "TOPLEFT", (gi - 1) * TREE_STEP + 8, 0); g.v:SetHeight(13)
                else
                    g.v:SetPoint("TOPLEFT", row, "TOPLEFT", (gi - 1) * TREE_STEP + 8, 0)
                    g.v:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", (gi - 1) * TREE_STEP + 8, 0)
                end
                g.h:SetShown(k == "t" or k == "l")
            end
            local x = math.min(#t.guides, TREE_GUIDES) * TREE_STEP
            row.fold:SetShown(nd.depth > 0 and #nd.kids > 0)
            row.fold:SetPoint("LEFT", row, "LEFT", x + 2, 0)
            row.fold.t:SetText(mFolded[nd.key] and "+" or "-")
            row.icon:SetPoint("LEFT", row, "LEFT", x + 20, 0)
            local _, _, _, _, ic = ItemInfo(nd.id)
            row.icon:SetTexture(ic or "Interface\\Icons\\INV_Misc_QuestionMark")
            row.name:SetText(nd.depth == 0 and (nd.name .. " x" .. nd.qty) or nd.name)
            row.name:SetTextColor(unpack(nd.depth == 0 and Hc.ORANGE or (nd.craft and Hc.TEXT or Hc.SOFT)))
            row.qty:SetText(nd.depth == 0 and "" or nd.qty)
            row.craft:SetText(nd.craft or "")
            row.craftBox:SetShown(nd.craft ~= nil)
            if nd.craft then row.craftBox:SetWidth(row.craft:GetStringWidth() + 12) end
            row.bg:SetShown(nd.depth == 0)
            row:Show()
        else
            row:Hide()
        end
    end

    -- TOTAL (SACS + BANQUE) : une ligne par objet à réunir (les objets fabriqués n'y sont pas), un clic par ligne.
    mNeeds = {}
    for _, l in ipairs(list) do if not l.made then mNeeds[#mNeeds + 1] = l end end
    mNeedOffset = math.max(0, math.min(mNeedOffset, #mNeeds - NEED_ROWS))
    local toPay, clicks = 0, 0
    for _, l in ipairs(mNeeds) do
        local miss = l.missing or 0
        local mapOnly = l.buy and miss > 0 and (l.buy.src or ""):find("marchand") and not (ns.PrixHV and ns.PrixHV(l.buy.id))
            and not (MerchantFrame and MerchantFrame:IsShown()) and true or false
        l._map = mapOnly
        if l.buy and miss > 0 then
            toPay = toPay + (l.cost or 0)
            if not mapOnly then clicks = clicks + 1 end
        end
    end
    for i, row in ipairs(f.needs) do
        local l = mNeeds[mNeedOffset + i]
        row.line = l
        if l then
            local miss = l.missing or 0
            local _, _, _, _, ic = ItemInfo(l.id or 0)
            row.icon:SetTexture(ic or "Interface\\Icons\\INV_Misc_QuestionMark")
            local split = l.id and where[l.id] and #where[l.id] > 1 and (" |cff5f8a99(" .. table.concat(where[l.id], " + ") .. ")|r") or ""
            row.name:SetText(l.name .. split)
            row.name:SetTextColor(unpack(l.recipe and Hc.ORANGE or Hc.TEXT))
            local txt
            if l.recipe then
                txt = l.price or ""
            else
                txt = string.format("|cff9fbfccil faut %d · tu as %d|r", l.need or 0, math.min(l.have or 0, l.need or 0))
                if l.note then txt = txt .. " |cff5f8a99(" .. l.note .. ")|r" end
                txt = txt .. (miss > 0 and (" · |cffffb054manque " .. miss .. "|r " .. (l.priceOnly or "")) or " · |cff5cffb0ok|r")
            end
            row.info:SetText(txt)
            row.mapMode = l._map
            if l.buy and miss > 0 then
                row.buy:SetLabel(l._map and "Carte" or (l.buy.kind == "recipe" and "Acheter" or ("Acheter " .. miss)))
                row.buy:SetWidth(row.buy.label:GetStringWidth() + 16)
                row.buy:Show()
            else
                row.buy:Hide()
            end
            row:Show()
        else
            row:Hide()
        end
    end
    local money = GetMoney()
    f.pay:SetText("À acheter : " .. Money(toPay))
    local after = money - toPay
    f.purse:SetText("Ta bourse : " .. Money(money) .. "   ·   après : " .. (after >= 0 and Money(after) or ("|cffff7373-" .. Money(-after) .. "|r")))
    if clicks == 0 then
        f.buyAll:SetLabel("Tu as tout")
        f.buyAll:SetEnabled(false)
    else
        f.buyAll:SetLabel(string.format("Tout acheter · %s · %d clic%s", Money(toPay), clicks, clicks > 1 and "s" or ""))
        f.buyAll:SetEnabled(after >= 0) -- (HV ou marchand ouvert : sinon BuyLine rappelle où acheter)
    end
    f.note:SetText(after < 0 and "|cffff7373Pas assez d'argent : baisse le nombre de fabrications.|r" or "")
end

function F.RefreshMetiers(keepList)
    if not (metiersFrame and metiersFrame:IsVisible() and API()) then return end
    if not mProf then mProf = API().Professions()[1] end
    DrawTabs()
    if not keepList then BuildList() end
    if Mt.markSort then Mt.markSort() end
    if mSel then
        -- Recette recalculée (prix, sacs) : on reprend la nouvelle entrée de la même recette.
        for _, e in ipairs(mList) do if e.spell == mSel.spell then mSel = e end end
    end
    mOffset = math.max(0, math.min(mOffset, #mList - MLIST_ROWS))
    DrawList()
    DrawFiche()
end

local function SelectRecipe(e)
    if mSel ~= e and (not mSel or mSel.spell ~= e.spell) then
        mWant, mFolded, mTreeOffset, mNeedOffset = 1, {}, 0, 0
    end
    mSel = e
    DrawList()
    DrawFiche()
end

-- Recherche d'un objet à fabriquer (tous métiers) : ouvre sa fiche.
local function OpenFound(x)
    local r = x.r
    local prof
    for _, pr in ipairs(API().Professions()) do if pr.id == r[1] then prof = pr end end
    prof = prof or { id = r[1], name = ns.METIERS and ns.METIERS[r[1]] or "?", learned = false }
    mProf = prof
    BuildList()
    local e = API().Compute(r[1], API().LevelOf(prof), r[2])[1]
    Mt.results:Hide()
    Mt.search.edit:SetText("")
    Mt.search.edit:ClearFocus()
    if e then
        mWant = 1
        mSel = e
        DrawTabs()
        DrawList()
        DrawFiche()
    end
end

local function UpdateResults()
    local text = Mt.search.edit:GetText() or ""
    Mt.placeholder:SetShown(text == "")
    local found = API() and API().Find(text) or {}
    for i, b in ipairs(Mt.resultButtons) do
        local x = found[i]
        b.found = x
        if x then
            local metier = ns.METIERS and ns.METIERS[x.r[1]] or ""
            b.text:SetText(string.format("%s  |cff5f8a99%s %d|r", x.label, metier, x.r[4] or 0))
            b:Show()
        else
            b:Hide()
        end
    end
    Mt.results:SetHeight(math.max(1, math.min(#found, #Mt.resultButtons)) * 28 + 4)
    Mt.results:SetShown(#found > 0)
end

-- « CARTE » (demande de Jérémie, 08/11) : un objet ou une recette qui ne s'achète QUE chez un marchand (pas en
-- vente à l'HV) → au lieu de « Acheter », un bouton qui ouvre la carte du monde sur le marchand de ta faction
-- le PLUS PROCHE de toi (s'il y en a plusieurs) et y pose un point (point de passage du jeu).
-- Marchands : recette = champ 11 de nos recettes (« PNJ:zone:faction », WhatsTraining) ; objet = QuestieDB
-- (Item « vendors »). Positions : QuestieDB (Npc « spawns », zone → carte avec ns.ZONE_MAP, EryAddon_Quetes.lua).
-- Distance : positions du monde (C_Map.GetWorldPosFromMapPos) ; un autre continent passe après.
local function QDB(entity, id, field)
    local Q = _G.LibQuestieDB
    local e = Q and Q[entity]
    if not (e and e.Get) then return nil end
    local ok, v = pcall(e.Get, id, field)
    return ok and v or nil
end

local function VendorsOf(itemID, vend)
    local mine = (UnitFactionGroup and UnitFactionGroup("player") == "Alliance") and "A" or "H"
    local out = {}
    for npc, _, fac in (vend or ""):gmatch("(%d+):(%d+):?(%a?)") do
        if fac == "" or fac == "N" or fac == mine then out[#out + 1] = tonumber(npc) end
    end
    if #out == 0 and itemID then
        for _, npc in ipairs(QDB("Item", itemID, "vendors") or {}) do
            local f = QDB("Npc", npc, "friendlyToFaction")
            if not f or f == "AH" or f == mine then out[#out + 1] = npc end
        end
    end
    return out
end

-- Tous les marchands de ta faction pour cet objet, le plus proche d'abord :
-- { { npc, name, map, zone, x, y (0 à 1), d (distance², 1e11 autre continent, 1e12 position inconnue) } }.
local function VendorList(itemID, vend)
    local vendors = VendorsOf(itemID, vend)
    local zoneMap = ns.ZONE_MAP or {}
    local pCont, pPos
    local pMap = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    if pMap then
        local pos = C_Map.GetPlayerMapPosition(pMap, "player")
        if pos then
            local ok, cont, wpos = pcall(C_Map.GetWorldPosFromMapPos, pMap, pos)
            if ok then pCont, pPos = cont, wpos end
        end
    end
    local list = {}
    for _, npc in ipairs(vendors) do
        local best = { npc = npc, name = QDB("Npc", npc, "name") or ("PNJ n° " .. npc), d = 1e12 }
        local moved = ns.NPC_MOVED and ns.NPC_MOVED[npc]
        local spawns = moved and { [moved.area] = { { moved.x, moved.y } } } or QDB("Npc", npc, "spawns") or {}
        local zoneMap = moved and { [moved.area] = moved.map } or zoneMap
        for area, pts in pairs(spawns) do
            local map = zoneMap[area]
            if map and type(pts) == "table" then
                for _, p in ipairs(pts) do
                    local x, y = p[1], p[2]
                    if x and y and x >= 0 and y >= 0 then
                        local d = 1e12 - 1 -- position connue, distance inconnue
                        local ok, cont, wpos = pcall(C_Map.GetWorldPosFromMapPos, map, CreateVector2D(x / 100, y / 100))
                        if ok and cont and pCont then
                            if cont == pCont and wpos and pPos then
                                local dx, dy = wpos.x - pPos.x, wpos.y - pPos.y
                                d = dx * dx + dy * dy
                            else
                                d = 1e11 -- autre continent
                            end
                        end
                        if d < best.d or not best.map then
                            best.map, best.x, best.y, best.d = map, x / 100, y / 100, d
                        end
                    end
                end
            end
        end
        if best.map then
            local info = C_Map.GetMapInfo and C_Map.GetMapInfo(best.map)
            best.zone = info and info.name or nil
        end
        list[#list + 1] = best
    end
    table.sort(list, function(a, b) return a.d < b.d end)
    return list
end

function F.ShowVendor(itemID, vend, label)
    label = label or "Objet"
    local list = VendorList(itemID, vend)
    if #list == 0 then Msg(label .. " : aucun marchand connu pour ta faction.") return end
    local best = list[1]
    if not best.map then
        local names = {}
        for i, v in ipairs(list) do if i <= 3 then names[#names + 1] = v.name end end
        Msg(label .. " : vendu par " .. table.concat(names, ", ") .. " (position inconnue).")
        return
    end
    -- Point sur la carte (point de passage du jeu, suivi à l'écran) + carte ouverte sur la zone du marchand.
    pcall(function()
        C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(best.map, best.x, best.y))
        if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then C_SuperTrack.SetSuperTrackedUserWaypoint(true) end
    end)
    if OpenWorldMap then
        pcall(OpenWorldMap, best.map)
    elseif WorldMapFrame then
        pcall(ShowUIPanel, WorldMapFrame)
        pcall(WorldMapFrame.SetMapID, WorldMapFrame, best.map)
    end
    Msg(string.format("%s : %s, %s (%d, %d). Point posé sur la carte.", label, best.name, best.zone or "?",
        math.floor(best.x * 100 + 0.5), math.floor(best.y * 100 + 0.5)))
end

-- Info-bulle « Vendu par » : tous les marchands de ta faction, le plus proche en premier (demande de Jérémie :
-- « quand je survole ce qui parle de marchands, je dois voir la liste des marchands »). Faux si aucun.
function F.VendorTooltip(owner, itemID, vend, title)
    local list = VendorList(itemID, vend)
    if #list == 0 then return false end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:AddLine(title or "Vendu par")
    for i, v in ipairs(list) do
        if i > 12 then GameTooltip:AddLine(string.format("… et %d autres", #list - 12), 0.6, 0.6, 0.6) break end
        local where = v.map and string.format("%s  %d, %d", v.zone or "?", math.floor(v.x * 100 + 0.5), math.floor(v.y * 100 + 0.5))
            or "position inconnue"
        local near = i == 1 and v.d < 1e11
        GameTooltip:AddDoubleLine(v.name .. (near and "  (le plus proche)" or ""), where,
            near and 0.36 or 1, 1, near and 0.69 or 1, 0.75, 0.75, 0.75)
    end
    GameTooltip:Show()
    return true
end

-- L'écran Métiers est créé UNE fois et accroché là où on l'affiche : la grande fenêtre de l'HV, ou la
-- fenêtre ouverte avec K (demande de Jérémie : « refaire l'onglet qui s'ouvre avec K pour afficher ça, en
-- version légèrement plus réduite »).
function F.AttachMetiers(holder)
    if not metiersFrame then
        metiersFrame = CreateFrame("Frame", nil, holder)
        F.CreateMetiersScreen(metiersFrame)
    end
    metiersFrame:SetParent(holder)
    metiersFrame:ClearAllPoints()
    metiersFrame:SetAllPoints(holder)
    metiersFrame:Show()
end

local kWindow
function F.MetiersWindow()
    if kWindow then return kWindow end
    local cw, ch = DESIGN_W - 2 - RAIL_W - 1, DESIGN_H - 2 - TOP_H
    kWindow = H().Window("EryMetiersFrame", cw, ch + 28, "Métiers")
    kWindow.content = CreateFrame("Frame", nil, kWindow)
    kWindow.content:SetPoint("TOPLEFT", 0, -28)
    kWindow.content:SetPoint("BOTTOMRIGHT")
    kWindow:SetScript("OnShow", function(self)
        -- Un peu plus petite que la grande fenêtre de l'HV, et toujours dans l'écran.
        self:SetScale(math.min(0.8, (UIParent:GetHeight() - 40) / (ch + 28), (UIParent:GetWidth() - 40) / cw))
        F.AttachMetiers(self.content)
        if H().FixBorders then H().FixBorders(self) end -- traits des cadres de CETTE fenêtre : au moins 1 vrai pixel
        F.RefreshMetiers()
    end)
    kWindow:Hide()
    return kWindow
end

-- Pour le test hors jeu.
F._TestMetiers = function(action, arg)
    if action == "select" then SelectRecipe(arg) elseif action == "want" then mWant = arg; DrawFiche()
    elseif action == "open" then OpenFound(arg) end
    return mList, mSel, mFiche, mWant, mProf
end

function F.CreateMetiersScreen(parent)
    local Hc = H()
    local cw = DESIGN_W - 2 - RAIL_W - 1
    local ch = DESIGN_H - 2 - TOP_H

    -- Recherche (en haut, toute la largeur).
    Mt.search = Box(parent, cw - 2 * PAD, 40)
    Mt.search:SetPoint("TOPLEFT", PAD, -PAD)
    local e = CreateFrame("EditBox", nil, Mt.search)
    e:SetPoint("TOPLEFT", 12, 0); e:SetPoint("BOTTOMRIGHT", -12, 0)
    e:SetFont(Hc.FONT, 15, ""); e:SetTextColor(unpack(Hc.TEXT)); e:SetAutoFocus(false)
    e:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus(); Mt.results:Hide() end)
    e:SetScript("OnEnterPressed", function() local b = Mt.resultButtons[1]; if b.found then OpenFound(b.found) end end)
    e:SetScript("OnTextChanged", UpdateResults)
    e:SetScript("OnEditFocusGained", function() SetEdges(Mt.search, Hc.CYAN) end)
    e:SetScript("OnEditFocusLost", function() SetEdges(Mt.search, { 0.165, 0.31, 0.388 }) end)
    Mt.search.edit = e
    Mt.placeholder = Hc.Text(Mt.search, 15, { 0.37, 0.5, 0.56 }); Mt.placeholder:SetPoint("LEFT", 12, 0)
    Mt.placeholder:SetText("Objet à fabriquer (tous métiers)")

    -- Onglets des métiers + « Monter le métier ».
    Mt.tabs = {}
    for i = 1, 8 do
        local b = Hc.Button(parent, "", 108, 32, "outline")
        b.label:SetFont(Hc.FONT, 13, "")
        b:SetPoint("TOPLEFT", PAD + (i - 1) * 113, -66)
        b:SetScript("OnClick", function(self) mProf = self.prof; mSel = nil; mOffset = 0; mLevel = nil; F.RefreshMetiers() end)
        Mt.tabs[i] = b
    end
    -- « Niv. » : niveau simulé du métier affiché (orange quand ce n'est pas ton vrai niveau) ; − / + de 5 en 5.
    local lvlLabel = Hc.Label(parent, "Niv.", 11, { 0.5, 0.64, 0.7 })
    lvlLabel:SetPoint("TOPLEFT", PAD + 8 * 113 + 6, -76)
    local lvMinus = Hc.Button(parent, "-", 22, 32, "muted"); lvMinus:SetPoint("LEFT", lvlLabel, "RIGHT", 6, 0)
    Mt.level = NumberBox(parent, 46, 32, 15, function()
        local v = tonumber(Mt.level.edit:GetText())
        if v and v >= 1 then mLevel = math.min(300, v); mSel = nil; mOffset = 0; F.RefreshMetiers() end
    end)
    Mt.level:SetPoint("LEFT", lvMinus, "RIGHT", 2, 0)
    Mt.level.edit:SetJustifyH("CENTER")
    local lvPlus = Hc.Button(parent, "+", 22, 32, "muted"); lvPlus:SetPoint("LEFT", Mt.level, "RIGHT", 2, 0)
    local function Step(d)
        if not mProf then return end
        local cur = mLevel or API().LevelOf(mProf)
        local v = math.max(1, math.min(300, (d > 0 and (math.floor(cur / 5) + 1) * 5) or (math.ceil(cur / 5) - 1) * 5))
        mLevel = (v ~= API().LevelOf(mProf)) and v or nil
        mSel = nil; mOffset = 0
        F.RefreshMetiers()
    end
    lvMinus:SetScript("OnClick", function() Step(-1) end)
    lvPlus:SetScript("OnClick", function() Step(1) end)
    for _, w in ipairs({ lvMinus, lvPlus }) do
        w:HookScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:AddLine("Voir les recettes à ce niveau du métier"); GameTooltip:Show()
        end)
        w:HookScript("OnLeave", function() GameTooltip:Hide() end)
    end
    local monter = Hc.Check(parent, "Monter le métier")
    monter:SetPoint("TOPRIGHT", -PAD - 130, -74)
    monter:SetChecked(EryAddonDB.jobsMonter and true or false)
    monter:SetScript("OnClick", function(self) EryAddonDB.jobsMonter = self:GetChecked() and true or false; F.RefreshMetiers() end)

    -- Liste des recettes (gauche).
    local listW, top = 478, -110 -- (+78 le 14/11 : colonnes « Niv. » et « % vente », le nom garde sa largeur)
    local list = Panel(parent)
    list:SetPoint("TOPLEFT", PAD, top)
    list:SetSize(listW, ch + top - PAD)
    local head = CreateFrame("Frame", nil, list)
    head:SetPoint("TOPLEFT", 1, -1); head:SetPoint("TOPRIGHT", -1, -1); head:SetHeight(30)
    local hb = Hc.Tex(head, "BACKGROUND", { 0.039, 0.082, 0.125 }, 1); hb:SetAllPoints()
    local h1 = Hc.Label(head, "Recette", 11, { 0.5, 0.64, 0.7 }); h1:SetPoint("LEFT", 66, 0)
    -- Titres de colonnes = TRI (demande de Jérémie, 14/11) : clic = trier par cette colonne, 2e clic = ordre
    -- inversé. Colonne du tri en cyan, avec « + » (du plus grand au plus petit) ou « - » à côté.
    local sortHeads = {}
    local function SortHead(text, key, anchor, x)
        local hbtn = CreateFrame("Button", nil, head)
        hbtn.label = Hc.Label(hbtn, text, 11, { 0.5, 0.64, 0.7 })
        hbtn.label:SetPoint(anchor, 0, 0)
        hbtn:SetPoint(anchor, head, anchor, x, 0)
        hbtn:SetSize(hbtn.label:GetStringWidth() + 14, 30)
        hbtn.text, hbtn.key = text, key
        hbtn:SetScript("OnClick", function(self)
            local t = MetiersSort()
            if t.k == self.key then t.desc = not t.desc else t.k, t.desc = self.key, SORT_FIRST_DESC[self.key] end
            mOffset = 0
            F.RefreshMetiers()
        end)
        hbtn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine("Trier par " .. SORT_TIPS[self.key])
            if MetiersSort().k == self.key then GameTooltip:AddLine("Reclique pour inverser l'ordre", 0.6, 0.6, 0.6) end
            GameTooltip:Show()
        end)
        hbtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        sortHeads[#sortHeads + 1] = hbtn
    end
    SortHead("Niv.", "niveau", "LEFT", 36)
    SortHead("Chance", "chance", "RIGHT", -224)
    SortHead("% vente", "vente", "RIGHT", -176)
    SortHead("Gain", "gain", "RIGHT", -86)
    SortHead("Recette", "recette", "RIGHT", -12)
    Mt.markSort = function()
        local t = MetiersSort()
        for _, hbtn in ipairs(sortHeads) do
            local on = t.k == hbtn.key
            hbtn.label:SetText(on and (hbtn.text .. (t.desc and " +" or " -")) or hbtn.text)
            hbtn.label:SetTextColor(unpack(on and Hc.CYAN or { 0.5, 0.64, 0.7 }))
        end
    end
    Mt.markSort()
    Mt.rows = {}
    for i = 1, MLIST_ROWS do
        local r = CreateFrame("Button", nil, list)
        r:SetPoint("TOPLEFT", 1, -31 - (i - 1) * 36); r:SetPoint("TOPRIGHT", -1, -31 - (i - 1) * 36); r:SetHeight(36)
        Hc.RowHighlight(r)
        r.sel = Hc.Tex(r, "BACKGROUND", { 0.059, 0.141, 0.2 }, 1); r.sel:SetAllPoints()
        local ln = Hc.Tex(r, "BORDER", { 0.071, 0.161, 0.227 }); ln:SetHeight(1); ln:SetPoint("BOTTOMLEFT"); ln:SetPoint("BOTTOMRIGHT")
        r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(24, 24); r.icon:SetPoint("LEFT", 8, 0)
        -- Colonne Chance de largeur fixe, et le nom s'arrête 8 px avant (coupé avec « … ») : il ne passe
        -- plus sous « 100 % » (retour de Jérémie, 08/11).
        r.chance = Hc.Text(r, 13, Hc.SOFT); r.chance:SetPoint("RIGHT", r, "RIGHT", -224, 0); r.chance:SetJustifyH("RIGHT")
        r.chance:SetWidth(46)
        r.rate = Hc.Text(r, 13, Hc.SOFT); r.rate:SetPoint("RIGHT", r, "RIGHT", -176, 0); r.rate:SetJustifyH("RIGHT")
        r.rate:SetWidth(42)
        -- Niveau de la recette (colonne « Niv. », 14/11), entre l'icône et le nom.
        r.level = Hc.Text(r, 12, Hc.SOFT); r.level:SetPoint("LEFT", r.icon, "RIGHT", 4, 0)
        r.level:SetWidth(26); r.level:SetJustifyH("CENTER")
        r.name = Hc.Text(r, 14, Hc.TEXT); r.name:SetPoint("LEFT", r.level, "RIGHT", 4, 0)
        r.name:SetPoint("RIGHT", r.chance, "LEFT", -8, 0)
        r.gain = Hc.Text(r, 13, Hc.GREEN); r.gain:SetPoint("RIGHT", r, "RIGHT", -86, 0); r.gain:SetJustifyH("RIGHT")
        -- Prix de la recette à apprendre (orange), vide si tu la connais (comme l'ancien onglet, demande de Jérémie).
        r.recipe = Hc.Text(r, 13, Hc.ORANGE); r.recipe:SetPoint("RIGHT", r, "RIGHT", -12, 0); r.recipe:SetJustifyH("RIGHT")
        r:SetScript("OnClick", function(self)
            if not self.entry then return end
            if ns.ShiftLink and ns.ShiftLink(self.entry.out, self.entry.spell) then return end
            SelectRecipe(self.entry)
        end)
        r:SetScript("OnEnter", function(self)
            if not self.entry then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetItemByID(self.entry.out)
            GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        r:Hide()
        Mt.rows[i] = r
    end
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta)
        mOffset = math.max(0, math.min(math.max(0, #mList - MLIST_ROWS), mOffset - delta * 3))
        DrawList()
    end)

    -- Fiche (droite).
    local fw = cw - 2 * PAD - listW - PAD
    local f = Panel(parent)
    f:SetPoint("TOPLEFT", list, "TOPRIGHT", PAD, 0)
    f:SetSize(fw, ch + top - PAD)
    Mt.fiche = f
    f.empty = Hc.Text(f, 16, Hc.SOFT); f.empty:SetPoint("CENTER"); f.empty:SetText("Choisis une recette, ou cherche un objet")
    f.body = CreateFrame("Frame", nil, f); f.body:SetAllPoints()
    local b = f.body
    local IN = 18
    f.icon = b:CreateTexture(nil, "ARTWORK"); f.icon:SetSize(48, 48); f.icon:SetPoint("TOPLEFT", IN, -IN)
    f.name = Hc.Text(b, 22, Hc.TEXT); f.name:SetPoint("TOPLEFT", f.icon, "TOPRIGHT", 12, -2); f.name:SetWidth(fw - 2 * IN - 60 - 160)
    f.sub = Hc.Text(b, 13, Hc.SOFT); f.sub:SetPoint("TOPLEFT", f.name, "BOTTOMLEFT", 0, -6); f.sub:SetWidth(fw - 2 * IN - 60 - 160)
    -- Survol de « À apprendre : patron … chez X ou 2 autres » : la liste des marchands du patron.
    local subHover = CreateFrame("Frame", nil, b)
    subHover:SetPoint("TOPLEFT", f.sub, "TOPLEFT", 0, 3); subHover:SetPoint("BOTTOMRIGHT", f.sub, "BOTTOMRIGHT", 0, -3)
    subHover:EnableMouse(true)
    subHover:SetScript("OnEnter", function(self)
        if mSel and not mSel.known and (mSel.vend or "") ~= "" then
            F.VendorTooltip(self, mSel.teach, mSel.vend, "Patron vendu par")
        end
    end)
    subHover:SetScript("OnLeave", function() GameTooltip:Hide() end)
    local gl = Hc.Label(b, "Gain par fabrication", 11, { 0.5, 0.64, 0.7 }); gl:SetPoint("TOPRIGHT", -IN, -IN)
    f.gain = Hc.Text(b, 22, Hc.GREEN); f.gain:SetPoint("TOPRIGHT", gl, "BOTTOMRIGHT", 0, -4); f.gain:SetJustifyH("RIGHT")
    f.sales = Hc.Text(b, 13, Hc.TEXT); f.sales:SetPoint("TOPLEFT", IN, -78); f.sales:SetWidth(fw - 2 * IN)
    f.reuse = Hc.Text(b, 12, Hc.SOFT); f.reuse:SetPoint("TOPLEFT", IN, -96); f.reuse:SetWidth(fw - 2 * IN)

    local qbox = Box(b, fw - 2 * IN, 70)
    qbox:SetPoint("TOPLEFT", IN, -118)
    -- (Pas de titre « Combien en fabriquer ? » : le compteur parle de lui-même, demande de Jérémie.)
    local minus = Hc.Button(qbox, "-", 34, 34, "muted"); minus:SetPoint("LEFT", 12, 0)
    local qe = NumberBox(qbox, 56, 34, 20, function()
        local v = tonumber(f.qtyEdit:GetText())
        if v and v >= 1 then mWant = math.min(200, v); DrawFiche() end
    end)
    qe:SetPoint("LEFT", minus, "RIGHT", 4, 0)
    f.qtyEdit = qe.edit
    f.qtyEdit:SetJustifyH("CENTER")
    local plus = Hc.Button(qbox, "+", 34, 34, "muted"); plus:SetPoint("LEFT", qe, "RIGHT", 4, 0)
    minus:SetScript("OnClick", function() mWant = math.max(1, mWant - 1); DrawFiche() end)
    plus:SetScript("OnClick", function() mWant = math.min(200, mWant + 1); DrawFiche() end)
    f.presetArea = CreateFrame("Frame", nil, qbox)
    f.presetArea:SetPoint("LEFT", plus, "RIGHT", 14, 0); f.presetArea:SetSize(420, 34)
    f.presets = {}
    for i, v in ipairs({ 1, 5, 10, 0, 0 }) do
        local pb = Hc.Button(f.presetArea, tostring(v), 40, 34, "outline")
        pb.label:SetFont(Hc.FONT, 13, "")
        pb.value = v
        pb:SetScript("OnClick", function(self) if self.value and self.value >= 1 then mWant = self.value; DrawFiche() end end)
        f.presets[i] = pb
    end
    f.gainNLabel = Hc.Text(qbox, 11, { 0.5, 0.64, 0.7 }); f.gainNLabel:SetPoint("TOPRIGHT", -12, -10); f.gainNLabel:SetJustifyH("RIGHT")
    f.gainN = Hc.Text(qbox, 20, Hc.GREEN); f.gainN:SetPoint("TOPRIGHT", f.gainNLabel, "BOTTOMRIGHT", 0, -6); f.gainN:SetJustifyH("RIGHT")

    -- Arbre de la recette (gauche) et TOTAL (SACS + BANQUE) (droite). Titres courts (demande de Jérémie : un
    -- long titre coûte de la place pour rien).
    local tw = fw - 2 * IN
    local RW = 290
    local TW = tw - RW - 10
    local function Head(parent, w)
        local h = CreateFrame("Frame", nil, parent)
        h:SetSize(w, 26)
        local hb = Hc.Tex(h, "BACKGROUND", { 0.039, 0.082, 0.125 }, 1); hb:SetAllPoints()
        return h
    end
    local th = Head(b, TW); th:SetPoint("TOPLEFT", IN, -200)
    -- Tout replier / tout déplier : deux petits boutons (info-bulle pour le sens).
    local function Mini(txt, tip, fn)
        local mb = Hc.Button(th, txt, 22, 18, "muted")
        mb:SetScript("OnClick", fn)
        mb:HookScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:AddLine(tip); GameTooltip:Show() end)
        mb:HookScript("OnLeave", function() GameTooltip:Hide() end)
        return mb
    end
    local foldAll = Mini("-", "Tout replier", function()
        local function F2(nd) if nd.depth > 0 and #nd.kids > 0 then mFolded[nd.key] = true end
            for _, k in ipairs(nd.kids) do F2(k) end end
        if Mt.treeRoot then F2(Mt.treeRoot) end
        mTreeOffset = 0; DrawFiche()
    end)
    foldAll:SetPoint("LEFT", 6, 0)
    local openAll = Mini("+", "Tout déplier", function() mFolded = {}; DrawFiche() end)
    openAll:SetPoint("LEFT", foldAll, "RIGHT", 4, 0)
    local hq = Hc.Label(th, "Qté", 11, { 0.5, 0.64, 0.7 }); hq:SetPoint("RIGHT", th, "LEFT", TW - 112, 0)
    local hm = Hc.Label(th, "Métier", 11, { 0.5, 0.64, 0.7 }); hm:SetPoint("RIGHT", th, "RIGHT", -8, 0)
    f.tree = {}
    for i = 1, TREE_ROWS do
        local r = CreateFrame("Frame", nil, b)
        r:SetPoint("TOPLEFT", th, "BOTTOMLEFT", 0, -(i - 1) * 26); r:SetSize(TW, 26)
        r:EnableMouse(true)
        r.bg = Hc.Tex(r, "BACKGROUND", { 0.051, 0.114, 0.169 }, 1); r.bg:SetAllPoints()
        local ln = Hc.Tex(r, "BORDER", { 0.059, 0.133, 0.188 }); ln:SetHeight(1); ln:SetPoint("BOTTOMLEFT"); ln:SetPoint("BOTTOMRIGHT")
        -- Traits d'arborescence : un trait vertical par niveau (entier, ou jusqu'au milieu pour le dernier
        -- enfant) et un petit trait horizontal vers l'objet.
        r.g = {}
        for gi = 1, TREE_GUIDES do
            local v = Hc.Tex(r, "ARTWORK", Hc.CYAN); v:SetWidth(1)
            local hz = Hc.Tex(r, "ARTWORK", Hc.CYAN); hz:SetSize(10, 1)
            hz:SetPoint("LEFT", r, "LEFT", (gi - 1) * TREE_STEP + 8, 0)
            r.g[gi] = { v = v, h = hz }
        end
        r.fold = CreateFrame("Button", nil, r); r.fold:SetSize(14, 14)
        Hc.Border(r.fold, Hc.CYAN)
        r.fold.t = Hc.Text(r.fold, 12, Hc.CYAN); r.fold.t:SetPoint("CENTER", 0, 1)
        r.fold:SetScript("OnClick", function(self)
            local t = self:GetParent().t
            if t then mFolded[t.node.key] = not mFolded[t.node.key] or nil; DrawFiche() end
        end)
        r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(18, 18)
        r.qty = Hc.Text(r, 14, Hc.TEXT); r.qty:SetPoint("RIGHT", r, "LEFT", TW - 112, 0); r.qty:SetJustifyH("RIGHT")
        r.craftBox = CreateFrame("Frame", nil, r); r.craftBox:SetSize(80, 18); r.craftBox:SetPoint("RIGHT", -6, 0)
        Hc.Border(r.craftBox, Hc.CYAN)
        r.craft = Hc.Text(r.craftBox, 11, Hc.CYAN); r.craft:SetPoint("CENTER")
        r.name = Hc.Text(r, 13, Hc.TEXT); r.name:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
        r.name:SetPoint("RIGHT", r, "LEFT", TW - 160, 0)
        r:SetScript("OnEnter", function(self)
            if not self.t then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetItemByID(self.t.node.id); GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        r:SetScript("OnMouseUp", function(self) if self.t and ns.ShiftLink then ns.ShiftLink(self.t.node.id) end end)
        r:Hide()
        f.tree[i] = r
    end
    local treeArea = CreateFrame("Frame", nil, b)
    treeArea:SetPoint("TOPLEFT", th, "BOTTOMLEFT"); treeArea:SetSize(TW, TREE_ROWS * 26)
    treeArea:EnableMouseWheel(true)
    treeArea:SetScript("OnMouseWheel", function(_, delta)
        mTreeOffset = math.max(0, math.min(math.max(0, #mTreeRows - TREE_ROWS), mTreeOffset - delta * 3)); DrawFiche()
    end)

    local nh = Head(b, RW); nh:SetPoint("TOPLEFT", th, "TOPRIGHT", 10, 0)
    local nl = Hc.Label(nh, "Total (sacs + banque)", 11, { 0.5, 0.64, 0.7 }); nl:SetPoint("LEFT", 8, 0)
    f.needs = {}
    for i = 1, NEED_ROWS do
        local r = CreateFrame("Frame", nil, b)
        r:SetPoint("TOPLEFT", nh, "BOTTOMLEFT", 0, -(i - 1) * 40); r:SetSize(RW, 40)
        r:EnableMouse(true)
        local ln = Hc.Tex(r, "BORDER", { 0.071, 0.161, 0.227 }); ln:SetHeight(1); ln:SetPoint("BOTTOMLEFT"); ln:SetPoint("BOTTOMRIGHT")
        r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(18, 18); r.icon:SetPoint("TOPLEFT", 6, -4)
        r.buy = Hc.Button(r, "Acheter", 70, 18, "outline"); r.buy:SetPoint("TOPRIGHT", -4, -3)
        r.buy.label:SetFont(Hc.FONT, 11, "")
        r.name = Hc.Text(r, 13, Hc.TEXT); r.name:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
        r.name:SetPoint("RIGHT", r.buy, "LEFT", -6, 0)
        r.info = Hc.Text(r, 11, Hc.SOFT); r.info:SetPoint("TOPLEFT", 8, -24); r.info:SetPoint("RIGHT", r, "RIGHT", -4, 0)
        r.buy:SetScript("OnClick", function(self)
            local p = self:GetParent()
            local l = p.line
            if not (l and l.buy) then return end
            if p.mapMode then F.ShowVendor(l.buy.id, l.recipe and mSel and mSel.vend or nil, l.name)
            else API().BuyLine(l.buy) end
        end)
        r.buy:HookScript("OnEnter", function(self)
            local p = self:GetParent()
            local l = p.line
            if p.mapMode and l and l.buy then F.VendorTooltip(self, l.buy.id, l.recipe and mSel and mSel.vend or nil, "Pas à l'HV · vendu par") end
        end)
        r.buy:HookScript("OnLeave", function() GameTooltip:Hide() end)
        r:SetScript("OnEnter", function(self)
            local l = self.line
            if not (l and l.id) then return end
            if (l.priceOnly or l.price or ""):find("marchand") then
                F.VendorTooltip(self, l.buy and l.buy.id or l.id, l.recipe and mSel and mSel.vend or nil, "Vendu par")
            else
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetItemByID(l.id); GameTooltip:Show()
            end
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        r:SetScript("OnMouseUp", function(self) if self.line and self.line.id and ns.ShiftLink then ns.ShiftLink(self.line.id) end end)
        r:Hide()
        f.needs[i] = r
    end
    local needArea = CreateFrame("Frame", nil, b)
    needArea:SetPoint("TOPLEFT", nh, "BOTTOMLEFT"); needArea:SetSize(RW, NEED_ROWS * 40)
    needArea:EnableMouseWheel(true)
    needArea:SetScript("OnMouseWheel", function(_, delta)
        mNeedOffset = math.max(0, math.min(math.max(0, #mNeeds - NEED_ROWS), mNeedOffset - delta * 2)); DrawFiche()
    end)

    f.pay = Hc.Text(b, 14, Hc.TEXT); f.pay:SetPoint("BOTTOMLEFT", IN, 48)
    f.purse = Hc.Text(b, 13, Hc.SOFT); f.purse:SetPoint("BOTTOMLEFT", IN, 26)
    f.note = Hc.Text(b, 12, Hc.SOFT); f.note:SetPoint("BOTTOMLEFT", IN, 8)
    f.buyAll = GoButton(b, 330, 50)
    f.buyAll.label:SetFont(Hc.FONT, 14, "")
    f.buyAll:SetPoint("BOTTOMRIGHT", -IN, 14)
    f.buyAll:SetScript("OnClick", function()
        -- Chaque clic achète le composant suivant (le jeu exige un clic par achat).
        for _, l in ipairs(mNeeds or {}) do
            if l.buy and (l.missing or 0) > 0 and not l._map then API().BuyLine(l.buy) return end
        end
    end)

    -- Résultats de la recherche (par-dessus le reste).
    Mt.results = CreateFrame("Frame", nil, parent)
    Mt.results:SetPoint("TOPLEFT", Mt.search, "BOTTOMLEFT", 0, -2)
    Mt.results:SetPoint("TOPRIGHT", Mt.search, "BOTTOMRIGHT", 0, -2)
    Mt.results:SetFrameLevel(parent:GetFrameLevel() + 20)
    local rbg = Hc.Tex(Mt.results, "BACKGROUND", { 0.024, 0.067, 0.102 }, 1); rbg:SetAllPoints()
    Hc.Border(Mt.results, Hc.CYAN)
    Mt.resultButtons = {}
    for i = 1, 10 do
        local rb = CreateFrame("Button", nil, Mt.results)
        rb:SetPoint("TOPLEFT", 2, -2 - (i - 1) * 28); rb:SetPoint("TOPRIGHT", -2, -2 - (i - 1) * 28); rb:SetHeight(28)
        Hc.RowHighlight(rb)
        rb.text = Hc.Text(rb, 14, Hc.TEXT); rb.text:SetPoint("LEFT", 10, 0)
        rb:SetScript("OnClick", function(self) if self.found then OpenFound(self.found) end end)
        rb:Hide()
        Mt.resultButtons[i] = rb
    end
    Mt.results:Hide()

    -- Après un achat (EryAddon_HV.lua appelle ns.JobsRefresh) : la fiche se met à jour aussi.
    local oldRefresh = ns.JobsRefresh
    ns.JobsRefresh = function(...)
        if oldRefresh then oldRefresh(...) end
        F.RefreshMetiers()
    end
end

---------------------------------------------------------------------------
-- Écran MES ENCHÈRES (maquette corrigée, 08/11) : tes annonces en cours, celles où quelqu'un est passé
-- dessous, annulation. PAS de « remettre à X » en un clic : annuler perd le dépôt et renvoie l'objet par
-- COURRIER ; on le remet ensuite en vente depuis l'écran Vendre (bande « Au courrier »).
--   - liste : C_AuctionHouse.QueryOwnedAuctions → OWNED_AUCTIONS_UPDATED → GetOwnedAuctionInfo
--     (auctionID, itemKey, itemLink, status 0 = en vente / 1 = vendue, quantity, timeLeftSeconds, buyoutAmount) ;
--   - « qui passe dessous » : une recherche par objet (SendSearchQuery, l'une après l'autre), moins cher des
--     AUTRES vendeurs (numOwnerItems / containsOwnerItem) comparé à ton prix à l'unité ; « vérifié il y a » ;
--   - annuler : C_AuctionHouse.CancelAuction (un clic par annonce, GetCancelCost = ce que ça coûte) →
--     AUCTION_CANCELED ; l'objet part dans EryAddonDB.auCourrier jusqu'à ce que la boîte aux lettres ne l'ait plus.
---------------------------------------------------------------------------
local En = {}                -- cadres
local enAuctions = {}        -- annonces lues { id, key, keyStr, link, name, icon, qty, unit, sold, left, commodity }
local enChecks = {}          -- [clé d'objet] = { low = moins cher des autres (ou false), t = heure }
local enQueue, enCurrent = {}, nil
local enFilter = "all"
local enOffset = 0
local EN_ROWS = 13
local lastCancel             -- annonce en cours d'annulation

local function KeyStr(k)
    return k and table.concat({ k.itemID or 0, k.itemLevel or 0, k.itemSuffix or 0, k.battlePetSpeciesID or 0 }, ":") or "?"
end

local function TimeText(sec)
    if not sec then return "?" end
    if sec < 3600 then return math.max(1, math.floor(sec / 60 + 0.5)) .. " min" end
    return math.floor(sec / 3600 + 0.5) .. " h"
end

local function AgoText(t)
    if not t then return "" end
    local s = time() - t
    if s < 60 then return "à l'instant" end
    return TimeText(s)
end

-- Dépôt d'une annonce : ce qu'en a noté « Mes ventes » à la mise en vente (même objet, la plus récente).
local function KnownDeposit(a)
    local mv = EryAddonDB.mesVentes
    local best
    for _, p in ipairs(mv and mv.annonces or {}) do
        if p.id == a.itemID and p.deposit and p.qty and p.qty > 0 and (not best or (p.t or 0) > (best.t or 0)) then best = p end
    end
    return best and math.floor(best.deposit * math.min(a.qty, best.qty) / best.qty + 0.5) or nil
end

local function ReadOwned()
    enAuctions = {}
    for i = 1, C_AuctionHouse.GetNumOwnedAuctions() or 0 do
        local info = C_AuctionHouse.GetOwnedAuctionInfo(i)
        if info and info.itemKey then
            local k = info.itemKey
            local okI, ki = pcall(C_AuctionHouse.GetItemKeyInfo, k)
            local commodity = okI and ki and ki.isCommodity or false
            local name, _, _, _, icon = ItemInfo(k.itemID)
            local qty = info.quantity or 1
            local buyout = info.buyoutAmount or info.bidAmount or 0
            local a = { id = info.auctionID, key = k, keyStr = KeyStr(k), itemID = k.itemID, link = info.itemLink,
                name = (okI and ki and ki.itemName) or name or ("objet " .. k.itemID), icon = icon or (okI and ki and ki.iconFileID),
                qty = qty, commodity = commodity, sold = info.status == 1, left = info.timeLeftSeconds,
                -- Prix à l'unité : une marchandise EN VENTE donne déjà l'unité ; une marchandise VENDUE donne le total
                -- (vu 10/11 : 3 Huiles vendues affichées « 1 po 10 pa 91 / u » = 3 x 36 pa 97) ; un objet donne le prix
                -- de l'annonce.
                unit = (commodity and info.status ~= 1) and buyout or math.floor(buyout / math.max(1, qty)) }
            a.deposit = KnownDeposit(a)
            local okC, cost = pcall(C_AuctionHouse.GetCancelCost, info.auctionID)
            a.cancelCost = okC and cost or nil
            enAuctions[#enAuctions + 1] = a
        end
    end
    -- La liste du jeu fait foi pour « En vente » de Mes ventes (demande de Jérémie : « je suis sur l'HV, il est censé
    -- savoir »).
    if ns.SyncOwnedAuctions then
        local real = {}
        for _, a in ipairs(enAuctions) do
            if not a.sold then real[a.itemID] = (real[a.itemID] or 0) + a.qty end
        end
        ns.SyncOwnedAuctions(real)
    end
end

-- Statut d'une annonce d'après le dernier contrôle de son objet.
local function Status(a)
    if a.sold then return "sold" end
    local c = enChecks[a.keyStr]
    if not c then return "unknown" end
    if c.low == false then return "alone" end
    if a.unit > c.low then return "under" end
    if a.unit == c.low then return "tie" end
    return "top"
end

local STATUS_TXT = {
    sold = { "Vendue · au courrier", { 0.36, 1, 0.69 } }, unknown = { "À vérifier", { 0.61, 0.78, 0.83 } },
    alone = { "Seul vendeur", { 0.36, 1, 0.69 } }, top = { "En tête", { 0.36, 1, 0.69 } },
    tie = { "À égalité", { 0.81, 0.91, 0.95 } }, under = { "Passée dessous", { 1, 0.69, 0.33 } },
}

local function FilteredAuctions()
    local out = {}
    for _, a in ipairs(enAuctions) do
        local st = Status(a)
        if enFilter == "all" or (enFilter == "under" and st == "under") or (enFilter == "top" and (st == "top" or st == "alone")) then
            out[#out + 1] = a
        end
    end
    local order = { under = 1, unknown = 2, tie = 3, top = 4, alone = 5, sold = 6 }
    table.sort(out, function(x, y)
        local ox, oy = order[Status(x)], order[Status(y)]
        if ox ~= oy then return ox < oy end
        return x.name < y.name
    end)
    return out
end

local function UndercutList()
    local out = {}
    for _, a in ipairs(enAuctions) do if Status(a) == "under" then out[#out + 1] = a end end
    return out
end

local function DrawEncheres()
    if not En.rows then return end
    local Hc = H()
    -- Cartes du haut.
    local active, under, soon, value, deposits = 0, 0, nil, 0, 0
    for _, a in ipairs(enAuctions) do
        if not a.sold then
            active = active + 1
            value = value + a.unit * a.qty
            deposits = deposits + (a.deposit or 0)
            if Status(a) == "under" then under = under + 1 end
            if a.left and a.left < 1800 and (not soon or a.left < soon.left) then soon = a end
        end
    end
    En.k1:SetText(active .. " annonce" .. (active > 1 and "s" or ""))
    En.k1s:SetText("tout vendu : " .. Money(math.floor(value * (1 - COMMISSION))))
    En.k2:SetText(under)
    En.k2:SetTextColor(unpack(under > 0 and Hc.ORANGE or Hc.TEXT))
    En.k3:SetText(soon and soon.name or "aucune")
    En.k3s:SetText(soon and ("dans " .. TimeText(soon.left)) or "rien sous 30 min")
    En.k4:SetText(deposits > 0 and Money(deposits) or "?")

    -- Onglets et boutons.
    local nTop = 0
    for _, a in ipairs(enAuctions) do local s = Status(a); if s == "top" or s == "alone" then nTop = nTop + 1 end end
    En.tAll:SetLabel("Toutes (" .. #enAuctions .. ")")
    En.tUnder:SetLabel("Passées dessous (" .. under .. ")")
    En.tTop:SetLabel("En tête (" .. nTop .. ")")
    En.tAll:SetStyle(enFilter == "all" and "solid" or "outline")
    En.tUnder:SetStyle(enFilter == "under" and "solid" or "outline")
    En.tTop:SetStyle(enFilter == "top" and "solid" or "outline")
    En.check:SetLabel(enCurrent and string.format("Vérification… %d", #enQueue + 1) or "Vérifier les prix")
    En.cancelAll:SetLabel(under > 0 and string.format("Annuler les %d passées dessous · %d clic%s", under, under, under > 1 and "s" or "")
        or "Annuler les passées dessous")
    En.cancelAll:SetEnabled(under > 0)

    -- Tableau.
    local list = FilteredAuctions()
    enOffset = math.max(0, math.min(enOffset, #list - EN_ROWS))
    for i, r in ipairs(En.rows) do
        local a = list[enOffset + i]
        r.a = a
        if a then
            r.icon:SetTexture(a.icon)
            r.name:SetText(a.name)
            r.qty:SetText(a.qty)
            r.price:SetText(Money(a.unit))
            local c = enChecks[a.keyStr]
            r.low:SetText(c and c.low and Money(c.low) or (c and "-" or ""))
            local st = Status(a)
            local info = STATUS_TXT[st]
            local txt = info[1]
            if st == "under" then txt = "Passée dessous de " .. Money(a.unit - c.low) end
            r.status:SetText(txt)
            r.status:SetTextColor(unpack(info[2]))
            r.low:SetTextColor(unpack(st == "under" and Hc.ORANGE or Hc.SOFT))
            r.checked:SetText(c and AgoText(c.t) or "")
            r.left:SetText(a.sold and "" or TimeText(a.left))
            r.left:SetTextColor(unpack(a.left and a.left < 1800 and { 1, 1, 1 } or Hc.SOFT))
            r.dep:SetText(a.deposit and Money(a.deposit) or "?")
            r.cancel:SetShown(not a.sold)
            r:Show()
        else
            r:Hide()
        end
    end

    -- Au courrier : ce que tu as annulé et pas encore relevé.
    local mail = EryAddonDB.auCourrier or {}
    local parts = {}
    for i, m in ipairs(mail) do
        if i > 4 then parts[#parts + 1] = string.format("et %d autres", #mail - 4) break end
        parts[#parts + 1] = string.format("%s x%d |cff5f8a99(annulée il y a %s)|r", m.name, m.qty, AgoText(m.t))
    end
    En.mailText:SetText(#mail > 0 and table.concat(parts, "     ") or "|cff5f8a99Rien à relever.|r")
end

-- Vérifie les prix : une recherche par objet, l'une après l'autre.
local function CheckNext()
    enCurrent = table.remove(enQueue, 1)
    if not enCurrent then DrawEncheres() return end
    if (C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady())
        or (ns.HVCanAutoSearch and not ns.HVCanAutoSearch()) then -- limite du jeu : 60 recherches automatiques / min
        table.insert(enQueue, 1, enCurrent); enCurrent = nil
        C_Timer.After(1, CheckNext)
        return
    end
    local cur = enCurrent
    C_AuctionHouse.SendSearchQuery(cur.key, {}, true) -- sans tri, comme TSM
    C_Timer.After(4, function() if enCurrent == cur then enCurrent = nil; CheckNext() end end)
    DrawEncheres()
end

local function StartChecks()
    if ns.HVUserAction then ns.HVUserAction() end
    local seen = {}
    enQueue = {}
    for _, a in ipairs(enAuctions) do
        if not a.sold and not seen[a.keyStr] then
            seen[a.keyStr] = true
            enQueue[#enQueue + 1] = { key = a.key, keyStr = a.keyStr, itemID = a.itemID, commodity = a.commodity }
        end
    end
    if not enCurrent then CheckNext() end
end

local function OnCheckResults(isCommodity, arg)
    local cur = enCurrent
    if not cur then return end
    if isCommodity and arg ~= cur.itemID then return end
    if not isCommodity and (type(arg) ~= "table" or KeyStr(arg) ~= cur.keyStr) then return end
    local low = false
    if isCommodity then
        for i = 1, C_AuctionHouse.GetNumCommoditySearchResults(arg) do
            local r = C_AuctionHouse.GetCommoditySearchResultInfo(arg, i)
            if r and r.unitPrice and (r.quantity or 0) - (r.numOwnerItems or 0) > 0 then low = r.unitPrice break end
        end
    else
        for i = 1, C_AuctionHouse.GetNumItemSearchResults(arg) do
            local r = C_AuctionHouse.GetItemSearchResultInfo(arg, i)
            local p = r and (r.buyoutAmount or r.bidAmount)
            if p and p > 0 and not r.containsOwnerItem and (not low or p < low) then low = p end
        end
    end
    enChecks[cur.keyStr] = { low = low, t = time() }
    enCurrent = nil
    C_Timer.After(0.3, CheckNext)
    DrawEncheres()
end

function F.RefreshEncheres()
    if not (win and win:IsShown() and currentScreen == "encheres") then return end
    if C_AuctionHouse.QueryOwnedAuctions then
        pcall(C_AuctionHouse.QueryOwnedAuctions, {
            { sortOrder = Enum.AuctionHouseSortOrder.Name, reverseSort = false },
            { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } })
    end
    DrawEncheres()
end

local function Cancel(a)
    if not a or a.sold then return end
    lastCancel = a
    local ok = pcall(C_AuctionHouse.CancelAuction, a.id)
    if not ok then Msg("annulation refusée : " .. a.name) end
end

function F.CreateEncheresScreen(parent)
    local Hc = H()
    local cw = DESIGN_W - 2 - RAIL_W - 1
    local ch = DESIGN_H - 2 - TOP_H
    local iw = cw - 2 * PAD

    -- Cartes.
    local kw = math.floor((iw - 3 * 12) / 4)
    local function Card(i, label, color)
        local c = Panel(parent)
        c:SetPoint("TOPLEFT", PAD + (i - 1) * (kw + 12), -PAD)
        c:SetSize(kw, 78)
        local l = Hc.Label(c, label, 11, color or { 0.5, 0.64, 0.7 }); l:SetPoint("TOPLEFT", 14, -12)
        local v = Hc.Text(c, 24, Hc.TEXT); v:SetPoint("TOPLEFT", 14, -30); v:SetWidth(kw - 28)
        local s = Hc.Text(c, 12, Hc.SOFT); s:SetPoint("TOPLEFT", 14, -58); s:SetWidth(kw - 28)
        return v, s
    end
    En.k1, En.k1s = Card(1, "En vente")
    En.k2, En.k2s = Card(2, "Passées dessous", Hc.ORANGE); En.k2s:SetText("quelqu'un est moins cher")
    En.k3, En.k3s = Card(3, "Expire bientôt")
    En.k4, En.k4s = Card(4, "Dépôts en jeu"); En.k4s:SetText("perdus si invendu ou annulé")

    -- Onglets + boutons.
    local y = -PAD - 78 - 14
    En.tAll = Hc.Button(parent, "Toutes", 130, 34, "solid"); En.tAll:SetPoint("TOPLEFT", PAD, y)
    En.tUnder = Hc.Button(parent, "Passées dessous", 190, 34, "outline"); En.tUnder:SetPoint("LEFT", En.tAll, "RIGHT", 8, 0)
    En.tTop = Hc.Button(parent, "En tête", 130, 34, "outline"); En.tTop:SetPoint("LEFT", En.tUnder, "RIGHT", 8, 0)
    for _, pair in ipairs({ { En.tAll, "all" }, { En.tUnder, "under" }, { En.tTop, "top" } }) do
        pair[1].label:SetFont(Hc.FONT, 13, "")
        pair[1]:SetScript("OnClick", function() enFilter = pair[2]; enOffset = 0; DrawEncheres() end)
    end
    En.cancelAll = GoButton(parent, 330, 34)
    local OR = Hc.ORANGE
    En.cancelAll.bg:SetColorTexture(OR[1], OR[2], OR[3], 1)
    for _, e in ipairs(En.cancelAll.edges) do e:SetColorTexture(OR[1], OR[2], OR[3], 1) end
    En.cancelAll.label:SetTextColor(0.12, 0.07, 0.01); En.cancelAll.label:SetFont(Hc.FONT, 13, "")
    En.cancelAll:SetPoint("TOPRIGHT", -PAD, y)
    -- Chaque clic annule la suivante (le jeu exige un clic par annulation).
    En.cancelAll:SetScript("OnClick", function() Cancel(UndercutList()[1]) end)
    En.check = Hc.Button(parent, "Vérifier les prix", 170, 34, "muted")
    En.check.label:SetFont(Hc.FONT, 13, "")
    En.check:SetPoint("RIGHT", En.cancelAll, "LEFT", -10, 0)
    En.check:SetScript("OnClick", StartChecks)

    -- Tableau.
    local tableTop = y - 34 - 12
    local mailH = 70
    local t = Panel(parent)
    t:SetPoint("TOPLEFT", PAD, tableTop)
    t:SetSize(iw, ch + tableTop - PAD - mailH - 12)
    local head = CreateFrame("Frame", nil, t)
    head:SetPoint("TOPLEFT", 1, -1); head:SetPoint("TOPRIGHT", -1, -1); head:SetHeight(30)
    local hb = Hc.Tex(head, "BACKGROUND", { 0.039, 0.082, 0.125 }, 1); hb:SetAllPoints()
    -- Colonnes (bord droit de chaque colonne), objet = ce qui reste.
    local COL = { qty = 400, price = 540, low = 680, status = 700, checked = 960, left = 1040, dep = 1130 }
    local function H1(text, x, right)
        local h = Hc.Label(head, text, 11, { 0.5, 0.64, 0.7 })
        if right then h:SetPoint("RIGHT", head, "LEFT", x, 0) else h:SetPoint("LEFT", head, "LEFT", x, 0) end
    end
    H1("Objet", 12); H1("Qté", COL.qty, true); H1("Prix / u", COL.price, true); H1("Moins cher", COL.low, true)
    H1("Statut", COL.status); H1("Vérifié", COL.checked, true); H1("Reste", COL.left, true); H1("Dépôt", COL.dep, true)
    En.rows = {}
    for i = 1, EN_ROWS do
        local r = CreateFrame("Frame", nil, t)
        r:SetPoint("TOPLEFT", 1, -31 - (i - 1) * 36); r:SetPoint("TOPRIGHT", -1, -31 - (i - 1) * 36); r:SetHeight(36)
        r:EnableMouse(true)
        Hc.RowHighlight(r)
        local ln = Hc.Tex(r, "BORDER", { 0.071, 0.161, 0.227 }); ln:SetHeight(1); ln:SetPoint("BOTTOMLEFT"); ln:SetPoint("BOTTOMRIGHT")
        r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(24, 24); r.icon:SetPoint("LEFT", 10, 0)
        r.name = Hc.Text(r, 14, Hc.TEXT); r.name:SetPoint("LEFT", r.icon, "RIGHT", 8, 0); r.name:SetWidth(COL.qty - 100)
        local function Cell(x, size, color)
            local fs = Hc.Text(r, size or 14, color or Hc.TEXT); fs:SetPoint("RIGHT", r, "LEFT", x, 0); fs:SetJustifyH("RIGHT")
            return fs
        end
        r.qty = Cell(COL.qty); r.price = Cell(COL.price); r.low = Cell(COL.low, 14, Hc.SOFT)
        r.status = Hc.Text(r, 13, Hc.TEXT); r.status:SetPoint("LEFT", r, "LEFT", COL.status, 0)
        r.checked = Cell(COL.checked, 12, Hc.SOFT); r.left = Cell(COL.left, 13, Hc.SOFT); r.dep = Cell(COL.dep, 13, Hc.SOFT)
        r.cancel = Hc.Button(r, "Annuler", 80, 26, "muted")
        r.cancel:SetPoint("RIGHT", -10, 0)
        r.cancel:SetScript("OnClick", function(self) Cancel(self:GetParent().a) end)
        r.cancel:SetScript("OnEnter", function(self)
            local a = self:GetParent().a
            if not a then return end
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:AddLine("Annuler : " .. a.name)
            GameTooltip:AddLine("Dépôt perdu" .. (a.deposit and (" : " .. Money(a.deposit)) or "") .. ". L'objet revient par courrier.", 1, 1, 1, true)
            if a.cancelCost and a.cancelCost > 0 then GameTooltip:AddLine("Coût de l'annulation : " .. Money(a.cancelCost), 1, 0.69, 0.33) end
            GameTooltip:Show()
        end)
        r.cancel:SetScript("OnLeave", function(self) GameTooltip:Hide(); self:SetStyle(self.style) end)
        r:SetScript("OnEnter", function(self)
            if not (self.a and self.a.link) then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetHyperlink(self.a.link); GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        r:Hide()
        En.rows[i] = r
    end
    t:EnableMouseWheel(true)
    t:SetScript("OnMouseWheel", function(_, delta) enOffset = math.max(0, enOffset - delta * 3); DrawEncheres() end)

    -- Au courrier.
    local m = Panel(parent)
    m:SetPoint("BOTTOMLEFT", PAD, PAD)
    m:SetSize(iw, mailH)
    local ml = Hc.Label(m, "Au courrier", 11, { 0.5, 0.64, 0.7 }); ml:SetPoint("TOPLEFT", 14, -12)
    local mh = Hc.Text(m, 12, Hc.SOFT); mh:SetPoint("LEFT", ml, "RIGHT", 12, 0)
    mh:SetText("relève-le, puis remets-le en vente depuis Vendre")
    En.mailText = Hc.Text(m, 13, Hc.TEXT); En.mailText:SetPoint("TOPLEFT", 14, -36); En.mailText:SetWidth(iw - 180)
    local go = Hc.Button(m, "Vendre", 120, 30, "outline")
    go:SetPoint("RIGHT", -14, 0)
    go:SetScript("OnClick", function() F.ShowScreen("vendre") end)
end

-- Une annulation réussie : l'objet part au courrier (liste « Au courrier »).
local function OnCanceled()
    local a = lastCancel
    lastCancel = nil
    if a then
        EryAddonDB.auCourrier = EryAddonDB.auCourrier or {}
        table.insert(EryAddonDB.auCourrier, 1, { itemID = a.itemID, name = a.name, qty = a.qty, t = time() })
        while #EryAddonDB.auCourrier > 30 do table.remove(EryAddonDB.auCourrier) end
    end
    F.RefreshEncheres()
end

-- Boîte aux lettres ouverte : un objet annulé qui n'y est plus a été relevé (65 min de grâce : le courrier met
-- 60 min à arriver depuis le patch Forever du 10/11), ou 30 jours passés.
local function OnMail()
    local list = EryAddonDB and EryAddonDB.auCourrier
    if not list or #list == 0 or not GetInboxNumItems then return end
    local inMail = {}
    for i = 1, GetInboxNumItems() do
        for k = 1, (ATTACHMENTS_MAX_RECEIVE or 16) do
            local ok, _, id = pcall(GetInboxItem, i, k)
            if ok and id then inMail[id] = true end
        end
    end
    for i = #list, 1, -1 do
        local m = list[i]
        if (not inMail[m.itemID] and time() - m.t > 3900) or time() - m.t > 30 * 86400 then table.remove(list, i) end
    end
end
F._TestEncheres = function() return enAuctions, enChecks, DrawEncheres, ReadOwned, OnCheckResults, StartChecks end

---------------------------------------------------------------------------
-- Écran OPPORTUNITÉS (ex-Anomalies, maquette corrigée 08/11) : achats rentables trouvés par le scan,
-- revente au MARCHAND ou PALIERS HV (poche bradée sous un mur, revente 1 pa sous le mur). Données et achat :
-- ceux d'Anomalies (ns.AnoAPI, EryAddon_HV.lua), même circuit (achat express, file d'enchères, devis vérifié,
-- moitié de la bourse au plus par clic). Liste à gauche (bouton d'achat par ligne), fiche à droite : l'échelle
-- des annonces (poche / ta revente / mur), ce que tu paies, touches, gagnes.
---------------------------------------------------------------------------
local Op = {}
local opFilter = "all"
local opOffset = 0
local opSel            -- entrée affichée dans la fiche
local OP_ROWS, LADDER_ROWS = 15, 9

local function Ano() return ns.AnoAPI end

local opSortN, opSortGain = -1, {}
local function OpItems()
    local out, nV, nP = {}, 0, 0
    for _, e in ipairs(Ano() and Ano().Items() or {}) do
        local pal = e.kind == "palier"
        if pal then nP = nP + 1 else nV = nV + 1 end
        if opFilter == "all" or (opFilter == "pnj" and not pal) or (opFilter == "palier" and pal) then out[#out + 1] = e end
    end
    -- Ligne CHOISIE qui n'est plus une affaire : elle reste à sa place tant que tu la consultes (demande de
    -- Jérémie) ; elle disparaît quand tu en choisis une autre.
    local keepSel = opSel and opSel.done
    if keepSel then out[#out + 1] = opSel end
    -- Trié par la colonne « Gain / clic », le plus gros d'abord (demande de Jérémie). Le gain de chaque ligne est
    -- FIGÉ jusqu'à ce que la liste change (ligne ajoutée / retirée) : sinon une ligne bougerait après chaque achat
    -- et le clic suivant tomberait sur un autre objet.
    local n = #(Ano() and Ano().Items() or {}) + (keepSel and 1 or 0)
    if n ~= opSortN then opSortN, opSortGain = n, {} end
    for _, e in ipairs(out) do
        if not opSortGain[e] then
            local ok, g = pcall(Ano().NextClickGain, e)
            opSortGain[e] = (ok and tonumber(g)) or e.unitGain or 0
        end
    end
    table.sort(out, function(a, b)
        if opSortGain[a] ~= opSortGain[b] then return opSortGain[a] > opSortGain[b] end
        return (a.name or "") < (b.name or "")
    end)
    return out, nV, nP
end

-- Prix de revente affiché : palier = prix de mise en vente visé (mur − 1 pa), marchand = prix marchand.
local function Resale(e)
    if e.kind == "palier" then
        return e.resale or math.floor((e.vendor or 0) / (1 - ((Ano() and Ano().Commission) or 0.05))), "HV"
    end
    return e.vendor, "marchand"
end

local function DrawOpFiche()
    local Hc, f = H(), Op.fiche
    local e = opSel
    f.empty:SetShown(e == nil)
    f.body:SetShown(e ~= nil)
    if not e then return end
    f.icon:SetTexture(e.icon)
    f.name:SetText(e.name)
    local pal = e.kind == "palier"
    local sub = pal and "Palier HV" or "Revente au marchand"
    if pal and e.perDay then sub = sub .. string.format(" · se vend %s / jour", Num(e.perDay)) end
    f.sub:SetText(sub)
    f.sub:SetTextColor(unpack(pal and Hc.CYAN or { 1, 0.91, 0.63 }))

    -- Échelle des annonces (paliers vérifiés) : la poche en vert, le mur en cyan, ta revente en pointillés.
    local levels = pal and e.levels or nil
    local checking = Ano().Checking and Ano().Checking(e)
    f.ladderTitle:SetText(Hc.Upper(checking and "Lecture des annonces…" or "Les annonces, du moins cher au plus cher"))
    f.ladderTitle:SetShown(levels ~= nil or checking)
    local rows, maxQ = {}, 1
    if levels then
        local placed = false
        for _, l in ipairs(levels) do
            if not placed and e.resale and l.p > e.resale then
                rows[#rows + 1] = { me = true, p = e.resale }
                placed = true
            end
            rows[#rows + 1] = l
            maxQ = math.max(maxQ, l.q)
        end
        if not placed and e.resale then rows[#rows + 1] = { me = true, p = e.resale } end
    end
    local barW = f.ladderW
    for i, r in ipairs(f.ladder) do
        local l = rows[i]
        if l and i <= LADDER_ROWS then
            r.price:SetText(Money(l.p))
            if l.me then
                r.bar:Hide()
                r.qty:SetText("")
                r.label:SetText("ta revente")
                r.label:SetTextColor(1, 0.91, 0.63)
                r.price:SetTextColor(1, 0.91, 0.63)
                r.dash:Show()
            else
                -- Sous le mur mais au-dessus du prix d'achat max : pas acheté (moins de 20 % de marge).
                local kind = (e.maxUnit and l.p <= e.maxUnit) and "pocket"
                    or ((e.wall and l.p >= e.wall and l.p <= e.wall * 1.25) and "wall")
                    or ((e.resale and l.p < e.resale) and "dear" or nil)
                local c = kind == "pocket" and Hc.GREEN or (kind == "wall" and Hc.CYAN or { 0.165, 0.31, 0.388 })
                r.bar:SetColorTexture(c[1], c[2], c[3], 1)
                r.bar:SetWidth(math.max(3, barW * l.q / maxQ))
                r.bar:Show()
                r.qty:SetText(l.q)
                r.label:SetText(kind == "pocket" and "tu achètes" or (kind == "wall" and "le mur"
                    or (kind == "dear" and "trop cher" or "")))
                if kind == "dear" then r.label:SetTextColor(unpack(Hc.SOFT)) else r.label:SetTextColor(c[1], c[2], c[3]) end
                r.price:SetTextColor(unpack(Hc.TEXT))
                r.dash:Hide()
            end
            r:Show()
        else
            r:Hide()
        end
    end

    -- Annonces moins chères que ta revente que tu n'achètes pas : elles se vendront AVANT les tiennes.
    local ahead = 0
    for _, l in ipairs(levels or {}) do
        if e.resale and l.p < e.resale and not (e.maxUnit and l.p <= e.maxUnit) then ahead = ahead + l.q end
    end
    if ahead > 0 then
        local mine = e.qty or 1
        local days = e.perDay and e.perDay > 0 and (ahead + mine) / e.perDay or nil
        f.warn:SetText(string.format("%d moins chères que ta revente restent devant toi%s.", ahead,
            days and string.format(" : env. %s jour%s pour tout vendre", Num(days), days >= 2 and "s" or "") or ""))
        f.warn:Show()
    else
        f.warn:Hide()
    end

    -- Tu paies / Tu touches / Gain visé (pour ce que le prochain clic achète).
    local entry, state = Ano().Entry()
    local resale, where = Resale(e)
    local n = (e.queue and 1) or (Ano().OnePerPurchase(e.id) and 1) or e.qty or 1
    local unitPaid = e.minPrice or 0
    if entry == e and e.queue and e.queue[1] then unitPaid = e.queue[1].buyoutAmount end
    local gain = Ano().NextClickGain(e) or 0
    f.t1:SetText(Money(unitPaid * n))
    f.t1s:SetText(string.format("%d x %s", n, Money(unitPaid)))
    local net = pal and math.floor(resale * (1 - Ano().Commission)) or resale
    f.t2:SetText(Money(net * n))
    f.t2s:SetText(pal and string.format("%d x %s, −5 %%", n, Money(resale)) or ("au marchand " .. Money(resale)))
    f.t3:SetText("+" .. Money(math.max(0, gain)))

    local label, enabled = Ano().ButtonText()
    if entry ~= e then label, enabled = (e.blocked and "Achats arrêtés" or "Acheter"), not e.blocked end
    if e.done then
        label, enabled = "Plus d'affaire", false
        f.t1:SetText("-"); f.t1s:SetText(""); f.t2:SetText("-"); f.t2s:SetText(""); f.t3:SetText("-")
    end
    f.buy:SetLabel(label)
    f.buy:SetEnabled(enabled and true or false)
    f.note:SetText(Ano().IsCommodity(e.id) and "arrive par courrier"
        or "1 annonce par clic · arrive par courrier")
end

local function DrawOpportunites()
    if not (Op.rows and Ano()) then return end
    local Hc = H()
    local list, nV, nP = OpItems()
    Op.tAll:SetLabel("Toutes (" .. (nV + nP) .. ")")
    Op.tPnj:SetLabel("Marchand (" .. nV .. ")")
    Op.tPal:SetLabel("Paliers HV (" .. nP .. ")")
    Op.tAll:SetStyle(opFilter == "all" and "solid" or "outline")
    Op.tPnj:SetStyle(opFilter == "pnj" and "solid" or "outline")
    Op.tPal:SetStyle(opFilter == "palier" and "solid" or "outline")
    local b = Ano().Bilan()
    local profit = (b.revente or 0) - (b.paye or 0)
    Op.bilan:SetText(string.format("Profit total : %s%s|r  |cff9fbfcc(%d achats)|r", profit >= 0 and "|cff5cffb0+" or "|cffff7373-",
        Money(math.abs(profit)), b.n or 0))
    local status, scanTime = Ano().Status()
    Op.status:SetText((status and status ~= "") and status
        or (scanTime and string.format("Dernier scan il y a %d min.", math.floor((time() - scanTime) / 60)) or "Aucun scan : clique sur « Scanner l'HV » en haut."))

    opOffset = math.max(0, math.min(opOffset, #list - OP_ROWS))
    local entry = Ano().Entry()
    for i, r in ipairs(Op.rows) do
        local e = list[opOffset + i]
        r.e = e
        if e then
            r.icon:SetTexture(e.icon)
            r.name:SetText(e.name)
            local pal = e.kind == "palier"
            r.type:SetText(pal and ("PALIER HV" .. (e.perDay and string.format(" · %s ventes / j", Num(e.perDay)) or "")) or "MARCHAND")
            r.type:SetTextColor(unpack(pal and Hc.CYAN or { 1, 0.91, 0.63 }))
            r.buyP:SetText(Money(e.minPrice or 0))
            local resale = Resale(e)
            r.sell:SetText(Money(resale or 0))
            local n = (e.queue and 1) or e.qty
            r.n:SetText(n and (e.qty and (tostring(n) .. (e.queue and string.format(" |cff9fbfccsur %d|r", e.qty) or "")) or "") or "?")
            local g = Ano().NextClickGain(e) or e.unitGain or 0
            r.gain:SetText("+" .. Money(math.max(0, g)) .. (e.qty and "" or " |cff9fbfcc/u|r"))
            local label, enabled = Ano().RowButtonText(e)
            if e.done then -- (ligne gardée parce que tu la consultes)
                r.type:SetText("PLUS D'AFFAIRE")
                r.type:SetTextColor(unpack(Hc.SOFT))
                r.gain:SetText("|cff9fbfcc-|r")
                label, enabled = "-", false
            end
            r.buy:SetLabel(label)
            r.buy:SetEnabled(enabled and true or false)
            r.sel:SetShown(opSel == e or entry == e)
            r:Show()
        else
            r:Hide()
        end
    end
    DrawOpFiche()
end
ns.OnAnoUpdate = function()
    if win and win:IsShown() then UpdateTop() end -- état du scan dans la barre du haut
    if Op.frame and Op.frame:IsVisible() then DrawOpportunites() end
end

local function OpBuy(e)
    if not e then return end
    if ns.ShiftLink and ns.ShiftLink(e.id) then return end -- Maj+clic = lien dans le chat, aucun achat
    opSel = e
    local entry, state = Ano().Entry()
    if entry ~= e or state == "done" then Ano().Select(e) else Ano().Click() end
    DrawOpportunites()
end

function F.CreateOpportunitesScreen(parent)
    local Hc = H()
    Op.frame = parent
    local cw = DESIGN_W - 2 - RAIL_W - 1
    local ch = DESIGN_H - 2 - TOP_H
    local iw = cw - 2 * PAD
    local ficheW = 420
    local listW = iw - ficheW - PAD

    -- Onglets, bilan, état du scan.
    Op.tAll = Hc.Button(parent, "Toutes", 130, 34, "solid"); Op.tAll:SetPoint("TOPLEFT", PAD, -PAD)
    Op.tPnj = Hc.Button(parent, "Marchand", 150, 34, "outline"); Op.tPnj:SetPoint("LEFT", Op.tAll, "RIGHT", 8, 0)
    Op.tPal = Hc.Button(parent, "Paliers HV", 160, 34, "outline"); Op.tPal:SetPoint("LEFT", Op.tPnj, "RIGHT", 8, 0)
    for _, pair in ipairs({ { Op.tAll, "all" }, { Op.tPnj, "pnj" }, { Op.tPal, "palier" } }) do
        pair[1].label:SetFont(Hc.FONT, 13, "")
        pair[1]:SetScript("OnClick", function() opFilter = pair[2]; opOffset = 0; DrawOpportunites() end)
    end
    local bilanBox = CreateFrame("Frame", nil, parent)
    bilanBox:SetPoint("TOPRIGHT", -PAD, -PAD - 8); bilanBox:SetSize(380, 20)
    Op.bilan = Hc.Text(bilanBox, 15, Hc.TEXT); Op.bilan:SetPoint("RIGHT"); Op.bilan:SetJustifyH("RIGHT")
    bilanBox:EnableMouse(true)
    bilanBox:SetScript("OnEnter", function(self)
        local b = Ano().Bilan()
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
        GameTooltip:AddLine("Achats revendus au marchand")
        GameTooltip:AddDoubleLine("Achats", string.format("%d (%d objets)", b.n or 0, b.objets or 0), 1, 1, 1, 1, 1, 1)
        GameTooltip:AddDoubleLine("Payé à l'HV", Money(b.paye or 0), 1, 1, 1, 1, 1, 1)
        GameTooltip:AddDoubleLine("Revente au marchand", Money(b.revente or 0), 1, 1, 1, 1, 1, 1)
        GameTooltip:AddLine("Depuis le " .. (b.debut or "?"), 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    bilanBox:SetScript("OnLeave", function() GameTooltip:Hide() end)
    Op.status = Hc.Text(parent, 12, Hc.SOFT); Op.status:SetPoint("TOPLEFT", PAD, -PAD - 44); Op.status:SetWidth(listW)

    -- Liste.
    local top = -PAD - 66
    local t = Panel(parent)
    t:SetPoint("TOPLEFT", PAD, top)
    t:SetSize(listW, ch + top - PAD)
    local head = CreateFrame("Frame", nil, t)
    head:SetPoint("TOPLEFT", 1, -1); head:SetPoint("TOPRIGHT", -1, -1); head:SetHeight(30)
    local hb = Hc.Tex(head, "BACKGROUND", { 0.039, 0.082, 0.125 }, 1); hb:SetAllPoints()
    -- Bords droits des colonnes ; l'objet prend le reste ; bouton à droite (90).
    local X_BUY, X_SELL, X_N, X_GAIN = listW - 400, listW - 310, listW - 230, listW - 104
    local function H1(text, x) local h = Hc.Label(head, text, 11, { 0.5, 0.64, 0.7 }); h:SetPoint("RIGHT", head, "LEFT", x, 0) end
    local h0 = Hc.Label(head, "Objet", 11, { 0.5, 0.64, 0.7 }); h0:SetPoint("LEFT", 12, 0)
    H1("Achat", X_BUY); H1("Revente", X_SELL); H1("Par clic", X_N); H1("Gain / clic", X_GAIN)
    Op.rows = {}
    for i = 1, OP_ROWS do
        local r = CreateFrame("Button", nil, t)
        r:SetPoint("TOPLEFT", 1, -31 - (i - 1) * 42); r:SetPoint("TOPRIGHT", -1, -31 - (i - 1) * 42); r:SetHeight(42)
        Hc.RowHighlight(r)
        r.sel = Hc.Tex(r, "BACKGROUND", { 0.059, 0.141, 0.2 }, 1); r.sel:SetAllPoints()
        local ln = Hc.Tex(r, "BORDER", { 0.071, 0.161, 0.227 }); ln:SetHeight(1); ln:SetPoint("BOTTOMLEFT"); ln:SetPoint("BOTTOMRIGHT")
        r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(26, 26); r.icon:SetPoint("LEFT", 10, 0)
        r.name = Hc.Text(r, 14, Hc.TEXT); r.name:SetPoint("TOPLEFT", r.icon, "TOPRIGHT", 8, 2)
        r.name:SetPoint("RIGHT", r, "LEFT", X_BUY - 70, 0)
        r.type = Hc.Text(r, 10, Hc.CYAN); r.type:SetPoint("TOPLEFT", r.name, "BOTTOMLEFT", 0, -3)
        local function Cell(x, size, color)
            local fs = Hc.Text(r, size or 14, color or Hc.TEXT); fs:SetPoint("RIGHT", r, "LEFT", x, 0); fs:SetJustifyH("RIGHT")
            return fs
        end
        r.buyP = Cell(X_BUY); r.sell = Cell(X_SELL, 14, Hc.SOFT); r.n = Cell(X_N); r.gain = Cell(X_GAIN, 15, Hc.GREEN)
        r.buy = Hc.Button(r, "Acheter", 84, 28, "outline")
        r.buy:SetPoint("RIGHT", -10, 0)
        r.buy:SetScript("OnClick", function(self) OpBuy(self:GetParent().e) end)
        r.buy:HookScript("OnEnter", function(self) local e = self:GetParent().e; if e then Ano().Prefetch(e) end end)
        r:SetScript("OnClick", function(self)
            if not self.e then return end
            if ns.ShiftLink and ns.ShiftLink(self.e.id) then return end
            opSel = self.e
            if Ano().Verify then Ano().Verify(self.e) end -- priorité à ce que tu regardes
            DrawOpportunites()
        end)
        r:SetScript("OnEnter", function(self)
            if not self.e then return end
            Ano().Prefetch(self.e) -- recherche au survol (objets non empilables) : le clic d'achat est prêt
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetItemByID(self.e.id); GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        r:Hide()
        Op.rows[i] = r
    end
    t:EnableMouseWheel(true)
    t:SetScript("OnMouseWheel", function(_, delta) opOffset = math.max(0, opOffset - delta * 3); DrawOpportunites() end)

    -- Fiche.
    local f = Panel(parent)
    f:SetPoint("TOPLEFT", t, "TOPRIGHT", PAD, 0)
    f:SetSize(ficheW, ch + top - PAD)
    Op.fiche = f
    f.empty = Hc.Text(f, 15, Hc.SOFT); f.empty:SetPoint("CENTER"); f.empty:SetText("Choisis une ligne")
    f.body = CreateFrame("Frame", nil, f); f.body:SetAllPoints()
    local bd, IN = f.body, 18
    f.icon = bd:CreateTexture(nil, "ARTWORK"); f.icon:SetSize(44, 44); f.icon:SetPoint("TOPLEFT", IN, -IN)
    f.name = Hc.Text(bd, 19, Hc.TEXT); f.name:SetPoint("TOPLEFT", f.icon, "TOPRIGHT", 12, -2); f.name:SetWidth(ficheW - 2 * IN - 56)
    f.sub = Hc.Text(bd, 12, Hc.CYAN); f.sub:SetPoint("TOPLEFT", f.name, "BOTTOMLEFT", 0, -6); f.sub:SetWidth(ficheW - 2 * IN - 56)
    f.ladderTitle = Hc.Label(bd, "Les annonces, du moins cher au plus cher", 11, { 0.5, 0.64, 0.7 })
    f.ladderTitle:SetPoint("TOPLEFT", IN, -80)
    f.ladderW = ficheW - 2 * IN - 96 - 50 - 90
    f.ladder = {}
    for i = 1, LADDER_ROWS + 1 do
        local r = CreateFrame("Frame", nil, bd)
        r:SetPoint("TOPLEFT", IN, -100 - (i - 1) * 28); r:SetSize(ficheW - 2 * IN, 28)
        r.price = Hc.Text(r, 13, Hc.TEXT); r.price:SetPoint("RIGHT", r, "LEFT", 90, 0); r.price:SetJustifyH("RIGHT")
        r.bar = Hc.Tex(r, "ARTWORK", Hc.GREEN); r.bar:SetHeight(14); r.bar:SetPoint("LEFT", r, "LEFT", 100, 0)
        r.label = Hc.Text(r, 11, Hc.GREEN); r.label:SetPoint("LEFT", r, "LEFT", 100 + f.ladderW + 8, 0)
        r.qty = Hc.Text(r, 13, Hc.TEXT); r.qty:SetPoint("RIGHT", r, "RIGHT", 0, 0); r.qty:SetJustifyH("RIGHT")
        r.dash = Hc.Tex(r, "ARTWORK", { 1, 0.91, 0.63 }, 0.8); r.dash:SetHeight(1)
        r.dash:SetPoint("LEFT", r, "LEFT", 100, 0); r.dash:SetWidth(f.ladderW)
        r:Hide()
        f.ladder[i] = r
    end
    f.warn = Hc.Text(bd, 12, Hc.ORANGE)
    f.warn:SetPoint("TOPLEFT", IN, -100 - (LADDER_ROWS + 1) * 28 - 10); f.warn:SetWidth(ficheW - 2 * IN)
    f.warn:SetJustifyH("LEFT")
    local tw = math.floor((ficheW - 2 * IN - 16) / 3)
    local function Tile(i, label, color)
        local b = Box(bd, tw, 64)
        b:SetPoint("BOTTOMLEFT", IN + (i - 1) * (tw + 8), 104)
        local l = Hc.Label(b, label, 10, color or { 0.5, 0.64, 0.7 }); l:SetPoint("TOPLEFT", 8, -8)
        local v = Hc.Text(b, 16, color or Hc.TEXT); v:SetPoint("TOPLEFT", 8, -24); v:SetWidth(tw - 16)
        local s = Hc.Text(b, 10, Hc.SOFT); s:SetPoint("TOPLEFT", 8, -46); s:SetWidth(tw - 16)
        return v, s
    end
    f.t1, f.t1s = Tile(1, "Tu paies")
    f.t2, f.t2s = Tile(2, "Tu touches")
    f.t3 = Tile(3, "Gain visé", Hc.GREEN)
    f.buy = GoButton(bd, ficheW - 2 * IN, 52)
    f.buy:SetPoint("BOTTOMLEFT", IN, 38)
    f.buy.label:SetFont(Hc.FONT, 14, "")
    f.buy:SetScript("OnClick", function() OpBuy(opSel) end)
    f.buy:HookScript("OnEnter", function() if opSel then Ano().Prefetch(opSel) end end)
    f.note = Hc.Text(bd, 12, Hc.SOFT); f.note:SetPoint("BOTTOM", 0, 14)
end

F._TestOp = function(e) opSel = e; DrawOpportunites(); return Op end -- (test hors jeu)

function F.RefreshOpportunites()
    if Op.frame and Op.frame:IsVisible() then DrawOpportunites() end
end

---------------------------------------------------------------------------
-- Écran MES VENTES (maquette corrigée, 08/11) : ce que tu as VRAIMENT gagné, par objet, sur une période
-- (aujourd'hui / 7 jours / depuis le début). Ventes : ns.MySales / ns.MySalesItems (EryAddon_HV.lua : factures
-- du courrier, sinon prix de l'annonce − 5 % en attendant le courrier). Coût : FIGÉ à la mise en vente (acheté /
-- fabriqué / ramassé, ns.CostBasis à ce moment-là) ; bénéfice = ns.MySales().benef = net − coût figé − dépôts perdus.
-- (11/11, Jérémie : avant, le coût était recalculé à l'affichage aux prix du jour → le bénéfice d'une vente FAITE
-- bougeait avec le marché.)
---------------------------------------------------------------------------
local Mv = {}
local mvPeriod = "week"
local mvOffset = 0
local MV2_ROWS = 15

local function MvSince()
    if mvPeriod == "today" then
        local d = date("*t")
        return time({ year = d.year, month = d.month, day = d.day, hour = 0 })
    elseif mvPeriod == "week" then
        return time() - 7 * 86400
    end
    return nil
end

local function MvRows()
    local rows = {}
    for _, s in ipairs(ns.MySalesItems and ns.MySalesItems(MvSince()) or {}) do
        if (s.vendus or 0) > 0 then
            s.cost, s.origin = (s.coutTot or 0) / s.vendus, s.co or "ramassé"
        else -- rien de vendu sur la période (seulement des invendus) : coût d'aujourd'hui, pour info
            local cost, origin = 0, "ramassé"
            if ns.CostBasis then cost, origin = ns.CostBasis(s.id) end
            s.cost, s.origin = cost or 0, origin
        end
        s.profit = s.benef or 0
        rows[#rows + 1] = s
    end
    table.sort(rows, function(a, b) return a.profit > b.profit end)
    return rows
end

local function HoursText(h)
    if not h then return "-" end
    if h < 1 then return math.max(1, math.floor(h * 60 + 0.5)) .. " min" end
    if h < 48 then return math.floor(h + 0.5) .. " h" end
    return math.floor(h / 24 + 0.5) .. " j"
end

local function DrawMesVentes()
    if not Mv.rows then return end
    local Hc = H()
    local rows = MvRows()
    -- Cartes.
    local profit, sold, net, hours, nH, expired, lost = 0, 0, 0, 0, 0, 0, 0
    local best, fastest
    for _, s in ipairs(rows) do
        profit = profit + s.profit
        sold, net = sold + (s.vendus or 0), net + (s.net or 0)
        if s.delaiMoyen and (s.nDelai or 0) > 0 then
            hours, nH = hours + s.delai, nH + s.nDelai
            if (s.vendus or 0) >= 3 and (not fastest or s.delaiMoyen < fastest.delaiMoyen) then fastest = s end
        end
        expired, lost = expired + (s.expires or 0), lost + (s.depotPerdu or 0)
        if (s.vendus or 0) > 0 and (not best or s.profit > best.profit) then best = s end
    end
    Mv.k1:SetText((profit >= 0 and "+" or "-") .. Money(math.abs(profit)))
    Mv.k1:SetTextColor(unpack(profit >= 0 and Hc.GREEN or Hc.RED))
    Mv.k1s:SetText(best and ("meilleur : " .. (best.name or "?")) or "")
    Mv.k2:SetText(sold)
    Mv.k2s:SetText("pour " .. Money(math.floor(net)) .. " nets")
    Mv.k3:SetText(nH > 0 and HoursText(hours / nH) or "-")
    Mv.k3s:SetText(fastest and ("le plus rapide : " .. (fastest.name or "?")) or "")
    Mv.k4:SetText(expired)
    Mv.k4:SetTextColor(unpack(expired > 0 and Hc.ORANGE or Hc.TEXT))
    Mv.k4s:SetText(lost > 0 and ("dépôts perdus : " .. Money(lost)) or "aucun dépôt perdu")
    for key, b in pairs(Mv.tabs) do b:SetStyle(key == mvPeriod and "solid" or "outline") end

    -- Tableau.
    mvOffset = math.max(0, math.min(mvOffset, #rows - MV2_ROWS))
    for i, r in ipairs(Mv.rows) do
        local s = rows[mvOffset + i]
        r.s = s
        if s then
            local _, _, _, _, icon = ItemInfo(s.id)
            r.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            r.name:SetText((s.name or "?") .. (s.estime and " |cff9fbfcc(courrier à lire)|r" or ""))
            r.sold:SetText(s.vendus or 0)
            r.delay:SetText(HoursText(s.delaiMoyen))
            r.netu:SetText((s.vendus or 0) > 0 and Money(math.floor(s.net / s.vendus)) or "-")
            r.costu:SetText(s.cost > 0 and Money(s.cost) or "0")
            r.origin:SetText(s.origin or "")
            r.profit:SetText((s.profit >= 0 and "+" or "-") .. Money(math.abs(math.floor(s.profit))))
            r.profit:SetTextColor(unpack(s.profit >= 0 and Hc.GREEN or Hc.RED))
            r.exp:SetText((s.expires or 0) > 0 and s.expires or "")
            r.dep:SetText((s.depotPerdu or 0) > 0 and ("-" .. Money(math.floor(s.depotPerdu))) or "")
            r.live:SetText((s.enCours or 0) > 0 and s.enCours or "")
            r:Show()
        else
            r:Hide()
        end
    end
    Mv.empty:SetShown(#rows == 0)
end

function F.RefreshMesVentes()
    if Mv.frame and Mv.frame:IsVisible() then DrawMesVentes() end
end

function F.CreateMesVentesScreen(parent)
    local Hc = H()
    Mv.frame = parent
    local cw = DESIGN_W - 2 - RAIL_W - 1
    local ch = DESIGN_H - 2 - TOP_H
    local iw = cw - 2 * PAD

    Mv.tabs = {}
    local prev
    for _, p in ipairs({ { "today", "Aujourd'hui" }, { "week", "7 jours" }, { "all", "Depuis le début" } }) do
        local b = Hc.Button(parent, p[2], 150, 34, "outline")
        b.label:SetFont(Hc.FONT, 13, "")
        if prev then b:SetPoint("LEFT", prev, "RIGHT", 8, 0) else b:SetPoint("TOPLEFT", PAD, -PAD) end
        b:SetScript("OnClick", function() mvPeriod = p[1]; mvOffset = 0; DrawMesVentes() end)
        Mv.tabs[p[1]] = b
        prev = b
    end

    local kw = math.floor((iw - 3 * 12) / 4)
    local function Card(i, label, color)
        local c = Panel(parent)
        c:SetPoint("TOPLEFT", PAD + (i - 1) * (kw + 12), -PAD - 34 - 14)
        c:SetSize(kw, 84)
        local l = Hc.Label(c, label, 11, color or { 0.5, 0.64, 0.7 }); l:SetPoint("TOPLEFT", 14, -12)
        local v = Hc.Text(c, 26, Hc.TEXT); v:SetPoint("TOPLEFT", 14, -30); v:SetWidth(kw - 28)
        local s = Hc.Text(c, 12, Hc.SOFT); s:SetPoint("TOPLEFT", 14, -62); s:SetWidth(kw - 28)
        return v, s
    end
    Mv.k1, Mv.k1s = Card(1, "Bénéfice réel", Hc.GREEN)
    Mv.k2, Mv.k2s = Card(2, "Objets vendus")
    Mv.k3, Mv.k3s = Card(3, "Délai moyen")
    Mv.k4, Mv.k4s = Card(4, "Invendus")

    local top = -PAD - 34 - 14 - 84 - 14
    local t = Panel(parent)
    t:SetPoint("TOPLEFT", PAD, top)
    t:SetSize(iw, ch + top - PAD)
    local head = CreateFrame("Frame", nil, t)
    head:SetPoint("TOPLEFT", 1, -1); head:SetPoint("TOPRIGHT", -1, -1); head:SetHeight(30)
    local hb = Hc.Tex(head, "BACKGROUND", { 0.039, 0.082, 0.125 }, 1); hb:SetAllPoints()
    -- Bords droits des colonnes (Origine : bord gauche) ; l'objet prend le reste.
    -- Ordre de lecture : ce que tu touches, ce que ça t'a coûté, ce que les invendus t'ont fait perdre, le bénéfice.
    local C = { sold = 420, delay = 500, netu = 610, costu = 720, origin = 740, exp = 880, dep = 1000, profit = 1100,
        live = 1180 }
    local function H1(text, x, left)
        local h = Hc.Label(head, text, 11, { 0.5, 0.64, 0.7 })
        if left then h:SetPoint("LEFT", head, "LEFT", x, 0) else h:SetPoint("RIGHT", head, "LEFT", x, 0) end
    end
    H1("Objet", 12, true); H1("Vendus", C.sold); H1("Délai", C.delay); H1("Net / u", C.netu); H1("Coût / u", C.costu)
    H1("Origine", C.origin, true); H1("Invendus", C.exp); H1("Dépôts perdus", C.dep); H1("Bénéfice", C.profit)
    H1("En vente", C.live)
    Mv.rows = {}
    for i = 1, MV2_ROWS do
        local r = CreateFrame("Frame", nil, t)
        r:SetPoint("TOPLEFT", 1, -31 - (i - 1) * 36); r:SetPoint("TOPRIGHT", -1, -31 - (i - 1) * 36); r:SetHeight(36)
        r:EnableMouse(true)
        Hc.RowHighlight(r)
        local ln = Hc.Tex(r, "BORDER", { 0.071, 0.161, 0.227 }); ln:SetHeight(1); ln:SetPoint("BOTTOMLEFT"); ln:SetPoint("BOTTOMRIGHT")
        r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(24, 24); r.icon:SetPoint("LEFT", 10, 0)
        r.name = Hc.Text(r, 14, Hc.TEXT); r.name:SetPoint("LEFT", r.icon, "RIGHT", 8, 0); r.name:SetWidth(C.sold - 110)
        local function Cell(x, color, size)
            local fs = Hc.Text(r, size or 14, color or Hc.TEXT); fs:SetPoint("RIGHT", r, "LEFT", x, 0); fs:SetJustifyH("RIGHT")
            return fs
        end
        r.sold = Cell(C.sold); r.delay = Cell(C.delay, Hc.SOFT); r.netu = Cell(C.netu); r.costu = Cell(C.costu, Hc.SOFT)
        r.origin = Hc.Text(r, 12, Hc.SOFT); r.origin:SetPoint("LEFT", r, "LEFT", C.origin, 0)
        r.profit = Cell(C.profit, Hc.GREEN, 15); r.exp = Cell(C.exp, Hc.ORANGE); r.live = Cell(C.live, Hc.SOFT)
        r.dep = Cell(C.dep, Hc.ORANGE)
        r:SetScript("OnEnter", function(self)
            if not self.s then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetItemByID(self.s.id); GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        r:SetScript("OnMouseUp", function(self) if self.s and ns.ShiftLink then ns.ShiftLink(self.s.id) end end)
        r:Hide()
        Mv.rows[i] = r
    end
    Mv.empty = Hc.Text(t, 15, Hc.SOFT); Mv.empty:SetPoint("CENTER"); Mv.empty:SetText("Aucune vente sur cette période")
    t:EnableMouseWheel(true)
    t:SetScript("OnMouseWheel", function(_, delta) mvOffset = math.max(0, mvOffset - delta * 3); DrawMesVentes() end)
end

---------------------------------------------------------------------------
-- Écran ACHETER (maquette corrigée, 08/11) : parcourir l'HV comme chez Blizzard. Catégories du jeu
-- (AuctionCategories, même source qu'Auctionator), recherche (SendBrowseQuery), résultats avec l'ÉCART au prix
-- du marché (TSM) et le VOLUME par jour ; fiche de l'objet : ses annonces (SendSearchQuery) et l'achat :
--   - empilable : quantité → ns.BuyReagent (prix annoncé par le serveur vérifié, confirmation) ;
--   - non empilable : une annonce par clic (PlaceBid), la moins chère des autres ou celle choisie.
-- Achat réussi → prix payé noté (EryAddonDB.prixPaye) : « Mes ventes » saura ce qu'il t'a coûté.
---------------------------------------------------------------------------
local Ac = {}
local acCat, acSub, acSub2      -- catégorie choisie (index), sous-catégorie, sous-sous-catégorie
local acResults = {}            -- { itemKey, id, qty, price, name, icon, quality, commodity, market, ecart, perDay }
local acOffset = 0
local acSel                     -- résultat affiché dans la fiche
local acListings                -- annonces de l'objet choisi { p, q, own, auctionID, who }
local acPick                    -- annonce choisie (objets non empilables)
local acQty = 1
local acPending, acBid          -- achat en cours (empilable / non empilable)
local AC_ROWS, AC_CAT_ROWS, AC_LIST_ROWS = 17, 28, 10

local function CatRows()
    local rows = {}
    for i, c in ipairs(AuctionCategories or {}) do
        rows[#rows + 1] = { level = 0, name = c.name, i = i }
        if acCat == i then
            for j, s in ipairs(c.subCategories or {}) do
                rows[#rows + 1] = { level = 1, name = s.name, i = i, j = j }
                if acSub == j then
                    for k, s2 in ipairs(s.subCategories or {}) do rows[#rows + 1] = { level = 2, name = s2.name, i = i, j = j, k = k } end
                end
            end
        end
    end
    return rows
end

local function CatFilters()
    local c = acCat and AuctionCategories and AuctionCategories[acCat]
    if not c then return {} end
    local s = acSub and c.subCategories and c.subCategories[acSub]
    local s2 = s and acSub2 and s.subCategories and s.subCategories[acSub2]
    return (s2 and s2.filters) or (s and s.filters) or c.filters or {}
end

local function ResultInfo(r)
    local okI, ki = pcall(C_AuctionHouse.GetItemKeyInfo, r.itemKey)
    local name, _, quality, _, icon = ItemInfo(r.itemKey.itemID)
    local id = r.itemKey.itemID
    local market = ns.TSM and ns.TSM("DBMarket", id)
    local e = { itemKey = r.itemKey, id = id, qty = r.totalQuantity or 0, price = r.minPrice or 0,
        name = (okI and ki and ki.itemName) or name or ("objet " .. id), icon = (okI and ki and ki.iconFileID) or icon,
        quality = (okI and ki and ki.quality) or quality, commodity = okI and ki and ki.isCommodity or false,
        market = market, perDay = ns.TSM and ns.TSM("DBRegionSoldPerDay", id) }
    if market and market > 0 and e.price > 0 then e.ecart = (e.price - market) / market end
    -- Objet pas encore chargé par le jeu (« objet 2679 », vu le 09/11) : on lui demande, et la ligne est
    -- complétée à l'arrivée de l'info (GET_ITEM_INFO_RECEIVED → F.AcItemInfo).
    if not ((okI and ki and ki.itemName) or name) then
        e.loading = true
        if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
    end
    return e
end

-- Info d'un objet arrivée : les lignes de résultats qui l'attendaient sont complétées (un seul redessin groupé).
local acInfoTimer
function F.AcItemInfo(itemID)
    local hit = false
    for _, e in ipairs(acResults) do
        if e.loading and e.id == itemID then
            local okI, ki = pcall(C_AuctionHouse.GetItemKeyInfo, e.itemKey)
            local name, _, quality, _, icon = ItemInfo(itemID)
            e.name = (okI and ki and ki.itemName) or name or e.name
            e.icon = (okI and ki and ki.iconFileID) or icon or e.icon
            e.quality = (okI and ki and ki.quality) or quality or e.quality
            if okI and ki and ki.isCommodity ~= nil then e.commodity = ki.isCommodity end
            e.loading = (okI and ki and ki.itemName) == nil and name == nil
            hit = true
        end
    end
    if hit and not acInfoTimer then
        acInfoTimer = true
        C_Timer.After(0.2, function() acInfoTimer = nil; if F.RefreshAcheter then F.RefreshAcheter() end end)
    end
end

local function ReadBrowse()
    acResults = {}
    local only = Ac.under and Ac.under:GetChecked()
    for _, r in ipairs(C_AuctionHouse.GetBrowseResults() or {}) do
        if r.itemKey then
            local e = ResultInfo(r)
            if not only or (e.ecart and e.ecart <= -0.05) then acResults[#acResults + 1] = e end
        end
    end
end

local function DrawAcheter()
    if not Ac.rows then return end
    local Hc = H()
    -- Catégories.
    local cats = CatRows()
    for i, b in ipairs(Ac.cats) do
        local c = cats[i]
        b.c = c
        if c then
            b.text:SetText(c.name)
            b.text:SetPoint("LEFT", 10 + c.level * 14, 0)
            local on = (c.level == 0 and acCat == c.i and not acSub) or (c.level == 1 and acSub == c.j and not acSub2)
                or (c.level == 2 and acSub2 == c.k)
            b.bg:SetColorTexture(0.059, 0.141, 0.2, on and 1 or 0)
            b.text:SetTextColor(unpack(on and { 1, 1, 1 } or (c.level == 0 and { 0.71, 0.83, 0.87 } or Hc.SOFT)))
            b:Show()
        else
            b:Hide()
        end
    end
    -- Résultats.
    acOffset = math.max(0, math.min(acOffset, #acResults - AC_ROWS))
    for i, r in ipairs(Ac.rows) do
        local e = acResults[acOffset + i]
        r.e = e
        if e then
            r.icon:SetTexture(e.icon)
            r.name:SetText(e.name)
            r.name:SetTextColor(QualityColor(e.quality))
            r.qty:SetText(e.qty)
            r.price:SetText(Money(e.price))
            if e.ecart then
                local pct = math.floor(e.ecart * 100 + (e.ecart >= 0 and 0.5 or -0.5))
                r.ecart:SetText((pct > 0 and "+" or "") .. pct .. " %")
                r.ecart:SetTextColor(unpack(pct <= -15 and Hc.GREEN or (pct > 0 and Hc.ORANGE or Hc.TEXT)))
            else
                r.ecart:SetText("")
            end
            r.vol:SetText(e.perDay and Num(e.perDay) or "")
            r.sel:SetShown(acSel and acSel.id == e.id)
            r:Show()
        else
            r:Hide()
        end
    end
    Ac.empty:SetShown(#acResults == 0)
    Ac.empty:SetText(Ac.searching and "Recherche…" or "Choisis une catégorie ou tape un nom")

    -- Fiche.
    local f = Ac.fiche
    f.empty:SetShown(acSel == nil)
    f.body:SetShown(acSel ~= nil)
    if not acSel then return end
    local e = acSel
    f.icon:SetTexture(e.icon)
    f.name:SetText(e.name)
    f.name:SetTextColor(QualityColor(e.quality))
    f.sub:SetText(e.commodity and "Empilable" or "Non empilable · une annonce par clic")
    f.v1:SetText(Money(e.price))
    f.v1s:SetText(e.ecart and (string.format("%+d %%", math.floor(e.ecart * 100 + 0.5)) .. " / marché") or "")
    f.v1s:SetTextColor(unpack(e.ecart and e.ecart <= -0.15 and Hc.GREEN or Hc.SOFT))
    f.v2:SetText(e.market and Money(math.floor(e.market)) or "?")
    f.v3:SetText(e.perDay and (Num(e.perDay) .. " / j") or "?")
    -- Palier repéré pour cet objet (écran Opportunités).
    local pal
    for _, x in ipairs(ns.AnoAPI and ns.AnoAPI.Items() or {}) do if x.id == e.id and x.kind == "palier" and x.resale then pal = x end end
    f.palier:SetShown(pal ~= nil)
    if pal then
        f.palierText:SetText(string.format("%s à %s sous un mur de %d à %s : revends à %s", tostring(pal.qty or "?"),
            Money(pal.minPrice or 0), pal.wallQty or 0, Money(pal.wall or 0), Money(pal.resale)))
        f.palier.e = pal
    end
    -- Annonces.
    f.colWho:SetShown(not e.commodity)
    local listings = acListings or {}
    for i, r in ipairs(f.list) do
        local l = listings[i]
        r.l = l
        if l then
            r.price:SetText(Money(l.p))
            r.qty:SetText(l.q)
            r.who:SetText(e.commodity and "" or (l.own > 0 and "toi" or (l.who or "")))
            r.sel:SetShown(not e.commodity and acPick == l)
            r:Show()
        else
            r:Hide()
        end
    end
    f.listState:SetText(acListings == nil and "recherche…" or (#listings == 0 and "plus rien en vente" or ""))
    -- Achat. La quantité saisie vaut pour les deux sortes d'objets (demande de Jérémie, 14/11) :
    -- empilable = tout d'un coup ; non empilable = le jeu exige un clic par annonce, chaque clic prend la
    -- suivante la moins chère jusqu'à la quantité voulue (sans attendre une nouvelle recherche).
    f.qtyBox:SetShown(true)
    local label, enabled = "Acheter", false
    local avail, total, left = 0, 0, acQty
    for _, l in ipairs(listings) do
        local n = math.max(0, l.q - l.own)
        if not e.commodity and not l.auctionID then n = 0 end
        avail = avail + n
        if left > 0 then local k = math.min(left, n); total = total + k * l.p; left = left - k end
    end
    -- (annonces pas encore lues : on ne touche pas à ce que tu as tapé)
    if acListings and acQty > avail then acQty = math.max(1, avail) end
    if not f.qtyEdit:HasFocus() then f.qtyEdit:SetText(acQty) end
    Ac.total = total
    local poor = total > GetMoney()
    if e.commodity then
        if avail > 0 then
            label = string.format("Acheter %d · %s", acQty, Money(total))
            enabled = not poor
        end
        f.note:SetText(poor and "|cffff7373Pas assez d'argent.|r" or "Total confirmé par le serveur · arrive par courrier")
    else
        if acPick and (acPick.q - acPick.own) <= 0 then acPick = nil end
        if not acPick then for _, l in ipairs(listings) do if l.own == 0 and l.auctionID and l.q > 0 then acPick = l break end end end
        if acPick then
            label = acQty > 1 and string.format("Acheter 1 sur %d · %s", acQty, Money(acPick.p))
                or ("Acheter 1 · " .. Money(acPick.p))
            enabled = acPick.p <= GetMoney()
        end
        f.note:SetText(poor and acQty > 1 and string.format("|cffff7373Pas assez d'argent pour %d (%s).|r", acQty, Money(total))
            or (acQty > 1 and string.format("Total pour %d : %s · 1 clic = 1 annonce", acQty, Money(total))
            or "1 clic = 1 annonce · arrive par courrier"))
    end
    if acPending and EryAddonDB.hvConfirmBlocked then label, enabled = "Confirmer l'achat", true
    elseif acPending or acBid then label, enabled = "Achat en cours…", false end
    f.buy:SetLabel(label)
    f.buy:SetEnabled(enabled)
end

local function SearchListings()
    if not acSel then return end
    if C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then
        C_Timer.After(0.3, SearchListings)
        return
    end
    acListings, acPick = nil, nil
    C_AuctionHouse.SendSearchQuery(acSel.itemKey, {}, true) -- sans tri, comme TSM
    DrawAcheter()
end

local function OnBuyResults(isCommodity, arg)
    if not acSel then return end
    if isCommodity and arg ~= acSel.id then return end
    if not isCommodity and (type(arg) ~= "table" or arg.itemID ~= acSel.id) then return end
    local list = {}
    if isCommodity then
        for i = 1, C_AuctionHouse.GetNumCommoditySearchResults(arg) do
            local r = C_AuctionHouse.GetCommoditySearchResultInfo(arg, i)
            if r and r.unitPrice then list[#list + 1] = { p = r.unitPrice, q = r.quantity or 0, own = r.numOwnerItems or 0 } end
        end
    else
        for i = 1, C_AuctionHouse.GetNumItemSearchResults(arg) do
            local r = C_AuctionHouse.GetItemSearchResultInfo(arg, i)
            local p = r and r.buyoutAmount
            if p and p > 0 then
                list[#list + 1] = { p = p, q = r.quantity or 1, own = r.containsOwnerItem and (r.quantity or 1) or 0,
                    auctionID = r.auctionID, who = r.owners and r.owners[1] or nil }
            end
        end
    end
    table.sort(list, function(a, b) return a.p < b.p end)
    acSel.commodity = isCommodity
    acListings = list
    DrawAcheter()
end

function F.AcheterSearch()
    if not Ac.search then return end
    if C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then
        C_Timer.After(0.3, F.AcheterSearch)
        return
    end
    -- Scan ou vérification en cours : ils se mettent en pause et reprennent après (règle de Jérémie, 09/11).
    if ns.HVUserAction then ns.HVUserAction() end
    acResults, acOffset, Ac.searching = {}, 0, true
    local text = Ac.search.edit:GetText() or ""
    C_AuctionHouse.SendBrowseQuery({ searchString = text, sorts = {
        { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false },
        { sortOrder = Enum.AuctionHouseSortOrder.Name, reverseSort = false } },
        filters = {}, itemClassFilters = CatFilters() })
    DrawAcheter()
end

local function OnBrowse()
    if not (Ac.frame and Ac.frame:IsVisible() and Ac.searching ~= nil) then return end
    if ns.HVBrowseOwner and ns.HVBrowseOwner() == "scan" then return end -- pages du scan, pas ta recherche
    Ac.searching = false
    ReadBrowse()
    DrawAcheter()
end

local function AcBuy()
    local e = acSel
    if not e or acBid or (acPending and not EryAddonDB.hvConfirmBlocked) then return end
    if e.commodity then
        if acPending and EryAddonDB.hvConfirmBlocked then -- le jeu exige un 2e clic pour confirmer
            ns.BuyReagent(acPending.id, acPending.qty, acPending.unit, e.name)
            return
        end
        if not Ac.total or acQty < 1 then return end
        local unit = math.ceil(Ac.total / acQty)
        acPending = { id = e.id, unit = unit, qty = acQty, t = time() }
        ns.BuyReagent(e.id, acQty, unit, e.name)
        C_Timer.After(20, function() if acPending and time() - acPending.t >= 20 then acPending = nil; DrawAcheter() end end)
    elseif acPick and acPick.auctionID then
        acBid = { id = e.id, price = acPick.p, money = GetMoney(), t = time(), l = acPick }
        local ok = pcall(C_AuctionHouse.PlaceBid, acPick.auctionID, acPick.p)
        if not ok then acBid = nil; Msg("achat refusé : " .. e.name) end
        C_Timer.After(6, function()
            if acBid and time() - acBid.t >= 6 then
                acBid = nil
                Msg(e.name .. " : achat non fait (l'annonce est sans doute partie). Rien n'a été payé.")
                SearchListings()
            end
        end)
    end
    DrawAcheter()
end

-- Achat réussi : prix payé noté pour « Mes ventes », annonces relues.
local function AcBought(id, unit, qty, unique)
    EryAddonDB.prixPaye = EryAddonDB.prixPaye or {}
    EryAddonDB.prixPaye[id] = { unit = unit, t = time() }
    if unique and ns.AddInbound then ns.AddInbound(id, qty) end -- (empilables : déjà fait par ns.BuyReagent)
    C_Timer.After(1, SearchListings)
end

F.AcOnBrowse = OnBrowse
function F.AcOnResults(isCommodity, arg)
    if Ac.frame and Ac.frame:IsVisible() then OnBuyResults(isCommodity, arg) end
end
function F.AcOnPurchase(ok)
    local p = acPending
    if not p then return end
    acPending = nil
    if ok then AcBought(p.id, p.unit, p.qty) end
    DrawAcheter()
end
-- Objet non empilable : pas d'événement fiable sur Forever → l'argent qui baisse du prix de l'annonce.
function F.AcOnMoney()
    local b = acBid
    if b and b.money - GetMoney() >= math.floor(b.price * 0.9) then
        acBid = nil
        Msg(string.format("acheté : 1 x %s pour %s (arrive par courrier).", acSel and acSel.name or "objet", Money(b.price)))
        -- Annonce retirée de la liste tout de suite, compteur baissé : le clic suivant prend la suivante.
        if b.l then b.l.q = b.l.q - 1 end
        if acPick == b.l then acPick = nil end
        if acQty > 1 then
            acQty = acQty - 1
            EryAddonDB.prixPaye = EryAddonDB.prixPaye or {}
            EryAddonDB.prixPaye[b.id] = { unit = b.price, t = time() }
            if ns.AddInbound then ns.AddInbound(b.id, 1) end
        else
            AcBought(b.id, b.price, 1, true) -- dernier de la série : annonces relues
        end
    end
    if Ac.frame and Ac.frame:IsVisible() then DrawAcheter() end
end

F._TestAc = function() return Ac, acResults, acSel, acListings, acPick end -- (test hors jeu)
function F.RefreshAcheter()
    if Ac.frame and Ac.frame:IsVisible() then DrawAcheter() end
end

function F.CreateAcheterScreen(parent)
    local Hc = H()
    Ac.frame = parent
    local cw = DESIGN_W - 2 - RAIL_W - 1
    local ch = DESIGN_H - 2 - TOP_H
    local catW, ficheW = 170, 390
    local midW = cw - 2 * PAD - catW - ficheW - 2 * PAD

    -- Catégories.
    local cat = Panel(parent)
    cat:SetPoint("TOPLEFT", PAD, -PAD)
    cat:SetSize(catW, ch - 2 * PAD)
    local cl = Hc.Label(cat, "Catégories", 11, { 0.5, 0.64, 0.7 }); cl:SetPoint("TOPLEFT", 12, -12)
    Ac.cats = {}
    for i = 1, AC_CAT_ROWS do
        local b = CreateFrame("Button", nil, cat)
        b:SetPoint("TOPLEFT", 4, -32 - (i - 1) * 25); b:SetPoint("TOPRIGHT", -4, -32 - (i - 1) * 25); b:SetHeight(25)
        b.bg = Hc.Tex(b, "BACKGROUND", { 0.059, 0.141, 0.2 }, 0); b.bg:SetAllPoints()
        Hc.RowHighlight(b)
        b.text = Hc.Text(b, 13, Hc.TEXT); b.text:SetPoint("LEFT", 10, 0); b.text:SetPoint("RIGHT", -4, 0)
        b:SetScript("OnClick", function(self)
            local c = self.c
            if not c then return end
            if c.level == 0 then
                if acCat == c.i and not acSub then acCat = nil else acCat, acSub, acSub2 = c.i, nil, nil end
            elseif c.level == 1 then
                acSub, acSub2 = c.j, nil
            else
                acSub2 = c.k
            end
            F.AcheterSearch()
        end)
        b:Hide()
        Ac.cats[i] = b
    end

    -- Recherche.
    local midX = PAD + catW + PAD
    Ac.search = Box(parent, midW - 260, 36)
    Ac.search:SetPoint("TOPLEFT", midX, -PAD)
    local e = CreateFrame("EditBox", nil, Ac.search)
    e:SetPoint("TOPLEFT", 10, 0); e:SetPoint("BOTTOMRIGHT", -10, 0)
    e:SetFont(Hc.FONT, 15, ""); e:SetTextColor(unpack(Hc.TEXT)); e:SetAutoFocus(false)
    e:SetScript("OnEnterPressed", function(self) self:ClearFocus(); F.AcheterSearch() end)
    e:SetScript("OnEscapePressed", e.ClearFocus)
    e:SetScript("OnTextChanged", function(self) Ac.ph:SetShown((self:GetText() or "") == "") end)
    Ac.search.edit = e
    Ac.ph = Hc.Text(Ac.search, 15, { 0.37, 0.5, 0.56 }); Ac.ph:SetPoint("LEFT", 10, 0); Ac.ph:SetText("Rechercher un objet")
    Ac.under = Hc.Check(parent, "Sous le marché")
    Ac.under:SetPoint("LEFT", Ac.search, "RIGHT", 12, 0)
    Ac.under:SetScript("OnClick", function() ReadBrowse(); DrawAcheter() end)
    local go = Hc.Button(parent, "Rechercher", 100, 36, "solid")
    go:SetPoint("TOPRIGHT", parent, "TOPLEFT", midX + midW, -PAD)
    go:SetScript("OnClick", F.AcheterSearch)

    -- Résultats.
    local t = Panel(parent)
    t:SetPoint("TOPLEFT", midX, -PAD - 36 - 12)
    t:SetSize(midW, ch - 2 * PAD - 48)
    local head = CreateFrame("Frame", nil, t)
    head:SetPoint("TOPLEFT", 1, -1); head:SetPoint("TOPRIGHT", -1, -1); head:SetHeight(30)
    local hb = Hc.Tex(head, "BACKGROUND", { 0.039, 0.082, 0.125 }, 1); hb:SetAllPoints()
    local X_QTY, X_PRICE, X_EC, X_VOL = midW - 270, midW - 170, midW - 90, midW - 12
    local function H1(text, x) local h = Hc.Label(head, text, 11, { 0.5, 0.64, 0.7 }); h:SetPoint("RIGHT", head, "LEFT", x, 0) end
    local h0 = Hc.Label(head, "Objet", 11, { 0.5, 0.64, 0.7 }); h0:SetPoint("LEFT", 12, 0)
    H1("Dispo", X_QTY); H1("Prix", X_PRICE); H1("Écart", X_EC); H1("Volume / j", X_VOL)
    Ac.rows = {}
    for i = 1, AC_ROWS do
        local r = CreateFrame("Button", nil, t)
        r:SetPoint("TOPLEFT", 1, -31 - (i - 1) * 38); r:SetPoint("TOPRIGHT", -1, -31 - (i - 1) * 38); r:SetHeight(38)
        Hc.RowHighlight(r)
        r.sel = Hc.Tex(r, "BACKGROUND", { 0.059, 0.141, 0.2 }, 1); r.sel:SetAllPoints()
        local ln = Hc.Tex(r, "BORDER", { 0.071, 0.161, 0.227 }); ln:SetHeight(1); ln:SetPoint("BOTTOMLEFT"); ln:SetPoint("BOTTOMRIGHT")
        r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(26, 26); r.icon:SetPoint("LEFT", 8, 0)
        r.name = Hc.Text(r, 14, Hc.TEXT); r.name:SetPoint("LEFT", r.icon, "RIGHT", 8, 0)
        r.name:SetPoint("RIGHT", r, "LEFT", X_QTY - 50, 0)
        local function Cell(x, color, size)
            local fs = Hc.Text(r, size or 14, color or Hc.TEXT); fs:SetPoint("RIGHT", r, "LEFT", x, 0); fs:SetJustifyH("RIGHT")
            return fs
        end
        r.qty = Cell(X_QTY, Hc.SOFT); r.price = Cell(X_PRICE); r.ecart = Cell(X_EC); r.vol = Cell(X_VOL, Hc.SOFT)
        r:SetScript("OnClick", function(self)
            if not self.e then return end
            if ns.ShiftLink and ns.ShiftLink(self.e.id) then return end
            acSel, acQty = self.e, 1
            SearchListings()
        end)
        r:SetScript("OnEnter", function(self)
            if not self.e then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetItemByID(self.e.id); GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        r:Hide()
        Ac.rows[i] = r
    end
    Ac.empty = Hc.Text(t, 15, Hc.SOFT); Ac.empty:SetPoint("CENTER")
    t:EnableMouseWheel(true)
    t:SetScript("OnMouseWheel", function(_, delta)
        acOffset = math.max(0, acOffset - delta * 3)
        -- Bas de la liste atteint : on demande la page suivante au serveur.
        if acOffset + AC_ROWS >= #acResults then
            if ns.HVBrowseOwner and ns.HVBrowseOwner() == "scan" then
                -- le scan a repris le fil des pages entre-temps : ta recherche est relancée (il se remet en pause)
                if Ac.searching ~= nil then F.AcheterSearch() return end
            elseif C_AuctionHouse.HasFullBrowseResults and not C_AuctionHouse.HasFullBrowseResults() then
                C_AuctionHouse.RequestMoreBrowseResults()
            end
        end
        DrawAcheter()
    end)

    -- Fiche.
    local f = Panel(parent)
    f:SetPoint("TOPLEFT", parent, "TOPLEFT", midX + midW + PAD, -PAD)
    f:SetSize(ficheW, ch - 2 * PAD)
    Ac.fiche = f
    f.empty = Hc.Text(f, 15, Hc.SOFT); f.empty:SetPoint("CENTER"); f.empty:SetText("Choisis un objet")
    f.body = CreateFrame("Frame", nil, f); f.body:SetAllPoints()
    local bd, IN = f.body, 16
    f.icon = bd:CreateTexture(nil, "ARTWORK"); f.icon:SetSize(44, 44); f.icon:SetPoint("TOPLEFT", IN, -IN)
    f.name = Hc.Text(bd, 18, Hc.TEXT); f.name:SetPoint("TOPLEFT", f.icon, "TOPRIGHT", 10, -2); f.name:SetWidth(ficheW - 2 * IN - 54)
    f.sub = Hc.Text(bd, 12, Hc.SOFT); f.sub:SetPoint("TOPLEFT", f.name, "BOTTOMLEFT", 0, -6)
    local tw = math.floor((ficheW - 2 * IN - 16) / 3)
    local function Tile(i, label)
        local b = Box(bd, tw, 62)
        b:SetPoint("TOPLEFT", IN + (i - 1) * (tw + 8), -76)
        local l = Hc.Label(b, label, 10, { 0.5, 0.64, 0.7 }); l:SetPoint("TOPLEFT", 8, -8)
        local v = Hc.Text(b, 16, Hc.TEXT); v:SetPoint("TOPLEFT", 8, -24); v:SetWidth(tw - 16)
        local s = Hc.Text(b, 10, Hc.SOFT); s:SetPoint("TOPLEFT", 8, -46); s:SetWidth(tw - 16)
        return v, s
    end
    f.v1, f.v1s = Tile(1, "Prix")
    f.v2 = Tile(2, "Marché")
    f.v3 = Tile(3, "Volume")
    -- Palier repéré (lien vers Opportunités).
    f.palier = Box(bd, ficheW - 2 * IN, 52)
    f.palier:SetPoint("TOPLEFT", IN, -148)
    SetEdges(f.palier, Hc.GREEN)
    local pl = Hc.Label(f.palier, "Palier repéré", 10, Hc.GREEN); pl:SetPoint("TOPLEFT", 8, -7)
    f.palierText = Hc.Text(f.palier, 12, Hc.TEXT); f.palierText:SetPoint("TOPLEFT", 8, -24); f.palierText:SetWidth(ficheW - 2 * IN - 110)
    local pb = Hc.Button(f.palier, "Voir", 80, 26, "outline")
    pb:SetPoint("RIGHT", -8, 0)
    pb:SetScript("OnClick", function() opSel = f.palier.e; F.ShowScreen("opportunites") end)
    -- Annonces.
    local al = Hc.Label(bd, "Annonces", 11, { 0.5, 0.64, 0.7 }); al:SetPoint("TOPLEFT", IN, -212)
    f.listState = Hc.Text(bd, 11, Hc.SOFT); f.listState:SetPoint("TOPRIGHT", -IN, -212)
    local lh = CreateFrame("Frame", nil, bd)
    lh:SetPoint("TOPLEFT", IN, -230); lh:SetSize(ficheW - 2 * IN, 26)
    local lhb = Hc.Tex(lh, "BACKGROUND", { 0.039, 0.082, 0.125 }, 1); lhb:SetAllPoints()
    local a1 = Hc.Label(lh, "Prix", 10, { 0.5, 0.64, 0.7 }); a1:SetPoint("RIGHT", lh, "LEFT", 130, 0)
    local a2 = Hc.Label(lh, "Dispo", 10, { 0.5, 0.64, 0.7 }); a2:SetPoint("RIGHT", lh, "LEFT", 200, 0)
    f.colWho = Hc.Label(lh, "Vendeur", 10, { 0.5, 0.64, 0.7 }); f.colWho:SetPoint("LEFT", lh, "LEFT", 216, 0)
    f.list = {}
    for i = 1, AC_LIST_ROWS do
        local r = CreateFrame("Button", nil, bd)
        r:SetPoint("TOPLEFT", lh, "BOTTOMLEFT", 0, -(i - 1) * 28); r:SetSize(ficheW - 2 * IN, 28)
        Hc.RowHighlight(r)
        r.sel = Hc.Tex(r, "BACKGROUND", { 0.059, 0.141, 0.2 }, 1); r.sel:SetAllPoints()
        r.price = Hc.Text(r, 13, Hc.TEXT); r.price:SetPoint("RIGHT", r, "LEFT", 130, 0); r.price:SetJustifyH("RIGHT")
        r.qty = Hc.Text(r, 13, Hc.TEXT); r.qty:SetPoint("RIGHT", r, "LEFT", 200, 0); r.qty:SetJustifyH("RIGHT")
        r.who = Hc.Text(r, 12, Hc.SOFT); r.who:SetPoint("LEFT", r, "LEFT", 216, 0); r.who:SetWidth(ficheW - 2 * IN - 220)
        -- Objet non empilable : clic = choisir cette annonce-là.
        r:SetScript("OnClick", function(self)
            if self.l and acSel and not acSel.commodity and self.l.own == 0 then acPick = self.l; DrawAcheter() end
        end)
        r:Hide()
        f.list[i] = r
    end
    -- Quantité (empilables) et achat.
    f.qtyBox = CreateFrame("Frame", nil, bd)
    f.qtyBox:SetPoint("BOTTOMLEFT", IN, 96); f.qtyBox:SetSize(ficheW - 2 * IN, 40)
    local ql = Hc.Label(f.qtyBox, "Quantité", 11, { 0.5, 0.64, 0.7 }); ql:SetPoint("LEFT", 0, 0)
    local minus = Hc.Button(f.qtyBox, "-", 34, 34, "muted"); minus:SetPoint("LEFT", 80, 0)
    local qe = NumberBox(f.qtyBox, 70, 34, 18, function()
        local v = tonumber(f.qtyEdit:GetText())
        if v and v >= 1 then acQty = v; DrawAcheter() end
    end)
    qe:SetPoint("LEFT", minus, "RIGHT", 4, 0)
    f.qtyEdit = qe.edit
    f.qtyEdit:SetJustifyH("CENTER")
    local plus = Hc.Button(f.qtyBox, "+", 34, 34, "muted"); plus:SetPoint("LEFT", qe, "RIGHT", 4, 0)
    minus:SetScript("OnClick", function() acQty = math.max(1, acQty - 1); DrawAcheter() end)
    plus:SetScript("OnClick", function() acQty = acQty + 1; DrawAcheter() end)
    f.plus = plus
    f.buy = GoButton(bd, ficheW - 2 * IN, 50)
    f.buy:SetPoint("BOTTOMLEFT", IN, 38)
    f.buy.label:SetFont(Hc.FONT, 15, "")
    f.buy:SetScript("OnClick", AcBuy)
    f.note = Hc.Text(bd, 11, Hc.SOFT); f.note:SetPoint("BOTTOM", 0, 14)
end

-- MAJ+CLIC sur un objet (chat, sacs, info-bulle…) quand l'écran Métiers est ouvert : son nom va dans la
-- barre de recherche (demande de Jérémie). Même méthode qu'Auctionator, recopiée : on s'accroche à la
-- fonction du jeu qui insère un lien, et on ne fait rien si le lien part vers une fenêtre de chat ouverte.
local function OnInsertLink(text)
    if type(text) ~= "string" then return end
    if win and win:IsShown() and currentScreen == "acheter" and Ac.search then
        local focus = GetCurrentKeyBoardFocus and GetCurrentKeyBoardFocus()
        if focus and focus ~= Ac.search.edit and focus.GetName and focus:GetName() then return end
        local name = text:match("|h%[(.-)%]|h") or text:match("%[(.-)%]")
        if name and name ~= "" then Ac.search.edit:SetText(name); F.AcheterSearch() end
        return
    end
    if not (metiersFrame and metiersFrame:IsVisible() and Mt.search) then return end
    local focus = GetCurrentKeyBoardFocus and GetCurrentKeyBoardFocus()
    if focus and focus ~= Mt.search.edit and focus.GetName and focus:GetName() then return end -- lien vers le chat
    local name = text:match("|h%[(.-)%]|h") or text:match("%[(.-)%]")
    if not name or name == "" then return end
    Mt.search.edit:SetText(name)
    UpdateResults()
    -- Un seul résultat, ou le 1er porte exactement ce nom : sa fiche s'ouvre directement.
    local first, second = Mt.resultButtons[1], Mt.resultButtons[2]
    if first.found and (first.found.label == name or not second:IsShown()) then OpenFound(first.found) end
end
if ChatFrameUtil and ChatFrameUtil.InsertLink then
    hooksecurefunc(ChatFrameUtil, "InsertLink", OnInsertLink)
elseif ChatEdit_InsertLink then
    hooksecurefunc("ChatEdit_InsertLink", OnInsertLink)
end
F._OnInsertLink = OnInsertLink -- pour le test hors jeu

---------------------------------------------------------------------------
-- La fenêtre
---------------------------------------------------------------------------
local function Fit()
    local s = math.min(1, (UIParent:GetWidth() - 20) / DESIGN_W, (UIParent:GetHeight() - 20) / DESIGN_H)
    win:SetScale(s)
    if H().FixBorders then H().FixBorders(win) end -- traits des cadres de CETTE fenêtre : au moins 1 vrai pixel
end

local function Create()
    if win then return end
    local Hc = H()
    win = CreateFrame("Frame", "EryHVFrame", UIParent)
    win:SetSize(DESIGN_W, DESIGN_H)
    win:SetPoint("CENTER")
    win:SetFrameStrata("HIGH")
    win:SetToplevel(true)
    win:EnableMouse(true)
    win:SetMovable(true)
    win:SetClampedToScreen(true)
    Hc.Skin(win, 1)
    tinsert(UISpecialFrames, "EryHVFrame") -- Échap ferme (et ferme l'HV)

    local top = CreateFrame("Frame", nil, win)
    top:SetPoint("TOPLEFT", 1, -1); top:SetPoint("TOPRIGHT", -1, -1); top:SetHeight(TOP_H - 1)
    local tbg = Hc.Tex(top, "BACKGROUND", { 0.039, 0.082, 0.125 }, 1); tbg:SetAllPoints()
    local tl = Hc.Tex(top, "BORDER", Hc.LINE); tl:SetHeight(1); tl:SetPoint("BOTTOMLEFT"); tl:SetPoint("BOTTOMRIGHT")
    top:EnableMouse(true); top:RegisterForDrag("LeftButton")
    top:SetScript("OnDragStart", function() win:StartMoving() end)
    top:SetScript("OnDragStop", function() win:StopMovingOrSizing() end)
    local brand = Hc.Label(top, "FDC · Hôtel des ventes", 16, Hc.CYAN); brand:SetPoint("LEFT", 20, 0)
    local unused
    win.scanChip = Chip(top, brand, 16)
    win.tsmChip, unused, win.tsmDot = Chip(top, win.scanChip, 8)
    win.mailChip, unused, win.mailDot = Chip(top, win.tsmChip, 8)

    local close = CreateFrame("Button", nil, top)
    close:SetSize(32, 32); close:SetPoint("RIGHT", -12, 0)
    Hc.Border(close, { 0.165, 0.31, 0.388 })
    close.t = Hc.Text(close, 18, Hc.SOFT); close.t:SetPoint("CENTER"); close.t:SetText("x")
    close:SetScript("OnClick", function() win:Hide() end)
    local goldBox = CreateFrame("Frame", nil, top)
    goldBox:SetSize(150, 28); goldBox:SetPoint("RIGHT", close, "LEFT", -10, 0)
    Hc.Border(goldBox, Hc.LINE)
    win.gold = Hc.Text(goldBox, 14, Hc.TEXT); win.gold:SetPoint("CENTER")
    local game = Hc.Button(top, "Interface du jeu", 150, 32, "muted")
    game:SetPoint("RIGHT", goldBox, "LEFT", -10, 0)
    -- Le scan (il sert à tous les écrans), comme la colonne de droite de l'interface du jeu.
    local scan = Hc.Button(top, "Scanner l'HV", 130, 32, "solid")
    scan:SetPoint("RIGHT", game, "LEFT", -18, 0)
    scan:SetScript("OnClick", function() if ns.AnoAPI then ns.AnoAPI.StartScan() end; UpdateTop() end)
    game:SetScript("OnClick", function()
        EryAddonDB.hvFenetre = false
        F.ShowGameUI()
    end)

    CreateRail(win)
    local content = CreateFrame("Frame", nil, win)
    content:SetPoint("TOPLEFT", RAIL_W + 2, -(TOP_H + 1))
    content:SetPoint("BOTTOMRIGHT", -1, 1)
    screenFrames.vendre = CreateFrame("Frame", nil, content)
    screenFrames.vendre:SetAllPoints()
    CreateSellScreen(screenFrames.vendre)
    screenFrames.metiers = CreateFrame("Frame", nil, content) -- support : l'écran Métiers y est accroché à l'affichage
    screenFrames.metiers:SetAllPoints()
    screenFrames.opportunites = CreateFrame("Frame", nil, content)
    screenFrames.opportunites:SetAllPoints()
    if F.CreateOpportunitesScreen then F.CreateOpportunitesScreen(screenFrames.opportunites) end
    screenFrames.mesventes = CreateFrame("Frame", nil, content)
    screenFrames.mesventes:SetAllPoints()
    if F.CreateMesVentesScreen then F.CreateMesVentesScreen(screenFrames.mesventes) end
    screenFrames.acheter = CreateFrame("Frame", nil, content)
    screenFrames.acheter:SetAllPoints()
    if F.CreateAcheterScreen then F.CreateAcheterScreen(screenFrames.acheter) end
    screenFrames.encheres = CreateFrame("Frame", nil, content)
    screenFrames.encheres:SetAllPoints()
    if F.CreateEncheresScreen then F.CreateEncheresScreen(screenFrames.encheres) end

    win:SetScript("OnHide", function()
        GameTooltip:Hide()
        if switchingToGame then return end
        -- Fermée (croix, Échap) : l'HV se ferme aussi, sinon la fenêtre du jeu resterait invisible.
        RestoreGameUI()
        if AuctionHouseFrame and AuctionHouseFrame:IsShown() and C_AuctionHouse.CloseAuctionHouse then
            C_AuctionHouse.CloseAuctionHouse()
        end
    end)
    win:Hide()
end

function F.Open()
    if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then return end
    Create()
    Fit()
    ShrinkGameUI()
    win:Show()
    EryAddonDB.hvFenetre = true
    UpdateTop()
    F.ShowScreen(EryAddonDB.hvEcran or currentScreen)
end

-- Affiche un écran de la nouvelle fenêtre (Vendre, Métiers) ; garde le choix pour la prochaine visite.
function F.ShowScreen(key)
    if not SCREENS[key] or not screenFrames[key] then key = "vendre" end
    currentScreen = key
    EryAddonDB.hvEcran = key
    for k, f in pairs(screenFrames) do f:SetShown(k == key) end
    MarkRail()
    if key == "vendre" then
        F.RefreshBags()
        F.UpdateSell()
        if sel then F.Search() end
    elseif key == "metiers" and F.RefreshMetiers then
        F.AttachMetiers(screenFrames.metiers)
        if H().FixBorders then H().FixBorders(win) end
        F.RefreshMetiers()
    elseif key == "encheres" and F.RefreshEncheres then
        F.RefreshEncheres()
    elseif key == "opportunites" and F.RefreshOpportunites then
        F.RefreshOpportunites()
    elseif key == "mesventes" and F.RefreshMesVentes then
        F.RefreshMesVentes()
    elseif key == "acheter" and F.RefreshAcheter then
        F.RefreshAcheter()
    end
end

-- Bouton pour ouvrir la nouvelle fenêtre, au-dessus de la colonne d'EryAddon à droite de l'HV.
local openButton
local function CreateOpenButton()
    if openButton or not AuctionHouseFrame then return end
    openButton = H().Button(AuctionHouseFrame, "Nouvelle fenêtre", 116, 24, "solid")
    openButton:SetPoint("BOTTOMLEFT", AuctionHouseFrame, "TOPRIGHT", 0, -26)
    openButton:SetScript("OnClick", F.Open)
end

---------------------------------------------------------------------------
-- Événements
---------------------------------------------------------------------------
local ev = CreateFrame("Frame")
for _, e in ipairs({ "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "COMMODITY_SEARCH_RESULTS_UPDATED",
    "ITEM_SEARCH_RESULTS_UPDATED", "BAG_UPDATE_DELAYED", "AUCTION_HOUSE_AUCTION_CREATED", "PLAYER_MONEY",
    "UI_ERROR_MESSAGE", "OWNED_AUCTIONS_UPDATED", "AUCTION_CANCELED", "MAIL_INBOX_UPDATE",
    "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", "AUCTION_HOUSE_BROWSE_RESULTS_ADDED",
    "COMMODITY_PURCHASE_SUCCEEDED", "COMMODITY_PURCHASE_FAILED", "GET_ITEM_INFO_RECEIVED" }) do
    pcall(ev.RegisterEvent, ev, e)
end
local OnEvent
OnEvent = function(_, event, ...)
    if event == "GET_ITEM_INFO_RECEIVED" then
        if F.AcItemInfo then F.AcItemInfo((...)) end
        return
    end
    if event == "AUCTION_HOUSE_SHOW" then
        C_Timer.After(0, function()
            CreateOpenButton()
            if EryAddonDB and EryAddonDB.hvFenetre then F.Open() end
        end)
    elseif event == "AUCTION_HOUSE_CLOSED" then
        switchingToGame = true
        if win then win:Hide() end
        switchingToGame = false
        RestoreGameUI()
        V.pending = nil
    elseif event == "BAG_UPDATE_DELAYED" and not (win and win:IsShown()) then
        if metiersFrame and metiersFrame:IsVisible() then F.RefreshMetiers(true) end
    elseif event == "MAIL_INBOX_UPDATE" then
        OnMail() -- (boîte aux lettres : HV fermé, la fenêtre n'a pas besoin d'être ouverte)
        if F.RefreshMesVentes then C_Timer.After(0.5, F.RefreshMesVentes) end
    elseif not (win and win:IsShown()) then
        return
    elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
        OnResults(true, ...)
        OnCheckResults(true, ...)
        if F.AcOnResults then F.AcOnResults(true, ...) end
    elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
        OnResults(false, ...)
        OnCheckResults(false, ...)
        if F.AcOnResults then F.AcOnResults(false, ...) end
    elseif event == "OWNED_AUCTIONS_UPDATED" then
        ReadOwned()
        DrawEncheres()
        -- 1re lecture : on vérifie tout de suite qui passe dessous.
        if currentScreen == "encheres" and not next(enChecks) and not enCurrent then StartChecks() end
    elseif event == "AUCTION_CANCELED" then
        OnCanceled()
    elseif event == "BAG_UPDATE_DELAYED" then
        if currentScreen == "metiers" then F.RefreshMetiers(true) else F.RefreshBags() end
        if metiersFrame and metiersFrame:IsVisible() and currentScreen ~= "metiers" then F.RefreshMetiers(true) end
    elseif event == "AUCTION_HOUSE_AUCTION_CREATED" then
        V.pending = nil
        Msg("mis en vente.")
        C_Timer.After(1, function() if sel then price = 0; F.Search() end end)
        UpdateTop()
    elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" or event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
        if F.AcOnBrowse then F.AcOnBrowse() end
    elseif event == "COMMODITY_PURCHASE_SUCCEEDED" or event == "COMMODITY_PURCHASE_FAILED" then
        if F.AcOnPurchase then F.AcOnPurchase(event == "COMMODITY_PURCHASE_SUCCEEDED") end
    elseif event == "PLAYER_MONEY" then
        UpdateTop()
        if F.AcOnMoney then F.AcOnMoney() end
    elseif event == "UI_ERROR_MESSAGE" then
        local _, text = ...
        if type(text) == "string" and GetTime() - lastPostTime < 5 then
            V.error = { text = text, t = time() }
            V.pending = nil
            F.UpdateSell()
        end
    end
end
ev:SetScript("OnEvent", OnEvent)
F._OnEvent = OnEvent -- pour le test hors jeu
