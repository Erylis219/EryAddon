"""Génère EryAddon_Recettes.lua à partir des données Forever (Camelot) de WhatsTraining,
complétées par les seuils de couleur officiels (table SkillLineAbility du jeu, wago.tools).
Usage : python gen_recettes.py <dossier Camelot> <fichier de sortie> [SkillLineAbility.csv] [ItemSparse.csv]"""
import csv
import os
import re
import sys

src_dir, out = sys.argv[1], sys.argv[2]
# Seuils officiels : [sort] = (jaune, gris, points par fabrication)
seuils = {}
if len(sys.argv) > 3:
    for r in csv.DictReader(open(sys.argv[3], encoding="utf-8")):
        seuils[int(r["Spell"])] = (int(r["TrivialSkillLineRankLow"]), int(r["TrivialSkillLineRankHigh"]),
                                   int(r["NumSkillUps"] or 1))
# Prix d'achat chez un marchand (table ItemSparse de Forever, wago.tools) : [objet] = prix en pc.
achat = {}
if len(sys.argv) > 4:
    for r in csv.DictReader(open(sys.argv[4], encoding="utf-8")):
        if r["BuyPrice"] and int(r["BuyPrice"]) > 0:
            achat[int(r["ID"])] = int(r["BuyPrice"])
NAMES = {171: "Alchimie", 164: "Forge", 185: "Cuisine", 333: "Enchantement", 202: "Ingénierie",
         129: "Secourisme", 356: "Pêche", 182: "Herboristerie", 165: "Travail du cuir",
         186: "Minage", 393: "Dépeçage", 197: "Couture"}
SOURCES = (("trainer", "T"), ("vendor", "V"), ("drop", "D"), ("quest", "Q"), ("world_object", "W"))

rows = []
for fname in sorted(os.listdir(src_dir)):
    if not fname.endswith(".lua"):
        continue
    text = open(os.path.join(src_dir, fname), encoding="utf-8").read()
    m = re.search(r"ns\.Recipes\[(\d+)\]", text)
    if not m:
        continue
    prof = int(m.group(1))
    for line in text.splitlines():
        sp = re.search(r"\bspell = (\d+)", line)
        cr = re.search(r"\bcreates = (\d+)", line)
        sk = re.search(r"\bskill = (\d+)", line)
        src = re.search(r"\bsource = \{([^}]*)\}", line)
        cost = re.search(r"\bcost = (\d+)", line)
        teach = re.search(r"\bteach = (\d+)", line)
        if not (sp and cr):
            continue
        letters = ""
        if src:
            for word, letter in SOURCES:
                if '"' + word + '"' in src.group(1):
                    letters += letter
        spell = int(sp.group(1))
        y, g, n = seuils.get(spell, (0, 0, 1))
        # Marchands qui vendent le patron (« PNJ:zone,… ») et réputation exigée (faction, rang).
        # Faction du marchand : A (Alliance), H (Horde), N (neutre / les deux).
        vend = ",".join("%s:%s:%s" % (a, b, (f[:1] if f else "N")) for a, b, f in
                        re.findall(r'npc = (\d+), area = (\d+)(?:, faction = "(\w+)")?', line))
        repm = re.search(r"reputation = \{ (\d+), (\d+)", line)
        # Toutes les réputations possibles (« faction:rang,… ») : une seule suffit (ex. centaures Gelkis OU Magram ;
        # Administration commerciale d'Azeroth OU Transports logistiques Durotar).
        repall = ""
        rb = re.search(r"reputation = \{([^}]*)\}", line)
        if rb:
            nums = re.findall(r"\d+", re.sub(r"ns\.L\.\w+", "", rb.group(1)))
            repall = ",".join("%s:%s" % (nums[i], nums[i + 1]) for i in range(0, len(nums) - 1, 2))
        mf = re.search(r"\bmerchantFavor = (\d+)", line)
        teach_id = int(teach.group(1)) if teach else 0
        rows.append((prof, spell, int(cr.group(1)), int(sk.group(1)) if sk else 0,
                     letters, int(cost.group(1)) if cost else 0, teach_id, y, g, n,
                     vend, int(repm.group(1)) if repm else 0, int(repm.group(2)) if repm else 0,
                     achat.get(teach_id, 0) if "V" in letters else 0,
                     repall, int(mf.group(1)) if mf else 0))

with open(out, "w", encoding="utf-8", newline="\n") as f:
    f.write("-- EryAddon : liste des recettes de Forever (tous métiers), FICHIER GÉNÉRÉ par outils/gen_recettes.py.\n")
    f.write("-- Source : add-on WhatsTraining, données « Camelot » (Forever).\n")
    f.write("-- Format : { métier, sort, objet créé, compétence requise, source, prix du maître (pc), objet-recette,\n")
    f.write("--            seuil jaune, seuil gris, points par fabrication,  (seuils officiels : table SkillLineAbility\n")
    f.write("--            de Forever 1.60.1, wago.tools ; vert = milieu entre jaune et gris ; 0 = inconnu)\n")
    f.write("--            marchands du patron \"PNJ:zone:faction(A/H/N),...\", réputation exigée : faction, rang (5 = Amical…),\n")
    f.write("--            prix du patron chez le marchand (pc, table ItemSparse ; 0 = inconnu),\n")
    f.write("--            toutes les réputations possibles \"faction:rang,...\" (une seule suffit),\n")
    f.write("--            prix en Faveur du marchand (0 = pas en Faveur) }\n")
    f.write("-- source : T maître, V marchand, D butin, Q quête, W objet du monde ; vide = connue d'office\n")
    f.write("local _, ns = ...\n")
    f.write("ns.METIERS = {\n")
    for k, v in NAMES.items():
        f.write(f'    [{k}] = "{v}",\n')
    f.write("}\n")
    f.write("ns.RECETTES = {\n")
    for r in rows:
        f.write('    {%d, %d, %d, %d, "%s", %d, %d, %d, %d, %d, "%s", %d, %d, %d, "%s", %d},\n' % r)
    f.write("}\n")
print(len(rows), "recettes")
