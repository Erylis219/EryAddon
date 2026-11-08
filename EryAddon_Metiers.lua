-- EryAddon : relevé des recettes de métiers, pour repérer les crafts rentables.
-- Automatique et silencieux (pas de commande) : quelques secondes après la connexion,
-- l'add-on demande au jeu, pour chacune des recettes de Forever (EryAddon_Recettes.lua) :
--   - les composants et leurs quantités (C_TradeSkillUI.GetRecipeSchematic) ;
--   - le nom, le prix marchand et la taille de pile des objets concernés.
-- Le tout est rangé dans EryAddonDB.metiers. Claude le lit après un /reload et le croise
-- avec les prix HV du dernier scan (EryAddonDB.hvPrix, rempli par la fenêtre Anomalies).
-- Une seule fois par version des données ; par petits paquets pour ne pas figer le jeu.

local ADDON_NAME, ns = ...
local issecret = ns.issecret

local DATA_VERSION = 1
local BATCH = 40 -- recettes lues par paquet

local function GetItemData(itemID)
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    local name, _, _, _, _, _, _, maxStack, _, _, sellPrice = getInfo(itemID)
    return name, sellPrice, maxStack
end

local function Schematic(spellID)
    if not (C_TradeSkillUI and C_TradeSkillUI.GetRecipeSchematic) then return nil, "API absente" end
    local ok, sch = pcall(C_TradeSkillUI.GetRecipeSchematic, spellID, false)
    if not ok then return nil, tostring(sch) end
    if type(sch) ~= "table" or issecret(sch) then return nil, "rien" end
    return sch
end

-- Composants « id:quantité,id:quantité » (seuls les composants obligatoires).
local function ReagentString(sch)
    local parts = {}
    for _, slot in ipairs(sch.reagentSlotSchematics or {}) do
        local first = slot.reagents and slot.reagents[1]
        local required = slot.required ~= false and (slot.reagentType == nil or slot.reagentType == 1)
        if first and first.itemID and required then
            parts[#parts + 1] = first.itemID .. ":" .. (slot.quantityRequired or 1)
        end
    end
    return table.concat(parts, ",")
end

local function SaveItem(db, itemID)
    if not itemID or db.objets[itemID] then return end
    local name, sell, stack = GetItemData(itemID)
    if name then
        db.objets[itemID] = string.format("%s|%d|%d", name, sell or 0, stack or 1)
    else
        db.manquants[itemID] = true
        if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(itemID) end
    end
end

-- 2e et 3e passages pour les objets dont le jeu n'avait pas encore chargé les infos.
local function RetryMissing(db, attempt)
    local still = {}
    for itemID in pairs(db.manquants) do
        db.manquants[itemID] = nil
        SaveItem(db, itemID)
    end
    for itemID in pairs(db.manquants) do still[#still + 1] = itemID end
    if #still > 0 and attempt < 4 then
        C_Timer.After(10, function() RetryMissing(db, attempt + 1) end)
    else
        db.fini = date("%d/%m/%Y %H:%M")
    end
end

local function Collect()
    local list = ns.RECETTES
    if not list then return end
    local db = EryAddonDB.metiers
    if type(db) ~= "table" or db.version ~= DATA_VERSION then
        db = { version = DATA_VERSION, recettes = {}, objets = {}, manquants = {}, erreurs = 0 }
        EryAddonDB.metiers = db
    elseif db.fini then
        return -- déjà fait
    end

    local index = 1
    local function batch()
        if InCombatLockdown() then C_Timer.After(5, batch); return end
        local last = math.min(index + BATCH - 1, #list)
        for i = index, last do
            local prof, spell, creates = list[i][1], list[i][2], list[i][3]
            local sch, err = Schematic(spell)
            if sch then
                local out = sch.outputItemID or creates
                db.recettes[spell] = string.format("%d|%d|%d|%d|%s", prof, out,
                    sch.quantityMin or 1, sch.quantityMax or sch.quantityMin or 1, ReagentString(sch))
                SaveItem(db, out)
                for _, slot in ipairs(sch.reagentSlotSchematics or {}) do
                    local first = slot.reagents and slot.reagents[1]
                    if first then SaveItem(db, first.itemID) end
                end
            else
                db.erreurs = db.erreurs + 1
                db.derniereErreur = string.format("sort %d : %s", spell, tostring(err))
                db.recettes[spell] = string.format("%d|%d|1|1|?", prof, creates) -- composants inconnus
                SaveItem(db, creates)
            end
        end
        index = last + 1
        if index <= #list then
            C_Timer.After(0.1, batch)
        else
            C_Timer.After(10, function() RetryMissing(db, 1) end)
        end
    end
    batch()
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function()
    C_Timer.After(15, function()
        local ok, err = pcall(Collect)
        if not ok then
            EryAddonDB.metiers = EryAddonDB.metiers or {}
            EryAddonDB.metiers.erreurFatale = tostring(err)
        end
    end)
end)

---------------------------------------------------------------------------
-- Niveaux de métier, notés tout seuls (demande de Jérémie) dans
-- EryAddonDB.niveaux = { date, perso, metiers = { ["Alchimie"] = "18/75", ... } }.
-- Mis à jour à la connexion, à chaque point gagné et à chaque niveau.
-- (Ne lit que les lignes visibles de la fenêtre Compétences : si la rubrique
-- « Métiers » y est repliée, les métiers n'apparaissent pas.)
---------------------------------------------------------------------------
-- Deux façons de lire les niveaux selon la version du jeu :
--   1. GetProfessions / GetProfessionInfo (jeu actuel : c'est celle qui marche sur Forever) ;
--   2. GetNumSkillLines / GetSkillLineInfo (ancien jeu), en secours.
-- (1re version : seulement la n°2, absente sur Forever → aucun métier relevé.)
local function SaveLevels()
    local metiers, source = {}, nil
    if GetProfessions and GetProfessionInfo then
        for _, index in pairs({ GetProfessions() }) do
            if index then
                local ok, name, _, rank, maxRank, _, _, skillLine = pcall(GetProfessionInfo, index)
                if ok and rank and not issecret(rank) then
                    -- Nom du métier tel que dans nos recettes (d'après son numéro), sinon celui du jeu.
                    name = (skillLine and ns.METIERS and ns.METIERS[skillLine]) or name
                    if name then metiers[name] = rank .. "/" .. (maxRank or "?") end
                    source = "GetProfessionInfo"
                end
            end
        end
    end
    if not next(metiers) and GetNumSkillLines and GetSkillLineInfo then
        local wanted = {}
        for _, name in pairs(ns.METIERS or {}) do wanted[name] = true end
        for i = 1, GetNumSkillLines() do
            local name, isHeader, _, rank, _, _, maxRank = GetSkillLineInfo(i)
            if not isHeader and name and wanted[name] and rank then
                metiers[name] = rank .. "/" .. (maxRank or "?")
                source = "GetSkillLineInfo"
            end
        end
    end
    EryAddonDB.niveaux = { date = date("%d/%m/%Y %H:%M"), perso = UnitLevel("player"),
        metiers = metiers, source = source or "aucune" }
end

ns.SaveLevels = SaveLevels -- partagé avec EryAddon_Jobs.lua

local levelPending = false
local function RequestLevels()
    if levelPending then return end
    levelPending = true
    C_Timer.After(2, function()
        levelPending = false
        pcall(SaveLevels)
    end)
end

local levelFrame = CreateFrame("Frame")
for _, ev in ipairs({ "PLAYER_LOGIN", "SKILL_LINES_CHANGED", "CHAT_MSG_SKILL", "PLAYER_LEVEL_UP" }) do
    pcall(levelFrame.RegisterEvent, levelFrame, ev)
end
levelFrame:SetScript("OnEvent", RequestLevels)

---------------------------------------------------------------------------
-- Prix des marchands, notés tout seuls à chaque ouverture d'un marchand (demande de Jérémie :
-- sur Forever, les prix ne suivent pas toujours la règle « 4 x prix de revente »,
-- ex. Fil runique 45 pa, Teinture rose 22 pa 50).
-- EryAddonDB.prixMarchand[objet] = prix d'achat À L'UNITÉ (pc) ; .date = dernier relevé.
---------------------------------------------------------------------------
local function MerchantItem(i)
    local itemID = GetMerchantItemID and GetMerchantItemID(i)
    if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
        local ok, info = pcall(C_MerchantFrame.GetItemInfo, i)
        if ok and type(info) == "table" then
            return itemID, info.price, info.stackCount or info.quantity, info.hasExtendedCost or info.currencyID
        end
    end
    if GetMerchantItemInfo then
        local _, _, price, stack, _, _, _, extendedCost = GetMerchantItemInfo(i)
        return itemID, price, stack, extendedCost and true or nil
    end
end

local function SaveMerchantPrices()
    if not GetMerchantNumItems then return end
    EryAddonDB.prixMarchand = EryAddonDB.prixMarchand or {}
    local db = EryAddonDB.prixMarchand
    for i = 1, GetMerchantNumItems() do
        local itemID, price, stack, otherCurrency = MerchantItem(i)
        -- Seulement les objets payés en or (pas en jetons, insignes, etc.).
        if itemID and price and price > 0 and not otherCurrency and not issecret(price) then
            db[itemID] = math.floor(price / math.max(stack or 1, 1) + 0.5)
        end
    end
    db.date = date("%d/%m/%Y %H:%M")
end

local merchantFrame = CreateFrame("Frame")
for _, ev in ipairs({ "MERCHANT_SHOW", "MERCHANT_UPDATE" }) do
    pcall(merchantFrame.RegisterEvent, merchantFrame, ev)
end
merchantFrame:SetScript("OnEvent", function()
    C_Timer.After(0.3, function() pcall(SaveMerchantPrices) end)
end)
