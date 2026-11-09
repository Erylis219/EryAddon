"""Exécute le calcul de route du guide (Lua 5.1, comme WoW) avec les vraies données sauvegardées."""
import sys
from lupa import lua51

addon, saved = sys.argv[1], sys.argv[2]
L = lua51.LuaRuntime(unpack_returned_tuples=True)

STUBS = r'''
ERR_AUCTION_SOLD_S = "Un acheteur a été trouvé pour votre vente aux enchères de %s."
ERR_AUCTION_EXPIRED_S = "Votre vente aux enchères de %s a expiré."
-- Cadres factices : un objet distinct par cadre / texture / texte, avec quelques réponses sensées.
local mt = {}
local function newDummy() return setmetatable({}, mt) end
local ANSWERS = { GetStringWidth = 100, GetWidth = 300, GetHeight = 20, GetText = "", IsShown = true,
                  GetChecked = false, GetEffectiveScale = 1, NumLines = 1, GetFrameLevel = 1 }
mt.__index = function(t, k)
  -- Scripts gardés (pour simuler survol / clic dans l'essai des fenêtres).
  if k == "SetScript" then return function(self, name, fn) rawset(self, "_s_" .. name, fn) end end
  if k == "GetScript" then return function(self, name) return rawget(self, "_s_" .. name) end end
  if type(k) == "string" and k:match("^%l") then return nil end -- champ non rempli (les méthodes ont une majuscule)
  if ANSWERS[k] ~= nil then local v = ANSWERS[k]; return function() return v end end
  return function() return newDummy() end
end
mt.__call = function() return newDummy() end
local dummy = newDummy()
function CreateFrame() return newDummy() end
function FauxScrollFrame_Update() end
function FauxScrollFrame_GetOffset() return 0 end
function FauxScrollFrame_OnVerticalScroll() end
GameTooltip = newDummy()
C_Timer = { After = function() end, NewTicker = function() return dummy end }
function hooksecurefunc() end
DEFAULT_CHAT_FRAME = dummy
UIParent = dummy
UISpecialFrames = {}
SlashCmdList = {}
tinsert = table.insert
date = os.date
time = os.time
GetTime = os.clock
function GetMoney() return 21094 end
function UnitName() return "Ery" end
function InCombatLockdown() return false end
function print(...) end
Enum = { SpellBookSpellBank = { Player = 0 } }
KNOWN = {}
C_SpellBook = { IsSpellKnown = function(spell) return KNOWN[spell] == true end }
C_Item = {
  GetItemCount = function() return 0 end,
  GetItemInfo = function() return nil end,
}
'''
L.execute(STUBS)
L.execute(open(saved, encoding="utf-8").read())

ns = L.table()
for f in ["EryAddon.lua", "EryAddon_Theme.lua", "EryAddon_HV.lua", "EryAddon_Recettes.lua", "EryAddon_Metiers.lua", "EryAddon_Jobs.lua", "EryAddon_Quetes.lua"]:
    chunk = L.eval("function(src, name) return assert(loadstring(src, name)) end")(open(addon + "/" + f, encoding="utf-8").read(), f)
    chunk("EryAddon", ns)

# Recettes connues d'office (source vide) + celles du maître déjà sous le niveau actuel pour l'alchimie.
L.execute('''
for _, r in ipairs(...) do
  if r[5] == "" and (r[7] or 0) == 0 then KNOWN[r[2]] = true end
end''', ns.RECETTES)

def money(c):
    c = int(round(c)); sign = "-" if c < 0 else ""; c = abs(c)
    return f"{sign}{c//10000} po {(c//100)%100} pa {c%100} pc"

for prof, name, skill in [(197, "Couture", 55), (171, "Alchimie", 25)]:
    route = ns._PlanRoute(prof, skill, 75)
    print(f"=== {name} {skill} -> {route.reached:.0f} (passes : {route.passes}) ===")
    print("achats", money(route.buy), "| apprentissages", money(route.learn), "| ventes", money(route.sell), "| bilan", money(route.net))
    segs = route.segments
    for i in range(1, len(segs) + 1):
        sg = segs[i]
        print(f"  {sg['from']:.0f} -> {sg.to:.0f} : {sg.crafts} x {ns._Objet(sg.c.out)}  (connue={sg.c.known})")

# ESSAI FENETRE : ouvre le guide (cadres factices) pour attraper une erreur de logique d'affichage.
L.execute('''
local ns = ...
for _, f in ipairs(ns.features) do if f.key == "jobs" then f.Enable() end end
local ok, err = pcall(function() ns.ToggleGuide(); ns.GuideRefresh() end)
print_ok = ok
GUIDE_ERR = err
''', ns)
print("ouverture du guide :", "OK" if L.globals().print_ok else ("ERREUR " + str(L.globals().GUIDE_ERR)))

# ESSAI PANNEAUX : panneau /eryaddon et fenêtre Jobs à part, avec les cadres factices.
L.execute('''
local ns = ...
local ok1, e1 = pcall(SlashCmdList.ERYADDON)
local ok2, e2 = pcall(function()
  local p = ns.CreateJobsPanel(UIParent); ns.JobsRefresh()
  -- Survol et clic sur chaque ligne, survol des lignes de la fiche, « Tout acheter ».
  local n = 0
  for _, row in ipairs(p.rows) do
    if row.entry then
      n = n + 1
      row:GetScript("OnEnter")(row)
      row:GetScript("OnClick")(row)
      for _, line in ipairs(p.card.lines) do line:GetScript("OnEnter")(line) end
    end
  end
  p.card.buyAll:GetScript("OnClick")(p.card.buyAll)
  JOBS_ROWS = n
  JOBS_CARD = p.card.item and p.card.item.name or "aucune"
end)
PANEL_RES = (ok1 and "panneau OK" or ("panneau ERREUR " .. tostring(e1))) .. " / " ..
            (ok2 and "Jobs OK" or ("Jobs ERREUR " .. tostring(e2)))
''', ns)
print(L.globals().PANEL_RES, "| lignes testées :", L.globals().JOBS_ROWS, "| fiche :", L.globals().JOBS_CARD)

# Recette à objet-recette mais sans source (étude du marché retirée le 09/11 : ses essais aussi).
L.execute('''
local ns = ...
C_AuctionHouse = C_AuctionHouse or {} -- (stub : créé avant par les essais de l'étude du marché)
-- Recette à objet-recette mais sans source (Élixir de robustesse, sort 1250783) : PAS connue d'office.
ROBUST = "absente"
for _, e in ipairs(ns._Compute(171, 150)) do
  if e.spell == 1250783 then ROBUST = string.format("connue=%s, à apprendre : %s", tostring(e.known), tostring(e.learnLabel)) end
end
''', ns)
print("Élixir de robustesse (attendu connue=false) :", L.globals().ROBUST)

# ESSAI TOUS LES MÉTIERS : route du niveau 1 au niveau 75 (métiers pas appris), bilan de chacun.
for prof, name in [(164, "Forge"), (165, "Travail du cuir"), (202, "Ingénierie"), (333, "Enchantement"),
                   (185, "Cuisine"), (129, "Secourisme"), (197, "Couture"), (171, "Alchimie")]:
    route = ns._PlanRoute(prof, 1, 75)
    segs = route.segments
    first = ns._Objet(segs[1].c.out)[0] if len(segs) > 0 else "-"
    print(f"{name:16} 1 -> {route.reached:.0f} : bilan {money(route.net):>16} | achats {money(route.buy):>16} | "
          f"{len(segs)} étapes, 1re : {first}")

# ESSAI LIVRES DE BIBLIOTHÈQUE : carte des Tarides (1413) ouverte → 3 icônes de livres.
L.execute('''
local ns = ...
WorldMapFrame = setmetatable({ GetMapID = function() return 1413 end,
  ScrollContainer = { Child = CreateFrame() } }, getmetatable(UIParent))
for _, f in ipairs(ns.features) do
  if f.key == "livres" then
    local ok, err = pcall(f.Enable)
    LIVRES_RES = ok and "activée sans erreur" or ("ERREUR " .. tostring(err))
  end
end
''', ns)
print("carte des livres :", L.globals().LIVRES_RES)

# ESSAI RÉCOMPENSE DE QUÊTE : 2 choix, le 2e vaut plus → pièce sur le 2e.
L.execute('''
local ns = ...
local b1 = setmetatable({ type = "choice", GetID = function() return 1 end, IsShown = function() return true end }, getmetatable(UIParent))
local b2 = setmetatable({ type = "choice", GetID = function() return 2 end, IsShown = function() return true end }, getmetatable(UIParent))
QuestInfoRewardsFrame = { RewardButtons = { b1, b2 } }
GetNumQuestChoices = function() return 2 end
GetQuestItemLink = function(_, i) return "lien" .. i end
GetQuestItemInfo = function() return "x", 1, 1 end
C_Item.GetItemInfo = function(link)
  if link == "lien1" then return "Bottes", nil, nil, nil, nil, nil, nil, nil, nil, nil, 539, nil, nil, 1 end
  return "Jambières", nil, nil, nil, nil, nil, nil, nil, nil, nil, 600, nil, nil, 1
end
local marked
local realCT = b2.CreateTexture
for _, f in ipairs(ns.features) do
  if f.key == "recompense" then
    f.Enable()
    -- on appelle directement l'événement (C_Timer factice ne lance rien) :
  end
end
local got
b1.CreateTexture = function(...) got = "Bottes (539)"; return CreateFrame() end
b2.CreateTexture = function(...) got = "Jambières (600)"; return CreateFrame() end
local ok, err = pcall(ns._MarkBestReward)
REC_RES = ok and ("pièce sur : " .. tostring(got) .. " (attendu Jambières)") or ("ERREUR " .. tostring(err))
''', ns)
print("récompense de quête :", L.globals().REC_RES)

# ESSAI MAJ+M : bascule de la grande mini-carte (cadres factices).
L.execute('''
local ns = ...
for _, f in ipairs(ns.features) do
  if f.key == "miniCarte" then
    SetOverrideBindingClick = function(_, _, key, button) BOUND = key .. " -> " .. button end
    ClearOverrideBindings = function() BOUND = "aucune" end
    local ok, err = pcall(function() f.Enable(); f.Disable(); f.Enable() end)
    MINI_RES = ok and ("touche posée : " .. tostring(BOUND)) or ("ERREUR " .. tostring(err))
  end
end
''', ns)
print("Maj+M :", L.globals().MINI_RES)

# ESSAI CARTE DES QUÊTES : fausse base QuestieDB (3 quêtes), index par carte, filtre « à prendre ».
L.execute('''
local ns = ...
bit = bit or { band = function(a, b) local r, p = 0, 1; while a > 0 and b > 0 do
  if a % 2 == 1 and b % 2 == 1 then r = r + p end; a, b, p = math.floor(a / 2), math.floor(b / 2), p * 2 end; return r end }
UnitRace = function() return "Orc", "Orc", 2 end
UnitClass = function() return "Mage", "MAGE", 8 end
UnitFactionGroup = function() return "Horde" end
UnitLevel = function() return 17 end
local quests = {
  [100] = { name = "Argent volé", startedBy = { { 50 } }, requiredLevel = 14, questLevel = 18, requiredRaces = 0 },
  [101] = { name = "Quête d'Alliance", startedBy = { { 50 } }, requiredLevel = 10, questLevel = 15, requiredRaces = 1 },
  [102] = { name = "Suite", startedBy = { { 50 } }, requiredLevel = 10, questLevel = 16, preQuestSingle = { 100 } },
  [103] = { name = "Trop vieille", startedBy = { { 50 } }, requiredLevel = 1, questLevel = 5 },
}
local npcs = { [50] = { name = "Gazrog", friendlyToFaction = "AH", spawns = { [17] = { { 51.9, 30.3 } } } } }
local function E(t) return { Get = function(id, key) return t[id] and t[id][key] end,
  GetAllIds = function() local l = {}; for id in pairs(t) do l[#l + 1] = id end; table.sort(l); return l end } end
LibQuestieDB = { Quest = E(quests), Npc = E(npcs), Object = E({}) }
C_QuestLog = { IsQuestFlaggedCompleted = function() return false end, GetLogIndexForQuestID = function() return nil end }
GetQuestGreenRange = function() return 8 end
local ticks = {}
C_Timer.NewTicker = function(_, fn) local t = { Cancel = function(self) self.dead = true end }; ticks[#ticks + 1] = { t, fn }; return t end
ns._QuetesBuild()
for _ = 1, 10 do for _, tk in ipairs(ticks) do if not tk[1].dead then tk[2]() end end end
local st = ns._QuetesStarters()
local s = st and st[1413] and st[1413][1]
local out = { "Tarides (1413) : " .. (s and (#s.quests .. " quêtes chez le PNJ 50 (attendu 3 : Alliance exclue)") or "RIEN") }
for _, q in ipairs({ 100, 101, 102, 103 }) do
  out[#out + 1] = q .. "=" .. tostring(ns._QuetesAvailable(q, 17))
end
strsplit = function(sep, str) local t = {}; for w in (str .. sep):gmatch("(.-)" .. sep:gsub("%-", "%%-")) do t[#t + 1] = w end; return unpack(t) end
GetTime = function() return 100 end
-- Gazrog ne propose RIEN (comme Mankrik et « Son nom est Olgra ») : la 100, « disponible » d'après la
-- base, est cachée ; elle revient au niveau suivant (nouvelle chance de l'avoir).
ns._QuetesOffer(50, {})
out[#out + 1] = "après dialogue sans quête : 100=" .. tostring(ns._QuetesAvailable(100, 17))
  .. " (attendu false) ; au niveau 18 : 100=" .. tostring(ns._QuetesAvailable(100, 18)) .. " (attendu true)"
ns._QuetesOffer(50, { [("Argent volé"):lower()] = true }) -- (comme le jeu : titre passé en minuscules)
out[#out + 1] = "proposée (par son nom) : 100=" .. tostring(ns._QuetesAvailable(100, 17)) .. " (attendu true)"
QUETES_RES = table.concat(out, " | ") .. "  (attendu 100=true, 101=true* (filtrée à l'index), 102=false, 103=false)"
''', ns)
print("carte des quêtes :", L.globals().QUETES_RES)

# ESSAI LIVRES SUR LA MINI-CARTE : joueur aux Tarides près de la plate-forme pétrolière (56.3, 8.8).
L.execute('''
local ns = ...
ForeverSecretsDB = nil
C_AddOns = { IsAddOnLoaded = function() return false end }
C_Map = C_Map or {}
C_Map.GetBestMapForUnit = function() return 1413 end
C_Map.GetPlayerMapPosition = function() return { GetXY = function() return 0.55, 0.10 end } end
C_Map.GetMapWorldSize = function() return 4000, 6000 end
Minimap = setmetatable({ GetZoom = function() return 0 end, GetWidth = function() return 140 end },
  getmetatable(UIParent))
IsIndoors = function() return false end
GetCVar = function() return "0" end
EryAddonDB.livresVus = {}
local ok, err = pcall(ns._RefreshMini)
MINI_LIVRES = ok and "calcul sans erreur" or ("ERREUR " .. tostring(err))
''', ns)
print("livres mini-carte :", L.globals().MINI_LIVRES)

# ESSAI MES VENTES : mise en vente de 5, « acheteur trouvé », courrier de vente, puis une expiration.
L.execute('''
local ns = ...
local T = ns._MySalesTest
local NOW = 2000000
time = function() return NOW end
GetTime = function() return NOW end
C_Item.GetItemID = function() return 5762 end
C_Item.GetItemName = function() return "Sac rouge en lin" end
EryAddonDB.mesVentes = nil
T.RecordPost({}, 5, 500)
NOW = NOW + 3 * 3600
ERR_AUCTION_SOLD_S = ERR_AUCTION_SOLD_S or "Un acheteur a été trouvé pour votre vente aux enchères de %s."
T.OnSystemText("Un acheteur a été trouvé pour votre vente aux enchères de Sac rouge en lin.")
local inbox = { { "seller", "Sac rouge en lin", "Bob", 0, 1000, 100, 50, 0, 0, 0, 2 } }
GetInboxNumItems = function() return #inbox end
GetInboxInvoiceInfo = function(i) return unpack(inbox[i]) end
T.ReadInvoices()
T.ReadInvoices() -- même courrier relu : pas compté deux fois
local s = ns.MySales(5762)
MV_RES = string.format("vendus %d (2), net %d (950), délai %.0f h (3 en jeu ; -1 ici : texte du jeu absent hors jeu), en cours %d (3), bénéfice coût connu=%s",
  s.vendus, s.net, s.delaiMoyen or -1, s.enCours, tostring(s.coutConnu))
''', ns)
print("mes ventes :", L.globals().MV_RES)

# ESSAI BESOIN GLOBAL (fiche Métiers, bug des Boulons, 08/11) : un objet demandé directement ET pour fabriquer
# un autre composant n'est compté qu'une fois dans le stock. Vraies recettes : Boulons de cuivre (3922) =
# 1 Barre de cuivre (2840) ; Barre (fonte 2657) = 1 Minerai de cuivre (2770) ; Modulateur en cuivre (3926) =
# 2 Boulons + 1 Barre + 2 Étoffe de lin (2589) ; Dragon mécanique en cuivre (3928) = Modulateur + Boulon +
# Barre + 2 Malachite (774).
L.execute('''
local ns = ...
local STOCK = {}
ns.Owned = function(id) return STOCK[id] or 0, 0 end
EryAddonDB.hvPrix = { t = time(), prix = { [2840] = 10, [4359] = 100, [2770] = 1000, [2589] = 5, [774] = 50, [4363] = 100000 } }
EryAddonDB.prixMarchand = {}
KNOWN[3922], KNOWN[3926] = true, true
local function Fiche(reag)
  local list, n, why, info = ns._Needs({ color = "easy", known = true, reag = reag, name = "Objet X", prof = 202 })
  local rows, buys = {}, {}
  for _, l in ipairs(list) do
    rows[#rows + 1] = string.format("%s%s %d/%d manque %d%s", l.indent and string.rep("  ", l.indent) or "",
      tostring(l.name), l.have, l.need, l.missing, l.buy and (" -> acheter " .. l.buy.need) or "")
    if l.buy then buys[l.id] = l.buy.need end
  end
  return list, buys, table.concat(rows, " | "), info.etapes
end
local out = {}
-- 1) Cas du bug : X = 2 Boulons + 3 Barres, stock 3 Barres → 5 Barres au total, il en manque 2.
STOCK = { [2840] = 3 }
local list, buys, rows, steps = Fiche("4359:2,2840:3")
local bar
for _, l in ipairs(list) do if l.id == 2840 then bar = l end end
out[#out + 1] = string.format("cas 1 : Barres il faut %d (5), manque %d (2), à acheter %s (2) => %s",
  bar.need, bar.missing, tostring(buys[2840]), (bar.need == 5 and bar.missing == 2 and buys[2840] == 2) and "OK" or "FAUX")
out[#out + 1] = "    " .. rows
out[#out + 1] = "    " .. steps
-- 2) Même cas avec 1 Boulon déjà dans les sacs : 1 Boulon à fabriquer → 4 Barres, il en manque 1.
STOCK = { [2840] = 3, [4359] = 1 }
list, buys = Fiche("4359:2,2840:3")
for _, l in ipairs(list) do if l.id == 2840 then bar = l end end
out[#out + 1] = string.format("cas 2 : Barres il faut %d (4), manque %d (1) => %s", bar.need, bar.missing,
  (bar.need == 4 and bar.missing == 1) and "OK" or "FAUX")
-- 3) Trois étages : Dragon mécanique ; Barres fondues (minerai pas cher) ; stock 3 Barres.
--    Modulateur 1 → 2 Boulons ; Boulons 1 + 2 = 3 → 3 Barres ; Barres 1 + 1 + 3 = 5, il en manque 2 → 2 Minerais.
EryAddonDB.hvPrix.prix[2770] = 2
STOCK = { [2840] = 3 }
list, buys, rows, steps = Fiche("4363:1,4359:1,2840:1,774:2")
local need = {}
for _, l in ipairs(list) do need[l.id] = l.need end
out[#out + 1] = string.format("cas 3 : Boulons %s (3), Barres %s (5), Minerai %s (2), Lin %s (2) => %s",
  tostring(need[4359]), tostring(need[2840]), tostring(need[2770]), tostring(need[2589]),
  (need[4359] == 3 and need[2840] == 5 and need[2770] == 2 and need[2589] == 2 and buys[2770] == 2) and "OK" or "FAUX")
out[#out + 1] = "    " .. rows
out[#out + 1] = "    " .. steps
BESOINS = table.concat(out, "\\n")
''', ns)
print("besoin global :\n" + L.globals().BESOINS)
