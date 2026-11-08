-- EryAddon : CARTE DES QUÊTES À PRENDRE (demande de Jérémie, pour se passer de Questie : « il met des
-- quêtes qui n'existent pas, il indique mal les endroits ; je veux les objectifs de WoW, il me manque
-- juste où prendre les quêtes »). Un « ! » sur la carte du monde à chaque PNJ / objet qui donne une
-- quête que tu peux prendre MAINTENANT ; survol = nom du PNJ, [niveau] nom de la quête ; MAJ = objectifs.
-- Filtre : pas faite, pas dans le journal, niveau requis atteint, pas grise, race / classe, quêtes
-- d'avant faites, quêtes exclusives, métier, réputation ; et quête CONNUE DU SERVEUR (vérifiée auprès
-- du jeu : C_QuestLog.RequestLoadQuestByID → QUEST_DATA_LOAD_RESULT).
local _, ns = ...

-- Zone du jeu (AreaTable, celle des positions de QuestieDB) -> carte (UiMap). GÉNÉRÉ depuis la table
-- UiMapAssignment de Forever 1.60.1.70862 (wago.tools), voir outils/zone_map.lua.
local ZONE_MAP = {[1]=1426, [3]=1418, [4]=1419, [8]=1435, [10]=1431, [11]=1437, [12]=1429, [14]=1411, [15]=1445, [16]=1447, [17]=1413, [28]=1422, [33]=1434, [36]=1416, [38]=1432, [40]=1436, [41]=1430, [44]=1433, [45]=1417, [46]=1428, [47]=1425, [51]=1427, [85]=1420, [130]=1421, [139]=1423, [141]=1438, [148]=1439, [215]=1412, [267]=1424, [331]=1440, [357]=1444, [361]=1448, [400]=1441, [405]=1443, [406]=1442, [440]=1446, [490]=1449, [493]=1450, [616]=2482, [618]=1452, [1377]=1451, [1497]=1458, [1519]=1453, [1537]=1455, [1637]=1454, [1638]=1456, [1657]=1457, [2597]=1459, [3277]=1460, [3358]=1461, [16591]=2548, [16593]=2521, [16606]=2524, [16651]=2652}
ns.ZONE_MAP = ZONE_MAP -- zone (AreaTable) → carte du jeu : aussi pour « Carte » de l'écran Métiers (EryAddon_Fenetre.lua)

-- Données des quêtes : add-on QuestieDB (installé SÉPARÉMENT de Questie ; il marche seul et
-- applique ses propres corrections Forever). Si QuestieDB est absent : la fonction ne fait rien.
local Quetes = { key = "quetes", label = "Carte : quêtes à prendre (sans Questie)" }
table.insert(ns.features, Quetes)
ns.DEFAULTS.quetes = false -- coupée tant que Jérémie n'a pas choisi (il ne veut pas des données de Questie)

local PIN_TAILLE = 11        -- taille des « ! » sur la carte (unités du canevas, comme les livres)
local MAX_SPAWNS = 4         -- positions affichées au plus par PNJ et par carte (PNJ qui se déplacent)
local BUDGET = 150           -- quêtes lues par image pendant la construction de l'index

local DB                     -- _G.LibQuestieDB
local starters = nil         -- [uiMapID] = { { kind, id, x, y, quests = { qid, … } }, … }
local npcQuests = {}         -- [PNJ] = { qid, … } d'après la base
local building = false
local pins, pinFrame = {}, CreateFrame("Frame")

local function Inconnues()
    EryAddonDB.quetesInconnues = EryAddonDB.quetesInconnues or {}
    return EryAddonDB.quetesInconnues
end

local function Get(entity, id, key)
    local ok, v = pcall(entity.Get, id, key)
    if ok then return v end
end

-- Race et classe du joueur, en masques (même convention que QuestieDB : 2^(numéro - 1)).
local function PlayerMasks()
    local _, _, race = UnitRace("player")
    local _, _, class = UnitClass("player")
    return 2 ^ ((race or 1) - 1), 2 ^ ((class or 1) - 1)
end

local function MaskOK(mask, bitValue)
    if not mask or mask == 0 then return true end
    return bit.band(mask, bitValue) ~= 0
end

---------------------------------------------------------------------------
-- Index : qui donne quelles quêtes, et où (construit une fois, petit à petit)
---------------------------------------------------------------------------
local function AddStarter(index, kind, id, qid, myFaction)
    if kind == "n" then
        npcQuests[id] = npcQuests[id] or {}
        table.insert(npcQuests[id], qid)
    end
    local entity = kind == "n" and DB.Npc or DB.Object
    if not entity then return end
    if kind == "n" then
        local f = Get(entity, id, "friendlyToFaction")
        if f and f ~= "AH" and f ~= myFaction then return end -- PNJ de l'autre faction
    end
    local spawns = Get(entity, id, "spawns")
    if type(spawns) ~= "table" then return end
    for zone, list in pairs(spawns) do
        local map = ZONE_MAP[zone]
        if map and type(list) == "table" then
            index[map] = index[map] or {}
            local byKey = index[map].byKey or {}
            index[map].byKey = byKey
            local key = kind .. id
            local s = byKey[key]
            if not s then
                s = { kind = kind, id = id, quests = {}, pos = {} }
                byKey[key] = s
                table.insert(index[map], s)
                for i, p in ipairs(list) do
                    if i > MAX_SPAWNS then break end
                    if type(p) == "table" and p[1] and p[2] then s.pos[#s.pos + 1] = { p[1], p[2] } end
                end
            end
            s.quests[#s.quests + 1] = qid
        end
    end
end

local RefreshPins -- plus bas

local function BuildIndex()
    if building or starters then return end
    DB = _G.LibQuestieDB
    if not (DB and DB.Quest and DB.Quest.GetAllIds and DB.Npc) then return end
    building = true
    local raceBit, classBit = PlayerMasks()
    local myFaction = (UnitFactionGroup("player") == "Alliance") and "A" or "H"
    local ok, ids = pcall(DB.Quest.GetAllIds)
    if not ok or type(ids) ~= "table" then building = false return end
    local list = {}
    -- GetAllIds() = liste croissante de numéros (GetAllIds(true) = table [numéro] = true).
    for k, v in pairs(ids) do list[#list + 1] = (type(v) == "number") and v or k end
    local index, i = {}, 0
    local ticker
    ticker = C_Timer.NewTicker(0, function()
        local stop = math.min(#list, i + BUDGET)
        for j = i + 1, stop do
            local qid = list[j]
            if type(qid) == "number" and MaskOK(Get(DB.Quest, qid, "requiredRaces"), raceBit)
                and MaskOK(Get(DB.Quest, qid, "requiredClasses"), classBit) then
                local sb = Get(DB.Quest, qid, "startedBy")
                if type(sb) == "table" then
                    for _, npc in ipairs(sb[1] or {}) do AddStarter(index, "n", npc, qid, myFaction) end
                    for _, obj in ipairs(sb[2] or {}) do AddStarter(index, "o", obj, qid, myFaction) end
                end
            end
        end
        i = stop
        if i >= #list then
            ticker:Cancel()
            starters, building = index, false
            if RefreshPins then RefreshPins() end
        end
    end)
end

---------------------------------------------------------------------------
-- Une quête est-elle à prendre MAINTENANT ?
---------------------------------------------------------------------------
local function Done(qid)
    if C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted then
        local ok, v = pcall(C_QuestLog.IsQuestFlaggedCompleted, qid)
        if ok then return v == true end
    end
    return false
end

local function InLog(qid)
    if C_QuestLog and C_QuestLog.GetLogIndexForQuestID then
        local ok, v = pcall(C_QuestLog.GetLogIndexForQuestID, qid)
        if ok and v and v > 0 then return true end
    end
    if GetQuestLogIndexByID then
        local ok, v = pcall(GetQuestLogIndexByID, qid)
        if ok and v and v > 0 then return true end
    end
    return false
end

-- Titres des quêtes du journal (en minuscules). Vu chez Questie : « Mankrik : [20] Son nom est Olgra
-- (Disponible) » alors que Jérémie l'avait déjà dans son journal → on compare AUSSI par le nom, au cas
-- où le numéro de la quête de la base ne serait pas celui du jeu.
local logTitles = {}
local function ReadLogTitles()
    logTitles = {}
    if C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo then
        local ok, n = pcall(C_QuestLog.GetNumQuestLogEntries)
        for i = 1, (ok and n or 0) do
            local ok2, info = pcall(C_QuestLog.GetInfo, i)
            if ok2 and info and info.title and not info.isHeader then logTitles[info.title:lower()] = true end
        end
    elseif GetNumQuestLogEntries and GetQuestLogTitle then
        for i = 1, GetNumQuestLogEntries() do
            local title, _, _, isHeader = GetQuestLogTitle(i)
            if title and not isHeader then logTitles[title:lower()] = true end
        end
    end
end

local function Trivial(qLevel, level)
    local range = (GetQuestGreenRange and GetQuestGreenRange()) or 8
    return qLevel and qLevel > 0 and (level - qLevel) > range
end

-- Niveau d'un métier par son numéro (relevé automatique d'EryAddon), ou 0.
local function SkillLevel(skillID)
    local name = ns.METIERS and ns.METIERS[skillID]
    local v = name and EryAddonDB.niveaux and EryAddonDB.niveaux.metiers and EryAddonDB.niveaux.metiers[name]
    return v and tonumber(v:match("^(%d+)")) or 0
end

local function RepOK(rep)
    if type(rep) ~= "table" or not rep[1] then return true end
    if GetFactionInfoByID then
        local ok, _, _, _, _, _, barValue = pcall(GetFactionInfoByID, rep[1])
        if ok and type(barValue) == "number" then return barValue >= (rep[2] or 0) end
    end
    return false
end

local requested = {}
local QuestTitle -- plus bas
local function Available(qid, level)
    if Inconnues()[qid] or Done(qid) or InLog(qid) then return false end
    -- Le PNJ ne te l'a pas proposée quand tu lui as parlé (condition inconnue de la base : quête
    -- d'avant, quête pas encore ouverte sur Forever…) : cachée tant que ni ton niveau ni le nombre de
    -- quêtes rendues n'ont changé (ce qui peut l'ouvrir).
    local np = EryAddonDB.quetesNonProposees and EryAddonDB.quetesNonProposees[qid]
    if np and np.niv == level and np.rendues == (EryAddonDB.quetesRendues or 0) then return false end
    local title = QuestTitle(qid)
    if title and logTitles[title:lower()] then return false end
    local req = Get(DB.Quest, qid, "requiredLevel") or 0
    if req > level then return false end
    if Trivial(Get(DB.Quest, qid, "questLevel"), level) then return false end
    local single = Get(DB.Quest, qid, "preQuestSingle")
    if type(single) == "table" and single[1] then
        local any = false
        for _, p in ipairs(single) do if Done(p) then any = true break end end
        if not any then return false end
    end
    for _, p in ipairs(Get(DB.Quest, qid, "preQuestGroup") or {}) do
        if not Done(p) then return false end
    end
    for _, x in ipairs(Get(DB.Quest, qid, "exclusiveTo") or {}) do
        if Done(x) or InLog(x) then return false end
    end
    local skill = Get(DB.Quest, qid, "requiredSkill")
    if type(skill) == "table" and skill[1] and SkillLevel(skill[1]) < (skill[2] or 1) then return false end
    if not RepOK(Get(DB.Quest, qid, "requiredMinRep")) then return false end
    -- Le serveur connaît-il cette quête ? (Questie en affichait qui n'existent pas.) Réponse par
    -- QUEST_DATA_LOAD_RESULT ; une quête inconnue du serveur est retirée pour de bon.
    if not requested[qid] and C_QuestLog and C_QuestLog.RequestLoadQuestByID then
        requested[qid] = true
        pcall(C_QuestLog.RequestLoadQuestByID, qid)
    end
    return true
end

QuestTitle = function(qid)
    if C_QuestLog and C_QuestLog.GetTitleForQuestID then
        local ok, t = pcall(C_QuestLog.GetTitleForQuestID, qid)
        if ok and t and t ~= "" then return t end
    end
    return Get(DB.Quest, qid, "name") or ("Quête " .. qid)
end

---------------------------------------------------------------------------
-- Carte du monde
---------------------------------------------------------------------------
local function Canvas()
    return WorldMapFrame and WorldMapFrame.ScrollContainer and WorldMapFrame.ScrollContainer.Child
end

local function ShowTip(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    local s = self.starter
    local entity = s.kind == "n" and DB.Npc or DB.Object
    GameTooltip:AddLine(Get(entity, s.id, "name") or "?", 1, 1, 1)
    local shift = IsShiftKeyDown and IsShiftKeyDown()
    for _, qid in ipairs(self.quests) do
        local qLevel = Get(DB.Quest, qid, "questLevel") or 0
        local c = GetQuestDifficultyColor and GetQuestDifficultyColor(qLevel) or { r = 1, g = 0.82, b = 0 }
        GameTooltip:AddLine(string.format("[%d] %s", qLevel, QuestTitle(qid)), c.r, c.g, c.b)
        if shift then
            for _, line in ipairs(Get(DB.Quest, qid, "objectivesText") or {}) do
                GameTooltip:AddLine("   " .. line, 0.85, 0.85, 0.85, true)
            end
        end
    end
    if not shift then GameTooltip:AddLine("Maj : objectifs", 0.5, 0.5, 0.5) end
    GameTooltip:Show()
end

local function Pin(n)
    if pins[n] then return pins[n] end
    local child = Canvas()
    local p = CreateFrame("Button", nil, child)
    p:SetFrameLevel(child:GetFrameLevel() + 400)
    p.tex = p:CreateTexture(nil, "OVERLAY")
    p.tex:SetAllPoints()
    p.tex:SetTexture("Interface\\GossipFrame\\AvailableQuestIcon")
    p:SetScript("OnEnter", ShowTip)
    p:SetScript("OnLeave", function() GameTooltip:Hide() end)
    pins[n] = p
    return p
end

RefreshPins = function()
    for _, p in pairs(pins) do p:Hide() end
    if not (Quetes.enabled and DB and starters and WorldMapFrame and WorldMapFrame:IsShown() and Canvas()) then return end
    local list = starters[WorldMapFrame:GetMapID()]
    if not list then return end
    local child = Canvas()
    local w, h = child:GetWidth(), child:GetHeight()
    local level = UnitLevel("player") or 1
    ReadLogTitles()
    local n = 0
    for _, s in ipairs(list) do
        local avail = {}
        for _, qid in ipairs(s.quests) do
            if Available(qid, level) then avail[#avail + 1] = qid end
        end
        if avail[1] then
            for _, pos in ipairs(s.pos) do
                n = n + 1
                local p = Pin(n)
                p.starter, p.quests = s, avail
                p:SetSize(PIN_TAILLE, PIN_TAILLE)
                p:ClearAllPoints()
                p:SetPoint("CENTER", child, "TOPLEFT", w * pos[1] / 100, -h * pos[2] / 100)
                p:Show()
            end
        end
    end
end

-- Événements : quêtes prises / rendues, niveau, réponse du serveur, MAJ pour les objectifs.
-- Numéro du PNJ à qui tu parles (« Creature-0-…-numéro-… »).
local function TalkingNpc()
    local guid = UnitGUID and UnitGUID("npc")
    if not guid then return nil end
    local kind, _, _, _, _, id = strsplit("-", guid)
    if kind == "Creature" then return tonumber(id) end
end

-- offered : { [numéro] = true, [titre en minuscules] = true } = TOUT ce que le PNJ propose.
local lastList = 0
local function RecordOffer(offered)
    local npc = TalkingNpc()
    local list = npc and npcQuests[npc]
    if not list then return end
    EryAddonDB.quetesNonProposees = EryAddonDB.quetesNonProposees or {}
    local np = EryAddonDB.quetesNonProposees
    local level = UnitLevel("player") or 1
    for _, qid in ipairs(list) do
        local title = QuestTitle(qid)
        if offered[qid] or (title and offered[title:lower()]) then
            np[qid] = nil
        elseif not Done(qid) and not InLog(qid) then
            np[qid] = { niv = level, rendues = EryAddonDB.quetesRendues or 0 }
        end
    end
    if WorldMapFrame and WorldMapFrame:IsShown() then RefreshPins() end
end

local function OnGossip()
    if not (C_GossipInfo and C_GossipInfo.GetAvailableQuests) then return end
    local ok, quests = pcall(C_GossipInfo.GetAvailableQuests)
    if not ok or type(quests) ~= "table" then return end
    local offered = {}
    for _, q in ipairs(quests) do
        if q.questID then offered[q.questID] = true end
        if q.title then offered[q.title:lower()] = true end
    end
    lastList = GetTime()
    RecordOffer(offered)
end

local function OnGreeting()
    if not GetNumAvailableQuests then return end
    local offered = {}
    for i = 1, GetNumAvailableQuests() do
        local title = GetAvailableTitle and GetAvailableTitle(i)
        if title then offered[title:lower()] = true end
        if GetAvailableQuestInfo then
            local ok, _, _, _, _, id = pcall(GetAvailableQuestInfo, i)
            if ok and type(id) == "number" then offered[id] = true end
        end
    end
    lastList = GetTime()
    RecordOffer(offered)
end

-- Le PNJ ouvre directement UNE quête (pas de liste juste avant) : c'est la seule qu'il propose.
local function OnDetail()
    if GetTime() - lastList < 3 then return end
    local id = GetQuestID and GetQuestID()
    local title = GetTitleText and GetTitleText()
    if not id and not title then return end
    local offered = {}
    if id and id > 0 then offered[id] = true end
    if title then offered[title:lower()] = true end
    RecordOffer(offered)
end

pinFrame:SetScript("OnEvent", function(_, event, a1, a2)
    if event == "GOSSIP_SHOW" then pcall(OnGossip) return end
    if event == "QUEST_GREETING" then pcall(OnGreeting) return end
    if event == "QUEST_DETAIL" then pcall(OnDetail) return end
    if event == "QUEST_TURNED_IN" then EryAddonDB.quetesRendues = (EryAddonDB.quetesRendues or 0) + 1 end
    if event == "QUEST_DATA_LOAD_RESULT" then
        if a2 == false and a1 then
            Inconnues()[a1] = true -- quête inconnue du serveur : jamais affichée
            if WorldMapFrame and WorldMapFrame:IsShown() then RefreshPins() end
        end
        return
    end
    if event == "MODIFIER_STATE_CHANGED" then
        local owner = GameTooltip:IsShown() and GameTooltip:GetOwner()
        if owner and owner.starter and owner.quests then ShowTip(owner) end
        return
    end
    if WorldMapFrame and WorldMapFrame:IsShown() then RefreshPins() end
end)

local hooked = false
local function HookMap()
    if hooked or not WorldMapFrame then return end
    hooked = true
    WorldMapFrame:HookScript("OnShow", function() BuildIndex(); RefreshPins() end)
    if WorldMapFrame.OnMapChanged then hooksecurefunc(WorldMapFrame, "OnMapChanged", RefreshPins) end
end

function Quetes.Enable()
    Quetes.enabled = true
    for _, ev in ipairs({ "QUEST_LOG_UPDATE", "QUEST_TURNED_IN", "PLAYER_LEVEL_UP", "QUEST_DATA_LOAD_RESULT",
        "MODIFIER_STATE_CHANGED", "GOSSIP_SHOW", "QUEST_GREETING", "QUEST_DETAIL" }) do
        pcall(pinFrame.RegisterEvent, pinFrame, ev)
    end
    HookMap()
    if not hooked and EventUtil and EventUtil.ContinueOnAddOnLoaded then
        EventUtil.ContinueOnAddOnLoaded("Blizzard_WorldMap", HookMap)
    end
    C_Timer.After(8, BuildIndex) -- index construit en arrière-plan après la connexion
end

function Quetes.Disable()
    Quetes.enabled = false
    pinFrame:UnregisterAllEvents()
    for _, p in pairs(pins) do p:Hide() end
end

-- SONDE (pour savoir si le jeu donne lui-même les quêtes disponibles, sans base de données) :
-- 10 s après la connexion, note dans EryAddonDB.sondeQuetes ce que le client sait faire. Claude lit
-- la sauvegarde. C_QuestLine.GetAvailableQuestLines(carte) = quêtes disponibles fournies par le
-- SERVEUR (client moderne) ; on regarde s'il existe sur Forever et ce qu'il renvoie.
local function Sonde()
    local r = { date = date("%d/%m %H:%M"), niveau = UnitLevel("player") }
    r.C_QuestLine = type(C_QuestLine)
    if type(C_QuestLine) == "table" then
        r.fonctions = {}
        for k in pairs(C_QuestLine) do r.fonctions[#r.fonctions + 1] = k end
        table.sort(r.fonctions)
    end
    local map = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    r.carte = map
    if map and C_QuestLine and C_QuestLine.GetAvailableQuestLines then
        if C_QuestLine.RequestQuestLinesForMap then pcall(C_QuestLine.RequestQuestLinesForMap, map) end
        C_Timer.After(3, function()
            local ok, lines = pcall(C_QuestLine.GetAvailableQuestLines, map)
            r.disponibles = ok and {} or ("erreur : " .. tostring(lines))
            if ok and type(lines) == "table" then
                for i, l in ipairs(lines) do
                    if i > 30 then break end
                    r.disponibles[#r.disponibles + 1] = string.format("%s | quête %s | %s, %s",
                        tostring(l.questLineName or l.questName), tostring(l.questID),
                        tostring(l.x), tostring(l.y))
                end
            end
            EryAddonDB.sondeQuetes = r
        end)
    end
    r.GetQuestsOnMap = type(C_QuestLog and C_QuestLog.GetQuestsOnMap)
    r.RequestLoadQuestByID = type(C_QuestLog and C_QuestLog.RequestLoadQuestByID)
    r.GetAvailableQuests = type(C_GossipInfo and C_GossipInfo.GetAvailableQuests)
    EryAddonDB.sondeQuetes = r
end
local sondeFrame = CreateFrame("Frame")
sondeFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
sondeFrame:SetScript("OnEvent", function(self)
    self:UnregisterAllEvents()
    C_Timer.After(10, function() pcall(Sonde) end)
end)

ns._QuetesBuild = function() starters = nil; building = false; BuildIndex() end -- (test hors jeu)
ns._QuetesStarters = function() return starters end
ns._QuetesAvailable = function(qid, level) DB = _G.LibQuestieDB; return Available(qid, level) end
ns._QuetesOffer = function(npc, offered) -- (test hors jeu)
    local real = UnitGUID
    UnitGUID = function() return "Creature-0-0-0-0-" .. npc .. "-0" end
    RecordOffer(offered)
    UnitGUID = real
end
