-- EryAddon : hôtel des ventes - fenêtre « Anomalies »
-- Liste les objets en vente MOINS CHER que ce que le marchand (PNJ) en donne,
-- et permet de les acheter un clic à la fois, en revérifiant le prix à chaque clic.
--
-- Forever utilise le NOUVEL hôtel des ventes (C_AuctionHouse), comme Auctionator.
-- Rappels du jeu :
--   - scan page par page (SendBrowseQuery), sans limite de temps, comme Auctionator ;
--     (le scan « complet » ReplicateItems, lui, est limité à 1 fois / 15 min : pas utilisé) ;
--   - chaque achat exige un clic du joueur (aucun achat automatique possible).

local ADDON_NAME, ns = ...
local Msg = ns.Msg
local issecret = ns.issecret

local HV = {
    key = "hvAnomalies",
    label = "Hôtel des ventes : fenêtre Anomalies",
}
table.insert(ns.features, HV)
ns.DEFAULTS.hvAnomalies = true

local PRICE_SORT = { {
    sortOrder = (Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price) or 0, -- tri par prix
    reverseSort = false,
} }

---------------------------------------------------------------------------
-- Petits outils
---------------------------------------------------------------------------
-- Somme d'argent avec les icônes or / argent / cuivre.
-- (GetCoinTextureString n'existe pas sur Forever : on le fait nous-mêmes.)
local GOLD = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t"
local SILVER = "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t"
local COPPER = "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t"

local function Money(copper)
    copper = math.floor((copper or 0) + 0.5)
    local g = math.floor(copper / 10000)
    local s = math.floor(copper / 100) % 100
    local c = copper % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = g .. GOLD end
    if s > 0 then parts[#parts + 1] = s .. SILVER end
    if c > 0 or #parts == 0 then parts[#parts + 1] = c .. COPPER end
    return table.concat(parts, " ")
end
ns.Money = Money -- partagé avec EryAddon_Jobs.lua

-- Plafond d'UN clic d'achat dans Anomalies : la moitié de ta bourse (demande de Jérémie : « quand je
-- n'ai pas assez de sous, acheter quand même, jusqu'à 50 % de ma bourse »). Un lot trop cher est
-- acheté en partie, dans cette limite.
local BUDGET_PART = 0.5
local function Budget()
    return math.floor(GetMoney() * BUDGET_PART)
end

-- Nom, icône, taille de pile et prix marchand d'un objet (nil si pas encore chargé).
local function ItemData(itemID)
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    local name, _, _, _, _, _, _, maxStack, _, icon, sellPrice = getInfo(itemID)
    return name, icon, maxStack, sellPrice
end

-- Objet « marchandise » (empilable, vendu à l'unité, ex. Dard de scorpide)
-- ou objet unique (ex. une arme) ? Les deux s'achètent différemment.
local function IsCommodity(itemID)
    -- Cette fonction refuse un simple numéro d'objet : on lui donne le lien de l'objet.
    -- Protégée par pcall : si elle refuse encore, on se rabat sur la taille de pile.
    local kinds = Enum.ItemCommodityStatus
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    local _, link = getInfo(itemID)
    if C_AuctionHouse.GetItemCommodityStatus and kinds and link then
        local ok, status = pcall(C_AuctionHouse.GetItemCommodityStatus, link)
        if ok and status == kinds.Commodity then return true end
        if ok and status == kinds.Item then return false end
    end
    local _, _, maxStack = ItemData(itemID)
    return (maxStack or 1) > 1
end

-- Résultats du scan. Attention : « hvAnomalies » est déjà pris par la case à cocher
-- (vrai/faux) ; les données ont donc leur propre nom.
-- Objets non empilables (patrons, armes…) : chaque exemplaire est une enchère à part,
-- le jeu n'en vend qu'UN par achat (constaté avec le Patron : Sac vert en laine).
local function OnePerPurchase(itemID)
    local _, _, maxStack = ItemData(itemID)
    return (maxStack or 1) <= 1
end

local function Saved()
    local s = EryAddonDB.hvScan
    -- (Une liste de l'ancienne version, sans « unitGain », est oubliée.)
    if type(s) ~= "table" or (s.items and s.items[1] and not s.items[1].unitGain) then
        EryAddonDB.hvScan = { items = {} }
    end
    return EryAddonDB.hvScan
end

local UpdateWindow -- défini plus bas

---------------------------------------------------------------------------
-- Scan de l'HV, page par page (même méthode que le scan par défaut d'Auctionator)
-- Pas de limite de 15 min : on demande au serveur la liste de tous les objets en
-- vente, avec pour chacun son PRIX LE PLUS BAS. Les anomalies s'affichent au fil
-- des pages ; à la fin, une vérification lit le détail (quantité, gain du lot).
---------------------------------------------------------------------------
local scanRunning = false
local scanResults, scanToken = {}, 0
local scanQty = {} -- [objet] = quantité en vente
local scanKeys, lastScanKeys = {}, {} -- [objet] = clé de recherche vue au scan (pour l'étude du marché)
local statusText = ""
-- Version COURTE de l'état (« EDM 71/3711 », « Scan : 1200 objets »), affichée sous les boutons de scan
-- collés à droite de l'HV (demande de Jérémie). sideStatus = le texte, créé avec les onglets.
local shortText, sideStatus = "", nil
-- Scan global (demande de Jérémie : « tout scanner, avant d'aller me coucher, même si ça dure 1 h ») :
-- scan + étude du marché de TOUS les objets de l'HV, sans la limite de 10 min ni l'âge minimal du relevé.
local globalMode = false

local function UpdateSide()
    if not sideStatus then return end
    local t = shortText
    if t == "" then
        local s = EryAddonDB and EryAddonDB.hvScan
        t = (type(s) == "table" and s.time) and string.format("Dernier scan :\nil y a %d min", math.floor((time() - s.time) / 60))
            or "Aucun scan"
    end
    sideStatus:SetText(t)
end

local function SetStatus(text, short)
    statusText = text
    shortText = short or ""
    UpdateSide()
    if UpdateWindow then UpdateWindow() end
end

local StartDetails -- défini plus bas : vérification des quantités après le scan
local SaveStudyKeys -- défini plus bas : clés de recherche de l'étude du marché

-- Liste affichée PENDANT le scan (demande de Jérémie) : chaque page reçue ajoute
-- tout de suite ses anomalies. liveSeen[id] = la ligne, ou false si l'objet a été
-- regardé et n'est pas une anomalie (pour l'instant).
local liveList, liveSeen = {}, {}

local function SortByUnitGain(list)
    table.sort(list, function(a, b) return a.unitGain > b.unitGain end)
end

-- Regarde un objet : si son prix le plus bas est sous le prix marchand, il entre
-- dans la liste (ou sa ligne est mise à jour). Renvoie false si les infos de
-- l'objet ne sont pas encore chargées par le jeu.
-- « Prix fantômes » : le scan voit un prix bas, mais la vérification ne trouve aucune enchère
-- achetable à ce prix (enchère sans achat immédiat, ta propre enchère…). On retient l'objet et
-- ce prix pour ne plus le proposer, tant que son prix le plus bas ne change pas.
-- (Bug signalé : Épée d'entraînement « +6 pc » à chaque scan, alors qu'aucune n'était à vendre.)
local function Phantoms()
    EryAddonDB.hvFantomes = EryAddonDB.hvFantomes or {}
    return EryAddonDB.hvFantomes
end

local function MarkExhausted(e)
    if e and e.minPrice then Phantoms()[e.id] = e.minPrice end
end

-- Clé de recherche d'un objet. Pour une arme / armure, la clé doit contenir le niveau d'objet :
-- on garde celle que donne le scan (bug : Épée d'entraînement jamais trouvée avec MakeItemKey(id)).
local function SearchKey(e)
    return e.itemKey or C_AuctionHouse.MakeItemKey(e.id)
end

local function ConsiderItem(itemID, minPrice, itemKey)
    local name, icon, _, vendor = ItemData(itemID)
    if not name or vendor == nil then return false end
    local entry = liveSeen[itemID]
    if Phantoms()[itemID] == minPrice then
        if entry == nil then liveSeen[itemID] = false end
        return true
    end
    Phantoms()[itemID] = nil -- prix différent : on le réexamine
    if minPrice < vendor then
        if entry then
            if vendor - minPrice > entry.unitGain then
                entry.unitGain, entry.minPrice, entry.itemKey = vendor - minPrice, minPrice, itemKey or entry.itemKey
            end
        else
            entry = {
                id = itemID, name = name, icon = icon, vendor = vendor, minPrice = minPrice, itemKey = itemKey,
                unitGain = vendor - minPrice, -- gain sur la moins chère, avant vérification
            }
            liveList[#liveList + 1] = entry
            liveSeen[itemID] = entry
        end
    elseif entry == nil then
        liveSeen[itemID] = false
    end
    return true
end

-- Fin du scan : on traite les objets dont les infos n'étaient pas encore chargées
-- (3 essais, 2 s d'écart), puis on lance la vérification des quantités.
local function FinishScan(missing, attempt)
    local still, count = {}, 0
    for itemID, minPrice in pairs(missing) do
        if not ConsiderItem(itemID, minPrice) then
            still[itemID] = minPrice
            count = count + 1
            if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(itemID) end
        end
    end
    if count > 0 and attempt < 3 then
        SortByUnitGain(liveList)
        SetStatus(string.format("Chargement des infos de %d objets…", count), "Scan : fin…")
        C_Timer.After(2, function() FinishScan(still, attempt + 1) end)
        return
    end

    SortByUnitGain(liveList)
    local saved = Saved()
    saved.items = liveList
    saved.time = time()
    scanRunning = false
    SetStatus("")
    Msg(string.format("scan de l'HV terminé : %d objets moins chers qu'au marchand.", #liveList))
    StartDetails(liveList)
end

local function AddBrowseResults(results)
    local changed = false
    for _, r in ipairs(results or {}) do
        local id = r.itemKey and r.itemKey.itemID
        if id and r.minPrice and r.minPrice > 0 and (r.totalQuantity or 0) > 0 then
            scanQty[id] = math.max(scanQty[id] or 0, r.totalQuantity)
            if not scanKeys[id] then scanKeys[id] = r.itemKey end
            if not scanResults[id] or r.minPrice < scanResults[id] then
                scanResults[id] = r.minPrice
                local before = #liveList
                ConsiderItem(id, r.minPrice, r.itemKey)
                if #liveList ~= before then changed = true end
            end
        end
    end
    if changed then SortByUnitGain(liveList) end
end

-- Seule l'étude du marché (annonces suivies) compte. L'ancienne estimation par baisse de quantité
-- entre deux scans donnait n'importe quoi (« Acide sulfurique : 2 984 ventes par jour ») : la quantité
-- lue par le scan varie sans qu'il y ait de vente. Elle est abandonnée.
function ns.HVSalesPerDay(itemID)
    local st = ns.MarketState and ns.MarketState(itemID)
    if st and st.parJour then return st.parJour end
    return nil
end

-- Page suivante, ou fin du scan quand le serveur a tout envoyé.
local function NextPage()
    if C_AuctionHouse.HasFullBrowseResults() then
        -- Objets pas encore regardés (infos non chargées pendant le scan).
        local missing = {}
        for id, price in pairs(scanResults) do
            if liveSeen[id] == nil then missing[id] = price end
        end
        -- Tous les prix du scan (prix le plus bas + quantité en vente), gardés pour
        -- l'étude des métiers (EryAddon_Metiers.lua, analysée par Claude).
        EryAddonDB.hvEcoul = nil -- ancienne estimation entre deux scans : abandonnée (voir ns.HVSalesPerDay)
        EryAddonDB.hvPrix = { date = date("%d/%m/%Y %H:%M"), t = time(), prix = scanResults, quantites = scanQty }
        if ns.JobsRefresh then ns.JobsRefresh() end -- nouveaux prix : Jobs et guide recalculés
        lastScanKeys = scanKeys
        pcall(SaveStudyKeys)
        scanResults, scanQty, scanKeys = {}, {}, {}
        FinishScan(missing, 1)
        return
    end
    local count = 0
    for _ in pairs(scanResults) do count = count + 1 end
    SetStatus(string.format("Scan en cours : %d objets lus, %d anomalies…", count, #liveList),
        string.format("Scan : %d objets", count))
    scanToken = scanToken + 1
    local token = scanToken
    C_AuctionHouse.RequestMoreBrowseResults()
    -- Le serveur limite le rythme des demandes : sans réponse, on redemande.
    C_Timer.After(5, function()
        if scanRunning and token == scanToken then NextPage() end
    end)
end

local function OnBrowseEvent(event, added)
    if not scanRunning then return end
    if event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then
        AddBrowseResults(C_AuctionHouse.GetBrowseResults())
    else
        AddBrowseResults(added)
    end
    NextPage()
end

local function StartScan()
    if scanRunning then return end
    -- Vérification / étude du marché en cours (ex. 12/30) : on l'arrête, pour que ses recherches ne
    -- se mêlent pas aux pages du scan ; elle repart d'elle-même à la fin du nouveau scan.
    if ns._StopDetails then ns._StopDetails() end
    scanRunning = true
    scanResults, scanQty, scanKeys = {}, {}, {}
    -- Nouvelle liste vide, remplie au fil des pages.
    liveList, liveSeen = {}, {}
    Saved().items = liveList
    scanToken = scanToken + 1
    local token = scanToken
    SetStatus("Scan demandé au serveur…", "Scan : envoi…")
    C_AuctionHouse.SendBrowseQuery({ searchString = "", sorts = {}, filters = {}, itemClassFilters = {} })
    C_Timer.After(10, function()
        if scanRunning and token == scanToken then
            scanRunning, globalMode = false, false
            SetStatus("Le serveur n'a pas répondu. Réessaie dans quelques secondes.", "Pas de réponse")
        end
    end)
end

---------------------------------------------------------------------------
-- Achat : un objet à la fois, nouvelle recherche après chaque achat
---------------------------------------------------------------------------
-- États : nil (rien choisi), "searching", "ready", "starting", "confirm",
--         "buying", "done" (plus rentable), "retry" (la recherche n'a pas répondu)
local Buyer = {}
local searchToken = 0

local function Search()
    local e = Buyer.entry
    if not e then return end
    Buyer.state = "searching"
    Buyer.autoConfirm = false
    searchToken = searchToken + 1
    local token = searchToken
    C_AuctionHouse.SendSearchQuery(SearchKey(e), PRICE_SORT, Buyer.commodity == false)
    C_Timer.After(4, function()
        if Buyer.state == "searching" and token == searchToken then
            Buyer.state = "retry"
            UpdateWindow()
        end
    end)
    UpdateWindow()
end

---------------------------------------------------------------------------
-- Compte rendu de chaque achat dans le chat, d'après ce qui s'est VRAIMENT passé :
--   prix payé  = argent avant − argent après ;
--   quantité   = enchères gagnées annoncées par le jeu (et non la quantité demandée).
-- Bilan fait 1,5 s après la réponse du serveur, le temps que l'argent et les objets
-- arrivent. Si l'achat n'était pas rentable : alerte rouge et achats de cet objet
-- arrêtés (garde-fou ajouté après le test du Patron : Sac vert en laine).
-- Chaque achat est aussi noté dans EryAddonDB.hvJournal (50 derniers) pour la mise au point.
---------------------------------------------------------------------------
-- Achats en attente du bilan, UN PAR OBJET : plusieurs achats peuvent se chevaucher
-- (clics rapides sur deux lignes). 1re version : un seul achat suivi à la fois, et l'argent
-- de la Dynamite a été compté dans la Malachite : fausse alerte « PERTE ».
-- File d'enchères : plusieurs achats du même objet peuvent être en cours en même temps,
-- donc chaque achat a son propre numéro de suivi.
local pendings = {}  -- [n° de suivi] = achat
local pendingSeq = 0
local lastPending    -- le plus récent (pour les événements qui ne disent pas quel objet)

local function ItemCount(itemID)
    local count = (C_Item and C_Item.GetItemCount) or GetItemCount
    return (count and count(itemID)) or 0
end

local function JournalAchat(line)
    EryAddonDB.hvJournal = EryAddonDB.hvJournal or {}
    local log = EryAddonDB.hvJournal
    log[#log + 1] = line
    while #log > 50 do table.remove(log, 1) end
end

-- BILAN CUMULÉ des achats d'Anomalies (demande de Jérémie, 08/11) : tout ce qui est acheté ici est
-- supposé revendu au marchand. EryAddonDB.anoBilan = { n (achats), objets, paye, revente (pc), debut }.
-- Jamais effacé. 1re fois : reprise de l'historique dans le journal (50 derniers achats, ceux où des
-- objets ont été reçus).
local function AnoBilan()
    local b = EryAddonDB.anoBilan
    if type(b) == "table" then return b end
    b = { n = 0, objets = 0, paye = 0, revente = 0 }
    for _, line in ipairs(EryAddonDB.hvJournal or {}) do
        local d, recu, paye, marchand = line:match(
            "^(%d+/%d+) [%d:]+ .-%(id %d+%) : demandé %d+, reçu (%d+), payé (%-?%d+) pc, prix marchand (%d+) pc")
        recu, paye, marchand = tonumber(recu), tonumber(paye), tonumber(marchand)
        if recu and recu > 0 and paye and marchand then
            b.n, b.objets = b.n + 1, b.objets + recu
            b.paye, b.revente = b.paye + paye, b.revente + marchand * recu
            b.debut = b.debut or d
        end
    end
    b.debut = b.debut or date("%d/%m")
    EryAddonDB.anoBilan = b
    return b
end

local function AddAnoBilan(received, paid, vendorUnit)
    local b = AnoBilan()
    b.n, b.objets = b.n + 1, b.objets + received
    b.paye, b.revente = b.paye + paid, b.revente + vendorUnit * received
end

-- unitArg / totalArg : prix annoncés par le serveur (objets empilables), pour le journal.
local function ExpectPurchase(qty, expected, unitArg)
    local e = Buyer.entry
    -- Les autres achats en cours se chevauchent avec celui-ci : leur argent se mélange.
    for _, other in pairs(pendings) do other.overlap = true end
    pendingSeq = pendingSeq + 1
    local p = {
        key = pendingSeq, entry = e, id = e.id, name = e.name, vendor = e.vendor, qty = qty,
        expected = expected, unitArg = unitArg,
        before = GetMoney(), countBefore = ItemCount(e.id),
        overlap = next(pendings) ~= nil,
    }
    pendings[pendingSeq] = p
    lastPending = p
    return p
end

-- Le plus ANCIEN achat en attente qui correspond et n'a pas encore reçu tout ce qu'il
-- attend (compteur « wonChat » ou « wonEvent ») : chaque annonce de victoire va au bon achat.
local function OldestPending(match, counter)
    local best
    for _, p in pairs(pendings) do
        if not p.reporting and match(p) and (p[counter] or 0) < p.qty and (not best or p.key < best.key) then
            best = p
        end
    end
    return best
end

local function PendingByText(text, counter)
    return OldestPending(function(p) return text:find(p.name, 1, true) ~= nil end, counter)
end

local ReportPurchase -- défini plus bas

---------------------------------------------------------------------------
-- ACHATS EN ROUTE : ce qu'on gagne à l'HV arrive par COURRIER, pas dans les sacs. Pour que Jobs
-- compte « 16/16 » tout de suite (demande de Jérémie), on note chaque achat :
-- EryAddonDB.enRoute[objet] = { q = quantité achetée, base = nombre dans les sacs au 1er achat, t }.
-- Possédé = max(sacs, base + q) ; la note disparaît quand les sacs ont tout reçu, quand la boîte aux
-- lettres ouverte ne contient plus l'objet, ou après 3 jours.
---------------------------------------------------------------------------
local function BagCount(itemID)
    local count = (C_Item and C_Item.GetItemCount) or GetItemCount
    return (count and count(itemID)) or 0
end

function ns.AddInbound(itemID, qty)
    if not itemID or not qty or qty <= 0 then return end
    EryAddonDB.enRoute = EryAddonDB.enRoute or {}
    local r = EryAddonDB.enRoute[itemID]
    if r then
        r.q, r.t = r.q + qty, time()
    else
        EryAddonDB.enRoute[itemID] = { q = qty, base = BagCount(itemID), t = time() }
    end
    if ns.JobsRefresh then C_Timer.After(0.2, ns.JobsRefresh) end
end

-- Quantité possédée (sacs + achats en route), et la part encore au courrier.
function ns.Owned(itemID)
    local bag = BagCount(itemID)
    local r = EryAddonDB and EryAddonDB.enRoute and EryAddonDB.enRoute[itemID]
    if not r then return bag, 0 end
    if bag >= r.base + r.q or time() - r.t > 3 * 86400 then
        EryAddonDB.enRoute[itemID] = nil
        return bag, 0
    end
    return r.base + r.q, r.base + r.q - bag
end

-- Boîte aux lettres ouverte : un objet en route qui n'y est plus a été pris (et peut-être déjà
-- utilisé) → on l'oublie. (2 minutes de grâce : le courrier d'un achat peut arriver en retard.)
local mailFrame = CreateFrame("Frame")
pcall(mailFrame.RegisterEvent, mailFrame, "MAIL_INBOX_UPDATE")
mailFrame:SetScript("OnEvent", function()
    local route = EryAddonDB and EryAddonDB.enRoute
    if not route or not next(route) or not GetInboxNumItems then return end
    local inMail = {}
    for i = 1, GetInboxNumItems() do
        for a = 1, (ATTACHMENTS_MAX_RECEIVE or 16) do
            local ok, _, id = pcall(GetInboxItem, i, a)
            if ok and id then inMail[id] = true end
        end
    end
    local changed = false
    for id, r in pairs(route) do
        if not inMail[id] and time() - r.t > 120 then route[id] = nil; changed = true end
    end
    if changed and ns.JobsRefresh then ns.JobsRefresh() end
end)

-- Combien d'objets a-t-on VRAIMENT gagnés ? Le jeu l'annonce de plusieurs façons
-- selon les versions ; on écoute tout, sans compter deux fois :
--   1. événements de l'HV (objet gagné, marchandise gagnée avec sa quantité) ;
--   2. à défaut, la ligne jaune du chat « Vous avez gagné les enchères pour X (x8) ».
-- (1re version : seul CHAT_MSG_SYSTEM était écouté, mais sur Forever cette ligne ne
-- passe pas par là : 5 pa annoncés « payés sans enchère gagnée » pour une Petite
-- bourse bleue bel et bien gagnée.)
local function StripColors(text)
    return (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h(.-)|h", "%1"))
end

local function CountFromText(text)
    local n = text:match("%(x(%d+)%)")
    return tonumber(n) or 1
end

-- Événement : marchandise gagnée (numéro d'objet, quantité).
local function OnCommodityWon(itemID, quantity)
    if issecret(itemID) then return end
    local p = OldestPending(function(q) return q.id == itemID end, "wonEvent")
    if not p then return end
    p.wonEvent = (p.wonEvent or 0) + (tonumber(quantity) or 1)
end

-- Événement : notification de l'HV avec un texte (objet unique gagné).
local function OnFormattedNotification(notification, text)
    if type(text) ~= "string" or issecret(text) then return end
    local kinds = Enum.AuctionHouseNotification
    if kinds and notification ~= kinds.AuctionWon then return end
    text = StripColors(text)
    local p = PendingByText(text, "wonEvent")
    if not p then return end
    p.wonEvent = (p.wonEvent or 0) + CountFromText(text)
end

-- Secours : la ligne affichée dans la fenêtre de chat.
local function OnChatLine(_, text)
    if not next(pendings) or type(text) ~= "string" or issecret(text) then return end
    text = StripColors(text)
    if not text:find("gagné les enchères", 1, true) then return end
    local p = PendingByText(text, "wonChat")
    if not p then return end
    p.wonChat = (p.wonChat or 0) + CountFromText(text)
    ReportPurchase(p) -- victoire annoncée : bilan 1,5 s plus tard
end
if DEFAULT_CHAT_FRAME then hooksecurefunc(DEFAULT_CHAT_FRAME, "AddMessage", OnChatLine) end

-- Arrête les achats d'un objet après une mauvaise surprise.
local function BlockEntry(e)
    e.blocked, e.done = true, true
    if Buyer.entry == e then Buyer.state, Buyer.queue = "done", {} end
end

ReportPurchase = function(p)
    p = p or lastPending
    if not p or p.reporting then return end
    p.reporting = true
    C_Timer.After(1.5, function()
        pendings[p.key] = nil
        local received = (p.wonChat and p.wonChat > 0 and p.wonChat) or p.wonEvent or 0
        if received == 0 then received = ItemCount(p.id) - p.countBefore end -- au cas où
        -- Prix payé : le prix annoncé par le serveur (ou celui de l'enchère) quand on a reçu
        -- la quantité prévue : exact, même si d'autres achats ont lieu en même temps.
        -- Sinon au prorata ; sinon (rien d'annoncé) la baisse de l'argent.
        local moneyDrop = p.before - GetMoney()
        local paid
        if p.expected and received == p.qty then
            paid = p.expected
        elseif p.expected and received > 0 and p.qty > 0 then
            paid = math.floor(p.expected * received / p.qty + 0.5)
        else
            paid = moneyDrop
        end
        AnoBilan() -- (reprise de l'historique AVANT d'écrire cet achat dans le journal : pas de double compte)
        JournalAchat(string.format("%s %s (id %d) : demandé %d, reçu %d, payé %d pc, prix marchand %d pc, "
            .. "annoncé total %s / unité %s", date("%d/%m %H:%M:%S"), p.name, p.id, p.qty, received, paid,
            p.vendor, tostring(p.expected), tostring(p.unitArg)))

        local blocked = false
        if received > 0 then
            ns.AddInbound(p.id, received) -- arrive par courrier
            AddAnoBilan(received, paid, p.vendor)
            local resale = p.vendor * received
            if resale > paid then
                Msg(string.format("|cff00ff00acheté|r %d x %s pour %s (%s l'unité). Revente au marchand : %s, gain %s.",
                    received, p.name, Money(paid), Money(paid / received), Money(resale), Money(resale - paid)))
            else
                Msg(string.format("|cffff3333PERTE|r : %d x %s payés %s (%s l'unité), le marchand n'en donne que %s. "
                    .. "Achats de cet objet arrêtés.", received, p.name, Money(paid), Money(paid / received), Money(resale)))
                blocked = true
            end
            if received ~= p.qty then
                Msg(string.format("   (quantité demandée : %d, reçue : %d)", p.qty, received))
            end
        elseif moneyDrop > 0 and p.overlap then
            -- Plusieurs achats en même temps : impossible de savoir à qui est cet argent.
            Msg(string.format("|cffff9933à vérifier|r : %s, aucune enchère gagnée annoncée (plusieurs achats "
                .. "en même temps).", p.name))
        elseif moneyDrop > 0 then
            Msg(string.format("|cffff9933attention|r : %s payés pour %s, mais aucune enchère gagnée n'a été "
                .. "annoncée. Achats de cet objet arrêtés par prudence.", Money(moneyDrop), p.name))
            blocked = true
        else
            Msg(string.format("|cffff6666achat non fait|r : %s. Rien n'a été payé.", p.name))
        end

        if blocked then BlockEntry(p.entry) end
        -- Nouvelle recherche seulement quand la file est vide et tous les achats sont réglés.
        if Buyer.state == "buying" and not next(pendings) then Search() else UpdateWindow() end
    end)
end

local function ReportFailure(reason, p)
    p = p or lastPending
    if not p or p.reporting then return end
    pendings[p.key] = nil
    Msg(string.format("|cffff6666achat non fait|r : %s (%s). Rien n'a été payé.", p.name, reason))
end

-- Filet de sécurité : sans nouvelle du serveur après 4 s, on regarde l'argent.
local function WatchPurchase(p)
    p = p or lastPending
    C_Timer.After(4, function()
        if pendings[p.key] ~= p or p.reporting then return end -- déjà traité
        if (p.wonEvent or 0) > 0 or (p.wonChat or 0) > 0 or (GetMoney() < p.before and not p.overlap) then
            ReportPurchase(p)
        else
            ReportFailure("l'enchère a sans doute déjà été achetée par quelqu'un d'autre", p)
            if Buyer.state == "buying" and not next(pendings) then Search() else UpdateWindow() end
        end
    end)
end

-- FILE D'ENCHÈRES (objets non empilables, demande de Jérémie) : la recherche a donné la liste
-- précise des enchères rentables, avec leur prix. Chaque clic achète directement la suivante,
-- À SON PRIX, sans nouvelle recherche. Si elle est déjà partie : rien n'est payé, le clic
-- suivant prend la suivante. On ne recherche à nouveau que quand la file est vide.
local function BuyNextAuction()
    local e = Buyer.entry
    local q = Buyer.queue or {}
    local skipped = 0
    while q[1] and q[1].buyoutAmount > Budget() do table.remove(q, 1); skipped = skipped + 1 end -- > 50 % de la bourse
    local a = q[1]
    if not a then
        if skipped > 0 then
            Msg(string.format("%s : chaque exemplaire coûte plus de la moitié de ta bourse (%s). Pas d'achat.",
                e.name, Money(Budget())))
            Buyer.state = "done"
            UpdateWindow()
            return
        end
        Search(); return
    end
    -- Une ligne peut regrouper plusieurs exemplaires au même prix : on la garde tant qu'il en reste.
    a.left = (a.left or a.quantity or 1) - 1
    if a.left <= 0 then table.remove(q, 1) end
    local p = ExpectPurchase(1, a.buyoutAmount) -- un achat = un exemplaire
    C_AuctionHouse.PlaceBid(a.auctionID, a.buyoutAmount)
    WatchPurchase(p)
    Buyer.queue = q
    Buyer.auction = q[1]
    Buyer.state = q[1] and "ready" or "buying"
    if e.qty then e.qty = math.max(0, e.qty - 1) end
    UpdateWindow()
end

local prefetch -- objet dont la recherche « au survol » est en cours (voir Prefetch plus bas)

function Buyer.Select(entry)
    if entry.blocked then
        Msg(entry.name .. " : achats arrêtés après une mauvaise surprise. Relance un scan pour réessayer.")
        return
    end
    if Buyer.state == "starting" or Buyer.state == "confirm" then
        C_AuctionHouse.CancelCommoditiesPurchase()
    end
    Buyer.entry = entry
    Buyer.commodity = IsCommodity(entry.id)

    if Buyer.commodity and not entry.done then
        -- ACHAT EXPRESS (objets empilables) : pas de recherche, on demande tout de suite
        -- au serveur le prix de N unités. Ce clic compte comme le 1er clic d'achat ;
        -- s'il reste rentable, le bouton passe à « Confirmer ».
        -- N = quantité rentable trouvée lors d'une recherche précédente, sinon 1
        -- (la moins chère est forcément sous le prix marchand d'après le scan).
        Buyer.qty = (entry.qty and entry.qty > 0) and entry.qty or 1
        if OnePerPurchase(entry.id) then Buyer.qty = 1 end
        -- Lot trop cher pour ta bourse : on commence par 1, la recherche ajustera ensuite.
        -- Lot plus cher que la moitié de ta bourse : on en prend la part que tu peux payer.
        local lotCost = entry.profit and (entry.vendor * Buyer.qty - entry.profit)
        if lotCost and lotCost > Budget() then
            local unit = lotCost / Buyer.qty
            local part = math.floor(Budget() / unit)
            if part < 1 then
                Msg(string.format("%s : un seul exemplaire coûte plus de la moitié de ta bourse (%s). Pas d'achat.",
                    entry.name, Money(Budget())))
                return
            end
            Msg(string.format("%s : %d sur %d (la moitié de ta bourse, %s).", entry.name, part, Buyer.qty, Money(Budget())))
            Buyer.qty = part
        end
        Buyer.state = "starting"
        C_AuctionHouse.StartCommoditiesPurchase(entry.id, Buyer.qty)
        -- Sans réponse du serveur, on repasse par une recherche normale.
        C_Timer.After(4, function()
            if Buyer.entry == entry and Buyer.state == "starting" then
                C_AuctionHouse.CancelCommoditiesPurchase()
                Search()
            end
        end)
        UpdateWindow()
    elseif not Buyer.commodity and entry.queue and #entry.queue > 0 and not entry.done then
        -- OBJET UNIQUE EN UN CLIC : les enchères rentables sont déjà connues (vérification
        -- après le scan) : on achète tout de suite la 1re de la file.
        Buyer.queue, entry.queue = entry.queue, nil
        BuyNextAuction()
    elseif not Buyer.commodity and prefetch == entry then
        -- Recherche du survol pas encore revenue : la ligne passe à « Acheter » dès la réponse.
        Buyer.state = "searching"
        UpdateWindow()
    else
        Search()
    end
end

-- Lot rentable d'une marchandise d'après les résultats de recherche :
-- quantité sous le prix marchand (limitée par l'argent disponible), coût total.
local function CommodityLot(itemID, vendor, money)
    local qty, cost, noMoney = 0, 0, false
    for i = 1, C_AuctionHouse.GetNumCommoditySearchResults(itemID) do
        local r = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
        if not r or r.unitPrice >= vendor then break end
        if r.unitPrice > money - cost then noMoney = true end
        local available = r.quantity - (r.numOwnerItems or 0)
        local affordable = math.floor((money - cost) / r.unitPrice)
        if affordable < available then available = affordable end
        if available > 0 then
            qty = qty + available
            cost = cost + available * r.unitPrice
        end
        if affordable <= 0 then break end
    end
    return qty, cost, noMoney
end

-- Objet unique : meilleure enchère achetable, et total de toutes les enchères rentables.
-- ATTENTION (cause des incidents Patron et Petite bourse bleue) : le jeu regroupe les
-- exemplaires identiques sur une ligne. « quantity = 6, buyoutAmount = 500 » veut dire
-- 6 exemplaires à 500 pc CHACUN, et un achat (PlaceBid) n'en prend QU'UN.
-- buyoutAmount est donc un prix À L'UNITÉ.
local function ItemLot(itemKey, vendor, money)
    local best, bestGain, totalQty, totalGain, noMoney = nil, 0, 0, 0, false
    for i = 1, C_AuctionHouse.GetNumItemSearchResults(itemKey) do
        local r = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
        if r and r.buyoutAmount and not r.containsOwnerItem then
            local gain = vendor - r.buyoutAmount -- gain pour UN exemplaire
            if gain > 0 then
                totalQty = totalQty + (r.quantity or 1)
                totalGain = totalGain + gain * (r.quantity or 1)
                if r.buyoutAmount > money then
                    noMoney = true
                elseif gain > bestGain then
                    best, bestGain = r, gain
                end
            end
        end
    end
    return best, totalQty, totalGain, noMoney
end

-- File des enchères rentables d'un objet unique, la moins chère d'abord.
local function ItemQueue(itemKey, vendor)
    local q = {}
    for i = 1, C_AuctionHouse.GetNumItemSearchResults(itemKey) do
        local r = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
        if r and r.buyoutAmount and r.auctionID and not r.containsOwnerItem and r.buyoutAmount < vendor then
            q[#q + 1] = { auctionID = r.auctionID, buyoutAmount = r.buyoutAmount, quantity = r.quantity or 1 }
        end
    end
    table.sort(q, function(a, b) return a.buyoutAmount < b.buyoutAmount end)
    return q
end

-- Résultats de recherche d'une marchandise : combien d'unités sous le prix marchand ?
local function OnCommodityResults(itemID)
    local e = Buyer.entry
    if Buyer.state ~= "searching" or not e or e.id ~= itemID then return end
    local qty, cost, noMoney = CommodityLot(itemID, e.vendor, Budget())
    Buyer.qty, Buyer.cost, Buyer.noMoney = qty, cost, noMoney
    if qty > 1 and OnePerPurchase(itemID) then
        -- Un seul exemplaire par achat : prix du moins cher seulement.
        local r = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, 1)
        Buyer.qty, Buyer.cost = 1, (r and r.unitPrice) or math.floor(cost / qty)
    end
    e.qty, e.profit = qty, e.vendor * qty - cost
    e.done = qty == 0
    Buyer.state = e.done and "done" or "ready"
    UpdateWindow()
end

-- Résultats de recherche d'un objet unique : la meilleure enchère à acheter.
local function OnItemResults(itemKey)
    local e = Buyer.entry
    if Buyer.state ~= "searching" or not e or not itemKey or itemKey.itemID ~= e.id then return end
    local best, totalQty, totalGain, noMoney = ItemLot(itemKey, e.vendor, Budget())
    Buyer.itemKey, Buyer.noMoney = itemKey, noMoney
    Buyer.queue = ItemQueue(itemKey, e.vendor)
    Buyer.auction = Buyer.queue[1]
    if not best then Buyer.queue, Buyer.auction = {}, nil end
    e.qty, e.profit = totalQty, totalGain
    e.done = best == nil
    Buyer.state = e.done and "done" or "ready"
    UpdateWindow()
end

---------------------------------------------------------------------------
-- ÉTUDE DU MARCHÉ (demande de Jérémie : trier les objets « morts » des objets « actifs »).
-- Après chaque scan, une recherche par objet que tes métiers fabriquent (liste donnée par
-- EryAddon_Jobs.lua : ns.MarketItems) relève les annonces : quantité, prix, vendeur, temps restant.
--
-- Version 2 (fiabilité, après « 67 144 ventes par jour » pour le Sac rouge en lin) :
--   - les annonces sont regroupées par VENDEUR + PRIX (le jeu regroupe lui-même les exemplaires
--     identiques des objets non empilables, et leur numéro d'enchère change : on ne s'y fie plus) ;
--   - le jeu n'envoie souvent que le DÉBUT de la liste (les moins chères) : on ne compare que la
--     partie vue dans les deux relevés (prix sous le plus haut prix vu des deux côtés) ; c'est là
--     que partent les ventes, les acheteurs prenant les moins chères ;
--   - par vendeur : ce qui disparaît et réapparaît à un autre prix = REMISE EN VENTE ;
--   - le reste qui disparaît : VENDU si le temps restant dépassait l'écart entre les relevés,
--     EXPIRÉ s'il était plus court, INCERTAIN sinon (objets non empilables : le jeu ne donne qu'une
--     tranche de temps : moins de 30 min, 30 min à 2 h, 2 h à 12 h, 12 h à 48 h) ;
--   - mémoire : les 7 derniers jours, chaque intervalle daté.
-- EryAddonDB.hvMarche[objet] = { v = 2, t, cap (prix max vu, nil = liste complète),
--   a = { ["vendeur|prix"] = { q, lmin, lmax (temps restant, s), first (vu depuis) } },
--   iv = { { t, h, vendu, incertain, expire, remis, nouveau }, … } }
---------------------------------------------------------------------------
local MARKET_DAYS = 7
-- Temps restant d'une tranche (objets non empilables) : minimum et maximum, en secondes.
local BAND = { [0] = { 0, 1800 }, [1] = { 1800, 7200 }, [2] = { 7200, 43200 }, [3] = { 43200, 172800 } }

local function Market()
    EryAddonDB.hvMarche = EryAddonDB.hvMarche or {}
    return EryAddonDB.hvMarche
end

-- Annonces d'un objet, regroupées par vendeur + prix ; renvoie aussi le prix le plus haut vu et si
-- la liste est complète.
local function ReadAuctions(event, arg, itemID)
    local groups, maxPrice, full = {}, 0, true
    local function Add(r, price, lmin, lmax)
        if not (r and price and price > 0) then return end
        local owner = (r.owners and r.owners[1]) or "?"
        if r.containsOwnerItem then owner = "player" end
        local key = owner .. "|" .. price
        local g = groups[key]
        if not g then
            g = { o = owner, p = price, q = 0, lmin = lmin, lmax = lmax }
            groups[key] = g
        end
        g.q = g.q + (r.quantity or 1)
        g.lmin, g.lmax = math.min(g.lmin, lmin), math.max(g.lmax, lmax)
        if price > maxPrice then maxPrice = price end
    end
    if event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
        for i = 1, C_AuctionHouse.GetNumCommoditySearchResults(itemID) do
            local r = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
            local left = r and r.timeLeftSeconds or 0
            Add(r, r and r.unitPrice, left, left)
        end
        if C_AuctionHouse.HasFullCommoditySearchResults then
            full = C_AuctionHouse.HasFullCommoditySearchResults(itemID) and true or false
        end
    else
        for i = 1, C_AuctionHouse.GetNumItemSearchResults(arg) do
            local r = C_AuctionHouse.GetItemSearchResultInfo(arg, i)
            local band = BAND[r and r.timeLeft or 0] or BAND[0]
            Add(r, r and (r.buyoutAmount or r.bidAmount), band[1], band[2])
        end
        if C_AuctionHouse.HasFullItemSearchResults then
            full = C_AuctionHouse.HasFullItemSearchResults(arg) and true or false
        end
    end
    -- Sauvegarde raisonnable : on garde les 25 groupes les moins chers ; au-delà, la liste est traitée
    -- comme incomplète (on ne compare que sous le prix du 25e).
    local n = 0
    for _ in pairs(groups) do n = n + 1 end
    if n > 25 then
        local prices = {}
        for _, g in pairs(groups) do prices[#prices + 1] = g.p end
        table.sort(prices)
        local limit = prices[25]
        for key, g in pairs(groups) do if g.p > limit then groups[key] = nil end end
        full, maxPrice = false, limit
    end
    return groups, (not full) and maxPrice or nil
end

-- Compare deux relevés (old, new : groupes vendeur|prix) sur la partie vue des deux côtés.
local function CompareAuctions(old, oldCap, new, newCap, elapsed)
    local iv = { t = time(), h = elapsed / 3600, vendu = 0, incertain = 0, expire = 0, remis = 0, nouveau = 0 }
    local cap = math.min(oldCap or math.huge, newCap or math.huge)
    -- Par vendeur : ce qui a disparu (avec son temps restant) et ce qui est apparu.
    local gone, came = {}, {}
    for key, a in pairs(old) do
        if a.o ~= "player" and a.p < cap then
            local n = new[key]
            local d = a.q - (n and n.q or 0)
            if d > 0 then
                gone[a.o] = gone[a.o] or {}
                table.insert(gone[a.o], { q = d, lmin = a.lmin, lmax = a.lmax })
            end
        end
    end
    for key, b in pairs(new) do
        if b.o ~= "player" and b.p < cap then
            local a = old[key]
            local d = b.q - (a and a.q or 0)
            if d > 0 then came[b.o] = (came[b.o] or 0) + d end
        end
    end
    for owner, list in pairs(gone) do
        -- Remise en vente : le même vendeur remet des exemplaires (à un autre prix).
        -- Vendeur inconnu (« ? » : le jeu cache les vendeurs des objets empilables) : ce qui disparaît et
        -- ce qui apparaît dans le même intervalle est compté comme remis en vente (guerres de prix),
        -- pas comme vendu (bug : « Acide sulfurique : 2 087 ventes par jour »).
        local relist = came[owner] or 0
        for _, g in ipairs(list) do
            local r = math.min(relist, g.q)
            relist = relist - r
            iv.remis = iv.remis + r
            came[owner] = (came[owner] or 0) - r
            local q = g.q - r
            if q > 0 then
                if g.lmin > elapsed + 300 then
                    iv.vendu = iv.vendu + q
                elseif g.lmax < elapsed then
                    iv.expire = iv.expire + q
                else
                    iv.incertain = iv.incertain + q
                end
            end
        end
    end
    for _, q in pairs(came) do if q > 0 then iv.nouveau = iv.nouveau + q end end
    return iv
end

local function RecordMarket(itemID, event, arg)
    local now = time()
    local new, cap = ReadAuctions(event, arg, itemID)
    local m = Market()[itemID]
    if m and m.v ~= 3 then m = nil end -- format v3 (remises « ? » corrigées, 07/11) : les anciens relevés, faux, sont oubliés
    for key, g in pairs(new) do
        local before = m and m.a and m.a[key]
        g.first = (before and before.first) or now
    end
    if m and m.t then
        local elapsed = now - m.t
        if elapsed < 15 * 60 then return end -- trop tôt : l'ancien relevé reste la référence
        m.iv = m.iv or {}
        -- Écart > 24 h (durée maximale d'une annonce) : toutes les annonces ont forcément disparu, on ne
        -- peut rien conclure (avant : 72 h → tout passait en « expiré », zéro vente : faux « mort »).
        if elapsed <= 24 * 3600 then
            table.insert(m.iv, CompareAuctions(m.a, m.cap, new, cap, elapsed))
        end
        -- Mémoire : les 7 derniers jours servent au calcul ; les plus anciens sont GARDÉS (30 bilans au plus)
        -- pour afficher la dernière info fiable quand il n'y a rien de récent (demande de Jérémie).
        while #m.iv > 20 do table.remove(m.iv, 1) end
    end
    m = m or { v = 3, iv = {} }
    m.t, m.a, m.cap = now, new, cap
    Market()[itemID] = m
    -- Pas plus de 1 500 objets suivis : les plus anciens relevés sont oubliés.
    local all, count = Market(), 0
    for _ in pairs(all) do count = count + 1 end
    if count > 1500 then
        local ages = {}
        for id, x in pairs(all) do ages[#ages + 1] = { id = id, t = x.t or 0 } end
        table.sort(ages, function(a, b) return a.t < b.t end)
        for i = 1, count - 1500 do all[ages[i].id] = nil end
    end
end
ns._RecordMarket = RecordMarket -- pour le test hors jeu (outils/test_guide.py)

-- État du marché d'un objet, ou nil si on ne l'a jamais relevé (format v2).
-- { etat = "mort" | "calme" | "actif" | "inconnu", parJour (estimation : sûres + moitié des
--   incertaines), min / max par jour (fourchette), vendeurs, enVente, dort (heures de la plus
--   vieille annonce encore là), heures observées, releves }
function ns.MarketState(itemID)
    local m = EryAddonDB and EryAddonDB.hvMarche and EryAddonDB.hvMarche[itemID]
    if not m or m.v ~= 3 or not m.a then return nil end
    local sellers, seen, listed, oldest = 0, {}, 0, 0
    for _, g in pairs(m.a) do
        if g.o ~= "player" then
            listed = listed + g.q
            if not seen[g.o] then seen[g.o] = true; sellers = sellers + 1 end
            oldest = math.max(oldest, (m.t - (g.first or m.t)) / 3600)
        end
    end
    local hours, sold, unsure, count = 0, 0, 0, 0
    local now = time()
    for _, iv in ipairs(m.iv or {}) do
        if now - (iv.t or now) <= MARKET_DAYS * 86400 then
            hours, sold, unsure = hours + iv.h, sold + iv.vendu, unsure + (iv.incertain or 0)
            count = count + 1
        end
    end
    -- Moins de 4 h observées ces 7 derniers jours (retour après une absence) : on garde aussi les bilans
    -- plus anciens, pour ne pas jeter une info solide au profit d'une demi-heure ; « relevé du … » si
    -- rien de récent du tout. Les nouveaux bilans prennent le relais d'eux-mêmes.
    local ancien
    if hours < 4 and m.iv and m.iv[1] then
        if count == 0 then ancien = m.iv[#m.iv].t end
        hours, sold, unsure, count = 0, 0, 0, 0
        for _, iv in ipairs(m.iv) do
            hours, sold, unsure = hours + iv.h, sold + iv.vendu, unsure + (iv.incertain or 0)
            count = count + 1
        end
    end
    local st = { vendeurs = sellers, enVente = listed, dort = oldest, heures = hours,
        releves = count + 1, ancien = ancien }
    if hours <= 0 then st.etat = "inconnu" return st end
    st.min = sold / hours * 24
    st.max = (sold + unsure) / hours * 24
    st.parJour = (sold + unsure / 2) / hours * 24
    if sold + unsure == 0 then
        -- « Mort » seulement avec assez de preuves : 2 jours observés et 3 relevés.
        -- « Mort » : aucune vente sur 8 h observées et au moins 3 relevés (choix de Jérémie ; avant 48 h).
        st.etat = (hours >= 8 and st.releves >= 3) and "mort" or "calme"
    elseif st.parJour < 1 then
        st.etat = "calme"
    else
        st.etat = "actif"
    end
    return st
end

-- Objets à étudier après ce scan : ce que tes métiers fabriquent et qui est en vente.
-- « minAge » (secondes) : seulement les objets relevés il y a plus longtemps que ça (reprise à
-- l'ouverture de l'HV) ; nil = tous. Les clés de recherche viennent du dernier scan, ou de la
-- sauvegarde (EryAddonDB.hvCles) : l'étude peut donc tourner sans refaire de scan.
-- Demande de Jérémie : « scanner un maximum, en 10 min environ », dans cet ordre :
--   1. tes objets (ventes, métiers principaux : ns.MarketItems) ;
--   2. le reste de l'HV DÉJÀ ÉTUDIÉ, le relevé le plus ancien d'abord (comparer deux relevés du MÊME objet
--      est ce qui donne les ventes : on relit d'abord ceux qu'on connaît) ;
--   3. le reste de l'HV jamais étudié (il entre dans la boucle s'il reste du temps) ;
--   4. Secourisme et Cuisine.
-- La limite de temps (STUDY_TIME) arrête l'étude ; le passage suivant reprend dans le même ordre.
local function StudyEntries(minAge)
    local list = {}
    local saved = EryAddonDB.hvCles or {}
    local market = EryAddonDB.hvMarche or {}
    local now = time()
    local seen = {}
    local function Due(id)
        local m = market[id]
        return not minAge or not (m and m.v == 3 and m.t) or now - m.t >= minAge
    end
    local function AddList(idlist)
        for _, id in ipairs(idlist) do
            if not seen[id] then
                seen[id] = true
                local key = lastScanKeys[id] or saved[id]
                if key and Due(id) then list[#list + 1] = { id = id, itemKey = key, study = true } end
            end
        end
    end
    AddList(ns.MarketItems and ns.MarketItems() or {})
    local secondary = ns.MarketItems and ns.MarketItems(true) or {}
    for _, id in ipairs(secondary) do seen[id] = seen[id] or "plus tard" end
    local known, fresh = {}, {}
    for id, key in pairs(saved) do
        if not seen[id] and Due(id) then
            local m = market[id]
            if m and m.v == 3 and m.t then
                known[#known + 1] = { id = id, itemKey = lastScanKeys[id] or key, study = true, age = m.t }
            else
                fresh[#fresh + 1] = { id = id, itemKey = lastScanKeys[id] or key, study = true }
            end
        end
    end
    table.sort(known, function(a, b) return a.age < b.age end)
    for _, e in ipairs(known) do list[#list + 1] = e end
    for _, e in ipairs(fresh) do list[#list + 1] = e end
    for _, id in ipairs(secondary) do if seen[id] == "plus tard" then seen[id] = nil end end
    AddList(secondary)
    return list
end

-- Après un scan : clés de recherche des objets étudiés gardées dans la sauvegarde.
SaveStudyKeys = function()
    EryAddonDB.hvCles = EryAddonDB.hvCles or {}
    for id, k in pairs(lastScanKeys) do
        if k then
            EryAddonDB.hvCles[id] = { itemID = k.itemID, itemLevel = k.itemLevel, itemSuffix = k.itemSuffix,
                battlePetSpeciesID = k.battlePetSpeciesID }
        end
    end
end

---------------------------------------------------------------------------
-- Après le scan : vérification des quantités de chaque objet de la liste
-- (une recherche par objet, automatique, AUCUN achat), pour connaître le gain
-- TOTAL du lot et trier la liste par ce gain (demande de Jérémie).
---------------------------------------------------------------------------
local detailQueue, detailCurrent, detailToken, detailTotal = {}, nil, 0, 0
local detailRunning = false
local detailStudied = false -- l'étude du marché a tourné : Jobs à rafraîchir à la fin
local STUDY_TIME = 600 -- secondes d'étude du marché par passage à l'HV (demande de Jérémie : ~10 min)
local studyStart -- heure de début de l'étude en cours

local function BuyerBusy()
    local s = Buyer.state
    return s == "searching" or s == "starting" or s == "confirm" or s == "buying"
end

local DetailNext
DetailNext = function()
    if not detailRunning then return end
    -- Pendant un achat, on laisse la place : on reprend une seconde plus tard.
    if BuyerBusy() then C_Timer.After(1, DetailNext); return end
    detailCurrent = table.remove(detailQueue, 1)
    if not detailCurrent then
        detailRunning, studyStart = false, nil
        local items = Saved().items
        table.sort(items, function(a, b) return (a.profit or a.unitGain) > (b.profit or b.unitGain) end)
        if globalMode then
            globalMode = false
            Msg(string.format("scan global terminé : %d objets étudiés.", detailTotal))
        end
        SetStatus("")
        if detailStudied then
            detailStudied = false
            if ns.JobsRefresh then ns.JobsRefresh() end -- état des marchés : Jobs et guide recalculés
        end
        return
    end
    local e = detailCurrent
    if e.study then
        studyStart = studyStart or GetTime()
        if not globalMode and GetTime() - studyStart > STUDY_TIME then
            -- 10 min atteintes : on s'arrête là ; le prochain passage reprend avec les plus anciens.
            detailQueue, detailCurrent, detailRunning, studyStart = {}, nil, false, nil
            SetStatus("Étude du marché : pause (10 min). Elle reprendra à ta prochaine visite.", "EDM : pause")
            if detailStudied then detailStudied = false; if ns.JobsRefresh then ns.JobsRefresh() end end
            return
        end
    end
    e.commodity = IsCommodity(e.id)
    if e.study and globalMode then
        local done = detailTotal - #detailQueue
        SetStatus(string.format("Scan global : étude du marché %d / %d (sans limite de temps)", done, detailTotal),
            string.format("Global %d/%d", done, detailTotal))
    elseif e.study then
        local left = studyStart and math.max(0, STUDY_TIME - (GetTime() - studyStart)) or STUDY_TIME
        SetStatus(string.format("Étude du marché : %d / %d  (encore %d min max)", detailTotal - #detailQueue,
            detailTotal, math.ceil(left / 60)), string.format("EDM %d/%d", detailTotal - #detailQueue, detailTotal))
    else
        SetStatus(string.format("Vérification des quantités : %d / %d", detailTotal - #detailQueue, detailTotal),
            string.format("Vérif. %d/%d", detailTotal - #detailQueue, detailTotal))
    end
    detailToken = detailToken + 1
    local token = detailToken
    C_AuctionHouse.SendSearchQuery(SearchKey(e), PRICE_SORT, not e.commodity)
    -- Sans réponse, on passe au suivant.
    C_Timer.After(4, function()
        if detailCurrent == e and token == detailToken then
            -- Aucune réponse : rien d'achetable trouvé → mis de côté à ce prix (prix fantôme).
            e.done = true
            if not e.study then MarkExhausted(e) end
            detailCurrent = nil
            DetailNext()
        end
    end)
end

StartDetails = function(list)
    detailQueue, detailCurrent = {}, nil
    for _, e in ipairs(list) do detailQueue[#detailQueue + 1] = e end
    -- Étude du marché : seulement les objets pas relevés depuis 30 min (inutile de refaire les autres) ;
    -- scan global : TOUS les objets.
    for _, e in ipairs(StudyEntries(not globalMode and 1800 or nil)) do detailQueue[#detailQueue + 1] = e end
    detailStudied = false
    detailTotal = #detailQueue
    detailRunning = detailTotal > 0
    DetailNext()
end

-- Étude seule, SANS scan (demande de Jérémie : « capitaliser sans être sur l'HV ») : à chaque
-- ouverture de l'HV, on reprend les objets relevés il y a plus d'une heure. Fermer l'HV l'arrête
-- (le jeu n'accepte les recherches que devant le commissaire-priseur) ; ce qui est relevé est gardé,
-- et la suite reprend à la prochaine ouverture.
local STUDY_MIN_AGE = 1800 -- 30 min : choix de Jérémie (l'HV de Forever bouge vite)
local function StartStudyOnly()
    if detailRunning or scanRunning then return end
    if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then return end
    local list = StudyEntries(STUDY_MIN_AGE)
    if #list == 0 then return end
    detailQueue, detailCurrent = list, nil
    detailStudied = false
    detailTotal = #list
    detailRunning = true
    DetailNext()
end

local function StopDetails()
    detailQueue, detailCurrent, detailRunning = {}, nil, false
end

-- Scan global : le scan normal, puis l'étude de tout l'HV sans limite (voir globalMode).
local function StartGlobalScan()
    if scanRunning or globalMode then return end
    globalMode = true
    Msg("scan global lancé : tout l'HV, ça peut prendre une heure. Reste devant le commissaire-priseur.")
    StartScan()
    if not scanRunning then globalMode = false end
end
ns._StopDetails = StopDetails

local function OnDetailResults(event, arg)
    local e = detailCurrent
    if not e then return end
    if e.study then
        local id = (event == "COMMODITY_SEARCH_RESULTS_UPDATED") and arg or (type(arg) == "table" and arg.itemID)
        if id ~= e.id then return end
        pcall(RecordMarket, e.id, event, arg)
        detailStudied = true
        detailCurrent = nil
        C_Timer.After(0.3, DetailNext)
        return
    end
    if event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
        if arg ~= e.id then return end
        local qty, cost = CommodityLot(e.id, e.vendor, math.huge) -- sans limite d'argent : gain du lot entier
        e.qty, e.profit, e.done = qty, e.vendor * qty - cost, qty == 0
        if e.done then MarkExhausted(e) end
    else
        if type(arg) ~= "table" or arg.itemID ~= e.id then return end
        local _, totalQty, totalGain = ItemLot(arg, e.vendor, math.huge)
        e.qty, e.profit, e.done = totalQty, totalGain, totalQty == 0
        if e.done then MarkExhausted(e) end
        -- Meilleure enchère payable, gardée pour l'achat en un clic.
        e.queue, e.queueTime = ItemQueue(arg, e.vendor), time() -- file d'enchères pour l'achat en un clic
    end
    detailCurrent = nil
    UpdateWindow()
    C_Timer.After(0.3, DetailNext) -- petite pause : le serveur limite le rythme des recherches
end

---------------------------------------------------------------------------
-- RECHERCHE AU SURVOL (demande de Jérémie : « au premier clic sur la ligne, ça essaye
-- d'acheter »). Pour un objet NON empilable (arme, cape…), acheter demande le numéro de
-- l'enchère, que seule une recherche donne ; et un clic « expire » avant la réponse du serveur.
-- On lance donc la recherche dès que la souris PASSE sur la ligne : le temps de cliquer,
-- la file d'enchères est prête et le premier clic achète. (Les objets empilables, eux,
-- s'achètent déjà au premier clic : achat express.)
---------------------------------------------------------------------------
local prefetchToken = 0
local PREFETCH_FRESH = 60 -- s : une file plus récente est réutilisée telle quelle

local function Prefetch(e)
    if not e or e.done or e.blocked or prefetch == e then return end
    if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then return end
    if IsCommodity(e.id) then return end
    if e.queue and #e.queue > 0 and e.queueTime and time() - e.queueTime < PREFETCH_FRESH then return end
    if BuyerBusy() or detailCurrent then return end
    if Buyer.entry == e and Buyer.state == "ready" then return end
    prefetch = e
    prefetchToken = prefetchToken + 1
    local token = prefetchToken
    C_AuctionHouse.SendSearchQuery(SearchKey(e), PRICE_SORT, true)
    C_Timer.After(4, function()
        if prefetch == e and token == prefetchToken then
            prefetch = nil
            if Buyer.entry == e and Buyer.state == "searching" then Buyer.state = "retry"; UpdateWindow() end
        end
    end)
end

local function OnPrefetchResults(itemKey)
    local e = prefetch
    if not e or type(itemKey) ~= "table" or itemKey.itemID ~= e.id then return end
    prefetch = nil
    if Buyer.entry == e and Buyer.state == "searching" then return end -- la ligne cliquée s'en charge
    e.queue, e.queueTime = ItemQueue(itemKey, e.vendor), time()
    if #e.queue == 0 then
        e.done = true
        MarkExhausted(e)
    end
    UpdateWindow()
end

-- Le bouton « Acheter » : chaque clic fait avancer d'une étape.
function Buyer.Click()
    local e = Buyer.entry
    if not e then return end
    if Buyer.state == "retry" then
        Search()
    elseif Buyer.state == "ready" and Buyer.commodity then
        Buyer.state = "starting"
        C_AuctionHouse.StartCommoditiesPurchase(e.id, Buyer.qty)
        UpdateWindow()
    elseif Buyer.state == "confirm" then
        Buyer.state = "buying"
        ExpectPurchase(Buyer.qty, Buyer.cost, Buyer.unitArg)
        C_AuctionHouse.ConfirmCommoditiesPurchase(e.id, Buyer.qty)
        WatchPurchase()
        UpdateWindow()
    elseif Buyer.state == "ready" and not Buyer.commodity then
        BuyNextAuction() -- enchère suivante de la file, sans nouvelle recherche
    end
end

-- Le serveur donne le prix réel juste avant l'achat : on n'achète que si c'est
-- toujours rentable.
local function OnCommodityPrice(unitPrice, totalPrice)
    local e = Buyer.entry
    if Buyer.state ~= "starting" or not e then return end
    if issecret(totalPrice) or issecret(unitPrice) or not totalPrice or totalPrice >= e.vendor * Buyer.qty
        or (unitPrice and unitPrice >= e.vendor) then
        C_AuctionHouse.CancelCommoditiesPurchase()
        Search()
        return
    end
    -- Garde-fou : prix annoncés incohérents (total très différent de unité x quantité) ?
    -- Alors pas d'achat automatique : on montre les chiffres et Jérémie confirme à la main.
    local suspicious = unitPrice and math.abs(unitPrice * Buyer.qty - totalPrice) > math.max(unitPrice, totalPrice * 0.1)
    Buyer.cost = totalPrice
    if totalPrice > Budget() then
        C_AuctionHouse.CancelCommoditiesPurchase()
        Search() -- la recherche limitera la quantité à la moitié de ta bourse
        return
    end

    -- UN SEUL CLIC (demande de Jérémie) : on confirme tout de suite, sans 2e clic.
    -- Si le jeu l'interdit (il exige parfois un vrai clic pour confirmer), l'événement
    -- ADDON_ACTION_BLOCKED nous prévient : on s'en souvient et on repasse au bouton
    -- « Confirmer » (voir OnActionBlocked).
    if suspicious then
        Msg(string.format("|cffff9933prix annoncé bizarre|r pour %s : %d x %s l'unité = %s ? Vérifie avant de confirmer.",
            e.name, Buyer.qty, Money(unitPrice), Money(totalPrice)))
    end
    Buyer.unitArg = unitPrice
    if not EryAddonDB.hvConfirmBlocked and not suspicious then
        Buyer.state = "buying"
        Buyer.autoConfirm = true
        ExpectPurchase(Buyer.qty, totalPrice, unitPrice)
        C_AuctionHouse.ConfirmCommoditiesPurchase(e.id, Buyer.qty)
        WatchPurchase()
    else
        Buyer.state = "confirm"
    end
    UpdateWindow()
end

-- Le jeu a bloqué une action de l'add-on (achat sans vrai clic).
local Course -- achat de composant en cours (onglet Jobs), voir ns.BuyReagent plus bas

local function OnActionBlocked(addon, func)
    if addon ~= ADDON_NAME then return end
    -- Achat de composant (onglet Jobs) bloqué : on passe au 2e clic de confirmation.
    if Course and Course.state == "buying" then
        EryAddonDB.hvConfirmBlocked = true
        Course.state = "confirm"
        Msg(Course.name .. " : le jeu exige un clic pour confirmer. Reclique sur « Acheter ».")
        return
    end
    if Buyer.autoConfirm and Buyer.state == "buying" then
        EryAddonDB.hvConfirmBlocked = true
        Buyer.autoConfirm = false
        if lastPending then pendings[lastPending.key] = nil end -- rien n'a été payé
        Buyer.state = "confirm"
        Msg("le jeu exige un clic pour confirmer un achat d'objets empilables : clique sur « Confirmer ». "
            .. "(C'est retenu, l'add-on ne réessaiera plus.)")
        UpdateWindow()
    else
        Msg("le jeu a bloqué une action : " .. tostring(func))
    end
end

---------------------------------------------------------------------------
-- Achat d'un composant pour l'onglet Jobs (bouton « Acheter » d'une recette dépliée).
-- Objets empilables seulement : le serveur annonce le prix du lot ; on n'achète que s'il
-- ne dépasse pas de plus de 20 % le prix prévu (les unités suivantes coûtent un peu plus).
---------------------------------------------------------------------------
-- Course (déclaré plus haut) : { id, qty, maxUnit, name, state = "starting" | "confirm" | "buying", total }

local refusedPrice = {} -- [objet] = { unit = prix unitaire annoncé par le serveur, t }
function ns.BuyReagent(itemID, qty, unit, name)
    if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then
        Msg(name .. " : ouvre l'hôtel des ventes pour l'acheter.")
        return
    end
    -- 2e clic quand le jeu exige un vrai clic pour confirmer.
    if Course and Course.state == "confirm" and Course.id == itemID then
        Course.state = "buying"
        C_AuctionHouse.ConfirmCommoditiesPurchase(Course.id, Course.qty)
        return
    end
    if Course or Buyer.state == "starting" or Buyer.state == "confirm" then
        Msg("un achat est déjà en cours, réessaie dans une seconde.")
        return
    end
    if not IsCommodity(itemID) then
        Msg(name .. " : objet non empilable, achète-le depuis l'onglet Acheter de l'HV.")
        return
    end
    -- Prix refusé au clic précédent : ce 2e clic l'accepte (bug : « plus de 20 % au-dessus du prix
    -- prévu » à chaque clic, le prix prévu venant d'un scan ancien).
    local seen = refusedPrice[itemID]
    if seen and time() - seen.t < 120 then unit = math.max(unit, seen.unit) end
    refusedPrice[itemID] = nil
    Course = { id = itemID, qty = qty, maxUnit = unit, name = name, state = "starting" }
    C_AuctionHouse.StartCommoditiesPurchase(itemID, qty)
    local c = Course
    C_Timer.After(5, function()
        if Course == c and c.state == "starting" then
            C_AuctionHouse.CancelCommoditiesPurchase()
            Msg(name .. " : le serveur n'a pas répondu, réessaie.")
            Course = nil
        end
    end)
end

---------------------------------------------------------------------------
-- Achat d'un objet NON empilable pour Jobs (une recette à l'HV, demande de Jérémie).
-- Il faut le numéro de l'enchère (donné par une recherche) et un clic réel : la recherche part
-- dès le SURVOL du bouton (ns.PrefetchUnique), et le clic achète la moins chère (PlaceBid) si
-- son prix ne dépasse pas de plus de 20 % le prix prévu. Sans recherche prête : le clic la lance
-- et le clic suivant achète.
---------------------------------------------------------------------------
local uniq = {} -- [objet] = { queue = { {auctionID, buyoutAmount}, … }, t, searching }
local uniqWatch -- achat en attente de l'annonce « Vous avez gagné les enchères » : { id, name, price, t }

function ns.PrefetchUnique(itemID)
    if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then return end
    local u = uniq[itemID]
    if u and (u.searching or (u.queue and time() - u.t < 60)) then return end
    uniq[itemID] = { searching = true, t = time() }
    C_AuctionHouse.SendSearchQuery(lastScanKeys[itemID] or C_AuctionHouse.MakeItemKey(itemID), PRICE_SORT, true)
    C_Timer.After(4, function()
        local v = uniq[itemID]
        if v and v.searching then uniq[itemID] = nil end
    end)
end

local function OnUniqueResults(itemKey)
    if type(itemKey) ~= "table" then return end
    local u = uniq[itemKey.itemID]
    if not (u and u.searching) then return end
    local q = {}
    for i = 1, C_AuctionHouse.GetNumItemSearchResults(itemKey) do
        local r = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
        if r and r.auctionID and r.buyoutAmount and not r.containsOwnerItem then
            q[#q + 1] = { auctionID = r.auctionID, buyoutAmount = r.buyoutAmount }
        end
    end
    table.sort(q, function(a, b) return a.buyoutAmount < b.buyoutAmount end)
    uniq[itemKey.itemID] = { queue = q, t = time() }
end

function ns.BuyUnique(itemID, unit, name)
    if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then
        Msg(name .. " : ouvre l'hôtel des ventes pour l'acheter.")
        return
    end
    local u = uniq[itemID]
    if not (u and u.queue) then
        ns.PrefetchUnique(itemID)
        Msg(name .. " : recherche en cours, reclique dans une seconde.")
        return
    end
    local a = table.remove(u.queue, 1)
    if not a then
        uniq[itemID] = nil
        Msg(name .. " : plus aucune en vente à l'HV.")
        return
    end
    if a.buyoutAmount > unit * 1.2 + 1 then
        table.insert(u.queue, 1, a)
        uniq[itemID] = nil -- prix revu à la prochaine recherche
        Msg(string.format("%s : la moins chère coûte maintenant %s (prévu : %s). Pas achetée.", name,
            Money(a.buyoutAmount), Money(unit)))
        return
    end
    if a.buyoutAmount > GetMoney() then
        Msg(name .. " : pas assez d'argent.")
        return
    end
    local before = GetMoney()
    uniqWatch = { id = itemID, name = name, price = a.buyoutAmount, t = GetTime() }
    C_AuctionHouse.PlaceBid(a.auctionID, a.buyoutAmount)
    C_Timer.After(5, function()
        if uniqWatch and uniqWatch.id == itemID then
            uniqWatch = nil
            if GetMoney() <= before - a.buyoutAmount then
                -- Pas d'annonce reconnue, mais l'argent a bien été payé : achat fait.
                Msg(string.format("|cff00ff00acheté|r %s pour %s. Il arrive par courrier.", name, Money(a.buyoutAmount)))
                ns.AddInbound(itemID, 1)
            else
                Msg(name .. " : |cffff6666pas d'enchère gagnée|r (déjà partie ?). Reclique pour la suivante.")
            end
        end
    end)
end

-- Annonce du jeu « Vous avez gagné les enchères pour X » : achat réussi.
if DEFAULT_CHAT_FRAME then
    hooksecurefunc(DEFAULT_CHAT_FRAME, "AddMessage", function(_, text)
        local w = uniqWatch
        if not w or type(text) ~= "string" or issecret(text) then return end
        text = StripColors(text)
        if text:find("gagné les enchères", 1, true) and text:find(w.name, 1, true) then
            uniqWatch = nil
            Msg(string.format("|cff00ff00acheté|r %s pour %s. Il arrive par courrier.", w.name, Money(w.price)))
            ns.AddInbound(w.id, 1)
        end
    end)
end

-- Prix annoncé par le serveur pour un achat de composant ; renvoie true si c'était le nôtre.
local function OnReagentPrice(unitPrice, totalPrice)
    local c = Course
    if not c or c.state ~= "starting" then return false end
    if issecret(totalPrice) or not totalPrice or totalPrice > c.maxUnit * c.qty * 1.2 + 1 then
        C_AuctionHouse.CancelCommoditiesPurchase()
        if totalPrice and not issecret(totalPrice) then
            refusedPrice[c.id] = { unit = totalPrice / c.qty, t = time() }
            Msg(string.format("%s : %d coûtent maintenant %s (prévu : %s). Reclique pour les acheter à ce prix.",
                c.name, c.qty, Money(totalPrice), Money(c.maxUnit * c.qty)))
        else
            Msg(c.name .. " : prix non communiqué par le serveur. Achat annulé.")
        end
        Course = nil
        return true
    end
    if totalPrice > GetMoney() then
        C_AuctionHouse.CancelCommoditiesPurchase()
        Msg(c.name .. " : pas assez d'argent pour ce lot.")
        Course = nil
        return true
    end
    c.total = totalPrice
    if EryAddonDB.hvConfirmBlocked then
        c.state = "confirm"
        Msg(string.format("%s : %d pour %s. Reclique sur « Acheter » pour confirmer.", c.name, c.qty, Money(totalPrice)))
    else
        c.state = "buying"
        C_AuctionHouse.ConfirmCommoditiesPurchase(c.id, c.qty)
    end
    return true
end

local function OnReagentDone(ok)
    local c = Course
    if not c or c.state ~= "buying" then return false end
    Course = nil
    if ok then
        Msg(string.format("|cff00ff00acheté|r %d x %s pour %s (%s l'unité). Il arrive par courrier.", c.qty,
            c.name, Money(c.total), Money(c.total / c.qty)))
        ns.AddInbound(c.id, c.qty)
    else
        Msg(c.name .. " : |cffff6666achat refusé par le serveur|r. Rien n'a été payé.")
    end
    C_Timer.After(1, function() if ns.JobsRefresh then ns.JobsRefresh() end end)
    return true
end

local function ResetBuyer()
    if Buyer.state == "starting" or Buyer.state == "confirm" then
        C_AuctionHouse.CancelCommoditiesPurchase()
    end
    Buyer.entry, Buyer.state, Buyer.auction, Buyer.queue = nil, nil, nil, nil
end

---------------------------------------------------------------------------
-- Fenêtre
---------------------------------------------------------------------------
local ROWS, ROW_H = 14, 24
local win, toggleButton
-- Bibliothèque d'Auctionator qui ajoute des onglets en bas de la fenêtre de l'HV
-- (comme son onglet « Auctionator »). Si elle manque, on garde une fenêtre à part.
local function TabLib()
    return LibStub and LibStub("LibAHTab-1-0", true)
end

local function ButtonText()
    local e, s = Buyer.entry, Buyer.state
    if not e then return "Choisis un objet dans la liste", false end
    if s == "searching" then return "Recherche…", false end
    if s == "retry" then return "Rechercher à nouveau", true end
    if s == "done" then
        return Buyer.noMoney and "Trop cher (moitié de ta bourse)" or "Plus rentable", false
    end
    if s == "starting" then return "Vérification du prix…", false end
    if s == "buying" then return "Achat en cours…", false end
    if s == "confirm" then
        return string.format("Confirmer : %d pour %s", Buyer.qty, Money(Buyer.cost)), true
    end
    if s == "ready" and Buyer.commodity then
        return string.format("Acheter %d (gain %s)", Buyer.qty, Money(e.vendor * Buyer.qty - Buyer.cost)), true
    end
    if s == "ready" and Buyer.auction then
        local a = Buyer.auction
        local n = 0
        for _, x in ipairs(Buyer.queue or {}) do n = n + (x.left or x.quantity or 1) end
        if n > 1 then
            return string.format("Acheter 1 (gain %s) — encore %d en file", Money(e.vendor - a.buyoutAmount), n), true
        end
        return string.format("Acheter 1 (gain %s)", Money(e.vendor - a.buyoutAmount)), true
    end
    return "…", false
end

-- Gain du PROCHAIN clic d'achat sur cette ligne :
--   objet unique : l'enchère suivante de la file (1 exemplaire) ;
--   objet empilable : le lot que le clic achète (tout le lot rentable, ou 1 si non empilable).
local function NextClickGain(e)
    if Buyer.entry == e then
        if Buyer.commodity and Buyer.qty and Buyer.cost and (Buyer.state == "ready" or Buyer.state == "confirm") then
            return e.vendor * Buyer.qty - Buyer.cost
        end
        if not Buyer.commodity and Buyer.auction then return e.vendor - Buyer.auction.buyoutAmount end
    end
    if e.queue and e.queue[1] then return e.vendor - e.queue[1].buyoutAmount end
    if e.profit and not OnePerPurchase(e.id) and not e.queue then return e.profit end
    return e.unitGain
end

-- Texte court du bouton d'une ligne (le détail reste affiché dans le grand bouton du bas).
local function RowButtonText(e)
    if e.blocked then return "|cffff3333Arrêté|r", false end
    if Buyer.entry ~= e then
        return e.done and "Revoir" or "Acheter", true
    end
    local s = Buyer.state
    if s == "searching" or s == "starting" or s == "buying" then return "…", false end
    if s == "retry" then return "Rechercher", true end
    if s == "done" then return "Revoir", true end
    if s == "confirm" then return "|cff00ff00Confirmer|r", true end
    if s == "ready" then return "Acheter", true end
    return "…", false
end

UpdateWindow = function()
    if not win or not win:IsShown() then return end
    local saved = Saved()
    -- Objets épuisés (plus rien de rentable) : la ligne disparaît (demande de Jérémie).
    local items = {}
    for _, e in ipairs(saved.items or {}) do
        if not e.done then items[#items + 1] = e end
    end

    if statusText ~= "" then
        win.status:SetText(statusText)
    elseif saved.time then
        win.status:SetText(string.format("Dernier scan : il y a %d min. %d objets rentables.",
            math.floor((time() - saved.time) / 60), #items))
    else
        win.status:SetText("Aucun scan. Clique sur « Scanner l'HV » (à droite).")
    end

    local b = AnoBilan()
    local profit = b.revente - b.paye
    win.bilan:SetText(string.format("Profit total : %s%s|r  (%d achats)", profit >= 0 and "|cff5cffb0+" or "|cffff7373-",
        Money(math.abs(profit)), b.n))

    FauxScrollFrame_Update(win.scroll, #items, ROWS, ROW_H)
    local offset = FauxScrollFrame_GetOffset(win.scroll)
    for i = 1, ROWS do
        local row, e = win.rows[i], items[offset + i]
        row.entry = e
        if e then
            row.icon:SetTexture(e.icon)
            row.icon:SetDesaturated(e.done == true)
            if e.done then
                -- Vérifié : plus rien de rentable.
                row.name:SetText(e.name)
                row.gain:SetText("épuisé")
            elseif e.qty then
                -- Vérifié par une recherche : quantité restante, et gain du PROCHAIN clic
                -- (demande de Jérémie : pas le total, qui baisse à chaque achat).
                row.name:SetText(string.format("%s x%d", e.name, e.qty))
                row.gain:SetText("+" .. Money(NextClickGain(e)) .. " /clic")
            else
                -- Pas encore vérifié : gain sur la moins chère, par unité.
                row.name:SetText(e.name)
                row.gain:SetText("+" .. Money(e.unitGain) .. " /u")
            end
            local grey = e.done and 0.5 or 1
            row.name:SetTextColor(grey, grey, grey)
            row.gain:SetTextColor(e.done and 0.5 or 0.4, e.done and 0.5 or 1, e.done and 0.5 or 0.4)
            row.selected:SetShown(Buyer.entry == e)
            local label, enabled = RowButtonText(e)
            row.buy:SetText(label)
            row.buy:SetEnabled(enabled)
            row:Show()
        else
            row:Hide()
        end
    end

    local text, enabled = ButtonText()
    win.buy:SetText(text)
    win.buy:SetEnabled(enabled)
    win.selection:SetText(Buyer.entry and Buyer.entry.name or "")
end

-- embedded = true : onglet DANS la fenêtre de l'HV ; sinon fenêtre à part, collée à droite.
local function CreateWindow(embedded)
    if embedded then
        win = CreateFrame("Frame", "EryAnomaliesFrame", AuctionHouseFrame)
        win:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPLEFT", 8, -28)
        win:SetPoint("BOTTOMRIGHT", AuctionHouseFrame, "BOTTOMRIGHT", -8, 28)
        ns.Holo.Skin(win) -- habillage « Holo »
    else
        win = CreateFrame("Frame", "EryAnomaliesFrame", UIParent, "BasicFrameTemplateWithInset")
        win:SetSize(400, 470)
        win:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPRIGHT", 4, 0)
        win:SetFrameStrata("HIGH")
        local title = win.TitleText or win:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        if not win.TitleText then title:SetPoint("TOP", 0, -5) end
        title:SetText("Anomalies : moins cher qu'au marchand")
    end
    win:EnableMouse(true)

    local H = ns.Holo
    local title = H.Label(win, "Anomalies  ·  moins cher qu'au marchand", 13, H.CYAN)
    title:SetPoint("TOPLEFT", 14, -10)

    -- Bilan cumulé de tous les achats faits ici (revente supposée au marchand), en haut à droite ;
    -- détail au survol. (Fenêtre à part, plus étroite : une ligne plus bas, à droite du bouton de scan.)
    local bilanBox = CreateFrame("Frame", nil, win)
    bilanBox:SetSize(300, 18)
    bilanBox:SetPoint("TOPRIGHT", -14, embedded and -8 or -32)
    win.bilan = H.Text(bilanBox, 13, H.TEXT)
    win.bilan:SetPoint("RIGHT")
    win.bilan:SetJustifyH("RIGHT")
    bilanBox:EnableMouse(true)
    bilanBox:SetScript("OnEnter", function(self)
        local b = AnoBilan()
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
        GameTooltip:AddLine("Bilan des achats d'Anomalies")
        GameTooltip:AddDoubleLine("Achats", string.format("%d (%d objets)", b.n, b.objets), 1, 1, 1, 1, 1, 1)
        GameTooltip:AddDoubleLine("Payé à l'HV", Money(b.paye), 1, 1, 1, 1, 1, 1)
        GameTooltip:AddDoubleLine("Revente au marchand", Money(b.revente), 1, 1, 1, 1, 1, 1)
        GameTooltip:AddLine("Depuis le " .. (b.debut or "?") .. ", en supposant que tu revends tout au marchand.",
            0.6, 0.6, 0.6, true)
        GameTooltip:Show()
    end)
    bilanBox:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Dans l'HV, les boutons de scan sont à droite de la fenêtre, au-dessus des onglets (SideTabs) :
    -- le scan sert à tout (Anomalies, Métiers, étude du marché). Fenêtre à part : bouton ici.
    local up = embedded and 26 or 0
    if not embedded then
        local scanButton = H.Button(win, "Scanner l'HV", 130, 22, "solid")
        scanButton:SetPoint("TOPLEFT", 12, -30)
        scanButton:SetScript("OnClick", StartScan)
    end

    win.status = H.Text(win, 12, H.SOFT)
    win.status:SetPoint("TOPLEFT", 12, -60 + up)
    win.status:SetPoint("RIGHT", -12, 0)
    win.status:SetJustifyH("LEFT")

    win.scroll = CreateFrame("ScrollFrame", "EryAnomaliesScroll", win, "FauxScrollFrameTemplate")
    win.scroll:SetPoint("TOPLEFT", 10, -76 + up)
    win.scroll:SetPoint("RIGHT", win, "RIGHT", -32, 0)
    win.scroll:SetHeight(ROWS * ROW_H)
    win.scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_H, UpdateWindow)
    end)

    win.rows = {}
    for i = 1, ROWS do
        local row = CreateFrame("Button", nil, win)
        row:SetHeight(ROW_H)
        row:SetPoint("TOPLEFT", win.scroll, "TOPLEFT", 0, -(i - 1) * ROW_H)
        row:SetPoint("RIGHT", win.scroll, "RIGHT", 0, 0)
        H.RowHighlight(row)
        local rowBg = row:CreateTexture(nil, "BACKGROUND")
        rowBg:SetPoint("TOPLEFT", 0, -1)
        rowBg:SetPoint("BOTTOMRIGHT", 0, 1)
        rowBg:SetColorTexture(H.ROW[1], H.ROW[2], H.ROW[3], 1)
        row.selected = row:CreateTexture(nil, "BORDER")
        row.selected:SetAllPoints()
        row.selected:SetColorTexture(H.CYAN[1], H.CYAN[2], H.CYAN[3], 0.18)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(20, 20)
        row.icon:SetPoint("LEFT", 2, 0)
        -- Bouton d'achat sur la ligne même (demande de Jérémie : le bouton du bas est trop loin).
        -- Ligne pas encore choisie : le clic la choisit (achat express pour les empilables).
        -- Ligne choisie : chaque clic fait avancer l'achat (Acheter → Confirmer → …).
        row.buy = H.Button(row, "Acheter", 84, 18, "outline")
        row.buy:SetPoint("RIGHT", -4, 0)
        row.buy:SetScript("OnClick", function(self)
            local e = self:GetParent().entry
            if not e then return end
            if ns.ShiftLink(e.id) then return end -- Maj+clic = lien dans le chat, aucun achat
            if Buyer.entry ~= e or Buyer.state == "done" then
                Buyer.Select(e)
            else
                Buyer.Click()
            end
        end)
        row.gain = H.Text(row, 12, H.GREEN)
        row.gain:SetPoint("RIGHT", row.buy, "LEFT", -8, 0)
        row.gain:SetJustifyH("RIGHT")
        row.name = H.Text(row, 13, H.TEXT)
        row.name:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
        row.name:SetPoint("RIGHT", row.gain, "LEFT", -6, 0)
        row.name:SetJustifyH("LEFT")
        row.name:SetWordWrap(false)
        row:SetScript("OnClick", function(self)
            if not self.entry then return end
            if ns.ShiftLink(self.entry.id) then return end -- Maj+clic = lien dans le chat, aucun achat
            Buyer.Select(self.entry)
        end)
        row.buy:HookScript("OnEnter", function(self) Prefetch(self:GetParent().entry) end)
        row:SetScript("OnEnter", function(self)
            if not self.entry then return end
            Prefetch(self.entry)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetItemByID(self.entry.id)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        win.rows[i] = row
    end

    win.selection = H.Text(win, 13, H.CYAN)
    win.selection:SetPoint("BOTTOMLEFT", 14, 48)
    win.selection:SetPoint("RIGHT", -14, 0)
    win.selection:SetJustifyH("LEFT")

    win.buy = H.Button(win, "", 100, 28, "solid")
    win.buy:SetHeight(28)
    win.buy:SetPoint("BOTTOMLEFT", 14, 12)
    win.buy:SetPoint("BOTTOMRIGHT", -14, 12)
    win.buy:SetScript("OnClick", Buyer.Click)

    win:SetScript("OnShow", UpdateWindow)
    if not embedded then
        win:SetScript("OnHide", function() EryAddonDB.hvWindowShown = false end)
    end
    win:Hide()
end

-- À la 1re ouverture de l'HV : onglets « Anomalies » et « Jobs » en bas de la fenêtre.
local tabsCreated = false

---------------------------------------------------------------------------
-- MES VENTES (demande de Jérémie : « en combien de temps, pour quel bénéfice »). Tes vrais résultats,
-- pas des estimations :
--   - mise en vente : C_AuctionHouse.PostCommodity / PostItem (accroche) → objet, quantité, prix, heure,
--     dépôt, valeur de ce que ça t'a coûté (ns.CostBasis, EryAddon_Jobs.lua : composants si tu sais le
--     fabriquer, sinon prix d'achat le plus bas) ;
--   - vendu : annonce du jeu « Un acheteur a été trouvé pour … » (texte du jeu ERR_AUCTION_SOLD_S, quelle
--     que soit la langue) → délai depuis la mise en vente ;
--   - montant exact : courrier « Vente réussie » (GetInboxInvoiceInfo : prix, commission) à l'ouverture de
--     la boîte aux lettres ;
--   - expiré : ERR_AUCTION_EXPIRED_S → dépôt perdu ; retiré : CancelAuction.
-- EryAddonDB.mesVentes = { annonces = { … en cours … }, faits = { … ventes / expirations … (300 max) },
--   courriers = { [signature] = nombre déjà comptés } }
---------------------------------------------------------------------------
local function MV()
    EryAddonDB.mesVentes = EryAddonDB.mesVentes or { annonces = {}, faits = {}, courriers = {} }
    local d = EryAddonDB.mesVentes
    d.annonces, d.faits, d.courriers = d.annonces or {}, d.faits or {}, d.courriers or {}
    return d
end

local function PatternOf(globalName)
    local f = _G[globalName]
    if type(f) ~= "string" then return nil end
    f = f:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%s", "(.+)")
    return "^" .. f
end
local SOLD_PAT, EXPIRED_PAT, REMOVED_PAT = PatternOf("ERR_AUCTION_SOLD_S"), PatternOf("ERR_AUCTION_EXPIRED_S"),
    PatternOf("ERR_AUCTION_REMOVED_S")

local function AddFait(f)
    local d = MV()
    table.insert(d.faits, f)
    while #d.faits > 300 do table.remove(d.faits, 1) end
end

-- La plus ancienne annonce en cours de cet objet (par nom), ou nil.
local function OldestPost(name)
    for i, a in ipairs(MV().annonces) do
        if a.name == name and (a.left or 0) > 0 then return a, i end
    end
end

local function RecordPost(itemLocation, quantity, unitPrice, duration, isItem)
    if not (itemLocation and quantity and unitPrice) then return end
    local okI, id = pcall(C_Item.GetItemID, itemLocation)
    local okN, name = pcall(C_Item.GetItemName, itemLocation)
    if not (okI and id and okN and name) then return end
    local deposit
    if C_AuctionHouse.CalculateCommodityDeposit then
        -- Dépôt réel : objet non empilable (CalculateItemDeposit) ou marchandise, à la durée choisie.
        local ok, d
        if isItem and C_AuctionHouse.CalculateItemDeposit then
            ok, d = pcall(C_AuctionHouse.CalculateItemDeposit, itemLocation, duration or 2, quantity)
        else
            ok, d = pcall(C_AuctionHouse.CalculateCommodityDeposit, id, duration or 2, quantity)
        end
        if ok then deposit = d end
    end
    table.insert(MV().annonces, { id = id, name = name, qty = quantity, left = quantity, unit = unitPrice,
        t = time(), cost = ns.CostBasis and ns.CostBasis(id) or nil, deposit = deposit })
end

if C_AuctionHouse and hooksecurefunc then
    if C_AuctionHouse.PostCommodity then
        hooksecurefunc(C_AuctionHouse, "PostCommodity", function(loc, dur, qty, unit) pcall(RecordPost, loc, qty, unit, dur) end)
    end
    if C_AuctionHouse.PostItem then
        hooksecurefunc(C_AuctionHouse, "PostItem", function(loc, dur, qty, bid, buyout)
            pcall(RecordPost, loc, qty, buyout or bid, dur, true)
        end)
    end
end

-- Vendu (heure) : « Un acheteur a été trouvé pour votre vente aux enchères de X ».
local lastSold = {}
local function OnSoldText(name)
    if lastSold[name] and GetTime() - lastSold[name] < 1 then return end -- même annonce vue deux fois
    lastSold[name] = GetTime()
    local a, ai = OldestPost(name)
    local d = MV()
    d.ventesSansCourrier = d.ventesSansCourrier or {}
    local sale = { name = name, t = time(), posted = a and a.t, unit = a and a.unit, cost = a and a.cost,
        id = a and a.id }
    if a and a.qty == 1 then
        sale.qty, sale.closed = 1, true
        table.remove(d.annonces, ai)
    end
    table.insert(d.ventesSansCourrier, sale)
end

local function OnExpiredText(name, cancelled)
    local a, i = OldestPost(name)
    if not a then return end
    AddFait({ kind = cancelled and "retire" or "expire", id = a.id, name = name, qty = a.left, t = time(),
        posted = a.t, deposit = a.deposit })
    table.remove(MV().annonces, i)
end

local function OnSystemText(text)
    if type(text) ~= "string" or issecret(text) then return end
    text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h(.-)|h", "%1")
    local n = SOLD_PAT and text:match(SOLD_PAT)
    if n then OnSoldText(n:gsub("^%[", ""):gsub("%]$", "")) return end
    n = EXPIRED_PAT and text:match(EXPIRED_PAT)
    if n then OnExpiredText(n:gsub("^%[", ""):gsub("%]$", ""), false) return end
    n = REMOVED_PAT and text:match(REMOVED_PAT)
    if n then OnExpiredText(n:gsub("^%[", ""):gsub("%]$", ""), true) end
end
if DEFAULT_CHAT_FRAME then
    hooksecurefunc(DEFAULT_CHAT_FRAME, "AddMessage", function(_, text) pcall(OnSystemText, text) end)
end

-- Prix de vente total d'un courrier. BUG VÉCU (08/11) : pour un objet EMPILABLE (potion, élixir, étoffe),
-- Forever met dans « buyout » le NOMBRE d'objets vendus (3 Élixirs vendus 4 pa 80 → buyout = 3), pas le prix.
-- La commission, elle, vaut toujours 5 % du prix (vérifié sur Kilt, Sac, Bottes, Gilet) : prix = commission x 20.
-- On garde buyout (ou bid) seulement s'il colle à ce calcul (écart d'arrondi de la commission).
local function InvoiceGross(bid, buyout, fee)
    fee = tonumber(fee) or 0
    if fee <= 0 then return tonumber(buyout) or tonumber(bid) or 0 end
    local est = fee * 20
    for _, v in ipairs({ tonumber(buyout) or 0, tonumber(bid) or 0 }) do
        if math.abs(v - est) <= 20 + est * 0.01 then return v end
    end
    return est
end

-- Réparation des ventes déjà enregistrées avec ce bug (une fois) : net = quantité − commission, donc
-- net < quantité (impossible pour une vraie vente) ; commission = quantité − net, vrai net = commission x 19.
local function RepairInvoiceNets(d)
    if d.netsRepares then return end
    for _, f in ipairs(d.faits or {}) do
        local qty = f.qty or 1
        if f.kind == "vendu" and f.net and f.net < qty then
            local fee = qty - f.net
            if fee > 0 then f.net = fee * 19 end
        end
    end
    d.netsRepares = true
end

-- Courriers « Vente réussie » : montant exact. Chaque courrier n'est compté qu'une fois (signature +
-- nombre déjà comptés, remis à jour quand des courriers disparaissent de la boîte).
local function ReadInvoices()
    if not (GetInboxNumItems and GetInboxInvoiceInfo) then return end
    local d = MV()
    RepairInvoiceNets(d)
    local present = {}
    local list = {}
    for i = 1, GetInboxNumItems() do
        local ok, kind, itemName, _, bid, buyout, deposit, fee, _, _, _, count = pcall(GetInboxInvoiceInfo, i)
        if ok and kind == "seller" and itemName and buyout then
            local key = table.concat({ itemName, buyout, deposit or 0, fee or 0, count or 0 }, "|")
            present[key] = (present[key] or 0) + 1
            if present[key] > (d.courriers[key] or 0) then
                list[#list + 1] = { name = itemName, gross = InvoiceGross(bid, buyout, fee), fee = fee or 0,
                    count = count, key = key }
                -- Valeurs brutes des 10 derniers courriers (diagnostic, lisible par Claude).
                d.brut = d.brut or {}
                table.insert(d.brut, 1, table.concat({ itemName, tostring(bid), tostring(buyout), tostring(deposit),
                    tostring(fee), tostring(count) }, "|"))
                while #d.brut > 10 do table.remove(d.brut) end
            end
        end
    end
    for key, n in pairs(d.courriers) do d.courriers[key] = math.min(n, present[key] or 0) end
    for _, inv in ipairs(list) do
        d.courriers[inv.key] = (d.courriers[inv.key] or 0) + 1
        -- La vente annoncée la plus ancienne de cet objet donne l'heure et le coût.
        local sale
        for i, s in ipairs(d.ventesSansCourrier or {}) do
            if s.name == inv.name then sale = table.remove(d.ventesSansCourrier, i) break end
        end
        local a, ai
        if not (sale and sale.closed) then a, ai = OldestPost(inv.name) end
        local unit = (sale and sale.unit) or (a and a.unit)
        local qty = inv.count or (unit and unit > 0 and math.max(1, math.floor(inv.gross / unit + 0.5))) or 1
        if a then
            a.left = (a.left or 0) - qty
            if a.left <= 0 then table.remove(d.annonces, ai) end
        end
        AddFait({ kind = "vendu", id = (sale and sale.id) or (a and a.id), name = inv.name, qty = qty,
            net = inv.gross - inv.fee, t = (sale and sale.t) or nil, posted = (sale and sale.posted) or (a and a.t),
            cost = (sale and sale.cost) or (a and a.cost) })
    end
end
local mailWatch = CreateFrame("Frame")
pcall(mailWatch.RegisterEvent, mailWatch, "MAIL_INBOX_UPDATE")
mailWatch:SetScript("OnEvent", function() pcall(ReadInvoices) end)

-- Bilan d'un objet (nil si aucune vente ni expiration) : { vendus, net, benef (si coût connu),
-- delai (heures, moyenne), expires, depotPerdu, enCours }
function ns.MySales(itemID)
    local d = EryAddonDB and EryAddonDB.mesVentes
    if not d then return nil end
    RepairInvoiceNets(d)
    local s = { vendus = 0, net = 0, benef = 0, coutConnu = true, delai = 0, nDelai = 0, expires = 0,
        depotPerdu = 0, enCours = 0 }
    local any = false
    for _, f in ipairs(d.faits or {}) do
        if f.id == itemID then
            any = true
            if f.kind == "vendu" then
                s.vendus = s.vendus + (f.qty or 0)
                s.net = s.net + (f.net or 0)
                if f.cost then s.benef = s.benef + (f.net or 0) - f.cost * (f.qty or 0) else s.coutConnu = false end
                if f.t and f.posted then s.delai = s.delai + (f.t - f.posted) / 3600; s.nDelai = s.nDelai + 1 end
            else
                s.expires = s.expires + (f.qty or 0)
                s.depotPerdu = s.depotPerdu + (f.deposit or 0)
            end
        end
    end
    -- Ventes annoncées dans le chat, courrier pas encore lu : comptées tout de suite, montant estimé
    -- (prix de l'annonce − 5 %), remplacé par le montant exact à l'ouverture de la boîte aux lettres.
    for _, v in ipairs(d.ventesSansCourrier or {}) do
        if v.id == itemID then
            any = true
            local q = v.qty or 1
            s.vendus = s.vendus + q
            local net = (v.unit or 0) * q * 0.95
            s.net = s.net + net
            if v.cost then s.benef = s.benef + net - v.cost * q else s.coutConnu = false end
            if v.t and v.posted then s.delai = s.delai + (v.t - v.posted) / 3600; s.nDelai = s.nDelai + 1 end
            s.estime = true
        end
    end
    for _, a in ipairs(d.annonces or {}) do
        if a.id == itemID then s.enCours = s.enCours + (a.left or 0); any = true end
    end
    if not any then return nil end
    s.delaiMoyen = s.nDelai > 0 and (s.delai / s.nDelai) or nil
    s.benef = s.benef - s.depotPerdu
    return s
end

-- Tous les objets que tu as vendus ou mis en vente, pour l'onglet « Mes ventes ».
function ns.MySalesItems()
    local d = EryAddonDB and EryAddonDB.mesVentes
    if d then RepairInvoiceNets(d) end
    local seen, list = {}, {}
    for _, src in ipairs({ d and d.faits or {}, d and d.annonces or {} }) do
        for _, f in ipairs(src) do
            if f.id and not seen[f.id] then
                seen[f.id] = true
                local s = ns.MySales(f.id)
                if s then s.id, s.name = f.id, f.name; list[#list + 1] = s end
            end
        end
    end
    table.sort(list, function(a, b) return a.benef > b.benef end)
    return list
end

ns._MySalesTest = { RecordPost = RecordPost, OnSystemText = OnSystemText, ReadInvoices = ReadInvoices }

-- Onglet « Mes ventes » dans l'HV : un objet par ligne, le plus rentable d'abord.
local MV_ROWS, MV_ROW_H = 16, 22
local function DelaiText(h)
    if not h then return "?" end
    if h < 1 then return string.format("%d min", math.floor(h * 60 + 0.5)) end
    if h < 48 then return string.format("%.0f h", h) end
    return string.format("%.0f j", h / 24)
end

local function CreateMySalesPanel(parent)
    local H = ns.Holo
    local p = CreateFrame("Frame", "EryMesVentesTab", parent)
    p:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, -28)
    p:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -8, 28)
    H.Skin(p)
    p:EnableMouse(true)
    local title = H.Text(p, 14, H.CYAN)
    title:SetPoint("TOPLEFT", 14, -12)
    title:SetText("Mes ventes")
    p.summary = H.Text(p, 12, H.SOFT)
    p.summary:SetPoint("TOPLEFT", 14, -34)
    p.summary:SetPoint("RIGHT", -14, 0)
    -- Colonnes (bord droit, depuis la droite).
    local COLS = { { "En cours", -10, 60 }, { "Expirés", -76, 60 }, { "Bénéfice", -142, 100 },
        { "Prix net / u", -248, 100 }, { "Délai moyen", -354, 80 }, { "Vendus", -440, 60 } }
    local head = H.Text(p, 10, H.DIM)
    head:SetPoint("TOPLEFT", 14, -58)
    head:SetText("OBJET")
    for _, c in ipairs(COLS) do
        local h = H.Text(p, 10, H.DIM)
        h:SetPoint("TOPRIGHT", p, "TOPRIGHT", c[2] - 22, -58)
        h:SetText(H.Upper and H.Upper(c[1]) or c[1])
    end
    p.scroll = CreateFrame("ScrollFrame", nil, p, "FauxScrollFrameTemplate")
    p.scroll:SetPoint("TOPLEFT", 10, -72)
    p.scroll:SetPoint("RIGHT", p, "RIGHT", -32, 0)
    p.scroll:SetHeight(MV_ROWS * MV_ROW_H)
    p.rows = {}
    for i = 1, MV_ROWS do
        local row = CreateFrame("Frame", nil, p)
        row:SetHeight(MV_ROW_H)
        row:SetPoint("TOPLEFT", p.scroll, "TOPLEFT", 0, -(i - 1) * MV_ROW_H)
        row:SetPoint("RIGHT", p.scroll, "RIGHT", 0, 0)
        local bg = H.Tex(row, "BACKGROUND", H.ROW, (i % 2 == 0) and 0.55 or 1); bg:SetAllPoints()
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(18, 18)
        row.icon:SetPoint("LEFT", 2, 0)
        row.name = H.Text(row, 13, H.TEXT)
        row.name:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
        row.name:SetPoint("RIGHT", row, "RIGHT", -510, 0)
        row.name:SetWordWrap(false)
        row.cols = {}
        for c, col in ipairs(COLS) do
            local t = H.Text(row, 12, H.TEXT)
            t:SetPoint("RIGHT", row, "RIGHT", col[2], 0)
            t:SetWidth(col[3])
            t:SetJustifyH("RIGHT")
            row.cols[c] = t
        end
        row:EnableMouse(true)
        row:SetScript("OnEnter", function(self)
            if self.id then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetItemByID(self.id)
                GameTooltip:Show()
            end
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row:SetScript("OnMouseUp", function(self, button)
            if button == "LeftButton" and self.id then ns.ShiftLink(self.id) end
        end)
        p.rows[i] = row
    end
    p.empty = H.Text(p, 13, H.DIM)
    p.empty:SetPoint("TOPLEFT", p.scroll, "TOPLEFT", 6, -10)
    p.empty:SetText("Aucune vente suivie pour l'instant : mets quelque chose en vente, ça s'affichera ici.")

    local function Refresh()
        if not p:IsShown() then return end
        local list = ns.MySalesItems and ns.MySalesItems() or {}
        local totNet, totBenef, totSold = 0, 0, 0
        for _, s in ipairs(list) do totNet, totBenef, totSold = totNet + s.net, totBenef + s.benef, totSold + s.vendus end
        p.summary:SetText(string.format("%d objets vendus pour %s net  ·  bénéfice %s%s|r", totSold, Money(totNet),
            totBenef >= 0 and "|cff5cffb0+" or "|cffff7373-", Money(math.abs(totBenef))))
        FauxScrollFrame_Update(p.scroll, #list, MV_ROWS, MV_ROW_H)
        local offset = FauxScrollFrame_GetOffset(p.scroll)
        for i, row in ipairs(p.rows) do
            local s = list[offset + i]
            row.id = s and s.id
            if s then
                row.icon:SetTexture((C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(s.id)) or nil)
                row.name:SetText(s.name or ("objet " .. s.id))
                row.cols[6]:SetText(s.vendus > 0 and tostring(s.vendus) or "|cff5f8a990|r")
                row.cols[5]:SetText(DelaiText(s.delaiMoyen))
                row.cols[4]:SetText(s.vendus > 0 and Money(s.net / s.vendus) or "")
                row.cols[3]:SetText(s.coutConnu and ((s.benef >= 0 and "|cff5cffb0+" or "|cffff7373-") .. Money(math.abs(s.benef)) .. "|r")
                    or "|cff5f8a99coût ?|r")
                row.cols[2]:SetText(s.expires > 0 and ("|cffff9933" .. s.expires .. "|r") or "")
                row.cols[1]:SetText(s.enCours > 0 and tostring(s.enCours) or "")
                row:Show()
            else
                row:Hide()
            end
        end
        p.empty:SetShown(#list == 0)
    end
    p.scroll:SetScript("OnVerticalScroll", function(self, off)
        FauxScrollFrame_OnVerticalScroll(self, off, MV_ROW_H, Refresh)
    end)
    p:SetScript("OnShow", Refresh)
    p:Hide()
    return p
end

-- Onglets à la VERTICALE, collés au bord droit de l'HV (demande de Jérémie : en bas, avec ceux du jeu et
-- d'Auctionator, « Mes ventes » dépassait de la fenêtre). Les onglets de LibAHTab restent (ils gèrent la
-- sélection, le titre et la fermeture des autres pages) mais leurs boutons du bas sont cachés.
local function SideTabs(lib, list)
    local H = ns.Holo
    local buttons = {}
    local function Mark(selectedID)
        for id, b in pairs(buttons) do b:SetStyle(id == selectedID and "solid" or "outline") end
    end
    -- Panneau à FOND PLEIN derrière toute la colonne (demande de Jérémie : en transparence, on voyait le
    -- décor et les noms des joueurs à travers les boutons). Même habillage que nos fenêtres (Holo.Skin).
    local panel = CreateFrame("Frame", nil, AuctionHouseFrame)
    -- −28 : même hauteur que le haut de nos pages dans l'HV (CreateWindow : TOPLEFT 8, −28), coins alignés.
    panel:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPRIGHT", 0, -28)
    H.Skin(panel)
    panel:EnableMouse(true) -- les clics ne traversent pas vers le monde
    -- En haut : les deux scans (ils servent à tous les onglets) et leur état en version courte.
    local scan = H.Button(panel, "Scanner l'HV", 104, 26, "muted")
    scan:SetPoint("TOPLEFT", panel, "TOPLEFT", 6, -6)
    scan:SetScript("OnClick", StartScan)
    local global = H.Button(panel, "Scan global", 104, 26, "muted")
    global:SetPoint("TOPLEFT", scan, "BOTTOMLEFT", 0, -4)
    global:SetScript("OnClick", StartGlobalScan)
    global:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Scan global")
        GameTooltip:AddLine("Scan + étude du marché de TOUS les objets de l'HV, sans limite de temps (environ 1 h).", 1, 1, 1, true)
        GameTooltip:AddLine("Reste devant le commissaire-priseur : fermer l'HV l'arrête (ce qui est relevé est gardé).", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    global:SetScript("OnLeave", function(self) GameTooltip:Hide(); self:SetStyle(self.style) end)
    sideStatus = H.Text(panel, 11, H.SOFT)
    sideStatus:SetPoint("TOPLEFT", global, "BOTTOMLEFT", 2, -6)
    sideStatus:SetWidth(100)
    sideStatus:SetJustifyH("LEFT")
    sideStatus:SetWordWrap(true)
    AuctionHouseFrame:HookScript("OnShow", UpdateSide)
    UpdateSide()
    local prev
    for _, t in ipairs(list) do
        local id, label = t[1], t[2]
        if lib:DoesIDExist(id) then
            local old = lib:GetButton(id)
            old:Hide()
            old:HookScript("OnShow", old.Hide) -- au cas où quelqu'un la réaffiche
            local b = H.Button(panel, label, 104, 26, "outline")
            if prev then
                b:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -4)
            else
                b:SetPoint("TOPLEFT", global, "BOTTOMLEFT", 0, -44) -- sous l'état du scan (2 lignes)
            end
            b:SetScript("OnClick", function() lib:SetSelected(id) end)
            buttons[id] = b
            prev = b
        end
    end
    -- Taille CALCULÉE (pas d'accroche au dernier bouton : il dépend lui-même du panneau, et le jeu refuse
    -- cette boucle, erreur « Cannot anchor to a region dependent on it » vue le 08/11).
    -- Marge 6 + scan 26 + 4 + global 26 + 44 (état) + onglets (26 + 4 entre eux) + marge 6.
    local n = 0
    for _ in pairs(buttons) do n = n + 1 end
    panel:SetSize(6 + 104 + 6, 6 + 26 + 4 + 26 + 44 + n * 26 + math.max(0, n - 1) * 4 + 6)
    -- Onglet choisi (le nôtre ou celui d'Auctionator) : surbrillance à jour.
    hooksecurefunc(lib, "SetSelected", function(_, id) Mark(id) end)
    -- Onglet du jeu (Acheter, Vendre…) : aucun des nôtres n'est choisi.
    hooksecurefunc(AuctionHouseFrame, "SetDisplayMode", function(_, mode)
        if mode ~= nil and #mode > 0 then Mark(nil) end
    end)
end

local function CreateTabs()
    local lib = TabLib()
    if tabsCreated or not lib then return tabsCreated end
    tabsCreated = true
    CreateWindow(true)
    lib:CreateTab("EryAddon_Anomalies", win, "Anomalies", "Anomalies : moins cher qu'au marchand")
    if ns.CreateJobsPanel then
        local jobs = ns.CreateJobsPanel(AuctionHouseFrame)
        lib:CreateTab("EryAddon_Jobs", jobs, "Métiers", "Métiers : monter ses métiers en gagnant de l'or")
    end
    local ventes = CreateMySalesPanel(AuctionHouseFrame)
    lib:CreateTab("EryAddon_MesVentes", ventes, "Mes ventes", "Mes ventes : délai, prix et bénéfice réels")
    SideTabs(lib, { { "EryAddon_Anomalies", "Anomalies" }, { "EryAddon_Jobs", "Métiers" },
        { "EryAddon_MesVentes", "Mes ventes" } })
    return true
end

local function ShowWindow(show)
    if not win then CreateWindow() end
    win:SetShown(show)
    EryAddonDB.hvWindowShown = show
end

local function CreateToggleButton()
    toggleButton = CreateFrame("Button", nil, AuctionHouseFrame, "UIPanelButtonTemplate")
    toggleButton:SetSize(100, 22)
    toggleButton:SetPoint("TOPRIGHT", AuctionHouseFrame, "BOTTOMRIGHT", -4, -2)
    toggleButton:SetText("Anomalies")
    toggleButton:SetScript("OnClick", function()
        ShowWindow(not (win and win:IsShown()))
    end)
end

---------------------------------------------------------------------------
-- Événements
---------------------------------------------------------------------------
local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", function(_, event, ...)
    if event == "AUCTION_HOUSE_SHOW" then
        C_Timer.After(3, StartStudyOnly) -- reprise de l'étude du marché, sans scan
        -- Petit délai : la fenêtre de l'HV de Blizzard est créée au même moment.
        C_Timer.After(0, function()
            if not AuctionHouseFrame then return end
            if CreateTabs() then return end -- onglets dans l'HV
            -- Secours sans la bibliothèque d'onglets : bouton + fenêtre à part.
            if not toggleButton then CreateToggleButton() end
            toggleButton:Show()
            if EryAddonDB.hvWindowShown then ShowWindow(true) end
        end)
    elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
        OnActionBlocked(...)
    elseif event == "AUCTION_HOUSE_CLOSED" then
        -- HV fermé n'importe quand (scan, vérification, étude, achat en cours) : tout s'arrête
        -- proprement ; ce qui est déjà relevé est gardé, la suite reprend à la prochaine ouverture.
        ResetBuyer()
        StopDetails()
        if globalMode then
            globalMode = false
            Msg("scan global interrompu (HV fermé). Ce qui est relevé est gardé ; relance-le à ta prochaine visite.")
        end
        if scanRunning then
            scanRunning = false
            scanToken = scanToken + 1 -- les relances programmées du scan s'annulent
            scanResults, scanQty, scanKeys = {}, {}, {}
            SetStatus("Scan interrompu (HV fermé) : relance-le à ta prochaine visite.", "Scan interrompu")
        end
        if Course then
            if Course.state == "starting" or Course.state == "confirm" then
                pcall(C_AuctionHouse.CancelCommoditiesPurchase)
            end
            Course = nil
        end
        prefetch = nil -- (uniqWatch reste : l'annonce « gagné les enchères » peut arriver après la fermeture)
        if not tabsCreated then
            local wasShown = win and win:IsShown()
            if win then win:Hide() end
            EryAddonDB.hvWindowShown = wasShown and true or false
        end
    elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" or event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
        OnBrowseEvent(event, ...)
    elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
        OnCommodityResults(...)
        OnDetailResults(event, ...)
    elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
        OnPrefetchResults(...)
        OnUniqueResults(...)
        OnItemResults(...)
        OnDetailResults(event, ...)
    elseif event == "COMMODITY_PRICE_UPDATED" then
        if not OnReagentPrice(...) then OnCommodityPrice(...) end
    elseif event == "COMMODITY_PRICE_UNAVAILABLE" then
        if Buyer.state == "starting" then
            C_AuctionHouse.CancelCommoditiesPurchase()
            Search()
        end
    elseif event == "COMMODITY_PURCHASE_SUCCEEDED" then
        if not OnReagentDone(true) then
            ReportPurchase() -- relance aussi la recherche, après le bilan
        end
    elseif event == "COMMODITY_PURCHASE_FAILED" then
        if OnReagentDone(false) then return end
        ReportFailure("refusé par le serveur")
        if Buyer.state == "buying" then Search() end
    elseif event == "AUCTION_HOUSE_SHOW_COMMODITY_WON_NOTIFICATION" then
        OnCommodityWon(...)
    elseif event == "AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION" then
        OnFormattedNotification(...)
    elseif event == "PLAYER_MONEY" then
        -- Achat d'un objet unique : l'argent a baissé, l'achat est fait.
        -- (Le bilan d'un objet unique part de l'annonce de victoire dans le chat.)
    end
end)

local EVENTS = {
    "AUCTION_HOUSE_SHOW",
    "AUCTION_HOUSE_CLOSED",
    "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED",
    "AUCTION_HOUSE_BROWSE_RESULTS_ADDED",
    "COMMODITY_SEARCH_RESULTS_UPDATED",
    "ITEM_SEARCH_RESULTS_UPDATED",
    "COMMODITY_PRICE_UPDATED",
    "COMMODITY_PRICE_UNAVAILABLE",
    "COMMODITY_PURCHASE_SUCCEEDED",
    "COMMODITY_PURCHASE_FAILED",
    "PLAYER_MONEY",
    "AUCTION_HOUSE_SHOW_COMMODITY_WON_NOTIFICATION",
    "AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION",
    "ADDON_ACTION_BLOCKED",
    "ADDON_ACTION_FORBIDDEN",
}

function HV.Enable()
    for _, ev in ipairs(EVENTS) do
        pcall(frame.RegisterEvent, frame, ev) -- ignore un événement absent sur Forever
    end
    if toggleButton then toggleButton:Show() end
end

function HV.Disable()
    frame:UnregisterAllEvents()
    ResetBuyer()
    if win then win:Hide() end
    if toggleButton then toggleButton:Hide() end
end

---------------------------------------------------------------------------
-- Fonction : icônes dans les sacs « mieux au marchand » / « mieux à l'HV »
---------------------------------------------------------------------------
-- Prix HV : le dernier prix scanné par Auctionator (son API publique).
-- Calcul pour une pile entière de N objets :
--   marchand = prix marchand x N
--   HV net   = prix HV x N, moins 5 % de commission
-- Règles de Forever CONFIRMÉES par un courrier « Vente réussie » (Parchemin de force, 07/11) :
--   commission 5 %, dépôt RENDU quand l'objet se vend. Le dépôt (1 pa minimum) n'est perdu que
--   si l'objet ne se vend pas (règle classique, pas encore vérifiée) : c'est le risque à couvrir.
-- Icône HV seulement si l'HV rapporte au moins 20 % de plus que le marchand ET au moins le dépôt
-- (sinon un invendu effacerait le bénéfice).
local Sacs = {
    key = "hvSacs",
    label = "Sacs : icônes « mieux au marchand » / « mieux à l'HV »",
}
table.insert(ns.features, Sacs)
ns.DEFAULTS.hvSacs = true

local DEPOSIT = 100        -- 1 pa : dépôt minimum, perdu seulement en cas d'invendu
local COMMISSION = 0.05    -- 5 % (confirmé)
local MARGIN = 0.20        -- l'HV doit rapporter au moins 20 % de plus que le marchand...
local MARGIN_MIN = DEPOSIT -- ... et au moins le dépôt qu'on risque

local ICON_PNJ = "Interface\\MoneyFrame\\UI-SilverIcon" -- pièce d'argent (choix de Jérémie)
local ICON_HV = "Interface\\Minimap\\Tracking\\Auctioneer"
local ICON_ROUGE = "Interface\\Common\\Indicator-Red" -- pastille rouge sous la pièce « marchand »

-- Prix HV d'un objet, gardé en mémoire 5 minutes (bug : gels en vidant la boîte aux lettres,
-- chaque objet récupéré relançait le calcul de toutes les icônes avec la recherche « par lien »
-- d'Auctionator, lente). On demande d'abord par numéro d'objet (rapide).
local priceCache, priceCacheTime = {}, 0
local function AuctionPrice(link, itemID)
    if not (Auctionator and Auctionator.API and Auctionator.API.v1) then return nil end
    if GetTime() - priceCacheTime > 300 then priceCache, priceCacheTime = {}, GetTime() end
    local cached = priceCache[itemID]
    if cached ~= nil then return cached or nil end
    local api = Auctionator.API.v1
    local ok, price = pcall(api.GetAuctionPriceByItemID, "EryAddon", itemID)
    if not (ok and price) then
        ok, price = pcall(api.GetAuctionPriceByItemLink, "EryAddon", link)
    end
    price = ok and price or nil
    priceCache[itemID] = price or false
    return price
end

-- Verdict pour une pile : "pnj", "hv" ou nil (pas d'avis), plus les deux montants.
local function Verdict(link, itemID, count)
    local _, _, _, vendor = ItemData(itemID)
    if not vendor or vendor <= 0 then return nil end -- invendable au marchand
    local price = AuctionPrice(link, itemID)
    if not price then return nil end                 -- pas de prix HV connu
    count = count or 1
    local vendorTotal = vendor * count
    local hvNet = price * count * (1 - COMMISSION) -- le dépôt est rendu à la vente
    if vendorTotal >= hvNet then return "pnj", vendorTotal, hvNet end
    if hvNet >= vendorTotal + math.max(MARGIN_MIN, vendorTotal * MARGIN) then
        return "hv", vendorTotal, hvNet
    end
    return nil, vendorTotal, hvNet -- trop proche pour conseiller
end

-- Infos de l'objet d'un bouton de sac : lien, numéro, quantité ; nil si vide ou lié.
local function ButtonItem(button)
    local bag = button.GetBagID and button:GetBagID() or (button:GetParent() and button:GetParent():GetID())
    local slot = button:GetID()
    if not bag or not slot or not C_Container then return nil end
    local info = C_Container.GetContainerItemInfo(bag, slot)
    if not info or not info.itemID or info.isBound then return nil end -- objet lié : pas vendable à l'HV
    return info.hyperlink, info.itemID, info.stackCount
end

local function UpdateButton(button)
    local kind
    if Sacs.enabled then
        local link, itemID, count = ButtonItem(button)
        if itemID then kind = Verdict(link, itemID, count) end
    end
    local tex = button.eryIcon
    if not kind then
        if tex then tex:Hide(); button.eryRed:Hide() end
        return
    end
    if not tex then
        -- « Mieux au marchand » : pièce d'argent posée sur une pastille ROUGE (Jérémie : la pièce seule
        -- ne se voyait pas assez). Pastille Interface\Common\Indicator-Red (utilisée par NodeSight).
        button.eryRed = button:CreateTexture(nil, "OVERLAY", nil, 6)
        button.eryRed:SetSize(16, 16)
        button.eryRed:SetPoint("TOPLEFT", 1, -1)
        button.eryRed:SetTexture(ICON_ROUGE)
        tex = button:CreateTexture(nil, "OVERLAY", nil, 7)
        button.eryIcon = tex
    end
    tex:ClearAllPoints()
    if kind == "pnj" then
        -- Pastille rouge SEULE : la pièce d'argent posée dessus la cachait (retour de Jérémie).
        tex:Hide()
        button.eryRed:Show()
        return
    else
        tex:SetSize(14, 14)
        tex:SetPoint("TOPLEFT", 1, -1)
        button.eryRed:Hide()
    end
    tex:SetTexture(kind == "pnj" and ICON_PNJ or ICON_HV)
    tex:Show()
end

-- Tous les boutons des sacs Blizzard ouverts (sac unique combiné ou sacs séparés).
local function ForEachBagButton(fn)
    local frames = { ContainerFrameCombinedBags }
    for i = 1, 13 do frames[#frames + 1] = _G["ContainerFrame" .. i] end
    for _, f in pairs(frames) do
        if f and f:IsShown() and f.EnumerateValidItems then
            for _, button in f:EnumerateValidItems() do fn(button) end
        end
    end
end

local function RefreshBags()
    ForEachBagButton(UpdateButton)
end

-- Plusieurs signaux d'un coup (ouverture, changement de sac) : un seul rafraîchissement.
local bagsPending = false
local function RequestBags()
    if bagsPending then return end
    bagsPending = true
    -- 0,5 s : en vidant la boîte aux lettres, les sacs changent à chaque objet ; on attend
    -- que ça se calme avant de refaire les icônes.
    C_Timer.After(0.5, function()
        bagsPending = false
        RefreshBags()
    end)
end

local hooked = false
local function HookBagFrames()
    if hooked then return end
    hooked = true
    local frames = { ContainerFrameCombinedBags }
    for i = 1, 13 do frames[#frames + 1] = _G["ContainerFrame" .. i] end
    for _, f in pairs(frames) do
        if f then f:HookScript("OnShow", RequestBags) end
    end
end

-- Ligne d'explication dans l'info-bulle d'un objet des sacs.
local tooltipHooked = false
local function HookTooltip()
    if tooltipHooked or not (TooltipDataProcessor and Enum.TooltipDataType) then return end
    tooltipHooked = true
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip)
        if not Sacs.enabled or tooltip ~= GameTooltip then return end
        local owner = tooltip:GetOwner()
        if not owner or not owner.eryIcon or not owner.eryIcon:IsShown() then return end
        local link, itemID, count = ButtonItem(owner)
        if not itemID then return end
        local kind, vendorTotal, hvNet = Verdict(link, itemID, count)
        if not kind then return end
        tooltip:AddLine(string.format("EryAddon : %s (marchand %s, HV net %s)",
            kind == "pnj" and "mieux au marchand" or "mieux à l'HV",
            Money(vendorTotal), Money(math.max(0, hvNet))), 0.6, 1, 0.6)
        tooltip:Show()
    end)
end

local bagFrame = CreateFrame("Frame")
bagFrame:SetScript("OnEvent", RequestBags)

function Sacs.Enable()
    Sacs.enabled = true
    HookBagFrames()
    HookTooltip()
    bagFrame:RegisterEvent("BAG_UPDATE_DELAYED")
    pcall(bagFrame.RegisterEvent, bagFrame, "AUCTION_HOUSE_CLOSED") -- nouveaux prix après un scan
    RequestBags()
end

function Sacs.Disable()
    Sacs.enabled = false
    bagFrame:UnregisterAllEvents()
    RefreshBags() -- cache les icônes
end
