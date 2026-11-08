"""Icônes de la barre de gauche de la nouvelle fenêtre (même dessin que la maquette « EryAddon HV refonte »).

Dessins au trait, BLANCS sur fond transparent (le jeu les teinte : cyan au repos, blanc pour l'écran choisi).
Dessinés en grand (512 px) puis réduits à 64 x 64 (bords lissés). Format TGA 32 bits non compressé, lu par WoW.
Usage : python outils/make_icones.py   (écrit media/icones/*.tga à côté du dossier outils)
"""
import math
import os
from PIL import Image, ImageDraw

BIG, OUT = 512, 64
K = BIG / 24.0            # le dessin de la maquette est sur une grille de 24 x 24
W = int(2.2 * K)          # épaisseur du trait (2 dans la maquette, un peu plus pour rester lisible en petit)


def P(x, y):
    return (x * K, y * K)


def line(d, pts, closed=False):
    pts = [P(*p) for p in pts]
    if closed:
        pts = pts + [pts[0]]
    d.line(pts, fill=(255, 255, 255, 255), width=W, joint="curve")
    r = W / 2  # bouts arrondis
    for x, y in pts:
        d.ellipse((x - r, y - r, x + r, y + r), fill=(255, 255, 255, 255))


def circle(d, cx, cy, rad, filled=False):
    x, y, r = cx * K, cy * K, rad * K
    if filled:
        d.ellipse((x - r, y - r, x + r, y + r), fill=(255, 255, 255, 255))
    else:
        d.ellipse((x - r, y - r, x + r, y + r), outline=(255, 255, 255, 255), width=W)


def arc_pts(cx, cy, rad, a0, a1, n=8):
    return [(cx + rad * math.cos(math.radians(a0 + (a1 - a0) * i / n)),
             cy + rad * math.sin(math.radians(a0 + (a1 - a0) * i / n))) for i in range(n + 1)]


def acheter(d):        # loupe
    circle(d, 11, 11, 7)
    line(d, [(16, 16), (20, 20)])


def opportunites(d):   # éclair
    line(d, [(13, 2), (4, 14), (11, 14), (10, 22), (19, 10), (12, 10)], closed=True)


def vendre(d):         # étiquette
    line(d, [(3, 12), (3, 4), (11, 4), (21, 14), (13, 22)], closed=True)
    circle(d, 7.5, 7.5, 1.6, filled=True)


def encheres(d):       # liste
    line(d, [(4, 6), (20, 6)])
    line(d, [(4, 12), (20, 12)])
    line(d, [(4, 18), (14, 18)])


def mesventes(d):      # barres
    line(d, [(4, 20), (4, 10)])
    line(d, [(10, 20), (10, 4)])
    line(d, [(16, 20), (16, 13)])
    line(d, [(22, 20), (2, 20)])


def metiers(d):        # fiole
    line(d, [(9, 3), (15, 3)])
    left = [(10, 3), (10, 9), (5, 18)] + arc_pts(7, 19, 2, 180, 90)[1:]
    right = arc_pts(17, 19, 2, 90, 0)[:-1] + [(19, 18), (14, 9), (14, 3)]
    line(d, left + [(7, 21), (17, 21)] + right)


ICONS = {"acheter": acheter, "opportunites": opportunites, "vendre": vendre,
         "encheres": encheres, "mesventes": mesventes, "metiers": metiers}

if __name__ == "__main__":
    out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "media", "icones")
    os.makedirs(out_dir, exist_ok=True)
    for name, draw in ICONS.items():
        img = Image.new("RGBA", (BIG, BIG), (0, 0, 0, 0))
        draw(ImageDraw.Draw(img))
        img = img.resize((OUT, OUT), Image.LANCZOS)
        path = os.path.join(out_dir, name + ".tga")
        img.save(path, format="TGA", compression=None)
        print("écrit", os.path.normpath(path))
