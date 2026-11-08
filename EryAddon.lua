-- EryAddon : petites fonctions pour Ery Table (WoW Forever, client frFR)
-- /eryaddon       : ouvre/ferme le panneau des fonctions
-- Le détail des calculs est noté tout seul dans EryAddonDB.releve (voir « Relevé automatique »).

local ADDON_NAME, ns = ... -- ns : table partagée avec les autres fichiers de l'add-on

-- Sur Forever, certaines valeurs sont "secrètes" en combat : on ne doit pas les utiliser.
local issecret = issecretvalue or function() return false end

local function AnySecret(...)
    for i = 1, select("#", ...) do
        if issecret((select(i, ...))) then return true end
    end
    return false
end

local function Msg(text)
    print("|cff66ccffEryAddon|r : " .. text)
end

-- Liste des fonctions (features) de l'add-on, dans l'ordre du panneau.
local features = {}

-- Valeurs par défaut des réglages sauvegardés.
local DEFAULTS = {
    efficacite = true,
    procBarrage = true,
    deflagration = true,
}

-- Partagé avec EryAddon_HV.lua (hôtel des ventes).
ns.features = features
ns.DEFAULTS = DEFAULTS
ns.Msg = Msg
ns.issecret = issecret

-- Chiffres de TSM (TradeSkillMaster + son application, 08/11 : Forever pris en charge, vérifié avec
-- Jérémie) : « DBMinBuyout » (prix le plus bas, cliché de l'HV toutes les heures), « DBMarket » (prix du
-- marché lissé), « DBRegionSaleAvg » (prix de vente moyen réel), « DBRegionSoldPerDay » (ventes par jour
-- et par HV), « DBRegionSaleRate » (part des annonces vendues, 0 à 1), « DBNumAuctions ». Prix en cuivre.
-- nil si TSM n'est pas chargé ou n'a rien pour cet objet. Gardé 60 s (appelé très souvent par Métiers).
local tsmCache, tsmCacheTime = {}, 0
local TSM_SCALED = { DBRegionSaleRate = 1000, DBRegionSoldPerDay = 1000 }

-- PRIX HV d'un objet (cuivre), le même partout (sacs, Métiers, récompense de quête, écran Vendre), SANS
-- Auctionator (règle de Jérémie, 08/11 : aucune dépendance à Auctionator, qui finira par être retiré ; TSM,
-- lui, reste) : notre scan s'il a moins d'1 h ; sinon le prix le plus bas de TSM (cliché horaire de tout l'HV) ;
-- sinon le DERNIER PRIX VU par nos scans (EryAddonDB.hvVu, comme la base de prix d'Auctionator), sinon notre
-- dernier scan. nil si rien. PAS le « prix du marché » de TSM pour un objet absent de l'HV : comparé aux prix
-- d'Auctionator sur 4 360 objets (08/11), c'était la cause des plus gros écarts (1 po → 80 po).
function ns.PrixHV(itemID)
    if not itemID then return nil end
    local scan = EryAddonDB and EryAddonDB.hvPrix
    local p = scan and scan.prix
    local mine = p and p[itemID]
    if mine and scan.t and time() - scan.t < 3600 then return mine end
    local tsm = ns.TSM and ns.TSM("DBMinBuyout", itemID)
    if tsm and tsm > 0 then return tsm end
    local seen = EryAddonDB and EryAddonDB.hvVu and EryAddonDB.hvVu[itemID]
    if type(seen) == "table" and seen.p then return seen.p end
    return mine
end
function ns.TSM(source, itemID)
    if not itemID or type(TSM_API) ~= "table" or not TSM_API.GetCustomPriceValue then return nil end
    local now = GetTime()
    if now - tsmCacheTime > 60 then tsmCache, tsmCacheTime = {}, now end
    local key = source .. ":" .. itemID
    local v = tsmCache[key]
    if v == nil then
        -- TSM ARRONDIT à l'entier tout ce que renvoie son API (vu dans son code, Object.lua : floor(x + 0.5)) :
        -- une part d'annonces vendues de 0,63 devenait « 1 » (100 %), 0,4 vente par jour devenait 0. Pour ces
        -- deux chiffres, on demande la valeur x 1000 et on divise.
        local scale = TSM_SCALED[source]
        local ok, r = pcall(TSM_API.GetCustomPriceValue, scale and (source .. "*" .. scale) or source, "i:" .. itemID)
        v = (ok and type(r) == "number") and (scale and r / scale or r) or false
        tsmCache[key] = v
    end
    return v or nil
end

-- Maj+clic sur un objet (ou une recette) dans une fenêtre d'EryAddon = son lien dans le chat, comme
-- dans les fenêtres du jeu (demande de Jérémie). Renvoie vrai si Maj était enfoncée : le clic ne doit
-- alors rien faire d'autre (surtout pas acheter). Fonctions vues dans WhatsTraining / Auctionator.
function ns.ShiftLink(itemID, spellID)
    local shift = (IsModifiedClick and IsModifiedClick("CHATLINK")) or (IsShiftKeyDown and IsShiftKeyDown())
    if not shift then return false end
    local link
    if itemID then
        local info = (C_Item and C_Item.GetItemInfo) or GetItemInfo
        link = info and select(2, info(itemID))
        if not link and C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(itemID) end
    end
    if not link and spellID then
        link = (C_Spell and C_Spell.GetSpellLink and C_Spell.GetSpellLink(spellID))
            or (GetSpellLink and GetSpellLink(spellID))
    end
    if not link then Msg("objet pas encore chargé : refais Maj+clic.") return true end
    -- Chat déjà ouvert : le lien s'ajoute au texte tapé ; sinon on ouvre le chat avec le lien
    -- (même méthode que WhatsTraining).
    local window = ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
    if window then
        window:Insert(link)
    else
        local open = (ChatFrameUtil and ChatFrameUtil.OpenChat) or ChatFrame_OpenChat
        if open then open(link) end
    end
    return true
end

---------------------------------------------------------------------------
-- Fonction 1 : efficacité (dégâts par point de mana) sur les icônes
---------------------------------------------------------------------------
local Eff = {
    key = "efficacite",
    label = "Efficacité dégâts / mana sur les icônes de sorts",
}
table.insert(features, Eff)

-- Noms des boutons des barres d'action Blizzard (1 à 12 chacun).
local BUTTON_PREFIXES = {
    "ActionButton",
    "MultiBarBottomLeftButton",
    "MultiBarBottomRightButton",
    "MultiBarRightButton",
    "MultiBarLeftButton",
    "MultiBar5Button",
    "MultiBar6Button",
    "MultiBar7Button",
}

local cache = {}   -- [spellID] = efficacité (nombre) ou false (pas de dégâts / pas de mana)
local labels = {}  -- [bouton] = texte affiché sur l'icône

local function GetSpellNameSafe(spellID)
    if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(spellID) end
    if GetSpellInfo then return (GetSpellInfo(spellID)) end
end

-- Description du sort (texte français). nil si pas encore chargée ou secrète.
local function GetDescription(spellID)
    local desc
    if C_Spell and C_Spell.GetSpellDescription then
        desc = C_Spell.GetSpellDescription(spellID)
    elseif GetSpellDescription then
        desc = GetSpellDescription(spellID)
    end
    if desc == nil or issecret(desc) or desc == "" then return nil end
    return desc
end

-- Coût en mana du sort, via l'API (pas de lecture de texte).
local function GetManaCost(spellID)
    local getCost = (C_Spell and C_Spell.GetSpellPowerCost) or GetSpellPowerCost
    if not getCost then return nil end
    local ok, costs = pcall(getCost, spellID)
    if not ok or issecret(costs) or type(costs) ~= "table" then return nil end
    for _, entry in ipairs(costs) do
        if AnySecret(entry.type, entry.name, entry.cost) then return nil end
        -- Mana = type 0
        if (entry.type == 0 or entry.name == "MANA") and entry.cost and entry.cost > 0 then
            return entry.cost
        end
    end
    return nil
end

-- Lit les dégâts dans la description FRANÇAISE du sort.
-- Exemples gérés :
--   "inflige 14 à 22 points de dégâts de Feu"      -> moyenne 18
--   "et 2 points de dégâts de Feu supplémentaires" -> + 2
--   Projectiles des arcanes : "3 vagues ... chacune infligeant 24 points de dégâts" -> 3 x 24
local function ParseDamage(desc)
    -- Enlève les espaces de milliers (normal, insécable, insécable fin) : "1 234" -> "1234"
    desc = desc:gsub("(%d)\194\160(%d)", "%1%2")
    desc = desc:gsub("(%d)\226\128\175(%d)", "%1%2")
    desc = desc:gsub("(%d) (%d)", "%1%2")
    -- Les autres espaces insécables deviennent des espaces normaux.
    -- (Ex. Éclair de givre : « 61[insécable]points de dégâts », invisible à l'écran.)
    desc = desc:gsub("\194\160", " ")
    desc = desc:gsub("\226\128\175", " ")

    -- Uniformise les écritures possibles :
    --   "18-20" ou "18 - 20" -> "18 à 20" ; "points de dégâts" -> "dégâts"
    desc = desc:gsub("(%d+) ?%- ?(%d+)", "%1 à %2")
    desc = desc:gsub("points? de dégâts", "dégâts")

    local total, found = 0, false

    -- Fourchettes "X à Y dégâts"
    for low, high in desc:gmatch("(%d+) à (%d+) dégâts") do
        total = total + (tonumber(low) + tonumber(high)) / 2
        found = true
    end

    -- Valeurs simples "X dégâts" (on retire d'abord les fourchettes déjà comptées)
    local rest = desc:gsub("%d+ à %d+ dégâts", "")
    for value in rest:gmatch("(%d+) dégâts") do
        total = total + tonumber(value)
        found = true
    end

    if not found then return nil end

    -- Dégâts répétés : on multiplie par le nombre de coups.
    local mult = 1
    -- "3 vagues ... chacune infligeant 24 dégâts"
    if desc:find("chacun") or desc:find("chaque") then
        local count = desc:match("(%d+) vagues") or desc:match("(%d+) projectiles") or desc:match("(%d+) fois")
        if count then mult = tonumber(count) end
    end
    -- "24 dégâts toutes les 1 sec pendant 3 sec" -> 3 coups
    if mult == 1 then
        -- " s" couvre « sec. » et « s »
        local every = desc:match("toutes les ([%d,]+) s")
        -- Projectiles des arcanes : « toutes les secondes pendant 3 sec. »
        if not every and (desc:find("toutes les secondes") or desc:find("chaque seconde")) then
            every = "1"
        end
        local during = desc:match("pendant ([%d,]+) s")
        every = every and tonumber((every:gsub(",", ".")))
        during = during and tonumber((during:gsub(",", ".")))
        if every and during and every > 0 then
            mult = math.floor(during / every + 0.5)
        end
    end

    return total * mult
end

-- Calcule (et garde en mémoire) l'efficacité d'un sort.
-- Retourne un nombre, false (rien à afficher), ou nil (pas calculable maintenant).
local function Compute(spellID)
    if cache[spellID] ~= nil then return cache[spellID] end
    if InCombatLockdown() then return nil end -- valeurs masquées en combat

    local desc = GetDescription(spellID)
    if not desc then return nil end -- texte pas encore chargé : on réessaiera

    local cost = GetManaCost(spellID)
    local damage = ParseDamage(desc)
    local value = false
    if cost and damage then
        value = math.floor(damage / cost * 10 + 0.5) / 10 -- arrondi à 0,1 près
    end
    cache[spellID] = value
    return value
end

-- Sort contenu dans un emplacement de barre d'action (ou dans une macro).
local function SpellFromSlot(slot)
    if not slot or slot == 0 or not HasAction(slot) then return nil end
    local ok, spellID = pcall(function()
        local actionType, id, subType = GetActionInfo(slot)
        if AnySecret(actionType, id, subType) then return nil end
        if actionType == "spell" then return id end
        if actionType == "macro" then
            if subType == "spell" then return id end
            if GetMacroSpell and id then
                local first, _, third = GetMacroSpell(id)
                if AnySecret(first, third) then return nil end
                return (type(first) == "number" and first) or (type(third) == "number" and third) or nil
            end
        end
        return nil
    end)
    if ok then return spellID end
end

-- Nombre à une décimale, avec une virgule à la française : 0.6 -> "0,6"
local function FormatValue(value)
    return (string.format("%.1f", value):gsub("%.", ","))
end

local function GetLabel(button)
    local fs = labels[button]
    if not fs then
        fs = button:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
        fs:SetDrawLayer("OVERLAY", 7)
        fs:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 2, 2)
        fs:SetTextColor(0.6, 1, 0.6) -- vert clair
        labels[button] = fs
    end
    return fs
end

function Eff.Refresh()
    if not Eff.enabled then return end
    for _, prefix in ipairs(BUTTON_PREFIXES) do
        for i = 1, 12 do
            local button = _G[prefix .. i]
            if button then
                local spellID = SpellFromSlot(button.action)
                local value = spellID and Compute(spellID)
                if value then
                    GetLabel(button):SetText(FormatValue(value))
                elseif labels[button] then
                    labels[button]:SetText("")
                end
            end
        end
    end
end

---------------------------------------------------------------------------
-- Relevé automatique et silencieux, pour la mise au point :
-- le détail du calcul et le texte de chaque sort (grimoire + barres) sont notés
-- dans EryAddonDB.releve. Le jeu l'écrit sur le disque au /reload ou à la
-- déconnexion, et Claude peut alors le lire. Rien n'est affiché en jeu.
---------------------------------------------------------------------------

-- Sorts actifs du grimoire. Deux versions de l'API selon le client.
local function SpellbookSpellIDs()
    local ids = {}
    if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines then
        local bank = (Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player) or 0
        local spellType = Enum and Enum.SpellBookItemType and Enum.SpellBookItemType.Spell
        for line = 1, C_SpellBook.GetNumSpellBookSkillLines() do
            local info = C_SpellBook.GetSpellBookSkillLineInfo(line)
            if info and info.itemIndexOffset and info.numSpellBookItems then
                for i = info.itemIndexOffset + 1, info.itemIndexOffset + info.numSpellBookItems do
                    local item = C_SpellBook.GetSpellBookItemInfo(i, bank)
                    if item and not AnySecret(item.spellID) and item.spellID and not item.isPassive
                        and (not spellType or item.itemType == spellType) then
                        table.insert(ids, item.spellID)
                    end
                end
            end
        end
    elseif GetNumSpellTabs then
        for tab = 1, GetNumSpellTabs() do
            local _, _, offset, numSpells = GetSpellTabInfo(tab)
            for i = offset + 1, offset + numSpells do
                local kind, id = GetSpellBookItemInfo(i, BOOKTYPE_SPELL or "spell")
                if kind == "SPELL" and id then table.insert(ids, id) end
            end
        end
    end
    return ids
end

local function Releve()
    if not Eff.enabled or InCombatLockdown() then return end
    local seen, list = {}, {}
    local function add(spellID)
        if not spellID or seen[spellID] then return end
        seen[spellID] = true
        local desc = GetDescription(spellID)
        local value = Compute(spellID)
        table.insert(list, {
            nom = GetSpellNameSafe(spellID) or "?",
            id = spellID,
            mana = GetManaCost(spellID),
            degats = desc and ParseDamage(desc),
            efficacite = value and FormatValue(value) or nil,
            texte = desc or "(pas encore chargé)",
        })
    end

    local ok, ids = pcall(SpellbookSpellIDs)
    if ok then
        for _, id in ipairs(ids) do add(id) end
    end
    for _, prefix in ipairs(BUTTON_PREFIXES) do
        for i = 1, 12 do
            local button = _G[prefix .. i]
            if button then add(SpellFromSlot(button.action)) end
        end
    end
    table.sort(list, function(a, b) return tostring(a.nom) < tostring(b.nom) end)

    EryAddonDB.releve = {
        date = date("%d/%m/%Y %H:%M"),
        grimoire = ok and "lu" or ("erreur : " .. tostring(ids)),
        sorts = list,
    }
end

-- Regroupe plusieurs demandes de mise à jour en une seule.
local refreshPending, relevePending = false, false
local function RequestRefresh()
    if not Eff.enabled then return end
    if not refreshPending then
        refreshPending = true
        C_Timer.After(0.2, function()
            refreshPending = false
            Eff.Refresh()
        end)
    end
    -- Le relevé attend 5 s : le temps que les textes des sorts se chargent.
    if not relevePending then
        relevePending = true
        C_Timer.After(5, function()
            relevePending = false
            -- Protégé : une erreur dans le relevé ne doit jamais gêner le jeu.
            local ok, err = pcall(Releve)
            if not ok then EryAddonDB.releve = { erreur = tostring(err) } end
        end)
    end
end

local effFrame = CreateFrame("Frame")
effFrame:SetScript("OnEvent", function(_, event)
    if event == "SPELLS_CHANGED" or event == "PLAYER_LEVEL_UP" then
        wipe(cache) -- nouveaux rangs de sorts : on recalcule tout
    end
    RequestRefresh()
end)

local EFF_EVENTS = {
    "ACTIONBAR_SLOT_CHANGED",
    "ACTIONBAR_PAGE_CHANGED",
    "UPDATE_BONUS_ACTIONBAR",
    "SPELLS_CHANGED",
    "PLAYER_LEVEL_UP",
    "PLAYER_REGEN_ENABLED", -- fin de combat
    "SPELL_TEXT_UPDATE",    -- description d'un sort chargée
}

function Eff.Enable()
    Eff.enabled = true
    for _, ev in ipairs(EFF_EVENTS) do
        pcall(effFrame.RegisterEvent, effFrame, ev) -- ignore un événement absent sur Forever
    end
    Eff.Refresh()
    C_Timer.After(3, Eff.Refresh) -- second passage, le temps que les textes se chargent
    RequestRefresh()              -- et lance le relevé automatique
end

function Eff.Disable()
    Eff.enabled = false
    effFrame:UnregisterAllEvents()
    for _, fs in pairs(labels) do fs:SetText("") end
end

---------------------------------------------------------------------------
-- Fonction 2 : alerte sonore de proc - Barrage de projectiles
---------------------------------------------------------------------------
-- Sur Forever, le buff du proc est masqué en combat. On regarde donc deux
-- signes visibles, comme l'add-on MageTricks :
--   1. le jeu fait briller Projectiles des arcanes (« surbrillance » de proc) ;
--   2. Projectiles des arcanes ne coûte plus de mana, alors que Boule de feu
--      ou Éclair de givre coûtent toujours (sinon c'est Idées claires, pas le proc).
local Barrage = {
    key = "procBarrage",
    label = "Alerte sonore : Barrage de projectiles",
}
table.insert(features, Barrage)

local TING = "Interface\\AddOns\\EryAddon\\ting.ogg"

-- Rangs connus des sorts utilisés (du plus faible au plus fort).
local MISSILE_RANKS = { 5143, 5144, 5145, 8416, 8417, 10211, 10212, 25345 }
local REFERENCE_RANKS = {
    { 133, 143, 145, 3140, 8400, 8401, 8402, 10148, 10149, 10150, 10151, 25306 }, -- Boule de feu
    { 116, 205, 837, 7322, 8406, 8407, 8408, 10179, 10180, 10181, 25304 },        -- Éclair de givre
}

local function Known(spellID)
    local check = IsPlayerSpell or IsSpellKnown
    if not check then return false end
    local ok, known = pcall(check, spellID)
    return ok and not issecret(known) and known == true
end

local function HighestKnown(ranks)
    for i = #ranks, 1, -1 do
        if Known(ranks[i]) then return ranks[i] end
    end
    -- Secours : on demande au jeu le sort par son nom (il renvoie le rang appris).
    local name = GetSpellNameSafe(ranks[1])
    if name and C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, name)
        if ok and type(info) == "table" and not issecret(info.spellID) then
            return info.spellID
        end
    end
end

-- La surbrillance de Projectiles des arcanes : vrai, faux, ou nil (illisible).
local function MissilesGlowing(missile)
    local ask = (C_SpellActivationOverlay and C_SpellActivationOverlay.IsSpellOverlayed) or IsSpellOverlayed
    if not ask or not missile then return nil end
    local ok, glow = pcall(ask, missile)
    if not ok or issecret(glow) or type(glow) ~= "boolean" then return nil end
    return glow
end

-- Coût en mana lisible ? (0 = gratuit, nil = illisible ou pas de coût)
local function ManaCostOrZero(spellID)
    local getCost = (C_Spell and C_Spell.GetSpellPowerCost) or GetSpellPowerCost
    if not getCost or not spellID then return nil end
    local ok, costs = pcall(getCost, spellID)
    if not ok or issecret(costs) or type(costs) ~= "table" then return nil end
    if (issecrettable and issecrettable(costs)) then return nil end
    local found = false
    for _, entry in ipairs(costs) do
        if AnySecret(entry.type, entry.cost) then return nil end
        if entry.type == 0 then
            found = true
            if (entry.cost or 0) > 0 then return entry.cost end
        end
    end
    if found or #costs == 0 then return 0 end
    return nil
end

-- Numéros des sorts à surveiller, cherchés une seule fois puis gardés en mémoire.
-- On les recherche seulement quand le grimoire change (nouveau rang appris).
local known = { missile = nil, refs = {} }
local function FindSpells()
    known.missile = HighestKnown(MISSILE_RANKS)
    known.refs = {}
    for _, ranks in ipairs(REFERENCE_RANKS) do
        local id = HighestKnown(ranks)
        if id then table.insert(known.refs, id) end
    end
end

local function BarrageActive()
    local missile = known.missile
    if not missile then return false, nil end

    if Barrage.glowEvent or MissilesGlowing(missile) then
        return true, "surbrillance"
    end

    -- Le coût des sorts de référence n'est lu que si Projectiles est gratuit (rare).
    if ManaCostOrZero(missile) == 0 then
        for _, ref in ipairs(known.refs) do
            local refCost = ManaCostOrZero(ref)
            if refCost and refCost > 0 then return true, "mana" end
        end
    end
    return false, nil
end

-- Petit journal des dernières alertes (dans la sauvegarde, pour la mise au point).
local function Journal(signal)
    EryAddonDB.journalProcs = EryAddonDB.journalProcs or {}
    local log = EryAddonDB.journalProcs
    table.insert(log, date("%d/%m %H:%M:%S") .. " : proc détecté (" .. signal .. ")"
        .. (InCombatLockdown() and ", en combat" or ", hors combat"))
    while #log > 20 do table.remove(log, 1) end
end

local function PlayTing()
    PlaySoundFile(TING, "Master")
end

local wasActive, lastTing = false, 0
local function CheckBarrage()
    if not Barrage.enabled then return end
    local ok, active, signal = pcall(BarrageActive)
    if not ok then return end
    if active and not wasActive and GetTime() - lastTing > 1 then
        lastTing = GetTime()
        PlayTing()
        Journal(signal)
    end
    wasActive = active
end

-- Le jeu envoie souvent plusieurs signaux en même temps (effet + coût + surbrillance) :
-- on n'en fait qu'une seule vérification, juste après.
local checkPending = false
local function RequestCheck()
    if checkPending then return end
    checkPending = true
    C_Timer.After(0, function()
        checkPending = false
        CheckBarrage()
    end)
end

local barrageFrame = CreateFrame("Frame")
barrageFrame:SetScript("OnEvent", function(_, event, spellID)
    if event == "SPELLS_CHANGED" then
        FindSpells()
    elseif spellID and not issecret(spellID)
        and (event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW" or event == "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE") then
        -- (L'identifiant peut être masqué en combat : la vérification lit alors la surbrillance elle-même.)
        for _, id in ipairs(MISSILE_RANKS) do
            if id == spellID then Barrage.glowEvent = (event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW") end
        end
    end
    RequestCheck()
end)

-- Pas de contrôle régulier : on ne regarde qu'au moment où le jeu signale un changement.
local BARRAGE_EVENTS = {
    "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW", -- un bouton se met à briller
    "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE",
    "SPELL_UPDATE_USABLE",                -- coût ou utilisabilité d'un sort modifié
    "SPELLS_CHANGED",                     -- nouveau rang appris : on recherche les numéros
}

function Barrage.Enable(fromPanel)
    Barrage.enabled = true
    wasActive = false
    FindSpells()
    for _, ev in ipairs(BARRAGE_EVENTS) do
        pcall(barrageFrame.RegisterEvent, barrageFrame, ev)
    end
    -- Un effet apparaît ou disparaît sur le personnage (le contenu peut être masqué,
    -- mais l'événement arrive quand même).
    pcall(barrageFrame.RegisterUnitEvent, barrageFrame, "UNIT_AURA", "player")
    if fromPanel then PlayTing() end -- fait entendre le son en cochant la case
end

function Barrage.Disable()
    Barrage.enabled = false
    barrageFrame:UnregisterAllEvents()
end

---------------------------------------------------------------------------
-- Fonction : DÉFLAGRATION DES ARCANES, charges et temps restant au centre de l'écran (demande de
-- Jérémie, 08/11 : l'affichage de Blizzard ne donne ni les charges ni le temps).
-- Le debuff n'est PAS lisible en combat sur Forever : on COMPTE les lancers du sort (méthode de
-- l'add-on MageTricks). Règle du jeu (texte du sort) : « Effet cumulable jusqu'à 4 fois. Dure 18 sec à
-- partir de la première application » : la durée ne se rallonge pas, aucun autre sort ne retire les
-- charges. (MageTricks compte 15 s : 3 s trop tôt.) La durée est relue dans le texte du sort, hors combat.
-- Hors combat, si le debuff est lisible, il sert à se recaler (après un /reload par exemple).
---------------------------------------------------------------------------
local Defla = {
    key = "deflagration",
    label = "Déflagration des arcanes : charges et temps au centre de l'écran",
}
table.insert(features, Defla)

local DEFLA_SPELL = 400574           -- Déflagration des arcanes (sort lancé)
local DEFLA_AURAS = { 36032, 400574 } -- debuff de charges (numéro vu dans MageTricks), et secours
local DEFLA_MAX = 4
local DEFLA_COUNTDOWN = 5 -- la barre rouge monte pendant les 5 s qui précèdent le GO
local DEFLA_BAR_W = 8
local deflaDuration = 18
local defla = { start = nil, count = 0 }
local deflaFrame
local DeflaRefresh

-- Temps d'incantation ACTUEL de Déflagration des arcanes (s), seuil du vert (demande de Jérémie : « le
-- temps de cast, ça dépend de la hâte ») : 1. lu dans le jeu (C_Spell.GetSpellInfo().castTime, en ms,
-- hâte comprise) quand il est lisible ; 2. sinon (masqué en combat ?) la durée MESURÉE du dernier lancer
-- (début → fin, UNIT_SPELLCAST_START / SUCCEEDED) ; 3. sinon la dernière valeur connue.
local deflaCast = 2.5
local deflaCastStart
local function DeflaCastTime()
    if C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, DEFLA_SPELL)
        if ok and type(info) == "table" and not (issecrettable and issecrettable(info))
            and not issecret(info.castTime) and (tonumber(info.castTime) or 0) > 0 then
            deflaCast = info.castTime / 1000
        end
    end
    return deflaCast
end

local function DeflaReadSpell()
    if InCombatLockdown() or not (C_Spell and C_Spell.GetSpellDescription) then return end
    local ok, desc = pcall(C_Spell.GetSpellDescription, DEFLA_SPELL)
    if not ok or type(desc) ~= "string" or issecret(desc) then return end
    local d = desc:gsub("\194\160", " "):match("Dure (%d+) sec")
    if tonumber(d) then deflaDuration = tonumber(d) end
end

local function DeflaCreate()
    if deflaFrame then return end
    local f = CreateFrame("Frame", "EryDeflagration", UIParent)
    f:SetSize(52, 52)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, -140) -- au milieu, un peu sous le personnage
    f:SetFrameStrata("HIGH")
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetAllPoints()
    f.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local tex = C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(DEFLA_SPELL)
    f.icon:SetTexture((not issecret(tex) and tex) or 135735)
    -- Cercle qui se vide pendant les 18 s.
    f.cd = CreateFrame("Cooldown", nil, f, "CooldownFrameTemplate")
    f.cd:SetAllPoints()
    if f.cd.SetHideCountdownNumbers then f.cd:SetHideCountdownNumbers(true) end
    if f.cd.SetDrawEdge then f.cd:SetDrawEdge(false) end
    -- Charges en ÉNORME au centre de l'icône (demande de Jérémie : 2 x la taille du temps essayé avant,
    -- qui était en 20) ; pas de chiffre du temps : le cercle qui se vide suffit.
    -- Le chiffre est posé sur un calque AU-DESSUS du cercle : sinon l'ombre du cercle le recouvre en partie
    -- et assombrit sa couleur (retour de Jérémie : « un truc qui cloche avec les couleurs »).
    local top = CreateFrame("Frame", nil, f)
    top:SetAllPoints()
    top:SetFrameLevel(f.cd:GetFrameLevel() + 2)
    -- (Icône entière en vert au GO : essayée puis RETIRÉE, « ça rend pas bien ». Seule la barre passe au vert.)
    f.count = top:CreateFontString(nil, "OVERLAY")
    f.count:SetFont("Fonts\\ARIALN.TTF", 40, "THICKOUTLINE")
    f.count:SetPoint("CENTER", f, "CENTER", 0, 0)
    -- Compte à rebours jusqu'au GO : barre verticale à droite de l'icône (même hauteur), vide jusqu'à
    -- 5 s avant le GO, puis monte en ROUGE ; pleine au GO, et alors VERTE avec l'icône.
    f.bar = CreateFrame("Frame", nil, f)
    f.bar:SetSize(DEFLA_BAR_W, 52)
    f.bar:SetPoint("LEFT", f, "RIGHT", 4, 0)
    local bg = f.bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.6)
    f.bar.fill = f.bar:CreateTexture(nil, "ARTWORK")
    f.bar.fill:SetPoint("BOTTOMLEFT")
    f.bar.fill:SetPoint("BOTTOMRIGHT")
    f.bar.fill:SetHeight(1)
    f.bar.fill:Hide()
    -- Mise à jour à chaque image (la barre doit monter sans à-coups).
    f:SetScript("OnUpdate", function() DeflaRefresh() end)
    f:Hide()
    deflaFrame = f
end

DeflaRefresh = function()
    if not deflaFrame then return end
    local left = defla.start and (defla.start + deflaDuration - GetTime())
    if not left or left <= 0 or defla.count < 1 then
        defla.start, defla.count = nil, 0
        deflaFrame:Hide()
        return
    end
    deflaFrame.count:SetText(defla.count)
    -- Couleurs des charges = celles d'OmniCC par défaut (demande de Jérémie ; valeurs de mémoire, OmniCC
    -- n'est pas installé) dans l'ordre de gravité : 1 gris (« heures »), 2 blanc (« minutes »),
    -- 3 jaune (« secondes »), 4 ROUGE (« bientôt fini », obligatoire).
    local OMNICC = { { 0.7, 0.7, 0.7 }, { 1, 1, 1 }, { 1, 1, 0.1 }, { 1, 0.1, 0.1 } }
    local c = OMNICC[math.min(DEFLA_MAX, defla.count)]
    deflaFrame.count:SetTextColor(c[1], c[2], c[3])
    -- GO = il reste moins qu'un temps d'incantation de Déflagration (hâte comprise). Sens (Jérémie) : c'est
    -- LE BON MOMENT pour relancer : le sort finira après la fin des charges, donc il les remet à zéro
    -- (1 charge, mana normal) au lieu de s'ajouter à 4 charges qui coûtent cher.
    local cast = DeflaCastTime()
    local go = left < cast
    -- Barre : vide à « GO + 5 s », pleine au GO.
    local frac = go and 1 or math.max(0, math.min(1, 1 - (left - cast) / DEFLA_COUNTDOWN))
    local fill = deflaFrame.bar.fill
    deflaFrame.bar:SetShown(frac > 0) -- barre vide : cachée en entier (fond compris), demande de Jérémie
    if frac > 0 then
        fill:SetHeight(math.max(1, 52 * frac))
        if go then fill:SetColorTexture(0, 1, 0, 1) else fill:SetColorTexture(1, 0.1, 0.1, 1) end
        fill:Show()
    else
        fill:Hide()
    end
    -- (Chiffre du temps RETIRÉ à la demande de Jérémie, 08/11 : le cercle qui se vide suffit.)
    deflaFrame:Show()
end

local function DeflaStart(start, count)
    defla.start, defla.count = start, count
    if deflaFrame then deflaFrame.cd:SetCooldown(start, deflaDuration) end
    DeflaRefresh()
end

-- Un lancer de Déflagration des arcanes : +1 charge (4 au plus) ; le temps part du PREMIER lancer.
local function DeflaOnCast()
    local now = GetTime()
    if not defla.start or now >= defla.start + deflaDuration then
        DeflaStart(now, 1)
    else
        defla.count = math.min(DEFLA_MAX, defla.count + 1)
        DeflaRefresh()
    end
end

-- Hors combat : le debuff lisible recale le compteur (charges et temps exacts).
local function DeflaFromAura()
    if InCombatLockdown() or not (C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID) then return end
    for _, id in ipairs(DEFLA_AURAS) do
        local ok, a = pcall(C_UnitAuras.GetPlayerAuraBySpellID, id)
        if ok and type(a) == "table" and not (issecrettable and issecrettable(a))
            and not AnySecret(a.applications, a.expirationTime, a.duration)
            and (a.expirationTime or 0) > 0 and (a.duration or 0) > 0 then
            deflaDuration = a.duration
            DeflaStart(a.expirationTime - a.duration, math.max(1, math.min(DEFLA_MAX, a.applications or 1)))
            return
        end
    end
end

local deflaEvents = CreateFrame("Frame")
deflaEvents:SetScript("OnEvent", function(_, event, unit, _, spellID)
    if event == "UNIT_SPELLCAST_START" then
        if unit == "player" and not issecret(spellID) and spellID == DEFLA_SPELL then deflaCastStart = GetTime() end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        if unit == "player" and not issecret(spellID) and spellID == DEFLA_SPELL then
            -- Durée réelle de ce lancer (hâte du moment comprise), gardée comme seuil de secours.
            local d = deflaCastStart and (GetTime() - deflaCastStart)
            if d and d > 0.3 and d < 6 then deflaCast = d end
            deflaCastStart = nil
            DeflaOnCast()
        end
    elseif event == "UNIT_AURA" then
        DeflaFromAura()
    elseif event == "PLAYER_DEAD" then
        defla.start, defla.count = nil, 0
        DeflaRefresh()
    elseif event == "SPELLS_CHANGED" or event == "PLAYER_REGEN_ENABLED" then
        DeflaReadSpell()
    end
end)

function Defla.Enable(fromPanel)
    DeflaCreate()
    DeflaReadSpell()
    for _, ev in ipairs({ "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_SUCCEEDED" }) do
        if not pcall(deflaEvents.RegisterUnitEvent, deflaEvents, ev, "player") then
            pcall(deflaEvents.RegisterEvent, deflaEvents, ev)
        end
    end
    pcall(deflaEvents.RegisterUnitEvent, deflaEvents, "UNIT_AURA", "player")
    for _, ev in ipairs({ "PLAYER_DEAD", "SPELLS_CHANGED", "PLAYER_REGEN_ENABLED" }) do
        pcall(deflaEvents.RegisterEvent, deflaEvents, ev)
    end
    DeflaFromAura()
    -- Case cochée dans le panneau : aperçu de 3 s (4 charges) pour voir où l'icône se place.
    if fromPanel then DeflaStart(GetTime() - (deflaDuration - 3), DEFLA_MAX) end
end

function Defla.Disable()
    deflaEvents:UnregisterAllEvents()
    defla.start, defla.count = nil, 0
    if deflaFrame then deflaFrame:Hide() end
end

---------------------------------------------------------------------------
-- Panneau des réglages (/eryaddon)
---------------------------------------------------------------------------
local panel

local function SetFeature(feature, on)
    EryAddonDB[feature.key] = on and true or false
    if on then
        feature.Enable(true) -- true : activée depuis le panneau
        Msg(feature.label .. " : |cff00ff00activée|r")
    else
        feature.Disable()
        Msg(feature.label .. " : |cffff6666désactivée|r")
    end
end

local function CreatePanel()
    -- Habillage « Holo » (EryAddon_Theme.lua).
    local H = ns.Holo
    panel = H.Window("EryAddonPanel", 440, 46 + #features * 28, "EryAddon", "Fonctions")
    panel:SetPoint("CENTER")
    panel:SetFrameStrata("DIALOG")

    for i, feature in ipairs(features) do
        local cb = H.Check(panel, feature.label)
        cb:SetPoint("TOPLEFT", 16, -40 - (i - 1) * 28)
        cb:SetChecked(EryAddonDB[feature.key])
        cb:SetScript("OnClick", function(self)
            SetFeature(feature, self:GetChecked())
        end)
        feature.checkbox = cb
    end

    panel:Hide()
end

---------------------------------------------------------------------------
-- Fonction : CARTE DES LIVRES DE BIBLIOTHÈQUE (Forever, toutes classes).
-- Une icône de livre sur la carte du monde (zone ouverte) pour chaque livre pas encore trouvé ;
-- survol = nom + où exactement. Un livre est « trouvé » dès qu'il passe dans tes sacs (on ne peut
-- pas savoir lesquels tu as déjà rendus avant cette fonction). Icône du PNJ à qui les rendre
-- (Fossoyeuse pour la Horde) quand tu as des livres dans ton sac.
-- Données : guide method.gg (emplacements), tables du jeu (numéros d'objets, noms, cartes).
---------------------------------------------------------------------------
local LIVRES = {
    -- { objet, carte, x, y, nom, où }
    { 203755, 1429, 65.4, 70.1, "Journal de recherche de l'archimage Théocritus", "Table, 3e étage de la tour d'Azora" },
    { 209845, 1436, 45.4, 70.5, "Envoûtements et glamours", "1re maison côté est de Ruisselune" },
    { 208860, 1436, 52.7, 53.8, "Rumi de Gnomeregan : le recueil d'œuvres", "Derrière l'aubergiste de la Colline des Sentinelles" },
    { 208860, 1432, 35.6, 48.9, "Rumi de Gnomeregan : le recueil d'œuvres", "Étage de l'auberge de Thelsamar (même livre)" },
    { 209849, 1431, 16.7, 28.5, "Crimes contre l'anatomie", "Crypte de la Colline-aux-Corbeaux (entrée ouest), banc au bas des escaliers" },
    { 209850, 1432, 77.5, 14.1, "Runes des rois-sorciers", "Grotte des ogres, chemin de gauche (2 ogres)" },
    { 209848, 1437, 33.6, 47.9, "Parchemins de Goaz", "Site de fouilles, niveau bas, au bout du chemin de droite" },
    { 203754, 1455, 75.7, 10.5, "Archimage Antonidas : l'autobiographie intégrale", "Grande table, salle des Explorateurs" },
    { 208185, 1420, 59.4, 52.3, "L'abécédaire métaphysique de l'apothicaire", "Étagère de la boutique d'alchimie de Brill" },
    { 209844, 1421, 63.5, 63.1, "Abrégé de Dalaran vol. 23", "Étagère du grand hall, dans l'enceinte du moulin d'Ambre" },
    { 209847, 1413, 56.3, 8.8, "Manuel des systèmes arcaniques", "Salle de contrôle en haut de la plate-forme pétrolière" },
    { 208800, 1413, 62.7, 36.3, "Baxtan : sur les magies destructrices", "Cabestan : table derrière le maître de vol, bâtiment des ingénieurs" },
    { 209846, 1413, 52.8, 54.7, "Secrets des Rêveurs", "Dernière salle de la caverne des Brumes (entrée en 46.0, 36.5), pas dans les Cavernes des lamentations" },
    { 209843, 1439, 59.6, 22.2, "Almanach de Nar'thalas vol. 74", "Escaliers des ruines, avant le niveau inondé" },
    { 209851, 1442, 74.4, 85.7, "Fureur de la terre", "Tonneau dans la tente à l'est du camp, près du grand totem" },
    { 207972, 1454, 38.6, 78.4, "Les leçons de Ta'zo", "Grande tablette au pavillon Darkbriar" },
    { 213165, 1434, 41.3, 50.9, "Les basilics : faut-il avoir peur de se faire pétrifier ?", "Grande table devant la grotte des basilics (chemin depuis 37.1, 48.8)" },
    { 215683, 1441, 34.4, 40.0, "Géomancie : une montagne de puissance", "Hutte principale au sommet du tertre Totem-sinistre, côté gauche (chemin depuis 31.9, 38.5)" },
    { 215815, 1416, 48.4, 57.5, "Les bases de la magie défensive", "Tour des ogres au carrefour (gardée par un ogre niveau 40)" },
    { 215822, 1445, 57.1, 20.8, "RwlRwlRwlRwl !", "Fourneau au milieu du camp des murlocs" },
    { 215816, 1417, 73.6, 65.2, "Un tissage de mensonges : mythes et légendes démystifiés", "Hutte côté est du village de Witherbark" },
    { 215817, 1443, 55.1, 26.2, "Les démons et vous", "Grand bâtiment, cercle intérieur de la forteresse de Thunder Axe" },
    { 215820, 1418, 56.7, 39.7, "Les Momies : le guide des morts-vivants répugnants", "Crypte, à côté de deux corps" },
    { 228141, 1422, 69.2, 72.3, "La nécromancie pour les nuls", "Scholomance (donjon) : table à l'étage" },
    { 228132, 1422, 38.3, 54.6, "Pommes de terre mortes-vivantes", "1er étage de la maison près de la grange" },
    { 228135, 1423, 71.8, 48.2, "Étude de la Lumière", "Dans la chapelle de l'Espoir de la Lumière" },
    { 228138, 1423, 47.3, 42.3, "La Dame et le Chevalier", "Maison incendiée au bord du lac" },
    { 228140, 1423, 26.6, 14.5, "Le Fléau : menace morte-vivante ou phénomène incompris ?", "Côté zone du pont, devant le donjon" },
    { 220345, 1435, 70.2, 51.9, "Sorcellerie sanguine", "Temple d'Atal'Hakkar : niveau du haut, côté arrière" },
    { 220350, 1425, 35.8, 72.5, "Voyages venimeux", "Dans le mur en demi-cercle, 1re pyramide à gauche" },
    { 228134, 1448, 65.1, 3.2, "Le guide complet du nord de Kalimdor", "Grotte de Timbermaw Hold, à gauche du pont" },
    { 228136, 1452, 60.4, 37.4, "Badaboum !", "À Long-Guet (Everlook)" },
    { 220349, 1428, 31.1, 30.1, "Plan de Formepierre", "Mont Rochenoire : tombe près de la pierre d'invocation (Franclorn Forgewright)" },
    { 228133, 1428, 31.6, 30.6, "Magma ou lave ?", "Profondeurs de Rochenoire : après Lothos Riftwaker (entrée du mont Rochenoire)" },
    { 220352, 1427, 38.1, 49.8, "Un esprit métallique", "Dans une tente, à côté d'un nain Sombrefer" },
    { 220348, 1447, 20.4, 62.3, "Étiquette quotidienne", "Au nord du point de vol, avant les ruines" },
    { 220346, 1446, 72.6, 47.5, "Légendes des Eaugures", "Étagère du bâtiment du milieu, crique du Gréement perdu" },
}
-- À qui rendre les livres : Horde = Owen Thadd (Fossoyeuse), Alliance = Garion Wendell (Hurlevent).
local RENDRE = {
    Horde = { 1458, 74.0, 32.5, "Owen Thadd", "Quartier de la magie : rends-lui tes livres de bibliothèque" },
    Alliance = { 1453, 49.0, 86.3, "Garion Wendell", "Tour des mages : rends-lui tes livres de bibliothèque" },
}

-- Livre RENDU = quête de remise faite (numéros de la base de ForeverSecrets ; 22 livres sur 36,
-- les autres : « trouvé » dès qu'il passe dans les sacs).
local LIVRE_QUETE = { [203754] = 79091, [203755] = 79092, [207972] = 79094, [208185] = 79095, [208800] = 79097,
    [208860] = 79093, [209843] = 78124, [209844] = 78127, [209845] = 78142, [209846] = 78143, [209847] = 78145,
    [209848] = 78146, [209849] = 78147, [209850] = 78148, [209851] = 78149, [213165] = 79535, [215683] = 79947,
    [215815] = 79948, [215816] = 79949, [215817] = 79950, [215820] = 79951, [215822] = 79952 }

local Livres = { key = "livres", label = "Carte : livres de bibliothèque" }
table.insert(features, Livres)
DEFAULTS.livres = true

local livrePins, livreFrame = {}, CreateFrame("Frame")
local LIVRE_TAILLE = 10 -- taille des icônes de livres sur la carte (unités du canevas, comme ForeverSecrets : 36)

-- L'add-on ForeverSecrets (installé) affiche déjà les livres, en plus complet (il sait lesquels sont
-- RENDUS grâce aux quêtes, mini-carte, liste). Quand il est là : nos icônes ne s'affichent pas, et on
-- se contente de RÉDUIRE les siennes (36 → LIVRE_TAILLE), sans toucher à ses fichiers (Jérémie : « divise
-- par 3 ou 4 »). Ses icônes sont des boutons du canevas de la carte qui portent un champ « book ».
-- v0.41 (Jérémie : sur la mini-carte, son livre « se colle » à la position du joueur et la carte n'est
-- pas précise) : si tu DÉCOCHES « Show book markers on the world map » dans ForeverSecrets, EryAddon
-- affiche les siens, sur la carte ET la mini-carte (position exacte). Coché : on réduit les siens.
local function ForeverSecretsLoaded()
    local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
    if not (isLoaded and isLoaded("ForeverSecrets")) then return false end
    local db = _G.ForeverSecretsDB
    local g = type(db) == "table" and type(db.books) == "table" and db.books.global
    return not (type(g) == "table" and g.showMapPins == false)
end

local function LivresVus()
    EryAddonDB.livresVus = EryAddonDB.livresVus or {}
    return EryAddonDB.livresVus
end

local function LivreFini(item)
    if LivresVus()[item] then return true end
    local q = LIVRE_QUETE[item]
    if q and C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted then
        local ok, done = pcall(C_QuestLog.IsQuestFlaggedCompleted, q)
        if ok and done then return true end
    end
    return false
end

local function NbDansSac()
    local count = (C_Item and C_Item.GetItemCount) or GetItemCount
    local n, seen = 0, {}
    for _, b in ipairs(LIVRES) do
        if not seen[b[1]] then
            seen[b[1]] = true
            if count and count(b[1]) > 0 then n = n + 1 end
        end
    end
    return n
end

-- Livres passés dans les sacs : « trouvés » (leur icône disparaît de la carte).
local function NoterSacs()
    local count = (C_Item and C_Item.GetItemCount) or GetItemCount
    if not count then return end
    local vus = LivresVus()
    for _, b in ipairs(LIVRES) do
        if not vus[b[1]] and count(b[1]) > 0 then vus[b[1]] = date("%d/%m/%Y") end
    end
end

local function Canvas()
    return WorldMapFrame and WorldMapFrame.ScrollContainer and WorldMapFrame.ScrollContainer.Child
end

local function Pin(i)
    if livrePins[i] then return livrePins[i] end
    local child = Canvas()
    local p = CreateFrame("Button", nil, child)
    p:SetSize(18, 18)
    p:SetFrameStrata("HIGH") -- comme ForeverSecrets : au-dessus des calques de la carte
    p:SetFrameLevel(child:GetFrameLevel() + 500)
    p.tex = p:CreateTexture(nil, "OVERLAY")
    p.tex:SetAllPoints()
    p:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(self.title, 1, 0.82, 0)
        GameTooltip:AddLine(self.where, 1, 1, 1, true)
        GameTooltip:AddLine(string.format("%.1f, %.1f", self.x, self.y), 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    p:SetScript("OnLeave", function() GameTooltip:Hide() end)
    livrePins[i] = p
    return p
end

local function Place(i, mapX, mapY, icon, title, where)
    local child = Canvas()
    local p = Pin(i)
    local w, h = child:GetWidth(), child:GetHeight()
    p:SetSize(LIVRE_TAILLE, LIVRE_TAILLE)
    p.tex:SetTexture(icon)
    p.title, p.where, p.x, p.y = title, where, mapX, mapY
    p:ClearAllPoints()
    p:SetPoint("CENTER", child, "TOPLEFT", w * mapX / 100, -h * mapY / 100)
    p:Show()
end

local function ShrinkForeverSecrets()
    local child = Canvas()
    if not child then return end
    for _, c in ipairs({ child:GetChildren() }) do
        if c.book and c.tex then c:SetSize(LIVRE_TAILLE, LIVRE_TAILLE) end
    end
end

local function RefreshLivres()
    for _, p in pairs(livrePins) do p:Hide() end
    if not (Livres.enabled and WorldMapFrame and WorldMapFrame:IsShown() and Canvas()) then return end
    if ForeverSecretsLoaded() then
        C_Timer.After(0, ShrinkForeverSecrets) -- après que ForeverSecrets a placé ses icônes
        return
    end
    local mapID = WorldMapFrame:GetMapID()
    local i = 0
    -- Carte d'un continent (Kalimdor, Royaumes de l'Est) : livres de toutes ses zones, à leur place
    -- sur le continent (rectangle de la zone dans le continent : C_Map.GetMapRectOnMap).
    local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(mapID)
    local continent = info and Enum and Enum.UIMapType and info.mapType == Enum.UIMapType.Continent
    for _, b in ipairs(LIVRES) do
        if not LivreFini(b[1]) then
            if b[2] == mapID then
                i = i + 1
                Place(i, b[3], b[4], "Interface\\Icons\\INV_Misc_Book_09", b[5], b[6])
            elseif continent and C_Map.GetMapRectOnMap then
                local ok, left, right, top, bottom = pcall(C_Map.GetMapRectOnMap, b[2], mapID)
                if ok and left and right and right > left then
                    i = i + 1
                    Place(i, (left + (right - left) * b[3] / 100) * 100, (top + (bottom - top) * b[4] / 100) * 100,
                        "Interface\\Icons\\INV_Misc_Book_09", b[5], b[6])
                    livrePins[i].x, livrePins[i].y = b[3], b[4] -- coordonnées de la zone dans l'info-bulle
                end
            end
        end
    end
    -- PNJ à qui rendre les livres, quand tu en as dans ton sac.
    local r = RENDRE[UnitFactionGroup and UnitFactionGroup("player") or "Horde"]
    local n = NbDansSac()
    if r and r[1] == mapID and n > 0 then
        i = i + 1
        Place(i, r[2], r[3], "Interface\\Icons\\INV_Misc_Book_11", r[4],
            r[5] .. string.format(" (%d dans ton sac)", n))
    end
end

-- Diamètre de la mini-carte en « mètres » du jeu selon le zoom (0 à 5), dehors / dedans (grottes).
local MINI_DIAM = {
    dehors = { 466.6667, 400, 333.3333, 266.6667, 200, 133.3333 },
    dedans = { 300, 240, 180, 120, 80, 50 },
}
local miniPins = {}

-- Taille de la carte en mètres-du-jeu (pour convertir un écart en coordonnées en distance).
local mapSizeCache = {}
local function MapSize(map)
    if mapSizeCache[map] then return unpack(mapSizeCache[map]) end
    local w, h
    if C_Map.GetMapWorldSize then w, h = C_Map.GetMapWorldSize(map) end
    if (not w or w == 0) and C_Map.GetWorldPosFromMapPos and CreateVector2D then
        local _, a = C_Map.GetWorldPosFromMapPos(map, CreateVector2D(0, 0))
        local _, b = C_Map.GetWorldPosFromMapPos(map, CreateVector2D(1, 1))
        if a and b then w, h = math.abs(a.y - b.y), math.abs(a.x - b.x) end
    end
    if w and w > 0 then mapSizeCache[map] = { w, h } end
    return w, h
end

local function MiniPin(i)
    if miniPins[i] then return miniPins[i] end
    local p = CreateFrame("Button", nil, Minimap)
    p:SetSize(12, 12)
    p:SetFrameLevel(Minimap:GetFrameLevel() + 8)
    p.tex = p:CreateTexture(nil, "OVERLAY")
    p.tex:SetAllPoints()
    p.tex:SetTexture("Interface\\Icons\\INV_Misc_Book_09")
    p:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine(self.title, 1, 0.82, 0)
        GameTooltip:AddLine(self.where, 1, 1, 1, true)
        GameTooltip:AddLine(string.format("%.1f, %.1f", self.x, self.y), 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    p:SetScript("OnLeave", function() GameTooltip:Hide() end)
    miniPins[i] = p
    return p
end

local function RefreshMini()
    for _, p in pairs(miniPins) do p:Hide() end
    if not (Livres.enabled and Minimap and C_Map and C_Map.GetBestMapForUnit) or ForeverSecretsLoaded() then return end
    local map = C_Map.GetBestMapForUnit("player")
    local pos = map and C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(map, "player")
    if not pos then return end
    local px, py = pos:GetXY()
    local w, h = MapSize(map)
    if not (px and w and h and w > 0) then return end
    local inside = IsIndoors and IsIndoors()
    local diam = (inside and MINI_DIAM.dedans or MINI_DIAM.dehors)[(Minimap:GetZoom() or 0) + 1] or 466.6667
    local size = Minimap:GetWidth()
    local scale, radius = size / diam, size / 2 - 5
    local facing = (GetCVar and GetCVar("rotateMinimap") == "1" and GetPlayerFacing and GetPlayerFacing()) or 0
    local sin, cos = math.sin(facing), math.cos(facing)
    local i = 0
    for _, b in ipairs(LIVRES) do
        if b[2] == map and not LivreFini(b[1]) then
            local dx, dy = (b[3] / 100 - px) * w, (b[4] / 100 - py) * h
            if facing ~= 0 then dx, dy = dx * cos - dy * sin, dx * sin + dy * cos end
            local ox, oy = dx * scale, -dy * scale
            local dist = math.sqrt(ox * ox + oy * oy)
            i = i + 1
            local p = MiniPin(i)
            if dist > radius then -- hors de la mini-carte : sur le bord, dans sa direction, en pâle
                ox, oy = ox * radius / dist, oy * radius / dist
                p:SetAlpha(0.55)
            else
                p:SetAlpha(1)
            end
            p.title, p.where, p.x, p.y = b[5], b[6], b[3], b[4]
            p:ClearAllPoints()
            p:SetPoint("CENTER", Minimap, "CENTER", ox, oy)
            p:Show()
        end
    end
end

ns._RefreshMini = RefreshMini -- (test hors jeu)

local miniElapsed = 0
local miniTicker = CreateFrame("Frame")
miniTicker:SetScript("OnUpdate", function(_, elapsed)
    miniElapsed = miniElapsed + elapsed
    if miniElapsed < 0.1 then return end
    miniElapsed = 0
    RefreshMini()
end)
miniTicker:Hide()

livreFrame:SetScript("OnEvent", function()
    NoterSacs()
    if WorldMapFrame and WorldMapFrame:IsShown() then RefreshLivres() end
end)

local hooked = false
local function HookMap()
    if hooked or not WorldMapFrame then return end
    hooked = true
    WorldMapFrame:HookScript("OnShow", RefreshLivres)
    if WorldMapFrame.OnMapChanged then hooksecurefunc(WorldMapFrame, "OnMapChanged", RefreshLivres) end
    -- Zoom de la carte : on remet les icônes à la bonne taille.
    if WorldMapFrame.OnCanvasScaleChanged then hooksecurefunc(WorldMapFrame, "OnCanvasScaleChanged", RefreshLivres) end
end

function Livres.Enable()
    Livres.enabled = true
    miniTicker:Show()
    NoterSacs()
    pcall(livreFrame.RegisterEvent, livreFrame, "BAG_UPDATE_DELAYED")
    HookMap()
    -- Carte du monde chargée plus tard (à la demande) : on s'y accroche quand elle arrive.
    if not hooked and EventUtil and EventUtil.ContinueOnAddOnLoaded then
        EventUtil.ContinueOnAddOnLoaded("Blizzard_WorldMap", function() HookMap(); RefreshLivres() end)
    end
    RefreshLivres()
end

function Livres.Disable()
    Livres.enabled = false
    miniTicker:Hide()
    for _, p in pairs(miniPins) do p:Hide() end
    livreFrame:UnregisterAllEvents()
    for _, p in pairs(livrePins) do p:Hide() end
end

---------------------------------------------------------------------------
-- Fonction : RÉCOMPENSE DE QUÊTE QUI VAUT LE PLUS (demande de Jérémie : « que ça me montre une
-- pièce d'or sur l'objet qui vaut le plus, comme ça je ne me prends pas la tête »).
-- Au moment de rendre une quête avec un choix de récompense : une pièce d'or sur l'objet au plus
-- gros prix de revente. Valeur = prix marchand x quantité ; si l'objet n'est PAS lié quand
-- ramassé (donc vendable à l'HV), prix de l'HV (dernier scan d'Auctionator) moins 5 % si c'est mieux.
---------------------------------------------------------------------------
local Recompense = { key = "recompense", label = "Quête : pièce d'or sur la récompense qui vaut le plus" }
table.insert(features, Recompense)
DEFAULTS.recompense = true

local coinMarks = {}

local function RewardValue(index)
    local link = GetQuestItemLink and GetQuestItemLink("choice", index)
    if not link then return nil end
    local _, _, count = GetQuestItemInfo("choice", index)
    count = (count and count > 0) and count or 1
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    local name, _, _, _, _, _, _, _, _, _, sellPrice, _, _, bindType = getInfo(link)
    if not name then return nil end -- infos pas encore chargées
    local value = (sellPrice or 0) * count
    if bindType ~= 1 and ns.PrixHV then
        local id = tonumber(link:match("item:(%d+)"))
        local hv = ns.PrixHV(id)
        if hv and hv * count * 0.95 > value then value = hv * count * 0.95 end
    end
    return value
end

local function ChoiceButtons()
    local list = {}
    local frame = QuestInfoRewardsFrame
    if frame and frame.RewardButtons then
        for _, b in ipairs(frame.RewardButtons) do
            if b:IsShown() and b.type == "choice" then list[#list + 1] = b end
        end
    end
    return list
end

local function HideCoins()
    for _, t in pairs(coinMarks) do t:Hide() end
end

local function MarkBestReward(attempt)
    HideCoins()
    if not Recompense.enabled or not GetNumQuestChoices or GetNumQuestChoices() < 2 then return end
    local best, bestValue, missing = nil, 0, false
    for _, b in ipairs(ChoiceButtons()) do
        local v = RewardValue(b:GetID())
        if v == nil then
            missing = true
        elseif v > bestValue then
            best, bestValue = b, v
        end
    end
    -- Objet pas encore connu du jeu : on réessaie un peu plus tard (3 fois).
    if missing and (attempt or 1) < 3 then
        C_Timer.After(0.5, function() MarkBestReward((attempt or 1) + 1) end)
    end
    if not best then return end
    local t = coinMarks[best]
    if not t then
        t = best:CreateTexture(nil, "OVERLAY", nil, 7)
        t:SetTexture("Interface\\MoneyFrame\\UI-GoldIcon")
        t:SetSize(16, 16)
        t:SetPoint("TOPLEFT", best.Icon or best, "TOPLEFT", -4, 4)
        coinMarks[best] = t
    end
    t:Show()
end

ns._MarkBestReward = MarkBestReward -- (test hors jeu)

local questFrame = CreateFrame("Frame")
questFrame:SetScript("OnEvent", function(_, event)
    if event == "QUEST_COMPLETE" then
        C_Timer.After(0, MarkBestReward) -- les boutons sont remplis juste après l'événement
    else
        HideCoins()
    end
end)

function Recompense.Enable()
    Recompense.enabled = true
    pcall(questFrame.RegisterEvent, questFrame, "QUEST_COMPLETE")
    pcall(questFrame.RegisterEvent, questFrame, "QUEST_FINISHED")
end

function Recompense.Disable()
    Recompense.enabled = false
    questFrame:UnregisterAllEvents()
    HideCoins()
end

---------------------------------------------------------------------------
-- Fonction : MAJ+M = LA MINI-CARTE EN GRAND (demande de Jérémie : dans une grotte, M ouvre la carte
-- de la zone ; lui veut « une carte, mais que de la mini-carte »). Maj+M (ou Échap) : la mini-carte
-- passe au milieu de l'écran, 2,5 fois plus grande, sur un fond sombre ; molette = zoom. Maj+M,
-- Échap ou un clic sur le fond : elle revient à sa place. Pas en combat (le jeu l'interdit).
-- La touche est posée par SetOverrideBindingClick (pas de fichier Bindings.xml).
---------------------------------------------------------------------------
local MiniCarte = { key = "miniCarte", label = "Maj+M : mini-carte en grand" }
table.insert(features, MiniCarte)
DEFAULTS.miniCarte = true

local MINI_SCALE = 2.5
local saved -- position, échelle et couche d'origine de la mini-carte

-- Fond sombre plein écran (clic = fermer) ; dans UISpecialFrames : Échap le ferme.
local miniBack = CreateFrame("Button", "EryMiniCarteFond", UIParent)
miniBack:SetAllPoints(UIParent)
miniBack:SetFrameStrata("DIALOG")
miniBack:Hide()
local fond = miniBack:CreateTexture(nil, "BACKGROUND")
fond:SetAllPoints()
fond:SetColorTexture(0, 0, 0, 0.55)
table.insert(UISpecialFrames, "EryMiniCarteFond")

local function MiniRestore()
    if not saved or not MinimapCluster then return end
    if InCombatLockdown and InCombatLockdown() then return end
    MinimapCluster:ClearAllPoints()
    for _, pt in ipairs(saved.points) do MinimapCluster:SetPoint(unpack(pt)) end
    MinimapCluster:SetScale(saved.scale)
    MinimapCluster:SetFrameStrata(saved.strata)
    if Minimap then Minimap:EnableMouseWheel(saved.wheel) end
    saved = nil
end

local function MiniToggle()
    if not MinimapCluster then return end
    if InCombatLockdown and InCombatLockdown() then
        Msg("pas de mini-carte en grand pendant un combat.")
        return
    end
    if saved then miniBack:Hide() return end -- OnHide remet tout en place
    saved = { points = {}, scale = MinimapCluster:GetScale(), strata = MinimapCluster:GetFrameStrata(),
        wheel = Minimap and Minimap:IsMouseWheelEnabled() or false }
    for i = 1, MinimapCluster:GetNumPoints() do saved.points[i] = { MinimapCluster:GetPoint(i) } end
    miniBack:Show()
    MinimapCluster:SetFrameStrata("FULLSCREEN")
    MinimapCluster:SetScale(MINI_SCALE)
    MinimapCluster:ClearAllPoints()
    -- Centre de la MINI-CARTE (pas du cadre qui l'entoure) au centre de l'écran : décalage entre
    -- les deux centres, en unités du cadre (les mêmes pour la mini-carte, qui en est l'enfant).
    local cx, cy = Minimap:GetCenter()
    local kx, ky = MinimapCluster:GetCenter()
    if cx and kx then
        MinimapCluster:SetPoint("CENTER", UIParent, "CENTER", -(cx - kx), -(cy - ky))
    else
        MinimapCluster:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
    if Minimap then Minimap:EnableMouseWheel(true) end
end
miniBack:SetScript("OnClick", function() miniBack:Hide() end)
miniBack:SetScript("OnHide", MiniRestore)

-- Molette sur la mini-carte (en grand) : zoom avant / arrière.
if Minimap then
    Minimap:HookScript("OnMouseWheel", function(self, delta)
        if not saved then return end
        local z = self:GetZoom() + (delta > 0 and 1 or -1)
        if z >= 0 and z < self:GetZoomLevels() then self:SetZoom(z) end
    end)
end

local miniBtn = CreateFrame("Button", "EryMiniCarteBouton", UIParent)
miniBtn:SetScript("OnClick", MiniToggle)
local miniOwner = CreateFrame("Frame")

local function BindKey()
    if InCombatLockdown and InCombatLockdown() then return end
    SetOverrideBindingClick(miniOwner, true, "SHIFT-M", "EryMiniCarteBouton")
end

function MiniCarte.Enable()
    MiniCarte.enabled = true
    if InCombatLockdown and InCombatLockdown() then
        miniOwner:RegisterEvent("PLAYER_REGEN_ENABLED") -- posée à la sortie du combat
    else
        BindKey()
    end
end
miniOwner:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_REGEN_ENABLED")
    if MiniCarte.enabled then BindKey() end
end)

function MiniCarte.Disable()
    MiniCarte.enabled = false
    miniBack:Hide()
    if not (InCombatLockdown and InCombatLockdown()) then ClearOverrideBindings(miniOwner) end
end

-- Les commandes « / » de WoW ne tiennent pas compte des majuscules :
-- /eryaddon, /EryAddon, /ERYADDON fonctionnent tous.
SLASH_ERYADDON1 = "/eryaddon"
SlashCmdList.ERYADDON = function()
    if not panel then CreatePanel() end
    panel:SetShown(not panel:IsShown())
end

---------------------------------------------------------------------------
-- Démarrage
---------------------------------------------------------------------------
local main = CreateFrame("Frame")
main:RegisterEvent("ADDON_LOADED")
main:RegisterEvent("PLAYER_LOGIN")
main:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        EryAddonDB = EryAddonDB or {}
        for key, value in pairs(DEFAULTS) do
            if EryAddonDB[key] == nil then EryAddonDB[key] = value end
        end
        EryAddonDB.test = nil -- ancien relevé de la commande /eryaddon test (supprimée)
    elseif event == "PLAYER_LOGIN" then
        for _, feature in ipairs(features) do
            if EryAddonDB[feature.key] then feature.Enable() end
        end
        Msg("chargé. Tape /eryaddon pour les réglages.")
    end
end)
