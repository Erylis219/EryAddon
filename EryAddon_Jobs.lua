-- EryAddon : onglet « Jobs » : monter ses métiers en gagnant (ou en perdant le moins) d'or.
-- Visible à deux endroits :
--   - onglet « Jobs » en bas de la fenêtre de l'HV (créé par EryAddon_HV.lua) ;
--   - bouton « Jobs » au-dessus de la fenêtre du métier (fenêtre à part).
-- Pour le métier choisi, au niveau RÉEL (relevé automatique, EryAddonDB.niveaux) :
--   - case « Monter le métier » COCHÉE : seulement les recettes qui font gagner des points,
--     classées par coût par point (celles qui rapportent d'abord) ;
--   - DÉCOCHÉE : les recettes les plus rentables, classées par gain.
-- Couleur et chance de gagner un point (règle du jeu classique) :
--   orange 100 % ; jaune et vert : chance = (seuil gris − niveau) / (seuil gris − seuil jaune).
--   Les seuils de chaque recette sont APPRIS en ouvrant la fenêtre du métier (la couleur lue à
--   chaque niveau resserre les seuils : EryAddonDB.seuils). Sans observation, ils sont estimés
--   (jaune = apprentissage + 40, vert = jaune + 20, gris = vert + 20) et la ligne porte « ~ ».
-- Prix : dernier scan de l'HV (EryAddonDB.hvPrix) et prix marchand ; composants : EryAddonDB.metiers.

local ADDON_NAME, ns = ...
local issecret = ns.issecret

local Jobs = {
    key = "jobs",
    label = "Onglet « Métiers » (monter ses métiers)",
}
table.insert(ns.features, Jobs)
ns.DEFAULTS.jobs = true

local COMMISSION = 0.05
-- Composants vendus par les marchands (prix d'achat estimé = 4 x prix de revente).
local VENDOR = {}
for _, id in ipairs({ 3371, 3372, 8925, 18256, 2320, 2321, 4291, 8343, 14341, 2880, 3466, 2678, 2692,
    3713, 159, 1179, 30817, 2596, 4289, 2324, 2604, 6260, 2605, 4340, 4341, 4342, 10290, 2325, 6217,
    4399, 4400, 3857, 17020, 4470 }) do VENDOR[id] = true end

local COLOR = { optimal = { 1, 0.5, 0.25 }, medium = { 1, 1, 0 }, easy = { 0.25, 0.75, 0.25 }, trivial = { 0.5, 0.5, 0.5 } }
local COLOR_NAME = { optimal = "orange", medium = "jaune", easy = "vert", trivial = "gris" }

local function Money(c)
    if not c then return "?" end
    return (c < 0 and "-" or "") .. ns.Money(math.abs(c))
end

---------------------------------------------------------------------------
-- Données
---------------------------------------------------------------------------
local function Objet(itemID)
    local db = EryAddonDB.metiers and EryAddonDB.metiers.objets
    local s = db and db[itemID]
    if s then
        local name, sell = s:match("^(.*)|(%d+)|%d+$")
        if name then return name, tonumber(sell) end
    end
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    local name, _, _, _, _, _, _, _, _, _, sell = getInfo(itemID)
    return name or ("objet " .. itemID), sell or 0
end

local function PrixHV(itemID)
    local p = EryAddonDB.hvPrix and EryAddonDB.hvPrix.prix
    if p and p[itemID] then return p[itemID] end
    -- Pas vu par notre scan : dernier prix d'Auctionator (ex. Fiole vide : 19 pc à l'HV).
    if Auctionator and Auctionator.API and Auctionator.API.v1 then
        local ok, v = pcall(Auctionator.API.v1.GetAuctionPriceByItemID, "EryAddon", itemID)
        if ok and type(v) == "number" and v > 0 then return v end
    end
end

-- Coût d'un composant : le moins cher entre l'HV et le marchand.
-- Prix réel relevé chez un marchand (EryAddon_Metiers.lua), ou nil.
local function PrixMarchand(itemID)
    local db = EryAddonDB.prixMarchand
    local v = db and db[itemID]
    return type(v) == "number" and v or nil
end

-- Coût d'un composant : le moins cher entre l'HV et le marchand.
-- Prix marchand : relevé réel s'il existe, sinon estimation 4 x prix de revente (« marchand ~ »)
-- pour les composants connus pour être vendus par les marchands.
local function UnitCost(itemID)
    local best, src = PrixHV(itemID), "HV"
    local vendorPrice, vendorSrc = PrixMarchand(itemID), "marchand"
    if not vendorPrice and VENDOR[itemID] then
        local _, sell = Objet(itemID)
        if sell and sell > 0 then vendorPrice, vendorSrc = sell * 4, "marchand ~" end
    end
    if vendorPrice and (not best or vendorPrice < best) then best, src = vendorPrice, vendorSrc end
    return best, src
end

-- L'autre prix (pour comparer, demande de Jérémie) : « (marchand 32) » si l'HV est le moins cher,
-- « (HV 40) » si c'est le marchand. Vide s'il n'y a qu'une source.
local function OtherPriceText(itemID, src, qty)
    local other
    if src == "HV" then
        other = PrixMarchand(itemID)
        if not other and VENDOR[itemID] then
            local _, sell = Objet(itemID)
            other = sell and sell > 0 and sell * 4 or nil
        end
        return other and (" |cff5f8a99(marchand " .. Money(other * qty) .. ")|r") or ""
    end
    other = PrixHV(itemID)
    return other and (" |cff5f8a99(HV " .. Money(other * qty) .. ")|r") or ""
end

local function IsKnown(spell)
    if C_SpellBook and C_SpellBook.IsSpellKnown and Enum and Enum.SpellBookSpellBank then
        local ok, known = pcall(C_SpellBook.IsSpellKnown, spell, Enum.SpellBookSpellBank.Player)
        if ok and not issecret(known) then return known == true end
    end
    if IsPlayerSpell then
        local ok, known = pcall(IsPlayerSpell, spell)
        if ok and not issecret(known) then return known == true end
    end
    return false
end

-- Niveau réel d'un métier : fenêtre du métier ouverte (le plus frais), sinon relevé automatique.
local liveSkill = {}
local function SkillOf(profName)
    if liveSkill[profName] then return liveSkill[profName] end
    local n = EryAddonDB.niveaux and EryAddonDB.niveaux.metiers and EryAddonDB.niveaux.metiers[profName]
    return n and tonumber(n:match("^(%d+)"))
end

---------------------------------------------------------------------------
-- Seuils de couleur (appris) et chance de gagner un point
---------------------------------------------------------------------------
-- Observation : à tel niveau, la recette était de telle couleur → on resserre les seuils.
local function Observe(spell, color, skill)
    EryAddonDB.seuils = EryAddonDB.seuils or {}
    local t = EryAddonDB.seuils[spell] or {}
    local changed = false
    local function lo(k) local v = t[k] and math.min(t[k], skill) or skill; changed = changed or v ~= t[k]; t[k] = v end
    local function hi(k) local v = t[k] and math.max(t[k], skill) or skill; changed = changed or v ~= t[k]; t[k] = v end
    if color == "optimal" then hi("o")
    elseif color == "medium" then lo("y1"); hi("y2")
    elseif color == "easy" then lo("g1"); hi("g2")
    elseif color == "trivial" then lo("t") end
    EryAddonDB.seuils[spell] = t
    if changed then ns.dataVersion = (ns.dataVersion or 0) + 1 end
end

-- Seuils jaune / vert / gris d'une recette ; « learned » = au moins une observation.
-- Chaque seuil est encadré par ce qu'on a observé : par ex. vu orange jusqu'à 30 et jaune
-- dès 34 → le seuil jaune est entre 31 et 34. S'il est encadré au point près, il est EXACT ;
-- sinon on prend l'estimation habituelle (jaune = apprentissage + 40, vert = jaune + 20,
-- gris = vert + 20) ramenée dans l'encadrement. (1re version : on prenait la limite la plus
-- basse — « vu jaune à 44 → vert dès 45 » — et les pourcentages baissaient trop vite.)
local function Bounded(guess, lo, hi)
    if hi and guess > hi then guess = hi end
    if lo and guess < lo then guess = lo end
    return guess, (lo ~= nil and hi ~= nil and lo == hi)
end

-- Seuils OFFICIELS de chaque recette (table SkillLineAbility de Forever 1.60.1, via wago.tools,
-- intégrée à EryAddon_Recettes.lua) : jaune et gris fixes ; vert = milieu des deux (règle du jeu).
-- C'est la source prioritaire ; les observations ne servent que pour une recette absente de la table.
local official
local function Official(spell)
    if not official then
        official = {}
        for _, r in ipairs(ns.RECETTES) do
            if (r[8] or 0) > 0 and (r[9] or 0) > 0 then official[r[2]] = r end
        end
    end
    return official[spell]
end

local function Thresholds(spell, learn)
    local o = Official(spell)
    if o then
        local y, gr = o[8], o[9]
        local g = math.floor((y + gr) / 2)
        if g <= y then g = y + 1 end
        if gr <= g then gr = g + 1 end
        return y, g, gr, true, { y = true, g = true, gr = true }
    end
    local t = EryAddonDB.seuils and EryAddonDB.seuils[spell]
    local learned = t ~= nil
    t = t or {}
    local y, yExact = Bounded(learn + 40, t.o and t.o + 1 or learn, t.y1 or t.g1 or t.t)
    local g, gExact = Bounded(y + 20, math.max(y + 1, t.y2 and t.y2 + 1 or 0), t.g1 or t.t)
    local gr, grExact = Bounded(g + 20, math.max(g + 1, t.g2 and t.g2 + 1 or 0), t.t)
    return y, g, gr, learned, { y = yExact, g = gExact, gr = grExact }
end

-- Recettes qui donnent PLUSIEURS points d'un coup (quand elles sont orange) :
-- EryAddonDB.pointsParCraft[sort] = nombre. Appris de trois façons : fenêtre du métier
-- (« x2 » à côté du nom), fonction moderne du jeu, ou observation d'un gain de plusieurs points.
local function Multi(spell)
    local o = Official and Official(spell)
    if o and (o[10] or 1) > 1 then return o[10] end -- points officiels par fabrication
    local db = EryAddonDB.pointsParCraft
    return (db and db[spell]) or 1
end

local function SetMulti(spell, n)
    if not n or issecret(n) or n < 2 then return end
    EryAddonDB.pointsParCraft = EryAddonDB.pointsParCraft or {}
    if EryAddonDB.pointsParCraft[spell] ~= n then ns.dataVersion = (ns.dataVersion or 0) + 1 end
    EryAddonDB.pointsParCraft[spell] = n
end

local function ColorAndChance(spell, learn, skill)
    local y, g, gr, learned, exact = Thresholds(spell, learn)
    local color
    if skill < y then color = "optimal"
    elseif skill < g then color = "medium"
    elseif skill < gr then color = "easy"
    else color = "trivial" end
    local chance = 1
    if color == "trivial" then
        chance = 0
    elseif color ~= "optimal" then
        chance = math.max(0, math.min(1, (gr - skill) / (gr - y)))
    end
    return color, chance, not learned, y, g, gr, exact
end

-- Peut-on se procurer cette recette sans chance ? Maître, patron chez un marchand, ou
-- objet-recette en vente à l'HV. (Recettes de butin / quête seulement : pas proposées.
-- Ex. Élixir d'Esprit mineur, recette de butin propre à Forever, que le maître n'a pas.)
-- Réputation suffisante pour acheter le patron ? (ex. patrons de l'Île de Zéphras : Amical avec
-- les Druides et druidesses de la Noctegriffe). Inconnue = on suppose que non.
local function RepOK(r)
    local faction, rank = r[12] or 0, r[13] or 0
    if faction == 0 then return true end
    if C_Reputation and C_Reputation.GetFactionDataByID then
        local ok, d = pcall(C_Reputation.GetFactionDataByID, faction)
        if ok and type(d) == "table" and type(d.reaction) == "number" then return d.reaction >= rank end
    end
    if GetFactionInfoByID then
        local ok, _, _, standing = pcall(GetFactionInfoByID, faction)
        if ok and type(standing) == "number" then return standing >= rank end
    end
    return false
end

-- Nom de la faction et rang actuel (1 Détesté … 5 Amical … 8 Exalté).
local function FactionInfo(faction)
    local name, now
    if C_Reputation and C_Reputation.GetFactionDataByID then
        local ok, d = pcall(C_Reputation.GetFactionDataByID, faction)
        if ok and type(d) == "table" then name, now = d.name, d.reaction end
    end
    if not name and GetFactionInfoByID then
        local ok, n, _, standing = pcall(GetFactionInfoByID, faction)
        if ok then name, now = n, standing end
    end
    return name or ("faction n° " .. faction), now
end

-- « Monter réputation : Amical avec … (tu es : Neutre) » si la réputation manque, sinon nil.
local function RepLine(e)
    if (e.repFaction or 0) == 0 or RepOK({ [12] = e.repFaction, [13] = e.repRank }) then return nil end
    local name, now = FactionInfo(e.repFaction)
    local need = _G["FACTION_STANDING_LABEL" .. e.repRank] or ("rang " .. e.repRank)
    local nowText = now and _G["FACTION_STANDING_LABEL" .. now]
    return string.format("|cffff9933Monter réputation : %s avec %s%s|r", need, name,
        nowText and (" (tu es : " .. nowText .. ")") or "")
end

-- Marchands du patron (données WhatsTraining « PNJ:zone:faction ») : seulement ceux de TA faction
-- (ou neutres), « Nom (zone) ». Noms des PNJ via Questie, gardés en mémoire.
local npcNames = {}
local RecipeSources -- défini plus bas (base Questie)
local function VendorNames(vend)
    local list = {}
    local mine = (UnitFactionGroup and UnitFactionGroup("player") == "Alliance") and "A" or "H"
    local Q = _G.LibQuestieDB
    for npc, area, fac in (vend or ""):gmatch("(%d+):(%d+):?(%a?)") do
        if fac == "" or fac == "N" or fac == mine then
            npc, area = tonumber(npc), tonumber(area)
            if npcNames[npc] == nil then
                local name = false
                if Q and Q.Npc and Q.Npc.Get then
                    local ok, v = pcall(Q.Npc.Get, npc, "name")
                    if ok and v then name = v end
                end
                npcNames[npc] = name
            end
            local zone = C_Map and C_Map.GetAreaInfo and C_Map.GetAreaInfo(area)
            if zone then zone = zone:gsub("%s*%b()", "") end
            list[#list + 1] = (npcNames[npc] or ("PNJ n° " .. npc)) .. (zone and (" (" .. zone .. ")") or "")
        end
    end
    return list
end

-- Les façons d'apprendre une recette, et la MOINS CHÈRE (demande de Jérémie) :
--   trainer = prix chez le maître ; vendors = marchands de ta faction ; vendorPrice = prix du patron
--   (relevé chez le marchand, sinon table ItemSparse du jeu, champ 14) ; vendorOK = réputation et
--   faction suffisantes ; hv = prix à l'HV ; best = « maître » / « marchand » / « HV », cost = son prix.
local function LearnOptions(r)
    local o = {}
    local src, teach = r[5] or "", r[7] or 0
    if src:find("T") then o.trainer = r[6] or 0 end
    if src:find("V") and teach > 0 then
        o.vendors = VendorNames(r[11])
        if not o.vendors[1] and (r[11] or "") == "" then o.vendors = RecipeSources(teach).vendors end
        o.vendorPrice = PrixMarchand(teach) or (((r[14] or 0) > 0) and r[14] or nil)
        o.vendorOK = RepOK(r) and ((r[11] or "") == "" or o.vendors[1] ~= nil)
        o.otherFaction = (r[11] or "") ~= "" and not o.vendors[1]
    end
    if teach > 0 then o.hv = PrixHV(teach) end
    local function Consider(where, cost)
        if cost and (not o.cost or cost < o.cost) then o.best, o.cost = where, cost end
    end
    if o.trainer then Consider("maître", o.trainer) end
    if o.vendorOK then Consider("marchand", o.vendorPrice) end
    if o.hv then Consider("HV", o.hv) end
    if not o.best and o.vendorOK then o.best = "marchand" end -- marchand au prix inconnu
    return o
end

local function Obtainable(r)
    if (r[5] or "") == "" then return true end
    return LearnOptions(r).best ~= nil
end

-- Court texte « où l'apprendre » (fiche, guide) : la façon la moins chère seulement.
local function LearnLabel(r)
    local o = LearnOptions(r)
    if o.best == "maître" then return "maître " .. Money(o.trainer) end
    if o.best == "HV" then return "patron à l'HV " .. Money(o.hv) end
    if o.best == "marchand" or (o.vendors and o.vendors[1]) then
        local names = o.vendors or {}
        local where = names[1] and ("chez " .. names[1] .. (#names > 1 and string.format(" ou %d autre%s", #names - 1,
            #names > 2 and "s" or "") or "")) or "chez un marchand"
        return "patron " .. (o.vendorPrice and (Money(o.vendorPrice) .. " ") or "") .. where
    end
    if o.otherFaction then
        return "patron vendu seulement à l'" .. ((UnitFactionGroup and UnitFactionGroup("player") == "Alliance")
            and "Horde" or "Alliance")
    end
    local src = r[5] or ""
    if src:find("D") then return "recette à trouver sur un monstre, voir info-bulle" end
    if src:find("Q") then return "recette de quête, voir info-bulle" end
    return "?"
end

-- Où trouver l'objet-recette, d'après la base de l'add-on Questie (si elle est chargée) :
-- PNJ qui le vendent, monstres qui le lâchent (niveau, zone, taux de drop quand Questie le
-- connaît : surtout pour les objets de quête, rarement pour les recettes), quêtes qui le donnent.
local sourceCache = {}
RecipeSources = function(itemID)
    -- Résultat : { questie = bool, vendors = { textes }, drops = { textes }, objects = bool, quests = { textes } }
    local empty = { questie = false, vendors = {}, drops = {}, quests = {} }
    if not itemID or itemID == 0 then return empty end
    if sourceCache[itemID] then return sourceCache[itemID] end
    local Q = _G.LibQuestieDB
    if not (Q and Q.Item and Q.Item.Get and Q.Npc and Q.Npc.Get) then return empty end
    local function get(entity, id, key)
        local ok, v = pcall(entity.Get, id, key)
        if ok then return v end
    end
    local function zoneOf(npcID)
        local zone = get(Q.Npc, npcID, "zoneID")
        return zone and C_Map and C_Map.GetAreaInfo and C_Map.GetAreaInfo(zone) or nil
    end
    local function npcText(npcID)
        local name = get(Q.Npc, npcID, "name") or ("PNJ " .. npcID)
        local lo, hi = get(Q.Npc, npcID, "minLevel"), get(Q.Npc, npcID, "maxLevel")
        local level = lo and ((hi and hi ~= lo) and (lo .. "-" .. hi) or tostring(lo)) or "?"
        local zone = zoneOf(npcID)
        return string.format("%s (niv. %s%s)", name, level, zone and (", " .. zone) or "")
    end
    local result = { questie = true, vendors = {}, drops = {}, quests = {} }

    -- Marchands : seulement ceux de TA faction (ou neutres), avec leur métier et leur ville.
    local myFaction = (UnitFactionGroup and UnitFactionGroup("player") == "Alliance") and "A" or "H"
    for _, npcID in ipairs(get(Q.Item, itemID, "vendors") or {}) do
        local f = get(Q.Npc, npcID, "friendlyToFaction")
        if f == nil or f == "AH" or f == myFaction then
            local name = get(Q.Npc, npcID, "name") or ("PNJ " .. npcID)
            local title = get(Q.Npc, npcID, "subName")
            local zone = zoneOf(npcID)
            result.vendors[#result.vendors + 1] = name .. (title and title ~= "" and (" — " .. title) or "")
                .. (zone and (" (" .. zone .. ")") or "")
        end
    end

    local drops = {}
    local DropDB = QuestieLoader and QuestieLoader.ImportModule and QuestieLoader:ImportModule("DropDB")
    for _, npcID in ipairs(get(Q.Item, itemID, "npcDrops") or {}) do
        local rate
        if DropDB and DropDB.GetItemDroprate then
            local ok, r = pcall(DropDB.GetItemDroprate, itemID, npcID)
            if ok and type(r) == "table" then rate = r[1] end
        end
        drops[#drops + 1] = { id = npcID, rate = rate }
    end
    table.sort(drops, function(a, b) return (a.rate or -1) > (b.rate or -1) end)
    for i, d in ipairs(drops) do
        if i > 8 then
            result.drops[#result.drops + 1] = string.format("… et %d autres monstres", #drops - 8)
            break
        end
        result.drops[#result.drops + 1] = npcText(d.id)
            .. (d.rate and string.format(" — %.1f %%", d.rate) or " — taux inconnu")
    end
    result.dropCount = #drops
    result.objects = #(get(Q.Item, itemID, "objectDrops") or {}) > 0
    for _, questID in ipairs(get(Q.Item, itemID, "questRewards") or {}) do
        local qname = Q.Quest and get(Q.Quest, questID, "name")
        result.quests[#result.quests + 1] = qname or ("quête " .. questID)
    end
    sourceCache[itemID] = result
    return result
end

-- Lignes « comment l'apprendre » de l'info-bulle, les plus simples d'abord (demande de Jérémie) :
-- maître du métier, puis marchands NOMMÉS de ta faction et HV ; le butin n'est mentionné que s'il
-- n'y a rien d'autre, et replié (maintenir MAJ pour voir la liste des monstres).
local function AddLearnLines(e)
    local tip = GameTooltip
    local profName = ns.METIERS[e.prof] or "métier"
    local any = false
    if e.src and e.src:find("T") then
        tip:AddLine(string.format("Recette : %s chez ton maître de %s", Money(e.trainerCost or 0), profName:lower()),
            1, 0.82, 0)
        any = true
    end
    local o = LearnOptions(e.r)
    local src = RecipeSources(e.teach)
    -- Règle de Jérémie : HV moins cher que le marchand → on n'affiche pas le marchand ;
    -- marchand moins cher (ou prix inconnu) → les deux.
    local showVendor = o.vendors and o.vendors[1] and not (o.hv and o.vendorPrice and o.hv <= o.vendorPrice)
    if showVendor then
        tip:AddLine("Patron" .. (o.vendorPrice and (" " .. Money(o.vendorPrice)) or "") .. " chez :", 1, 0.82, 0)
        for i, v in ipairs(o.vendors) do
            if i > 3 then tip:AddLine(string.format("  … et %d autres", #o.vendors - 3), 0.7, 0.7, 0.7) break end
            tip:AddLine("  " .. v, 0.9, 0.9, 0.9)
        end
        local repLine = RepLine(e)
        if repLine then tip:AddLine(repLine, 1, 1, 1, true) end
        any = true
    end
    if o.hv then
        tip:AddLine("Patron à l'HV : " .. Money(o.hv), 1, 0.82, 0)
        any = true
    end
    if any then return end
    -- Seulement du butin / des quêtes.
    local n = (src.dropCount or 0) + #src.quests
    if n == 0 then
        tip:AddLine(src.questie and "Recette de butin (aucune source connue dans Questie)"
            or "Recette de butin (active Questie pour savoir où)", 1, 0.6, 0.2)
    elseif IsShiftKeyDown and IsShiftKeyDown() then
        tip:AddLine("Où trouver la recette :", 1, 0.6, 0.2)
        for _, l in ipairs(src.drops) do tip:AddLine("  Lâchée par : " .. l, 0.9, 0.9, 0.9, true) end
        if src.objects then tip:AddLine("  Aussi dans des coffres / objets du monde", 0.9, 0.9, 0.9) end
        for _, q in ipairs(src.quests) do tip:AddLine("  Récompense de quête : " .. q, 0.9, 0.9, 0.9, true) end
    else
        tip:AddLine(string.format("Recette de butin : %d source%s — maintiens MAJ pour voir", n, n > 1 and "s" or ""),
            1, 0.6, 0.2)
    end
end

-- Comment apprendre une recette qu'on ne connaît pas encore.
local function HowToLearn(r)
    local src, cost, teach = r[5], r[6], r[7]
    local parts = {}
    if src:find("T") then parts[#parts + 1] = "maître (" .. Money(cost) .. ")" end
    if src:find("V") then
        local known = teach and teach > 0 and PrixMarchand(teach)
        parts[#parts + 1] = known and ("marchand (" .. Money(known) .. ")") or "marchand"
    end
    if src:find("D") then parts[#parts + 1] = "butin" end
    if src:find("Q") then parts[#parts + 1] = "quête" end
    if teach and teach > 0 and PrixHV(teach) then parts[#parts + 1] = "recette à l'HV " .. Money(PrixHV(teach)) end
    return #parts > 0 and table.concat(parts, ", ") or "?"
end

-- Recette qui fabrique un objet (pour proposer « fabriquer au lieu d'acheter »).
local producers
local function Producer(itemID)
    if not producers then
        producers = {}
        for _, r in ipairs(ns.RECETTES) do
            if not producers[r[3]] then producers[r[3]] = r[2] end
        end
    end
    return producers[itemID]
end

-- Données d'une recette relevées dans le jeu : objet créé, quantité moyenne, composants.
local function RecipeData(spell)
    local db = EryAddonDB.metiers and EryAddonDB.metiers.recettes
    local d = db and db[spell]
    if not d then return nil end
    local _, out, qmin, qmax, reag = d:match("^(%d+)|(%d+)|(%d+)|(%d+)|(.*)$")
    if not out or reag == "?" or reag == "" then return nil end
    return tonumber(out), (tonumber(qmin) + tonumber(qmax)) / 2, reag
end

-- Niveau maximum actuel du métier (palier du maître), ex. « 18/75 » → 75.
local function CapOf(profName)
    local n = EryAddonDB.niveaux and EryAddonDB.niveaux.metiers and EryAddonDB.niveaux.metiers[profName]
    return (n and tonumber(n:match("/(%d+)"))) or 75
end

-- RÉUTILISATION (seule vraie plus-value de l'ancien guide, d'après Jérémie) : quelles recettes du
-- même métier, jusqu'au palier actuel et qui font encore gagner des points, utilisent cet objet ?
-- [métier][objet] = { { name, learn, qty }, … } (3 au plus, par niveau d'apprentissage).
local reuseCache, reuseKey = {}, nil
local function ReuseOf(profID, itemID, skill, cap)
    local key = profID .. "|" .. skill .. "|" .. cap .. "|" .. (ns.dataVersion or 0)
    if reuseKey ~= key then reuseCache, reuseKey = {}, key end
    local map = reuseCache[profID]
    if not map then
        map = {}
        for _, r in ipairs(ns.RECETTES or {}) do
            local grey = (r[9] or 0) > 0 and r[9] or (r[4] + 60)
            if r[1] == profID and r[4] <= cap and grey > skill then
                local _, _, reag = RecipeData(r[2])
                for id, q in (reag or ""):gmatch("(%d+):(%d+)") do
                    id = tonumber(id)
                    map[id] = map[id] or {}
                    table.insert(map[id], { out = r[3], learn = r[4], qty = tonumber(q) })
                end
            end
        end
        for _, list in pairs(map) do table.sort(list, function(a, b) return a.learn < b.learn end) end
        reuseCache[profID] = map
    end
    local list = map[itemID]
    if not list then return nil end
    local out = {}
    for _, u in ipairs(list) do
        if u.out ~= itemID then out[#out + 1] = u end
    end
    return out[1] and out or nil
end

-- « Sert aussi pour : Sac rouge en lin (60), Kilt coloré (70) » (3 au plus).
local function ReuseText(e)
    local list = ReuseOf(e.prof, e.out, e.skill, CapOf(ns.METIERS[e.prof] or ""))
    if not list then return nil end
    local parts = {}
    for i, u in ipairs(list) do
        if i > 3 then parts[#parts + 1] = "…" break end
        parts[#parts + 1] = string.format("%s (niv. %d)", Objet(u.out), u.learn)
    end
    return "Sert aussi pour : " .. table.concat(parts, ", ")
end
ns._ReuseText = ReuseText -- (test hors jeu)

-- Coût d'UN exemplaire d'un composant si on le fabrique soi-même (recette connue), ou nil.
local function CraftUnitCost(itemID)
    local spell = Producer(itemID)
    if not spell or not IsKnown(spell) then return nil end
    local _, qty, reag = RecipeData(spell)
    if not reag then return nil end
    local total = 0
    for id, n in reag:gmatch("(%d+):(%d+)") do
        local c = UnitCost(tonumber(id))
        if not c then return nil end
        total = total + c * tonumber(n)
    end
    return total / qty, spell
end

-- Ce que vaut une unité de cet objet pour toi (suivi de tes ventes, EryAddon_HV.lua) : prix de ses
-- composants si tu sais le fabriquer, sinon le prix d'achat le plus bas (HV ou marchand).
function ns.CostBasis(itemID)
    local craft = CraftUnitCost(itemID)
    if craft then return craft end
    return (UnitCost(itemID))
end


-- Le moins cher entre acheter le composant et le fabriquer.
local function BestCost(itemID)
    local buy, src = UnitCost(itemID)
    local craft = CraftUnitCost(itemID)
    if craft and (not buy or craft < buy) then return craft, "fabriqué" end
    return buy, src
end

-- Toutes les recettes d'un métier jusqu'au niveau donné, chiffrées.
local function Compute(profID, skill)
    local list = {}
    local db = EryAddonDB.metiers and EryAddonDB.metiers.recettes
    if not db then return list end
    for _, r in ipairs(ns.RECETTES) do
        local prof, spell, learn = r[1], r[2], r[4]
        local data = prof == profID and learn <= skill and db[spell]
        -- Recette ni connue ni accessible (butin, quête) : pas proposée.
        -- (Les recettes de butin ou de quête restent affichées, marquées, avec leurs sources
        -- dans l'info-bulle : demande de Jérémie, « il faut que j'aie les données sous les yeux ».)
        if data then
            local _, out, qmin, qmax, reag = data:match("^(%d+)|(%d+)|(%d+)|(%d+)|(.*)$")
            out, qmin, qmax = tonumber(out), tonumber(qmin), tonumber(qmax)
            local qty = (qmin + qmax) / 2
            local known = IsKnown(spell) or r[5] == ""
            local color, chance, estimated, y, g, gr, exact = ColorAndChance(spell, learn, skill)

            local cost, details = 0, {}
            if reag == "?" or reag == "" then
                cost = nil
            else
                for id, n in reag:gmatch("(%d+):(%d+)") do
                    id, n = tonumber(id), tonumber(n)
                    local c, src = BestCost(id)
                    local name = Objet(id)
                    if c then
                        if cost then cost = cost + c * n end
                        details[#details + 1] = string.format("%d x %s : %s (%s)", n, name, Money(c * n), src)
                    else
                        cost = nil
                        details[#details + 1] = string.format("%d x %s : prix inconnu", n, name)
                    end
                end
            end

            local name, sell = Objet(out)
            local hv = PrixHV(out)
            -- Marché mort (étude du marché : aucune vente depuis 12 h ou plus) : pas de vente à l'HV.
            local st = ns.MarketState and ns.MarketState(out)
            if st and st.etat == "mort" then hv = nil end
            local saleHV = hv and hv * qty * (1 - COMMISSION)
            local saleVendor = (sell or 0) * qty
            local sale, saleSrc = saleVendor, "marchand"
            if saleHV and saleHV > saleVendor then sale, saleSrc = saleHV, "HV" end
            local gain = cost and (sale - cost)

            list[#list + 1] = {
                spell = spell, out = out, name = name, learn = learn, known = known,
                color = color, chance = chance, estimated = estimated, y = y, g = g, gr = gr, exact = exact,
                cost = cost, sale = sale, saleSrc = saleSrc, gain = gain,
                -- Points espérés : orange = nombre de points de la recette ; jaune/vert = 1 x chance.
                multi = Multi(spell),
                points = (color == "optimal") and Multi(spell) or chance,
                perPoint = (gain and chance > 0) and (-gain / ((color == "optimal") and Multi(spell) or chance)) or nil, -- coût par point (négatif = rapporte)
                details = details, howTo = not known and HowToLearn(r) or nil,
                learnLabel = not known and LearnLabel(r) or nil,
                teach = r[7], hardToGet = not known and not Obtainable(r), r = r,
                src = r[5], trainerCost = r[6], prof = prof,
                vend = r[11] or "", repFaction = r[12] or 0, repRank = r[13] or 0,
                reag = reag, skill = skill,
            }
        end
    end
    return list
end

---------------------------------------------------------------------------
-- Lecture de la fenêtre du métier : niveau réel + couleur de chaque recette connue
---------------------------------------------------------------------------
local function ProfIDByName(name)
    for id, n in pairs(ns.METIERS or {}) do
        if n == name then return id end
    end
end

-- Fenêtre de métier MODERNE (celle de Forever, ouverte par K) : on lit directement chaque
-- recette par son numéro (C_TradeSkillUI). Couleur = relativeDifficulty (0 orange, 1 jaune,
-- 2 vert, 3 gris). (1re version : seulement l'ancienne fenêtre → couleurs jamais apprises.)
local DIFFICULTY = { [0] = "optimal", [1] = "medium", [2] = "easy", [3] = "trivial" }
-- Métier de chaque recette (numéro de sort → numéro de métier), d'après nos recettes.
local recipeProfID
local function ProfOfRecipe(spell)
    if not recipeProfID then
        recipeProfID = {}
        for _, r in ipairs(ns.RECETTES) do recipeProfID[r[2]] = r[1] end
    end
    return recipeProfID[spell]
end

local function CaptureModern()
    local T = C_TradeSkillUI
    if not (T and T.GetAllRecipeIDs and T.GetRecipeInfo) then return false end
    local diag = { source = "fenêtre moderne", date = date("%d/%m %H:%M") }
    EryAddonDB.lectureMetier = diag
    -- Niveau du métier ouvert, si le jeu le donne (sinon : relevé automatique des niveaux).
    for _, fn in ipairs({ "GetChildProfessionInfo", "GetBaseProfessionInfo" }) do
        if T[fn] then
            local ok, v = pcall(T[fn])
            if ok and type(v) == "table" and type(v.skillLevel) == "number" and v.skillLevel > 0
                and not issecret(v.skillLevel) then
                local name = (v.professionID and ns.METIERS[v.professionID])
                    or (v.parentProfessionID and ns.METIERS[v.parentProfessionID])
                    or v.parentProfessionName or v.professionName
                if name then liveSkill[name] = v.skillLevel end
                diag.infoMetier = tostring(name) .. " " .. v.skillLevel
                break
            end
        end
    end
    if ns.SaveLevels then pcall(ns.SaveLevels) end
    local ok, ids = pcall(T.GetAllRecipeIDs)
    if not ok or type(ids) ~= "table" then diag.erreur = "GetAllRecipeIDs : " .. tostring(ids) return false end
    diag.recettesFenetre, diag.apprises, diag.avecCouleur, diag.reconnues = #ids, 0, 0, 0
    for _, id in ipairs(ids) do
        local ok2, r = pcall(T.GetRecipeInfo, id)
        if ok2 and type(r) == "table" then
            if not diag.champs then
                -- Noms des informations données par le jeu (pour comprendre une API inconnue).
                local keys = {}
                for k, v in pairs(r) do keys[#keys + 1] = k .. "=" .. tostring(v) end
                table.sort(keys)
                diag.champs = table.concat(keys, ", ")
            end
            if r.learned then
                diag.apprises = diag.apprises + 1
                local color = DIFFICULTY[r.relativeDifficulty]
                local profID = ProfOfRecipe(id)
                local rank = profID and SkillOf(ns.METIERS[profID])
                if profID then diag.reconnues = diag.reconnues + 1 end
                if color and rank then
                    Observe(id, color, rank)
                    diag.avecCouleur = diag.avecCouleur + 1
                end
                if type(r.numSkillUps) == "number" then SetMulti(id, r.numSkillUps) end
            end
        end
    end
    if diag.avecCouleur > 0 then EryAddonDB.seuilsDate = date("%d/%m %H:%M") end
    return diag.avecCouleur > 0
end

local function CaptureTradeSkill()
    if CaptureModern() then return end
    if not (GetTradeSkillLine and GetNumTradeSkills and GetTradeSkillInfo and GetTradeSkillItemLink) then return end
    local profName, rank = GetTradeSkillLine()
    local profID = profName and ProfIDByName(profName)
    if not profID or not rank or issecret(rank) then return end
    liveSkill[profName] = rank
    local byOut = {}
    for _, r in ipairs(ns.RECETTES) do
        if r[1] == profID then
            byOut[r[3]] = byOut[r[3]] or {}
            table.insert(byOut[r[3]], r[2])
        end
    end
    for i = 1, GetNumTradeSkills() do
        local _, skillType, _, _, _, numSkillUps = GetTradeSkillInfo(i)
        if COLOR[skillType] then
            local link = GetTradeSkillItemLink(i)
            local itemID = link and tonumber(link:match("item:(%d+)"))
            for _, spell in ipairs((itemID and byOut[itemID]) or {}) do
                Observe(spell, skillType, rank)
                if type(numSkillUps) == "number" then SetMulti(spell, numSkillUps) end
                if C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo then
                    local ok, info = pcall(C_TradeSkillUI.GetRecipeInfo, spell)
                    if ok and type(info) == "table" and type(info.numSkillUps) == "number" then
                        SetMulti(spell, info.numSkillUps)
                    end
                end
            end
        end
    end
    EryAddonDB.seuilsDate = date("%d/%m %H:%M")
end

---------------------------------------------------------------------------
-- Affichage (plusieurs exemplaires : onglet de l'HV + fenêtre à part)
---------------------------------------------------------------------------
local ROWS, ROW_H = 15, 22
local panels = {}
local current -- métier affiché { id, name }


-- Métiers de fabrication du jeu (demande de Jérémie : voir aussi ceux qu'il n'a pas, pour choisir).
local CRAFTS = { 171, 197, 185, 129, 164, 165, 202, 333 }
-- Noms courts pour les onglets.
local SHORT = { [129] = "Secours.", [165] = "Cuir", [202] = "Ingé.", [333] = "Enchant." }

-- Tes métiers d'abord (learned = true), puis les autres métiers de fabrication (niveau 1).
local function MyProfessions()
    local result, seen = {}, {}
    local levels = EryAddonDB.niveaux and EryAddonDB.niveaux.metiers or {}
    for id, name in pairs(ns.METIERS or {}) do
        if (levels[name] or liveSkill[name]) and id ~= 182 and id ~= 393 and id ~= 356 then
            result[#result + 1] = { id = id, name = name, learned = true }
            seen[id] = true
        end
    end
    table.sort(result, function(a, b) return a.name < b.name end)
    local others = {}
    for _, id in ipairs(CRAFTS) do
        if not seen[id] and ns.METIERS and ns.METIERS[id] then
            others[#others + 1] = { id = id, name = ns.METIERS[id], learned = false }
        end
    end
    table.sort(others, function(a, b) return a.name < b.name end)
    for _, pr in ipairs(others) do result[#result + 1] = pr end
    return result
end

-- Niveau d'un métier ; un métier pas appris part du niveau 1.
local function LevelOf(pr)
    return (pr and SkillOf(pr.name)) or 1
end

-- Texte d'un onglet : « Alchimie 32 », « Forge » (pas appris).
local function TabLabel(pr)
    local name = SHORT[pr.id] or pr.name
    return pr.learned and (name .. " " .. (SkillOf(pr.name) or "?")) or name
end

-- Objets à étudier en PRIORITÉ sur le marché (EryAddon_HV.lua, StudyEntries) : tes ventes, puis les
-- objets de tes métiers principaux en propagation autour de ton niveau (voir Propagation), puis leurs
-- composants (400 au plus). secondaryOnly : Secourisme / Cuisine, étudiés en dernier.
function ns.MarketItems(secondaryOnly)
    local LIMIT = 400
    local ids, seen = {}, {}
    local function Add(id)
        if id and id > 0 and not seen[id] and #ids < LIMIT then seen[id] = true; ids[#ids + 1] = id end
    end
    -- 1. Ce que tu as mis en vente ou vendu (suivi de tes ventes).
    local mv = EryAddonDB.mesVentes
    if mv then
        for _, src in ipairs({ mv.annonces or {}, mv.faits or {}, mv.ventesSansCourrier or {} }) do
            for _, f in ipairs(src) do Add(f.id) end
        end
    end
    -- 2. Tes métiers PRINCIPAUX d'abord (Jérémie : « le Secourisme et la Cuisine, on s'en moque ») :
    --    objets fabriqués encore utiles (pas gris), puis leurs composants, puis le reste ;
    --    les métiers secondaires viennent après.
    local SECONDAIRE = { [129] = true, [185] = true, [356] = true }
    local main, second, level = {}, {}, {}
    for _, pr in ipairs(MyProfessions()) do
        if pr.learned then
            if SECONDAIRE[pr.id] then second[pr.id] = CapOf(pr.name) else main[pr.id] = CapOf(pr.name) end
            level[pr.id] = LevelOf(pr)
        end
    end
    -- Recettes des métiers PRINCIPAUX en « propagation » autour de ton niveau (demande de Jérémie, 08/11) :
    -- chaque métier part de SON niveau et s'en éloigne d'un cran à la fois, vers le haut ET vers le bas
    -- (distance = |niveau d'apprentissage − ton niveau|) ; tous tes métiers avancent en même temps, et à
    -- distance égale le métier le plus monté passe d'abord, puis la recette en dessous de ton niveau.
    local function Propagation(profs)
        local ranks = {}
        for id in pairs(profs) do ranks[#ranks + 1] = id end
        table.sort(ranks, function(a, b)
            if (level[a] or 1) ~= (level[b] or 1) then return (level[a] or 1) > (level[b] or 1) end
            return a < b
        end)
        local rankOf = {}
        for i, id in ipairs(ranks) do rankOf[id] = i end
        local list = {}
        for _, r in ipairs(ns.RECETTES or {}) do
            if rankOf[r[1]] then
                local diff = (r[4] or 1) - (level[r[1]] or 1)
                list[#list + 1] = { r = r, d = math.abs(diff), up = diff > 0, rank = rankOf[r[1]] }
            end
        end
        table.sort(list, function(a, b)
            if a.d ~= b.d then return a.d < b.d end
            if a.rank ~= b.rank then return a.rank < b.rank end
            if a.up ~= b.up then return not a.up end
            return a.r[2] < b.r[2]
        end)
        return list
    end
    if secondaryOnly then
        -- Secourisme, Cuisine : en DERNIER, après tout le reste de l'HV (ordre voulu par Jérémie).
        ids, seen = {}, {}
        for _, r in ipairs(ns.RECETTES or {}) do
            local cap = second[r[1]]
            if cap and r[4] <= cap then Add(r[3]) end
        end
        return ids
    end
    local around = Propagation(main)
    for _, x in ipairs(around) do Add(x.r[3]) end -- les objets fabriqués, du plus proche au plus loin
    for _, x in ipairs(around) do                 -- puis leurs composants, dans le même ordre
        local _, _, reag = RecipeData(x.r[2])
        for id in (reag or ""):gmatch("(%d+):%d+") do Add(tonumber(id)) end
    end
    return ids
end

local function Rows()
    if not current then return {} end
    local skill = LevelOf(current)
    local all, rows = Compute(current.id, skill), {}
    if EryAddonDB.jobsMonter then
        -- Orange et jaune ; le VERT seulement s'il rapporte de l'or (règle de Jérémie :
        -- on arrête une recette quand elle devient verte, sauf si elle est rentable).
        for _, e in ipairs(all) do
            if e.chance > 0 and (e.color ~= "easy" or (e.gain and e.gain > 0)) then rows[#rows + 1] = e end
        end
        -- Tri par gain aussi (demande de Jérémie) ; la case ne fait que filtrer.
        table.sort(rows, function(a, b)
            if (a.gain ~= nil) ~= (b.gain ~= nil) then return a.gain ~= nil end
            if a.gain and b.gain and a.gain ~= b.gain then return a.gain > b.gain end
            return a.chance > b.chance
        end)
    else
        for _, e in ipairs(all) do
            if e.gain and e.gain > 0 then rows[#rows + 1] = e end
        end
        table.sort(rows, function(a, b) return a.gain > b.gain end)
    end
    return rows
end

---------------------------------------------------------------------------
-- Fiche d'une recette : combien en fabriquer, et les composants à acheter
---------------------------------------------------------------------------

-- Ce qu'on a : sacs + achats de l'HV encore au courrier (EryAddon_HV.lua, ns.Owned).
local function ItemCount(itemID)
    if ns.Owned then return (ns.Owned(itemID)) end
    local count = (C_Item and C_Item.GetItemCount) or GetItemCount
    return (count and count(itemID)) or 0
end
local function MailCount(itemID)
    if not ns.Owned then return 0 end
    local _, mail = ns.Owned(itemID)
    return mail or 0
end


-- Nombre de fabrications pour monter jusqu'au VERT (on s'arrête au vert), sans dépasser le
-- maximum actuel du métier (ex. 75 : au-delà, il faut d'abord le maître) ;
-- recette déjà verte (affichée seulement si rentable) : 1 à la fois.
local function CraftsPlanned(e)
    if e.color == "easy" or e.color == "trivial" then return 1, "recette verte rentable : 1 à la fois", nil end
    local cap = CapOf(ns.METIERS[e.prof] or "")
    local stop = math.min(e.g, cap)
    if stop <= e.skill then return 1, string.format("tu es au maximum (%d) : va voir ton maître", cap), nil end
    local crafts = 0
    for s = e.skill, stop - 1 do
        if s < e.y then
            crafts = crafts + 1 / math.max(1, e.multi)
        else
            local ch = (e.gr - s) / (e.gr - e.y)
            if ch <= 0 then break end
            crafts = crafts + 1 / ch
        end
    end
    local n = math.min(200, math.max(1, math.ceil(crafts)))
    if stop < e.g then
        return n, string.format("~%d fabrications pour monter de %d à %d (ton maximum ; elle passe verte à %d)",
            n, e.skill, stop, e.g), stop
    end
    return n, string.format("~%d fabrications pour monter de %d à %d (passage au vert)", n, e.skill, e.g), stop
end

-- Achat d'un composant : à l'HV (fenêtre ouverte) ou chez un marchand (fenêtre ouverte).
local function BuyFromMerchant(itemID, qty)
    if not (MerchantFrame and MerchantFrame:IsShown() and GetMerchantNumItems and GetMerchantItemID) then return false end
    for i = 1, GetMerchantNumItems() do
        if GetMerchantItemID(i) == itemID then
            local maxStack = (GetMerchantItemMaxStack and GetMerchantItemMaxStack(i)) or 20
            local left = qty
            while left > 0 do
                local k = math.min(left, maxStack)
                BuyMerchantItem(i, k)
                left = left - k
            end
            ns.Msg(string.format("acheté chez le marchand : %d x %s.", qty, Objet(itemID)))
            return true
        end
    end
    return false
end

-- Achat : là OÙ TU ES (demande de Jérémie : « je veux pouvoir décider d'acheter à l'HV si j'ai la flemme
-- de marcher ») : fenêtre d'un marchand ouverte → chez lui ; HV ouvert → à l'HV, même si le marchand est
-- moins cher (les deux prix sont affichés sur la ligne). Ni l'un ni l'autre : on rappelle les deux prix.
-- part = 2 ou 4 : boutons « 1/2 » et « 1/4 » (demande de Jérémie) : seulement cette part de ce qui
-- manque, arrondie au-dessus (43 → 22 ou 11).
local function BuyLine(l, part)
    local missing = math.max(0, l.need - l.have)
    if missing == 0 then ns.Msg(l.name .. " : tu en as déjà assez.") return end
    if part then missing = math.ceil(missing / part) end
    if MerchantFrame and MerchantFrame:IsShown() and BuyFromMerchant(l.id, missing) then return end
    local hv = PrixHV(l.id)
    if AuctionHouseFrame and AuctionHouseFrame:IsShown() then
        if l.kind == "recipe" then
            if ns.BuyUnique then ns.BuyUnique(l.id, hv or l.unit, l.name) end
        elseif ns.BuyReagent then
            ns.BuyReagent(l.id, missing, hv or l.unit, l.name)
        end
        return
    end
    local vendor = PrixMarchand(l.id) or ((l.src or ""):find("marchand") and l.unit) or nil
    ns.Msg(string.format("%s : %d à acheter. HV : %s, marchand : %s. Ouvre l'HV ou la fenêtre d'un marchand.",
        l.name, missing, hv and (Money(hv) .. " pièce") or "pas en vente",
        vendor and (Money(vendor) .. " pièce") or "inconnu"))
end

-- Ce qu'il faut pour la recette choisie, en phrases simples (fiche de droite) :
-- { text, detail, status, buy = article à acheter (pour BuyLine), indent }
-- Prix pour apprendre la recette si on ne la connaît pas (la façon la moins chère : maître, patron
-- chez un marchand, HV), 0 si connue ; 2e valeur : où (« maître », « marchand », « HV »).
local function EntryLearnCost(e)
    if e.known or not e.r then return 0 end
    local o = LearnOptions(e.r)
    return o.cost or 0, o.best
end

-- « Mage royal  4/16 » : ce que tu as / ce qu'il faut (vert quand c'est complet), demande de
-- Jérémie ; ce qui est encore au courrier (acheté à l'HV) compte, et c'est précisé.
local OK_ICON = "|TInterface\\RAIDFRAME\\ReadyCheck-Ready:14:14|t"
-- « 4/16 » seul (colonne à part dans la fiche : jamais coupé, demande de Jérémie).
local function CountStr(have, need)
    local color = have >= need and "|cff5cffb0" or (have > 0 and "|cffffcc66" or "|cffd8f4ff")
    return string.format("%s%d/%d|r", color, math.min(have, need), need)
end

local function CountText(name, have, need)
    local color = have >= need and "|cff5cffb0" or (have > 0 and "|cffffcc66" or "|cffd8f4ff")
    return string.format("%s  %s%d/%d|r", name, color, math.min(have, need), need)
end
local function MailNote(id)
    local mail = MailCount(id)
    return mail > 0 and string.format("dont %d au courrier", mail) or nil
end

-- Fiche de la recette choisie (maquette validée par Jérémie, 07/11) : une ligne par composant avec
-- PAR FABRICATION, SUR TOI, IL FAUT (pour l'objectif), MANQUE, et en dessous le prix (les deux
-- sources) + bouton Acheter ; ce qui se fabrique moins cher est détaillé (ses composants en retrait).
-- info = { maintenant = fabrications possibles avec ce que tu as, bloque = ce qui manque pour la 1re,
--          apres = fabrications possibles après « Tout acheter » (nil si quelque chose est introuvable),
--          etapes = « 1. Achète … 2. Fabrique … 3. Fabrique … » }
local function PriceLine(id, missing, buy, src)
    if missing <= 0 then return "|cff5cffb0tu as tout|r" end
    if not buy then return "|cffff7373introuvable à l'HV et chez les marchands relevés|r" end
    return Money(buy * missing) .. " |cff5f8a99" .. src .. "|r" .. OtherPriceText(id, src, missing)
end

local function Needs(e)
    local n, why, stop = CraftsPlanned(e)
    local list = {}
    local info = { maintenant = nil, bloque = nil, apres = n, etapes = "" }
    local achats, fabrications = {}, {}

    -- La recette elle-même, si tu ne la connais pas encore : en premier.
    if not e.known then
        local cost, where = EntryLearnCost(e)
        local teach = (e.teach and e.teach > 0) and e.teach or nil
        local label = teach and Objet(teach) or "Recette"
        local row = { recipe = true, id = teach, name = label, per = "", need = 1 }
        if teach and ItemCount(teach) > 0 then
            row.have, row.missing = 1, 0
            row.price = "|cff5cffb0dans tes sacs : clic droit dessus pour l'apprendre|r"
        elseif where == "maître" then
            row.have, row.missing = 0, 1
            local metier = (ns.METIERS[e.prof] or "métier"):lower()
            local de = metier:match("^[aeiouyéèêàâîôû]") and "d'" or "de "
            row.price = Money(cost) .. " |cff5f8a99chez ton maître " .. de .. metier .. "|r"
            info.apprendre = "Apprends la recette chez ton maître " .. de .. metier
        elseif where then
            row.have, row.missing = 0, 1
            row.price = (cost > 0 and Money(cost) or "prix ?") .. " |cff5f8a99" .. where .. "|r"
            row.buy = { kind = "recipe", id = teach, need = 1, have = 0, name = label, unit = cost, src = where }
            row.cost = cost
            achats[#achats + 1] = "la recette"
        else
            local price = e.r and LearnOptions(e.r).vendorPrice
            local repLocked = (e.repFaction or 0) > 0 and not RepOK({ [12] = e.repFaction, [13] = e.repRank })
            row.have, row.missing = 0, 1
            row.price = (price and (Money(price) .. " |cff5f8a99marchand|r") or "|cffff7373pas en vente|r")
                .. (repLocked and " |cffff9933· réputation d'abord|r" or "")
            info.apres = nil
        end
        list[#list + 1] = row
        if row.missing > 0 then info.maintenant, info.bloque = 0, "recette à apprendre" end
    end

    if e.reag and e.reag ~= "?" and e.reag ~= "" then
        for id, q in e.reag:gmatch("(%d+):(%d+)") do
            id, q = tonumber(id), tonumber(q)
            local need, have = q * n, ItemCount(id)
            local missing = math.max(0, need - have)
            local name = Objet(id)
            -- Fabrications possibles tout de suite : le composant le plus juste décide.
            local possible = math.floor(have / q)
            if not info.maintenant or possible < info.maintenant then
                info.maintenant = possible
                info.bloque = possible == 0 and string.format("il manque %d %s pour la 1re", q - have, name) or nil
            end
            local note = MailNote(id)
            local buy, src = UnitCost(id)
            local craft, spell = CraftUnitCost(id)
            if missing > 0 and craft and (not buy or craft < buy) then
                local _, made, subReag = RecipeData(spell)
                local toMake = math.ceil(missing / made)
                list[#list + 1] = { id = id, name = name, per = q, have = have, need = need, missing = missing,
                    price = string.format("|cff5cffb0à fabriquer : %d fabrication%s (moins cher)|r", toMake,
                        toMake > 1 and "s" or "") .. (note and ("  |cff5f8a99" .. note .. "|r") or "") }
                fabrications[#fabrications + 1] = string.format("%d %s", missing, name)
                for sid, sq in subReag:gmatch("(%d+):(%d+)") do
                    sid, sq = tonumber(sid), tonumber(sq)
                    local sneed, shave = sq * toMake, ItemCount(sid)
                    local smiss = math.max(0, sneed - shave)
                    local sbuy, ssrc = UnitCost(sid)
                    list[#list + 1] = {
                        indent = true, id = sid, name = Objet(sid), per = sq, have = shave, need = sneed, missing = smiss,
                        price = PriceLine(sid, smiss, sbuy, ssrc),
                        buy = (smiss > 0 and sbuy) and { kind = "buy", id = sid, need = smiss, have = 0, name = Objet(sid),
                            unit = sbuy, src = ssrc } or nil,
                        cost = (smiss > 0 and sbuy) and sbuy * smiss or 0,
                    }
                    if smiss > 0 then
                        if sbuy then achats[#achats + 1] = string.format("%d %s", smiss, Objet(sid)) else info.apres = nil end
                    end
                end
            else
                list[#list + 1] = {
                    id = id, name = name, per = q, have = have, need = need, missing = missing,
                    price = PriceLine(id, missing, buy, src) .. ((missing == 0 and note) and ("  |cff5f8a99" .. note .. "|r") or ""),
                    buy = (missing > 0 and buy) and { kind = "buy", id = id, need = missing, have = 0, name = name,
                        unit = buy, src = src } or nil,
                    cost = (missing > 0 and buy) and buy * missing or 0,
                }
                if missing > 0 then
                    if buy then achats[#achats + 1] = string.format("%d %s", missing, name) else info.apres = nil end
                end
            end
        end
    end
    info.maintenant = info.maintenant or 0

    -- Étapes, dans l'ordre : acheter, fabriquer les composants, fabriquer l'objet.
    local steps, k = {}, 0
    if info.apprendre then
        k = k + 1
        steps[#steps + 1] = string.format("%d. %s", k, info.apprendre)
    end
    if achats[1] then
        k = k + 1
        steps[#steps + 1] = string.format("%d. Achète %s", k, table.concat(achats, ", "))
    end
    for _, f in ipairs(fabrications) do
        k = k + 1
        steps[#steps + 1] = string.format("%d. Fabrique %s", k, f)
    end
    k = k + 1
    steps[#steps + 1] = string.format("%d. Fabrique %d %s", k, n, e.name)
    info.etapes = table.concat(steps, "   ")
    return list, n, why, info, stop
end

ns._Needs = Needs -- (test hors jeu)
ns._Compute = function(...) return Compute(...) end

local selectedSpell -- recette affichée dans la fiche

local SalesText

-- « Se vend : env. 3 par jour à l'HV (12 en vente) », d'après l'écoulement entre deux scans
-- (EryAddon_HV.lua). En rouge si on en fabriquerait nettement plus que ce qui part en 3 jours.
SalesText = function(itemID, planned)
    -- Étude du marché (annonces suivies une à une) quand on l'a.
    local st = ns.MarketState and ns.MarketState(itemID)
    if st and st.etat ~= "inconnu" then
        local function Num(v)
            return v >= 10 and string.format("%d", math.floor(v + 0.5)) or (string.format("%.1f", v):gsub("%.", ","))
        end
        -- Info ancienne (rien de récent) : on la montre quand même, avec sa date.
        local old = st.ancien and (" |cff5f8a99(relevé du " .. date("%d/%m", st.ancien) .. ")|r") or ""
        local days = st.heures >= 48 and string.format("%d jours", math.floor(st.heures / 24 + 0.5))
            or string.format("%d h", math.floor(st.heures + 0.5))
        if st.etat == "mort" then
            return string.format("|cffff7373Marché mort : aucune vente en %s|r |cff5f8a99(%d en vente%s)|r", days,
                st.enVente, st.dort >= 24 and string.format(", mêmes annonces depuis %d jours",
                    math.floor(st.dort / 24 + 0.5)) or "") .. old
        end
        local color = st.etat == "actif" and "|cff5cffb0" or "|cffff9933"
        if st.etat == "actif" and planned and planned > st.parJour * 3 then color = "|cffff9933" end
        -- Fourchette quand une partie des disparitions est incertaine (vendue ou expirée ?).
        local amount = (st.max - st.min >= 0.5) and (Num(st.min) .. " à " .. Num(st.max)) or Num(st.parJour)
        return string.format("%sMarché %s : %s vente%s par jour|r |cff5f8a99(%d en vente, %d vendeur%s)|r",
            color, st.etat, amount, st.max >= 2 and "s" or "", st.enVente, st.vendeurs,
            st.vendeurs > 1 and "s" or "") .. old
    end
    local listed = EryAddonDB.hvPrix and EryAddonDB.hvPrix.quantites and EryAddonDB.hvPrix.quantites[itemID] or 0
    local perDay = ns.HVSalesPerDay and ns.HVSalesPerDay(itemID)
    if not perDay then
        return "|cff5f8a99Ventes à l'HV : pas encore assez de relevés|r"
    end
    local amount = perDay >= 10 and string.format("%d", math.floor(perDay + 0.5))
        or (string.format("%.1f", perDay):gsub("%.", ","))
    local color = "|cffd8f4ff"
    if perDay < 0.2 then color = "|cffff7373"
    elseif planned and planned > perDay * 3 then color = "|cffff9933" end
    return string.format("%sSe vend : env. %s par jour à l'HV|r |cff5f8a99(%d en vente)|r", color,
        perDay < 0.2 and "0" or amount, listed)
end

local function RefreshPanel(p)
    if not p:IsShown() then return end
    local H = ns.Holo
    if ns.SaveLevels then pcall(ns.SaveLevels) end
    local profs = MyProfessions()
    if current then
        for _, pr in ipairs(profs) do if pr.id == current.id then current = pr end end
    else
        current = profs[1]
    end
    for i, b in ipairs(p.profButtons) do
        local pr = profs[i]
        if pr then
            b.prof = pr
            b:SetText(TabLabel(pr))
            if b.SetStyle then b:SetStyle((current and current.id == pr.id) and "solid" or "muted") end
            b:Show()
        else
            b:Hide()
        end
    end
    p.check:SetChecked(EryAddonDB.jobsMonter == true)

    local rows = Rows()
    -- GAIN = par fabrication (ne bouge pas quand tu fabriques) ; RECETTE = son prix, à part
    -- (Jérémie : un total sur « N fabrications » variait à chaque fabrication et cachait le gain).
    -- Le tri reste celui de Rows() : gain par fabrication, ou coût par point (case « Monter »).
    for _, e in ipairs(rows) do
        e.n = CraftsPlanned(e)
        e.learnCost = EntryLearnCost(e)
    end
    p.status:SetText(current and string.format("%s : %s   ·   prix HV du %s", current.name,
        current.learned and ("niveau " .. LevelOf(current)) or "|cffff9933pas appris : calcul depuis le niveau 1|r",
        EryAddonDB.hvPrix and EryAddonDB.hvPrix.date or "aucun scan")
        or "Aucun métier relevé : fais un /reload.")

    -- Liste de gauche : nom (couleur du jeu), chance, gain par fabrication.
    FauxScrollFrame_Update(p.scroll, #rows, ROWS, ROW_H)
    local offset = FauxScrollFrame_GetOffset(p.scroll)
    local selected
    for _, e in ipairs(rows) do if e.spell == selectedSpell then selected = e end end
    if not selected then selected = rows[1]; selectedSpell = selected and selected.spell end
    for i = 1, ROWS do
        local row, e = p.rows[i], rows[offset + i]
        row.entry = e
        if e then
            local c = COLOR[e.color] or COLOR.trivial
            row.name:SetText(e.name .. (e.known and "" or (e.hardToGet and " |cffff9933*|r" or " |cff5f8a99*|r"))
                .. (ReuseText(e) and " |TInterface\\Buttons\\UI-RefreshButton:12:12|t" or ""))
            row.name:SetTextColor(c[1], c[2], c[3])
            row.chance:SetText(string.format("%d %%", math.floor(e.chance * 100 + 0.5)))
            row.chance:SetTextColor(c[1], c[2], c[3])
            row.value:SetText(e.gain and ((e.gain >= 0 and "|cff5cffb0+" or "|cffff7373-") .. Money(math.abs(e.gain))
                .. "|r") or "?")
            row.recipe:SetText((e.learnCost or 0) > 0 and ("|cffff9933" .. Money(e.learnCost) .. "|r") or "")
            row.icon:SetTexture((C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(e.out)) or nil)
            row.selected:SetShown(e == selected)
            -- Données de l'objet demandées d'avance : son info-bulle (stats) sera prête au survol.
            if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, e.out) end
            row:Show()
        else
            row:Hide()
        end
    end
    p.empty:SetShown(#rows == 0 and current ~= nil)
    p.headGain:SetText("GAIN")

    -- Fiche de droite : la recette choisie.
    local f = p.card
    f.item = selected
    if not selected then f:Hide() return end
    f:Show()
    local e = selected
    local c = COLOR[e.color] or COLOR.trivial
    f.icon:SetTexture((C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(e.out)) or nil)
    f.title:SetText(e.name)
    f.title:SetTextColor(c[1], c[2], c[3])
    if e.known then
        f.learn:SetText(string.format("%s · %d %%%s", COLOR_NAME[e.color] or "?", math.floor(e.chance * 100 + 0.5),
            (e.color == "optimal" and e.multi > 1) and (" · " .. e.multi .. " points") or ""))
    else
        f.learn:SetText("|cffff9933À apprendre : " .. (e.learnLabel or "?") .. "|r")
    end
    f.gain:SetText(e.gain and ((e.gain >= 0 and "|cff5cffb0+" or "|cffff7373-") .. Money(math.abs(e.gain)) .. "|r") or "?")

    local needs, n, why, info, stop = Needs(e)
    f.needs = needs
    -- Recette à acheter : remboursée après combien de fabrications ; sinon réputation ou réutilisation.
    local learnCost = e.learnCost or EntryLearnCost(e)
    local payback
    if learnCost > 0 then
        payback = (e.gain and e.gain > 0)
            and string.format("|cffff9933Recette %s : remboursée après %d fabrications|r", Money(learnCost),
                math.ceil(learnCost / e.gain))
            or string.format("|cffff7373Recette %s : jamais remboursée|r", Money(learnCost))
    end
    local reuse = ReuseText(e)
    f.rep:SetText(((not e.known) and RepLine(e)) or payback or (reuse and ("|cff39d0ff" .. reuse .. "|r")) or "")
    local mine = ns.MySales and ns.MySales(e.out)
    if mine and mine.vendus > 0 then
        local delai = mine.delaiMoyen and (mine.delaiMoyen < 1 and string.format("%d min", math.floor(mine.delaiMoyen * 60 + 0.5))
            or string.format("%.0f h", mine.delaiMoyen)) or "?"
        f.sales:SetText(string.format("|cffd8f4ffTes ventes : %d vendus, en %s en moyenne, %s net / u|r%s%s",
            mine.vendus, delai, Money(mine.net / mine.vendus),
            mine.expires > 0 and string.format("  |cffff9933%d expirés|r", mine.expires) or "",
            mine.enCours > 0 and string.format("  |cff5f8a99(%d en vente)|r", mine.enCours) or ""))
    else
        f.sales:SetText(SalesText(e.out, n))
    end

    -- Les 3 chiffres.
    local b1, b2, b3 = f.boxes[1], f.boxes[2], f.boxes[3]
    b1.value:SetText(info.maintenant >= n and ("|cff5cffb0" .. info.maintenant .. "|r")
        or (info.maintenant > 0 and ("|cffffcc66" .. info.maintenant .. "|r") or ("|cffff7373" .. info.maintenant .. "|r")))
    b1.sub:SetText(info.bloque or "avec ce que tu as")
    b2.value:SetText(tostring(n))
    b2.sub:SetText((e.color == "easy" or e.color == "trivial") and "rentable, 1 à la fois"
        or (stop and string.format("%d à %d", e.skill, stop)) or why)
    if info.apres then
        b3.value:SetText("|cff5cffb0" .. info.apres .. "|r")
        local total = e.gain and (e.gain * n - learnCost)
        b3.sub:SetText(total and ((total >= 0 and "gain env. +" or "coût env. ") .. Money(math.abs(total))) or "")
    else
        b3.value:SetText("|cffff7373?|r")
        b3.sub:SetText("un élément est introuvable")
    end

    -- Tableau des composants.
    local toPay = 0
    for _, nd in ipairs(needs) do toPay = toPay + (nd.cost or 0) end
    local function Num(v, color) return v and ((color or "") .. tostring(v) .. (color and "|r" or "")) or "" end
    for i, line in ipairs(f.lines) do
        local nd = needs[i]
        line.need = nd
        if nd then
            local indent = nd.indent and 18 or 6
            line.text:SetPoint("TOPLEFT", indent, -2)
            line.price:SetPoint("BOTTOMLEFT", indent, 3)
            line.text:SetText(nd.indent and ("|cffb8d8e6" .. nd.name .. "|r") or nd.name)
            local enough = (nd.have or 0) >= (nd.need or 0)
            line.cols[1]:SetText(Num(nd.missing, (nd.missing or 0) > 0 and "|cffff7373" or "|cff5cffb0"))
            line.cols[2]:SetText(Num(nd.need))
            line.cols[3]:SetText(Num(nd.have, enough and "|cff5cffb0" or ((nd.have or 0) > 0 and "|cffffcc66" or nil)))
            line.cols[4]:SetText(Num(nd.per ~= "" and nd.per or nil))
            line.price:SetText(nd.price or "")
            line.buy:SetShown(nd.buy ~= nil)
            local miss = nd.buy and nd.buy.kind ~= "recipe" and math.max(0, (nd.buy.need or 0) - (nd.buy.have or 0)) or 0
            line.half:SetShown(miss >= 2)
            line.quarter:SetShown(miss >= 4)
            line:Show()
        else
            line:Hide()
        end
    end
    local hidden = #needs - #f.lines
    f.more:SetText(hidden > 0 and string.format("… et %d autre%s ligne%s (survole « Tout acheter »)", hidden,
        hidden > 1 and "s" or "", hidden > 1 and "s" or "") or "")
    f.steps:SetPoint("TOPLEFT", 10, -140 - #f.lines * (f.rowStep or 36) - (hidden > 0 and 14 or 2))
    f.steps:SetText("|cff39d0ffÉTAPES|r   " .. info.etapes)
    f.buyAll:SetText(toPay > 0 and ("Tout acheter (" .. Money(toPay) .. ")") or "Rien à acheter")
    f.buyAll:SetEnabled(toPay > 0)
end


local function RefreshAll()
    for _, p in ipairs(panels) do RefreshPanel(p) end
    if ns.GuideRefresh then ns.GuideRefresh() end -- le guide aussi (défini plus bas)
end
ns.JobsRefresh = RefreshAll -- appelé après un achat de composant (EryAddon_HV.lua)

local function ShowTooltip(row)
    local e = row.entry
    if not e then return end
    local tip = GameTooltip
    tip:SetOwner(row, "ANCHOR_RIGHT")
    -- L'objet fabriqué, comme dans le jeu (nom, stats, prix des autres add-ons).
    if e.out and tip.SetItemByID then pcall(tip.SetItemByID, tip, e.out) end
    if tip:NumLines() == 0 then
        tip:AddLine(e.name, 1, 1, 1)
    else
        tip:AddLine(" ")
    end
    tip:AddLine("|cff39d0ffEryAddon|r : " .. e.name, 1, 1, 1)
    if e.multi > 1 then
        tip:AddLine(string.format("Donne %d points par fabrication tant qu'elle est orange", e.multi), 1, 0.5, 0.25)
    end
    -- « ≈ » est absent de la police du jeu : on écrit « env. ».
    local function T(v, sure) return sure and tostring(v) or ("env. " .. v) end
    local ex = e.exact or {}
    tip:AddLine(SalesText(e.out), 1, 1, 1, true)
    local reuse = ReuseText(e)
    if reuse then tip:AddLine(reuse, 0.22, 0.82, 1, true) end
    tip:AddLine(string.format("Seuils : jaune %s, vert %s, gris %s (apprentissage %d)",
        T(e.y, ex.y), T(e.g, ex.g), T(e.gr, ex.gr), e.learn), 0.8, 0.8, 0.8)
    if not e.known then AddLearnLines(e) end
    tip:AddLine(" ")
    for _, d in ipairs(e.details) do tip:AddLine(d, 0.9, 0.9, 0.9) end
    tip:AddLine(" ")
    tip:AddLine("Coût : " .. Money(e.cost), 1, 1, 1)
    tip:AddLine("Revente (" .. e.saleSrc .. ") : " .. Money(e.sale), 1, 1, 1)
    if e.gain then
        tip:AddLine("Bilan par fabrication : " .. (e.gain >= 0 and "+" or "") .. Money(e.gain),
            e.gain >= 0 and 0.4 or 1, e.gain >= 0 and 1 or 0.4, 0.4)
    end
    if (e.learnCost or 0) > 0 then
        tip:AddLine((e.gain and e.gain > 0)
            and string.format("Recette %s : remboursée après %d fabrications", Money(e.learnCost),
                math.ceil(e.learnCost / e.gain))
            or string.format("Recette %s : jamais remboursée", Money(e.learnCost)), 1, 0.6, 0.2)
    end
    tip:Show()
end

-- Appuyer / relâcher MAJ pendant le survol d'une recette : l'info-bulle se redessine (pour
-- déplier ou replier la liste des monstres qui lâchent la recette).
local shiftFrame = CreateFrame("Frame")
pcall(shiftFrame.RegisterEvent, shiftFrame, "MODIFIER_STATE_CHANGED")
shiftFrame:SetScript("OnEvent", function()
    if not GameTooltip:IsShown() then return end
    local owner = GameTooltip:GetOwner()
    if owner and owner.entry and owner.eryJobsRow then ShowTooltip(owner) end
end)

-- Construit le contenu dans un cadre : parent = fenêtre de l'HV (onglet) ou UIParent (fenêtre à part).
-- Présentation (refonte demandée par Jérémie, « j'y comprends rien ») : liste des recettes à gauche
-- (nom, chance, gain), FICHE de la recette choisie à droite (plan, ce qui manque, tout acheter).
function ns.CreateJobsPanel(parent)
    local embedded = parent ~= UIParent
    local H = ns.Holo
    local p
    if embedded then
        p = CreateFrame("Frame", "EryJobsTab", parent)
        p:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, -28)
        p:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -8, 28)
        H.Skin(p)
    else
        p = H.Window("EryJobsFrame", 980, 600, "Métiers", "Monter ses métiers")
        p:SetPoint("CENTER", 150, 0)
    end
    p:EnableMouse(true)

    p.profButtons = {}
    for i = 1, 8 do
        local b = H.Button(p, "", 90, 22, "muted")
        b:SetPoint("TOPLEFT", 12 + (i - 1) * 94, -32)
        b:SetScript("OnClick", function(self) current = self.prof; selectedSpell = nil; RefreshAll() end)
        p.profButtons[i] = b
    end
    p.check = H.Check(p, "Monter le métier (seulement les recettes qui font gagner des points)")
    p.check:SetPoint("TOPLEFT", 14, -64)
    p.check:SetScript("OnClick", function(self)
        EryAddonDB.jobsMonter = self:GetChecked() and true or false
        RefreshAll()
    end)
    p.status = H.Text(p, 12, H.DIM)
    p.status:SetPoint("TOPLEFT", 14, -86)

    -- Liste de gauche.
    local head = H.Text(p, 11, H.DIM)
    head:SetPoint("TOPLEFT", 14, -102)
    head:SetText("NOM")

    p.scroll = CreateFrame("ScrollFrame", nil, p, "FauxScrollFrameTemplate")
    p.scroll:SetPoint("TOPLEFT", 10, -116)
    -- Onglet de l'HV (largeur fixe) : liste plus étroite pour laisser la place à la fiche.
    p.scroll:SetSize(embedded and 320 or 400, ROWS * ROW_H)
    -- En-têtes alignés sur les colonnes (de droite à gauche : recette 58, gain 66, chance 38).
    local function Head(text, right)
        local fs = H.Text(p, 11, H.DIM)
        fs:SetPoint("BOTTOMRIGHT", p.scroll, "TOPRIGHT", -right, 3)
        fs:SetText(text)
        return fs
    end
    Head("RECETTE", 4)
    p.headGain = Head("GAIN", 66)
    Head("CHANCE", 136)
    p.scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_H, function() RefreshPanel(p) end)
    end)
    p.rows = {}
    for i = 1, ROWS do
        local row = CreateFrame("Button", nil, p)
        row:SetHeight(ROW_H)
        row:SetPoint("TOPLEFT", p.scroll, "TOPLEFT", 0, -(i - 1) * ROW_H)
        row:SetPoint("RIGHT", p.scroll, "RIGHT", 0, 0)
        H.RowHighlight(row)
        local rowBg = row:CreateTexture(nil, "BACKGROUND")
        rowBg:SetPoint("TOPLEFT", 0, -1)
        rowBg:SetPoint("BOTTOMRIGHT", 0, 1)
        rowBg:SetColorTexture(H.ROW[1], H.ROW[2], H.ROW[3], 1)
        row.selected = row:CreateTexture(nil, "BORDER")
        row.selected:SetAllPoints()
        row.selected:SetColorTexture(H.CYAN[1], H.CYAN[2], H.CYAN[3], 0.18)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(18, 18)
        row.icon:SetPoint("LEFT", 2, 0)
        -- Prix de la recette à acheter (vide si tu la connais).
        row.recipe = H.Text(row, 12, H.TEXT)
        row.recipe:SetPoint("RIGHT", -4, 0)
        row.recipe:SetWidth(58)
        row.recipe:SetJustifyH("RIGHT")
        row.value = H.Text(row, 12, H.TEXT)
        row.value:SetPoint("RIGHT", row.recipe, "LEFT", -4, 0)
        row.value:SetWidth(66)
        row.value:SetJustifyH("RIGHT")
        row.chance = H.Text(row, 12, H.SOFT)
        row.chance:SetPoint("RIGHT", row.value, "LEFT", -4, 0)
        row.chance:SetWidth(38)
        row.chance:SetJustifyH("RIGHT")
        row.name = H.Text(row, 13, H.TEXT)
        row.name:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
        row.name:SetPoint("RIGHT", row.chance, "LEFT", -6, 0)
        row.eryJobsRow = true
        row:SetScript("OnClick", function(self)
            if not self.entry then return end
            -- Maj+clic : lien de l'objet fabriqué dans le chat (le sort si rien n'est fabriqué).
            if ns.ShiftLink(self.entry.out, self.entry.spell) then return end
            selectedSpell = self.entry.spell; RefreshAll()
        end)
        row:SetScript("OnEnter", function(self) if self.entry then ShowTooltip(self) end end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        p.rows[i] = row
    end
    p.empty = H.Text(p, 13, H.DIM)
    p.empty:SetPoint("TOPLEFT", p.scroll, "TOPLEFT", 6, -10)
    p.empty:SetText("Rien à afficher avec les prix actuels.")
    local legend = H.Text(p, 11, H.DIM)
    legend:SetPoint("TOPLEFT", p.scroll, "BOTTOMLEFT", 2, -4)
    legend:SetText("* = recette à apprendre   |TInterface\\Buttons\\UI-RefreshButton:12:12|t = resservira")

    -- Fiche de droite (maquette validée par Jérémie) : en-tête, 3 chiffres (maintenant / objectif /
    -- après achat), tableau des composants sur 2 lignes (chiffres, puis prix + Acheter), étapes.
    local f = CreateFrame("Frame", nil, p)
    f:SetPoint("TOPLEFT", p.scroll, "TOPRIGHT", 24, 14)
    f:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -12, 12)
    local fbg = H.Tex(f, "BACKGROUND", H.BG2, 0.6); fbg:SetAllPoints()
    H.Border(f, H.LINE)
    p.card = f
    local iconBtn = CreateFrame("Button", nil, f)
    iconBtn:SetSize(32, 32)
    iconBtn:SetPoint("TOPLEFT", 10, -10)
    iconBtn:SetScript("OnEnter", function(self)
        if f.item then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetItemByID(f.item.out)
            GameTooltip:Show()
        end
    end)
    iconBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    iconBtn:SetScript("OnClick", function()
        if f.item then ns.ShiftLink(f.item.out, f.item.spell) end
    end)
    f.icon = iconBtn:CreateTexture(nil, "ARTWORK")
    f.icon:SetAllPoints()
    f.gain = H.Text(f, 16, H.GREEN)
    f.gain:SetPoint("TOPRIGHT", -10, -10)
    f.gain:SetJustifyH("RIGHT")
    local gainSub = H.Text(f, 11, H.DIM)
    gainSub:SetPoint("TOPRIGHT", -10, -29)
    gainSub:SetText("par fabrication")
    f.title = H.Text(f, 16, H.CYAN)
    f.title:SetPoint("TOPLEFT", f.icon, "TOPRIGHT", 8, 0)
    f.title:SetPoint("RIGHT", f.gain, "LEFT", -8, 0)
    f.learn = H.Text(f, 12, H.SOFT) -- couleur · chance, ou « À apprendre : … »
    f.learn:SetPoint("TOPLEFT", f.icon, "TOPRIGHT", 8, -19)
    f.learn:SetPoint("RIGHT", gainSub, "LEFT", -8, 0)
    f.rep = H.Text(f, 11, H.SOFT) -- réputation, recette remboursée, ou « sert aussi pour »
    f.rep:SetPoint("TOPLEFT", 10, -45)
    f.rep:SetPoint("RIGHT", -10, 0)
    f.sales = H.Text(f, 11, H.SOFT)
    f.sales:SetPoint("TOPLEFT", 10, -57)
    f.sales:SetPoint("RIGHT", -10, 0)
    -- Survol de l'en-tête : comment apprendre la recette (maître, marchands nommés, réputation, HV).
    local learnHover = CreateFrame("Frame", nil, f)
    learnHover:SetPoint("TOPLEFT", 48, -26)
    learnHover:SetPoint("TOPRIGHT", -90, -26)
    learnHover:SetHeight(44)
    learnHover:EnableMouse(true)
    learnHover:SetScript("OnEnter", function(self)
        local e = f.item
        if not e or e.known then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(e.name, 1, 1, 1)
        AddLearnLines(e)
        GameTooltip:Show()
    end)
    learnHover:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Les 3 chiffres.
    f.boxes = {}
    for i, label in ipairs({ "Maintenant", "Objectif", "Après achat" }) do
        local b = CreateFrame("Frame", nil, f)
        b:SetHeight(50)
        if i == 1 then b:SetPoint("TOPLEFT", 8, -72) else b:SetPoint("TOPLEFT", f.boxes[i - 1], "TOPRIGHT", 6, 0) end
        local bb = H.Tex(b, "BACKGROUND", H.BG, 0.9); bb:SetAllPoints()
        local ac = H.Tex(b, "BORDER", H.CYAN); ac:SetPoint("TOPLEFT"); ac:SetPoint("BOTTOMLEFT"); ac:SetWidth(3)
        local l = H.Label(b, label, 10, H.DIM); l:SetPoint("TOPLEFT", 9, -4)
        b.value = H.Text(b, 18, H.TEXT); b.value:SetPoint("TOPLEFT", 9, -16)
        b.sub = H.Text(b, 10, H.DIM); b.sub:SetPoint("TOPLEFT", 9, -36); b.sub:SetPoint("RIGHT", -4, 0)
        b.sub:SetWordWrap(false)
        f.boxes[i] = b
    end
    local function SizeBoxes(w)
        w = w or f:GetWidth() or 300
        for _, b in ipairs(f.boxes) do b:SetWidth(math.max(60, (w - 16 - 12) / 3)) end
    end
    f:SetScript("OnSizeChanged", function(_, w) SizeBoxes(w) end)
    SizeBoxes()

    -- Colonnes du tableau (bord droit de chaque colonne, depuis la droite de la ligne).
    -- Bouton Acheter seul à droite (72 px) ; chiffres au milieu (retour de Jérémie).
    -- v0.49.0 : boutons « 1/4 » « 1/2 » (26 px chacun) à gauche d'Acheter → chiffres décalés de 58 px.
    local COLS = { { "Manque", -142 }, { "Il faut", -194 }, { "Sur toi", -246 }, { "Par fab.", -298 } }
    local header = H.Text(f, 10, H.DIM)
    header:SetPoint("TOPLEFT", 14, -128)
    header:SetText("COMPOSANT")
    for _, col in ipairs(COLS) do
        local h = H.Text(f, 10, H.DIM)
        h:SetPoint("TOPRIGHT", f, "TOPRIGHT", col[2] - 8, -128)
        h:SetText(H.Upper and H.Upper(col[1]) or col[1])
    end
    -- Lignes de 34 px (pas de 36) : le bouton Acheter, en bas à droite, ne touche plus le chiffre
    -- « Manque » au-dessus (retour de Jérémie).
    local ROW_STEP = 36
    local nRows = embedded and 4 or 7
    f.lines = {}
    for i = 1, nRows do
        local line = CreateFrame("Frame", nil, f)
        line:SetHeight(ROW_STEP - 2)
        line:SetPoint("TOPLEFT", 8, -140 - (i - 1) * ROW_STEP)
        line:SetPoint("RIGHT", -8, 0)
        local lb = H.Tex(line, "BACKGROUND", H.ROW, (i % 2 == 0) and 0.55 or 1); lb:SetAllPoints()
        local sep = H.Tex(line, "BORDER", H.LINE, 0.9)
        sep:SetPoint("BOTTOMLEFT"); sep:SetPoint("BOTTOMRIGHT"); sep:SetHeight(1)
        line.cols = {}
        for c, col in ipairs(COLS) do
            local t = H.Text(line, 13, H.TEXT)
            t:SetPoint("RIGHT", line, "RIGHT", col[2], 0) -- centré en hauteur, comme le bouton
            t:SetWidth(44)
            t:SetJustifyH("RIGHT")
            line.cols[c] = t
        end
        line.text = H.Text(line, 13, H.TEXT)
        line.text:SetPoint("TOPLEFT", 6, -2)
        line.text:SetPoint("RIGHT", line, "RIGHT", -348, 0)
        line.text:SetWordWrap(false)
        line.buy = H.Button(line, "Acheter", 64, 20, "outline")
        line.buy:SetPoint("RIGHT", -6, 0)
        line.buy:HookScript("OnEnter", function(self)
            local nd = self:GetParent().need
            if nd and nd.buy and nd.buy.kind == "recipe" and nd.buy.src == "HV" and ns.PrefetchUnique then
                ns.PrefetchUnique(nd.buy.id)
            end
        end)
        -- Maj+clic sur la ligne (ou sur un de ses boutons : jamais d'achat alors) = lien dans le chat.
        -- Ligne de la recette : l'objet-recette, sinon le sort de la recette.
        local function LinkLine()
            local nd = line.need
            return nd and ns.ShiftLink(nd.id, nd.recipe and f.item and f.item.spell or nil)
        end
        line.buy:SetScript("OnClick", function(self)
            if LinkLine() then return end
            local nd = self:GetParent().need
            if nd and nd.buy then BuyLine(nd.buy) end
        end)
        -- « 1/2 » et « 1/4 » : achètent cette part de ce qui manque (même hauteur, même centre qu'Acheter).
        local function PartButton(label, part, anchor)
            local b = H.Button(line, label, 26, 20, "outline")
            b:SetPoint("RIGHT", anchor, "LEFT", -3, 0)
            b:SetScript("OnClick", function(self)
                if LinkLine() then return end
                local nd = self:GetParent().need
                if nd and nd.buy then BuyLine(nd.buy, part) end
            end)
            return b
        end
        line.half = PartButton("1/2", 2, line.buy)
        line.quarter = PartButton("1/4", 4, line.half)
        line.price = H.Text(line, 11, H.SOFT)
        line.price:SetPoint("BOTTOMLEFT", 6, 3)
        line.price:SetPoint("RIGHT", line.quarter, "LEFT", -6, 0)
        line.price:SetWordWrap(false)
        line:EnableMouse(true)
        line:SetScript("OnEnter", function(self)
            if self.need and self.need.id then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetItemByID(self.need.id)
                GameTooltip:Show()
            end
        end)
        line:SetScript("OnLeave", function() GameTooltip:Hide() end)
        line:SetScript("OnMouseUp", function(_, button) if button == "LeftButton" then LinkLine() end end)
        line:Hide()
        f.lines[i] = line
    end
    f.more = H.Text(f, 11, H.DIM)
    f.rowStep = ROW_STEP
    f.more:SetPoint("TOPLEFT", 14, -140 - nRows * ROW_STEP)
    f.steps = H.Text(f, 11, H.SOFT)
    f.steps:SetPoint("TOPLEFT", 10, -140 - nRows * ROW_STEP - 2)
    f.steps:SetPoint("RIGHT", -10, 0)
    f.steps:SetJustifyH("LEFT")
    f.steps:SetWordWrap(true)
    -- Un clic = un achat : on achète le composant suivant qui manque (le jeu exige un clic par achat).
    f.buyAll = H.Button(f, "Tout acheter", 200, 26, "solid")
    f.buyAll:SetPoint("BOTTOMLEFT", 8, 8)
    f.buyAll:SetPoint("BOTTOMRIGHT", -8, 8)
    f.buyAll:HookScript("OnEnter", function()
        for _, nd in ipairs(f.needs or {}) do
            if nd.buy then
                if nd.buy.kind == "recipe" and nd.buy.src == "HV" and ns.PrefetchUnique then ns.PrefetchUnique(nd.buy.id) end
                return
            end
        end
    end)
    f.buyAll:SetScript("OnClick", function()
        for _, nd in ipairs(f.needs or {}) do
            if nd.buy then BuyLine(nd.buy) return end
        end
    end)

    p:SetScript("OnShow", function() RefreshPanel(p) end)
    p:Hide()
    panels[#panels + 1] = p
    return p
end

---------------------------------------------------------------------------
-- GUIDE DE MÉTIER : la route de montage la moins chère en or (seul critère : l'argent).
-- Petite fenêtre, un onglet par métier : « Maintenant : fabrique … », la liste de courses
-- avec boutons « Acheter », puis les étapes suivantes et le bilan de la route.
--
-- Calcul (simulation niveau par niveau, en plusieurs passes) :
--   - à chaque niveau, on choisit la recette au plus petit coût net par point espéré :
--     (composants achetés ou pris dans le stock − valeur de ce qu'on fabrique + apprentissage)
--     / points espérés (orange = points de la recette ; jaune / vert = chance) ;
--   - le stock de départ = ce que tu as dans tes sacs ; ce qu'on fabrique va dans le stock et
--     peut servir plus loin (rouleaux de lin → sacs en lin) ;
--   - passe 1 : tout ce qu'on fabrique est valorisé à son prix de revente ; passe 2 et
--     suivantes : un produit que la route RÉUTILISE est valorisé à ce qu'il coûterait à
--     acheter (valeur d'usage), et coûte ce même prix quand on le reprend du stock (pas
--     de double comptage) ; on recommence tant que la route change (4 passes au plus) ;
--   - à la fin, le stock restant est revendu : HV (− 5 %) dans la limite de ce que le marché
--     absorbe (au plus la quantité déjà en vente, minimum 5), le reste au marchand.
-- Le bilan affiché est l'argent réel : achats + apprentissages − ventes.
-- Recalculé à l'ouverture, après chaque scan de l'HV et chaque point gagné.
---------------------------------------------------------------------------
local guideWin, guideProf
local standalone -- fenêtre Jobs à part (créée au premier besoin)

-- Combien d'exemplaires l'HV peut vraiment ABSORBER : ventes estimées sur 3 jours (écoulement
-- entre deux scans) ; sans estimation, 5. (Bug « 58 x Chemise blanche en lin » : on prenait la
-- quantité EN VENTE (36 chemises) comme ce qu'on pourrait vendre ; or beaucoup en vente = marché
-- saturé, pas marché porteur. Jérémie : « une chemise qui ne donne rien, ça ne se vend pas ».)
local SELL_DAYS, SELL_DEFAULT = 3, 2
-- Prix du TEMPS d'une fabrication (pc), compté dans le choix des recettes (pas dans le bilan).
-- 2 pc au début : une recette verte à 20 % revendue au prix de ses composants paraissait gratuite →
-- « 58 x Chemise blanche », « 103 x Sac en lin » (Jérémie). À 20 pc : Couture 55 → 75 = ~25
-- fabrications (Gilets rouges, Sacs rouges) au lieu de ~80, pour ~12 pa de plus.
local CRAFT_EFFORT = 20
local function Absorb(itemID)
    local perDay = ns.HVSalesPerDay and ns.HVSalesPerDay(itemID)
    if perDay then return math.floor(perDay * SELL_DAYS + 0.5) end
    return SELL_DEFAULT
end

-- Revente d'un objet : le meilleur de l'HV (− 5 %) et du marchand. « soldAlready » =
-- exemplaires déjà vendus dans la simulation (au-delà de ce que l'HV absorbe : marchand).
local function SaleValue(itemID, soldAlready)
    local _, sell = Objet(itemID)
    local vendor = sell or 0
    local hv = PrixHV(itemID)
    if not hv then return vendor end
    if (soldAlready or 0) >= Absorb(itemID) then return vendor end
    return math.max(vendor, hv * (1 - COMMISSION))
end

-- Prix pour apprendre une recette pas encore connue, ou nil si impossible sans chance.
local function LearnCost(r)
    if (r[5] or "") == "" then return 0 end
    local o = LearnOptions(r)
    if not o.best then return nil end
    return o.cost or 0
end

-- Recettes candidates d'un métier (connues, ou apprenables à coup sûr), jusqu'au niveau visé.
local function Candidates(profID, cap)
    local list = {}
    for _, r in ipairs(ns.RECETTES) do
        if r[1] == profID and r[4] < cap then
            local spell = r[2]
            local known = IsKnown(spell) or r[5] == ""
            local learnCost = known and 0 or LearnCost(r)
            local out, qty, reag = RecipeData(spell)
            if reag and learnCost then
                local inputs = {}
                for id, n in reag:gmatch("(%d+):(%d+)") do inputs[#inputs + 1] = { tonumber(id), tonumber(n) } end
                local y, g, gr = Thresholds(spell, r[4])
                list[#list + 1] = {
                    spell = spell, out = out, qty = qty, inputs = inputs, learn = r[4], known = known,
                    learnCost = learnCost, y = y, g = g, gr = gr, multi = Multi(spell), r = r,
                }
            end
        end
    end
    return list
end

local function PointsAt(c, s)
    if s < c.y then return math.max(1, c.multi) end
    if s >= c.gr then return 0 end
    return math.max(0, math.min(1, (c.gr - s) / (c.gr - c.y)))
end

-- Une simulation complète de la montée, de « skill » à « cap ».
local function Simulate(cands, skill, cap, keep, keepQty)
    keepQty = keepQty or {}
    local inv, sold, learned = {}, {}, {}
    local buyMoney, sellMoney, learnMoney = 0, 0, 0
    -- Ce qui est pris dans tes SACS n'est pas gratuit (question de Jérémie) : compté à ce qu'il
    -- coûterait à racheter (sinon à sa revente).
    local stockMoney = 0
    local producedUsed = {} -- [objet] = exemplaires fabriqués puis réutilisés par la route
    local fromCraft = {}    -- [objet] = exemplaires en stock venant d'une fabrication
    for _, c in ipairs(cands) do
        for _, inp in ipairs(c.inputs) do inv[inp[1]] = inv[inp[1]] or ItemCount(inp[1]) end
        inv[c.out] = inv[c.out] or ItemCount(c.out)
    end
    -- Valeur d'usage (prix d'achat évité) SEULEMENT pour la quantité que la route réutilise ;
    -- au-delà, ce qu'on fabrique ne vaut que son prix de revente. (Bug : « 20 x Rouleau d'étoffe
    -- de lin » en vert pour 1 point, parce que CHAQUE rouleau comptait comme « utile ».)
    local function UseValue(id)
        if keep[id] and (fromCraft[id] or 0) < (keepQty[id] or 0) then return keep[id] end
        return SaleValue(id, fromCraft[id])
    end
    local function StockValue(id) return UseValue(id) end
    -- Valeur de « units » exemplaires de plus (chaque exemplaire à sa place dans la file de vente :
    -- les premiers au prix de l'HV, les suivants au marchand une fois le marché rempli).
    -- Au-delà de ce que l'HV absorbe, la revente au marchand ne compte PAS comme un gain pour
    -- choisir (au plus le prix des composants) : sinon une recette rentable au marchand devient une
    -- « machine à sous » et le guide propose « 35 x Sac en lin » pour 1 point. (Le bilan, lui,
    -- compte bien l'argent réel de ces ventes.)
    local function OutValue(id, units, unitCost)
        local total, base, j = 0, fromCraft[id] or 0, 0
        while j < units do
            local part = math.min(1, units - j)
            local idx = base + j
            local v
            if keep[id] and idx < (keepQty[id] or 0) then
                v = keep[id]
            else
                v = SaleValue(id, idx)
                if idx >= Absorb(id) then v = math.min(v, unitCost) end
            end
            total = total + part * v
            j = j + 1
        end
        return total
    end

    -- Montée POINT PAR POINT : à chaque niveau, on choisit la recette, puis on compte le nombre
    -- MOYEN de fabrications pour gagner ce point (1 / chance ; une orange à N points en donne N
    -- d'un coup). (1re version : par fractions de point → la chance baissant vers le gris, la
    -- simulation n'atteignait jamais le niveau visé : « 2000 x Sac en lin », et un gel à chaque
    -- fabrication pendant le recalcul.)
    local segments, s, guard = {}, math.floor(skill), 0
    while s < cap and guard < 1000 do
        guard = guard + 1
        local best, bestScore
        for _, c in ipairs(cands) do
            local pts = c.learn <= s and PointsAt(c, s) or 0
            if pts > 0 then
                local cost, ok = 0, true
                for _, inp in ipairs(c.inputs) do
                    local id, n = inp[1], inp[2]
                    local fromStock = math.min(inv[id] or 0, n)
                    cost = cost + fromStock * StockValue(id)
                    if n > fromStock then
                        local u = UnitCost(id)
                        if not u then ok = false break end
                        cost = cost + (n - fromStock) * u
                    end
                end
                if ok then
                    -- Ce point coûte k fabrications (orange : 1 fabrication = « multi » points) : on compte
                    -- la vraie valeur des k produits (le marché se remplit), pas k fois le prix de l'HV.
                    local orangeHere = s < c.y
                    local k = orangeHere and 1 or (1 / pts)
                    local gained = orangeHere and pts or 1
                    local outVal = OutValue(c.out, c.qty * k, cost / c.qty)
                    local learnPart = learned[c.spell] and 0 or (c.learnCost / math.max(1, c.g - s))
                    -- + un petit prix par fabrication (temps passé) pour départager : à argent égal,
                    -- la recette qui demande le moins de fabrications.
                    local score = (cost * k - outVal + learnPart + CRAFT_EFFORT * k) / gained
                    if not bestScore or score < bestScore then best, bestScore = c, score end
                end
            end
        end
        if not best then break end -- plus aucune recette ne fait monter (prix manquants ?)

        -- On fabrique la recette choisie autant de fois qu'il faut, en moyenne, pour ce point.
        local c = best
        local orange = s < c.y
        local k = orange and 1 or (1 / PointsAt(c, s)) -- nombre moyen de fabrications
        if not learned[c.spell] then
            learned[c.spell] = true
            if not c.known then learnMoney = learnMoney + c.learnCost end
        end
        local seg = segments[#segments]
        if not seg or seg.c ~= c then
            seg = { c = c, from = s, crafts = 0, buy = {}, cost = 0 }
            segments[#segments + 1] = seg
        end
        for _, inp in ipairs(c.inputs) do
            local id, n = inp[1], inp[2] * k
            local fromStock = math.min(inv[id] or 0, n)
            inv[id] = (inv[id] or 0) - fromStock
            local fromBag = fromStock - math.min(fromStock, fromCraft[id] or 0)
            if fromBag > 0 then stockMoney = stockMoney + fromBag * (UnitCost(id) or SaleValue(id, 0)) end
            if fromStock > 0 and (fromCraft[id] or 0) > 0 then
                local used = math.min(fromStock, fromCraft[id])
                fromCraft[id] = fromCraft[id] - used
                producedUsed[id] = (producedUsed[id] or 0) + used
                seg.usesOwn = seg.usesOwn or {}
                seg.usesOwn[id] = (seg.usesOwn[id] or 0) + used
            end
            local toBuy = n - fromStock
            if toBuy > 0 then
                local u = UnitCost(id)
                buyMoney = buyMoney + toBuy * u
                seg.buy[id] = (seg.buy[id] or 0) + toBuy
                seg.cost = seg.cost + toBuy * u
            end
        end
        inv[c.out] = (inv[c.out] or 0) + c.qty * k
        fromCraft[c.out] = (fromCraft[c.out] or 0) + c.qty * k
        seg.crafts = seg.crafts + k
        s = s + (orange and math.max(1, c.multi) or 1)
        seg.to = math.min(cap, s)
    end

    -- Revente de ce qui reste de la production (pas ce qui était déjà dans les sacs).
    for id, n in pairs(fromCraft) do
        for _ = 1, math.floor(n) do
            sellMoney = sellMoney + SaleValue(id, sold[id])
            sold[id] = (sold[id] or 0) + 1
        end
    end
    return {
        segments = segments, reached = s, buy = buyMoney, sell = sellMoney, learn = learnMoney,
        net = sellMoney - buyMoney - learnMoney - stockMoney, stock = stockMoney, producedUsed = producedUsed,
    }
end

-- Plusieurs passes : les produits réutilisés par la route sont revalorisés à leur valeur d'usage.
local function PlanRoute(profID, skill, cap)
    local cands = Candidates(profID, cap)
    local keep, keepQty, route, signature = {}, {}, nil, nil
    for pass = 1, 4 do
        route = Simulate(cands, skill, cap, keep, keepQty)
        local parts = {}
        for _, seg in ipairs(route.segments) do parts[#parts + 1] = seg.c.spell .. "x" .. seg.crafts end
        local sig = table.concat(parts, ",")
        route.passes = pass
        if sig == signature then break end
        signature = sig
        keep, keepQty = {}, {}
        for id, used in pairs(route.producedUsed) do
            local u = UnitCost(id)
            keep[id] = math.max(SaleValue(id, 0), u or 0) -- valeur d'usage : ce qu'il coûterait à acheter
            keepQty[id] = used                             -- … mais seulement pour cette quantité
        end
    end
    return route
end


---------------------------------------------------------------------------
-- Fenêtre du guide
---------------------------------------------------------------------------
local GUIDE_BUY_LINES, GUIDE_NEXT_LINES = 6, 5

local function SegText(seg)
    local c = seg.c
    local name = Objet(c.out)
    local crafts = math.ceil(seg.crafts)
    return string.format("%d à %d : %d x %s", math.floor(seg.from), math.floor(seg.to + 0.5), crafts, name)
end

local function GuideRefresh()
    local w = guideWin
    if not w or not w:IsShown() then return end
    local H = ns.Holo
    if ns.SaveLevels then pcall(ns.SaveLevels) end
    local profs = MyProfessions()
    if guideProf then
        for _, pr in ipairs(profs) do if pr.id == guideProf.id then guideProf = pr end end
    else
        guideProf = profs[1]
    end
    for i, b in ipairs(w.tabs) do
        local pr = profs[i]
        if pr then
            b.prof = pr
            b:SetLabel(TabLabel(pr))
            b:SetStyle((guideProf and guideProf.id == pr.id) and "solid" or "muted")
            b:Show()
        else
            b:Hide()
        end
    end
    for _, l in ipairs(w.buyLines) do l:Hide() end
    for _, fs in ipairs(w.nextLines) do fs:SetText("") end
    w.now:SetText("")
    w.keep:SetText("")
    w.summary:SetText("")
    w.bilan:SetText("")
    w.bar:SetValue(0)
    if not guideProf then
        w.progress:SetText("Aucun métier relevé : fais un /reload.")
        return
    end
    local skill, cap = LevelOf(guideProf), CapOf(guideProf.name)
    w.progress:SetText(string.format("PROGRESSION  %d / %d", skill, cap))
    w.bar:SetValue(skill / cap)
    if skill >= cap then
        w.now:SetText("Palier atteint : va voir le maître pour le palier suivant.")
        return
    end
    -- On ne recalcule la route que si quelque chose a changé : métier, niveau, prix (nouveau
    -- scan), couleurs apprises, contenu des sacs. (Avant : recalcul à chaque ouverture et à
    -- chaque signal de la fenêtre → gel à l'appui sur K.)
    local key = table.concat({ guideProf.id, skill, cap, EryAddonDB.hvPrix and EryAddonDB.hvPrix.date or "",
        ns.dataVersion or 0, ns.bagVersion or 0, EryAddonDB.prixMarchand and EryAddonDB.prixMarchand.date or "" }, "|")
    local ok, route
    if w.routeKey == key and w.route then
        ok, route = true, w.route
    else
        local t0 = debugprofilestop and debugprofilestop() or 0
        ok, route = pcall(PlanRoute, guideProf.id, skill, cap)
        EryAddonDB.perf = EryAddonDB.perf or {}
        EryAddonDB.perf.route = string.format("%.0f ms (%s %d)", (debugprofilestop and debugprofilestop() or 0) - t0,
            guideProf.name, skill)
        if ok then w.routeKey, w.route = key, route end
    end
    if not ok or not route then
        w.now:SetText("Calcul impossible : " .. tostring(route))
        return
    end
    w.bilan:SetText("BILAN ESTIMÉ  " .. (route.net >= 0 and "|cff5cffb0+" or "|cffff7373") .. Money(route.net) .. "|r")
    w.summary:SetText(string.format("achats %s%s   ·   apprentissages %s   ·   ventes %s   ·   jusqu'à %d",
        Money(route.buy), (route.stock or 0) > 0 and ("   ·   tes sacs " .. Money(route.stock)) or "",
        Money(route.learn), Money(route.sell), math.floor(route.reached)))

    -- Résumé lisible gardé dans la sauvegarde (pour que Claude puisse vérifier la route).
    EryAddonDB.guide = EryAddonDB.guide or {}
    local saved = { date = date("%d/%m %H:%M"), bilan = route.net, passes = route.passes }
    for _, seg in ipairs(route.segments) do saved[#saved + 1] = SegText(seg) end
    EryAddonDB.guide[guideProf.name] = saved

    local first = route.segments[1]
    if not first then
        w.now:SetText("Aucune recette ne fait monter avec les prix connus : refais un scan de l'HV.")
        return
    end
    local c = first.c
    w.now:SetText(string.format("Fabrique |cff39d0ff%d x %s|r  |cff5f8a99%d à %d|r",
        math.ceil(first.crafts), Objet(c.out), math.floor(first.from), math.floor(first.to + 0.5)))
    if not guideProf.learned then
        w.keep:SetText("|cffff9933Métier pas appris : va voir un maître de " .. guideProf.name:lower() .. ".|r")
    elseif not c.known then
        w.keep:SetText("|cffff9933À apprendre d'abord : " .. LearnLabel(c.r) .. "|r")
    end
    -- Ce qu'on fabrique ici sert-il plus loin ?
    for _, seg in ipairs(route.segments) do
        if seg ~= first and seg.usesOwn and seg.usesOwn[c.out] then
            w.keep:SetText((c.known and "" or (w.keep:GetText() .. "   ")) ..
                string.format("|cff5cffb0Garde-les|r : ils serviront pour %s.", Objet(seg.c.out)))
            break
        end
    end
    -- Composants de l'étape actuelle, comme dans Jobs (demande de Jérémie) : « Mage royal 4/16 »
    -- = tu as / il faut (sacs + achats encore au courrier), prix de ce qui manque, bouton Acheter.
    local crafts = math.ceil(first.crafts - 0.01)
    local i, missingAny = 0, false
    for _, inp in ipairs(c.inputs) do
        local id, q = inp[1], inp[2]
        i = i + 1
        local line = w.buyLines[i]
        if not line then break end
        local need, have = q * crafts, ItemCount(id)
        local missing = math.max(0, need - have)
        local unit, src = UnitCost(id)
        line.item = { kind = "buy", id = id, need = missing, have = 0, name = Objet(id), unit = unit, src = src }
        line.icon:SetTexture((C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(id)) or nil)
        local mail = MailCount(id)
        line.text:SetText(CountText(Objet(id), have, need)
            .. (mail > 0 and string.format("  |cff5f8a99dont %d au courrier|r", mail) or ""))
        if missing > 0 then
            missingAny = true
            line.price:SetText(unit and (Money(unit * missing) .. " |cff5f8a99" .. (src or "") .. "|r")
                or "|cffff7373introuvable|r")
            line.buy:SetShown(unit ~= nil)
        else
            line.price:SetText(OK_ICON)
            line.buy:Hide()
        end
        line:Show()
    end
    w.buyEmpty:SetText((i > 0 and not missingAny) and "|cff5cffb0Tu as tout : tu peux fabriquer.|r" or "")
    -- Étapes suivantes.
    for k = 2, math.min(#route.segments, GUIDE_NEXT_LINES + 1) do
        local seg = route.segments[k]
        w.nextLines[k - 1]:SetText((seg.c.known and "" or "|cffff9933(à apprendre)|r ") .. SegText(seg))
    end
end
ns.GuideRefresh = GuideRefresh
ns._PlanRoute = PlanRoute -- (accès pour les tests hors jeu de Claude)
ns._Objet = Objet

local function CreateGuide()
    local H = ns.Holo
    local w = H.Window("EryGuideFrame", 470, 496, "Guide de métier", "Route la moins chère")
    w:SetPoint("CENTER", -250, 80)

    w.tabs = {}
    for i = 1, 8 do
        local b = H.Button(w, "", 108, 22, "muted")
        b:SetPoint("TOPLEFT", 10 + ((i - 1) % 4) * 113, i <= 4 and -36 or -62)
        b:SetScript("OnClick", function(self) guideProf = self.prof; GuideRefresh() end)
        w.tabs[i] = b
    end

    w.progress = H.Text(w, 12, H.SOFT)
    w.progress:SetPoint("TOPLEFT", 12, -96)
    w.bilan = H.Text(w, 12, H.SOFT)
    w.bilan:SetPoint("TOPRIGHT", -12, -96)
    w.bilan:SetJustifyH("RIGHT")
    w.bar = H.Bar(w, 6)
    w.bar:SetPoint("TOPLEFT", 12, -112)
    w.bar:SetPoint("TOPRIGHT", -12, -112)
    w.summary = H.Text(w, 11, H.DIM)
    w.summary:SetPoint("TOPLEFT", 12, -123)
    w.summary:SetPoint("RIGHT", -12, 0)

    -- Encadré « MAINTENANT » : filet cyan à gauche, fond légèrement plus clair.
    local nowBox = CreateFrame("Frame", nil, w)
    nowBox:SetPoint("TOPLEFT", 12, -140)
    nowBox:SetPoint("TOPRIGHT", -12, -140)
    nowBox:SetHeight(46)
    local nb = H.Tex(nowBox, "BACKGROUND", H.BG2); nb:SetAllPoints()
    local accent = H.Tex(nowBox, "BORDER", H.CYAN); accent:SetPoint("TOPLEFT"); accent:SetPoint("BOTTOMLEFT"); accent:SetWidth(3)
    local nowLabel = H.Label(nowBox, "Maintenant", 10, H.DIM)
    nowLabel:SetPoint("TOPLEFT", 12, -6)
    w.now = H.Text(nowBox, 15, H.TEXT)
    w.now:SetPoint("TOPLEFT", 12, -22)
    w.now:SetPoint("RIGHT", -8, 0)
    w.keep = H.Text(w, 12, H.SOFT)
    w.keep:SetPoint("TOPLEFT", 14, -192)
    w.keep:SetPoint("RIGHT", -12, 0)

    local shopLabel = H.Label(w, "Composants", 10, H.DIM)
    shopLabel:SetPoint("TOPLEFT", 12, -212)
    w.buyEmpty = H.Text(w, 12, H.DIM)
    w.buyEmpty:SetPoint("TOPRIGHT", -14, -212)
    w.buyEmpty:SetJustifyH("RIGHT")
    w.buyLines = {}
    for i = 1, GUIDE_BUY_LINES do
        local line = CreateFrame("Frame", nil, w)
        line:SetHeight(22)
        line:SetPoint("TOPLEFT", 12, -226 - (i - 1) * 24)
        line:SetPoint("RIGHT", -12, 0)
        local lb = H.Tex(line, "BACKGROUND", H.ROW); lb:SetAllPoints()
        line:EnableMouse(true)
        line:SetScript("OnEnter", function(self)
            if self.item and self.item.id then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetItemByID(self.item.id)
                GameTooltip:Show()
            end
        end)
        line:SetScript("OnLeave", function() GameTooltip:Hide() end)
        line.icon = line:CreateTexture(nil, "ARTWORK")
        line.icon:SetSize(16, 16)
        line.icon:SetPoint("LEFT", 4, 0)
        line.buy = H.Button(line, "Acheter", 64, 16, "outline")
        line.buy:SetPoint("RIGHT", -4, 0)
        line.buy:SetScript("OnClick", function(self)
            local item = self:GetParent().item
            if item then BuyLine(item) end -- (la quantité tient déjà compte de tes sacs)
        end)
        line.price = H.Text(line, 12, H.TEXT)
        line.price:SetPoint("RIGHT", line.buy, "LEFT", -8, 0)
        line.price:SetJustifyH("RIGHT")
        line.text = H.Text(line, 12, H.TEXT)
        line.text:SetPoint("LEFT", line.icon, "RIGHT", 6, 0)
        line.text:SetPoint("RIGHT", line.price, "LEFT", -6, 0)
        line:Hide()
        w.buyLines[i] = line
    end

    local nextLabel = H.Label(w, "Ensuite", 10, H.DIM)
    nextLabel:SetPoint("TOPLEFT", 12, -226 - GUIDE_BUY_LINES * 24 - 6)
    w.nextLines = {}
    for i = 1, GUIDE_NEXT_LINES do
        local fs = H.Text(w, 12, H.SOFT)
        fs:SetPoint("TOPLEFT", 14, -226 - GUIDE_BUY_LINES * 24 - 6 - i * 16)
        fs:SetPoint("RIGHT", -12, 0)
        w.nextLines[i] = fs
    end

    w:SetScript("OnShow", function()
        GuideRefresh()
        if ns.ArrangeWindows then ns.ArrangeWindows() end
    end)
    w:Hide()
    guideWin = w
end

-- Place « win » à côté de « ref » : à droite s'il y a la place, sinon à gauche, sinon dessous.
local function Place(win, ref)
    local l, r, b = ref:GetLeft(), ref:GetRight(), ref:GetBottom()
    if not (l and r) then return end
    local screen = UIParent:GetRight() or 0
    local w = win:GetWidth() or 500
    win:ClearAllPoints()
    if r + 6 + w <= screen then
        win:SetPoint("TOPLEFT", ref, "TOPRIGHT", 6, 0)
    elseif l - 6 - w >= 0 then
        win:SetPoint("TOPRIGHT", ref, "TOPLEFT", -6, 0)
    elseif b and b - (win:GetHeight() or 500) >= 0 then
        win:SetPoint("TOPLEFT", ref, "BOTTOMLEFT", 0, -6)
    else
        win:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -10, 10)
    end
end

-- Guide et Jobs ouverts ensemble : côte à côte, jamais l'un sur l'autre (retour de Jérémie).
-- Jobs collé à la fenêtre des métiers : le guide se range à côté de Jobs ; sinon l'inverse.
local function Arrange()
    if not (standalone and standalone:IsShown() and guideWin and guideWin:IsShown()) then return end
    if standalone.docked then Place(guideWin, standalone) else Place(standalone, guideWin) end
end
ns.ArrangeWindows = Arrange

-- Fenêtre des métiers ouverte en ce moment (livre des métiers ou fenêtre d'un métier).
local function OpenHost()
    for _, name in ipairs({ "ProfessionsBookFrame", "ProfessionsFrame", "TradeSkillFrame" }) do
        local f = _G[name]
        if f and f:IsShown() then return f end
    end
end

local function DockWindow(win, host)
    win:ClearAllPoints()
    win:SetPoint("TOPLEFT", host, "TOPRIGHT", 52, 0) -- (place pour les icônes de WhatsTraining)
    if win.SetClampedToScreen then win:SetClampedToScreen(true) end
    win.docked = host
end

local function EnsureJobs()
    if not standalone then standalone = ns.CreateJobsPanel(UIParent) end
    return standalone
end

local function ToggleStandalone()
    if not Jobs.enabled then return end
    local j = EnsureJobs()
    if j:IsShown() then j:Hide() return end
    local host = OpenHost()
    if host then DockWindow(j, host) else j.docked = nil end
    j:Show()
    Arrange()
end

function ns.ToggleGuide()
    if not Jobs.enabled then return end
    if not guideWin then CreateGuide() end
    if guideWin:IsShown() then guideWin:Hide() return end
    local host = OpenHost()
    guideWin.docked = host -- se ferme avec la fenêtre des métiers
    if host and not (standalone and standalone:IsShown()) then DockWindow(guideWin, host) end
    guideWin:Show()
    Arrange()
end

-- Boutons « Jobs » et « Guide » au-dessus d'une fenêtre des métiers.
local function MakeButtons(host)
    if host.eryButtons then return host.eryButtons end
    local H = ns.Holo
    local b = H.Button(host, "Métiers", 70, 20, "solid")
    b:SetPoint("BOTTOMRIGHT", host, "TOPRIGHT", -4, 2)
    b:SetScript("OnClick", ToggleStandalone)
    host.eryButtons = b
    return b
end

-- K (fenêtre des métiers) ouvre JOBS directement (demande de Jérémie : « je veux ouvrir la fenêtre
-- de Jobs directement, pas juste le guide »), collé à sa droite. Les fenêtres ouvertes quand tu
-- refermes K (Jobs, guide, ou les deux) sont celles qui se rouvriront la fois suivante
-- (EryAddonDB.fenetresK) ; elles se ferment avec la fenêtre des métiers.
local function DockTo(frame)
    if not frame or frame.eryDocked then return end
    frame.eryDocked = true
    MakeButtons(frame)
    frame:HookScript("OnShow", function()
        if not Jobs.enabled then return end
        local want = EryAddonDB.fenetresK or { jobs = true }
        if want.jobs then
            local j = EnsureJobs()
            DockWindow(j, frame)
            j:Show()
        end
        if false and want.guide then -- guide retiré (07/11) : Jobs seul
            if not guideWin then CreateGuide() end
            if not (standalone and standalone:IsShown()) then DockWindow(guideWin, frame) end
            guideWin.docked = frame
            guideWin:Show()
        end
        Arrange()
    end)
    frame:HookScript("OnHide", function()
        local js = standalone and standalone:IsShown() and standalone.docked == frame
        local gs = guideWin and guideWin:IsShown() and guideWin.docked == frame
        if js or gs then EryAddonDB.fenetresK = { jobs = js and true or false, guide = gs and true or false } end
        -- Une autre fenêtre des métiers encore ouverte (livre → fenêtre d'un métier) : on la suit.
        local other = OpenHost()
        if js then if other then DockWindow(standalone, other) else standalone:Hide(); standalone.docked = nil end end
        if gs then if other then guideWin.docked = other else guideWin:Hide(); guideWin.docked = nil end end
        Arrange()
    end)
end

local function TryDock()
    -- Sur Forever : K ouvre le livre des métiers (ProfessionsBookFrame) ; un métier ouvre sa fenêtre
    -- moderne (ProfessionsFrame).
    for _, name in ipairs({ "ProfessionsFrame", "TradeSkillFrame", "ProfessionsBookFrame" }) do
        if _G[name] then DockTo(_G[name]) end
    end
end
if EventUtil and EventUtil.ContinueOnAddOnLoaded then
    EventUtil.ContinueOnAddOnLoaded("Blizzard_Professions", TryDock)
    EventUtil.ContinueOnAddOnLoaded("Blizzard_TradeSkillUI", TryDock)
    EventUtil.ContinueOnAddOnLoaded("Blizzard_ProfessionsBook", TryDock)
end
if ToggleProfessionsBook then
    hooksecurefunc("ToggleProfessionsBook", function() C_Timer.After(0, TryDock) end)
end

local tradeButton

-- Boutons « Jobs » et « Guide » au-dessus de la fenêtre de métier (moderne sur Forever :
-- ProfessionsFrame ; ancienne : TradeSkillFrame).
local function AttachToTradeSkill()
    local host = ProfessionsFrame or TradeSkillFrame
    if tradeButton or not host then return end
    tradeButton = MakeButtons(host)
end

-- Observation : juste après avoir fabriqué une recette, le métier gagne N points d'un coup.
local recipeProf -- [sort] = nom du métier
local lastCraft, lastLevels = nil, {}
local noGain = {} -- [sort] = { level, count } : fabrications de suite sans point
local function CurrentLevels()
    if ns.SaveLevels then pcall(ns.SaveLevels) end
    local out = {}
    for name, v in pairs(EryAddonDB.niveaux and EryAddonDB.niveaux.metiers or {}) do
        out[name] = tonumber(v:match("^(%d+)"))
    end
    return out
end

local craftFrame = CreateFrame("Frame")
craftFrame:SetScript("OnEvent", function(_, event, unit, _, spellID)
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        if unit ~= "player" or not spellID or issecret(spellID) then return end
        if not recipeProf then
            recipeProf = {}
            for _, r in ipairs(ns.RECETTES) do recipeProf[r[2]] = ns.METIERS[r[1]] end
        end
        if recipeProf[spellID] then
            lastLevels = CurrentLevels()
            lastCraft = { spell = spellID, prof = recipeProf[spellID], time = GetTime() }
            -- Garde-fou (bug : Élixir d'Esprit mineur fabriqué 12 fois sans un point, le guide
            -- le croyait orange) : 10 fabrications de suite au même niveau sans aucun point =
            -- la recette est grise à ce niveau.
            local level = lastLevels[recipeProf[spellID]]
            if level then
                local ng = noGain[spellID]
                if ng and ng.level == level then ng.count = ng.count + 1 else noGain[spellID] = { level = level, count = 1 } end
                if noGain[spellID].count > 10 then Observe(spellID, "trivial", level) end
            end
        end
    elseif lastCraft and GetTime() - lastCraft.time < 3 then
        local now = CurrentLevels()
        local before, after = lastLevels[lastCraft.prof], now[lastCraft.prof]
        if before and after and after - before >= 2 then SetMulti(lastCraft.spell, after - before) end
        if before and after and after > before then lastCraft = nil end
    end
end)

local pending, bagPending = false, false
local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", function(_, event)
    if event == "BAG_UPDATE_DELAYED" then
        ns.bagVersion = (ns.bagVersion or 0) + 1 -- sacs changés : liste de courses à refaire
        if not bagPending then
            bagPending = true
            C_Timer.After(0.5, function()
                bagPending = false
                for _, p in ipairs(panels) do if p:IsShown() then RefreshPanel(p) end end
            end)
        end
        return
    end
    if pending then return end
    pending = true
    -- 1 s après l'ouverture (le temps que la fenêtre charge ses recettes) ou un point gagné.
    C_Timer.After(1, function()
        pending = false
        if not Jobs.enabled then return end
        AttachToTradeSkill()
        if tradeButton then tradeButton:Show() end
        local t0 = debugprofilestop and debugprofilestop() or 0
        pcall(CaptureTradeSkill)
        EryAddonDB.perf = EryAddonDB.perf or {}
        EryAddonDB.perf.lecture = string.format("%.0f ms", (debugprofilestop and debugprofilestop() or 0) - t0)
        EryAddonDB.perf.date = date("%d/%m %H:%M:%S")
        RefreshAll()
    end)
end)

function Jobs.Enable()
    Jobs.enabled = true
    -- (Plus de TRADE_SKILL_UPDATE / LIST_UPDATE : ils arrivent sans arrêt, y compris à chaque
    -- fabrication, et relançaient tous les calculs.)
    for _, ev in ipairs({ "TRADE_SKILL_SHOW", "CHAT_MSG_SKILL", "NEW_RECIPE_LEARNED", "BAG_UPDATE_DELAYED" }) do
        pcall(frame.RegisterEvent, frame, ev)
    end
    pcall(craftFrame.RegisterUnitEvent, craftFrame, "UNIT_SPELLCAST_SUCCEEDED", "player")
    pcall(craftFrame.RegisterEvent, craftFrame, "CHAT_MSG_SKILL")
    pcall(craftFrame.RegisterEvent, craftFrame, "SKILL_LINES_CHANGED")
end

function Jobs.Disable()
    Jobs.enabled = false
    frame:UnregisterAllEvents()
    craftFrame:UnregisterAllEvents()
    if tradeButton then tradeButton:Hide() end
    for _, p in ipairs(panels) do p:Hide() end
end
