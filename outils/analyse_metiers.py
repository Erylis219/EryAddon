"""Analyse des crafts rentables à partir de la sauvegarde EryAddon (SavedVariables).
Usage : python analyse_metiers.py <EryAddon.lua des SavedVariables> <rapport.md>"""
import re
import sys
from collections import defaultdict

src, out = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8", errors="replace").read()

# --- mini-lecteur de tables Lua (format SavedVariables) ---------------------
TOKEN = re.compile(r'\s*(?:(\{)|(\})|(\[)|(\])|(=)|(,)|("(?:\\.|[^"\\])*")|(-?\d+(?:\.\d+)?(?:e-?\d+)?)|(true|false|nil)|([A-Za-z_][A-Za-z0-9_]*))', re.S)

def tokens(s):
    pos = 0
    while pos < len(s):
        m = TOKEN.match(s, pos)
        if not m or m.end() == pos:
            if s[pos:].strip() == "":
                return
            raise ValueError("lecture impossible à " + str(pos) + " : " + s[pos:pos + 40])
        pos = m.end()
        yield m

def unescape(raw):
    body = raw[1:-1]
    body = body.replace('\\"', '"').replace("\\n", "\n").replace("\\\\", "\\")
    return body

def parse(s):
    it = tokens(s)
    toks = list(it)
    i = 0

    def value():
        nonlocal i
        t = toks[i]
        if t.group(1):
            i += 1
            return table()
        if t.group(7):
            i += 1
            return unescape(t.group(7))
        if t.group(8):
            i += 1
            v = t.group(8)
            return float(v) if ("." in v or "e" in v) else int(v)
        if t.group(9):
            i += 1
            return {"true": True, "false": False, "nil": None}[t.group(9)]
        raise ValueError("valeur inattendue " + t.group(0))

    def table():
        nonlocal i
        result, n = {}, 1
        while True:
            t = toks[i]
            if t.group(2):
                i += 1
                return result
            if t.group(6):
                i += 1
                continue
            if t.group(3):  # [clé] = valeur
                i += 1
                key = value()
                i += 1  # ]
                i += 1  # =
                result[key] = value()
            elif t.group(10) and toks[i + 1].group(5):
                key = t.group(10)
                i += 2
                result[key] = value()
            else:
                result[n] = value()
                n += 1

    out = {}
    while i < len(toks):
        name = toks[i].group(10)
        i += 2  # nom =
        out[name] = value()
    return out

db = parse(text)["EryAddonDB"]
met = db.get("metiers") or {}
prix = (db.get("hvPrix") or {}).get("prix") or {}
quant = (db.get("hvPrix") or {}).get("quantites") or {}
date_prix = (db.get("hvPrix") or {}).get("date", "?")
# Prix réels relevés chez les marchands (clés numériques seulement ; « date » à part).
prix_marchand = {k: v for k, v in (db.get("prixMarchand") or {}).items() if isinstance(k, int)}

objets = {}
for k, v in (met.get("objets") or {}).items():
    name, sell, stack = v.rsplit("|", 2)
    objets[int(k)] = (name, int(sell), int(stack))

METIERS = {171: "Alchimie", 164: "Forge", 185: "Cuisine", 333: "Enchantement", 202: "Ingénierie",
           129: "Secourisme", 356: "Pêche", 182: "Herboristerie", 165: "Travail du cuir",
           186: "Minage", 393: "Dépeçage", 197: "Couture"}

# Composants vendus par les marchands (prix d'achat estimé = 4 x prix de revente).
VENDOR = {3371, 3372, 8925, 18256, 2320, 2321, 4291, 8343, 14341, 2880, 3466, 2678, 2692, 3713,
          159, 1179, 30817, 2596, 4289, 2324, 2604, 6260, 2605, 4340, 4341, 4342, 10290, 2325,
          6217, 4399, 4400, 3857, 17020, 4470, 3371}
COMMISSION = 0.05

def name(i):
    return objets.get(i, ("objet " + str(i), 0, 1))[0]

def money(c):
    c = int(round(c))
    sign = "-" if c < 0 else ""
    c = abs(c)
    g, s, cu = c // 10000, (c // 100) % 100, c % 100
    parts = []
    if g: parts.append(f"{g} po")
    if s: parts.append(f"{s} pa")
    if cu or not parts: parts.append(f"{cu} pc")
    return sign + " ".join(parts)

def unit_cost(i):
    """(coût, source) d'un composant : le moins cher entre HV et marchand."""
    options = []
    if i in prix:
        options.append((prix[i], "HV"))
    if i in prix_marchand:
        options.append((prix_marchand[i], "marchand"))
    elif i in VENDOR and i in objets and objets[i][1] > 0:
        options.append((objets[i][1] * 4, "marchand ~"))
    return min(options) if options else (None, None)

rows, sans_composants, sans_prix = [], 0, 0
for spell, v in (met.get("recettes") or {}).items():
    prof, outp, qmin, qmax, reag = v.split("|", 4)
    prof, outp, qmin, qmax = int(prof), int(outp), int(qmin), int(qmax)
    if reag == "?" or reag == "":
        sans_composants += 1
        continue
    qty = (qmin + qmax) / 2
    cost, missing, detail = 0, [], []
    for part in reag.split(","):
        rid, rq = part.split(":")
        rid, rq = int(rid), int(rq)
        c, srcp = unit_cost(rid)
        if c is None:
            missing.append(name(rid))
        else:
            cost += c * rq
            detail.append(f"{rq} x {name(rid)} ({money(c)} {srcp})")
    if outp not in prix or missing:
        sans_prix += 1
        continue
    vente = prix[outp] * qty * (1 - COMMISSION)
    marchand = objets.get(outp, ("", 0, 1))[1] * qty
    rows.append({
        "metier": METIERS.get(prof, str(prof)), "objet": name(outp), "qte": qty,
        "cout": cost, "vente": vente, "marge": vente - cost,
        "ratio": (vente / cost) if cost else 0, "marchand": marchand,
        "dispo": quant.get(outp, 0), "detail": "; ".join(detail),
    })

rows.sort(key=lambda r: r["marge"], reverse=True)
with open(out, "w", encoding="utf-8") as f:
    f.write(f"# Crafts rentables d'après le scan du {date_prix}\n\n")
    f.write(f"- Recettes analysées avec prix complets : {len(rows)}\n")
    f.write(f"- Sans composants connus : {sans_composants} ; sans prix HV pour le produit ou un composant : {sans_prix}\n")
    f.write("- Vente = prix HV le plus bas x quantité produite, moins 5 % de commission.\n\n")
    par_metier = defaultdict(list)
    for r in rows:
        par_metier[r["metier"]].append(r)
    f.write("## Les plus rentables, tous métiers\n\n| Métier | Objet | Coût | Vente HV nette | Marge | x | En vente |\n|---|---|---|---|---|---|---|\n")
    for r in [r for r in rows if r["marge"] > 0][:40]:
        f.write(f"| {r['metier']} | {r['objet']} | {money(r['cout'])} | {money(r['vente'])} | {money(r['marge'])} | {r['ratio']:.1f} | {r['dispo']} |\n")
    f.write("\n## Par métier : nombre de crafts rentables et marge totale (1 craft de chaque)\n\n| Métier | Rentables | Somme des marges | Meilleur |\n|---|---|---|---|\n")
    for m, lst in sorted(par_metier.items(), key=lambda kv: -sum(max(0, r["marge"]) for r in kv[1])):
        pos = [r for r in lst if r["marge"] > 0]
        best = pos[0]["objet"] + " (" + money(pos[0]["marge"]) + ")" if pos else "-"
        f.write(f"| {m} | {len(pos)} / {len(lst)} | {money(sum(r['marge'] for r in pos))} | {best} |\n")
    for m, lst in sorted(par_metier.items()):
        pos = [r for r in lst if r["marge"] > 0][:15]
        if not pos:
            continue
        f.write(f"\n## {m} : 15 meilleurs\n\n| Objet | Coût | Vente HV nette | Marge | x | En vente |\n|---|---|---|---|---|---|\n")
        for r in pos:
            f.write(f"| {r['objet']} | {money(r['cout'])} | {money(r['vente'])} | {money(r['marge'])} | {r['ratio']:.1f} | {r['dispo']} |\n")
    f.write("\n## Détail des composants (40 premiers)\n\n")
    for r in [r for r in rows if r["marge"] > 0][:40]:
        f.write(f"- **{r['objet']}** ({r['metier']}) : {r['detail']}\n")
print(len(rows), "recettes chiffrées ;", sum(1 for r in rows if r["marge"] > 0), "rentables")
