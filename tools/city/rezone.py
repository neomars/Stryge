"""Zone de jeu d'un secteur : points d'évacuation et bouches de métro placés DANS la zone.

Le jeu ne se joue plus que sur un disque de 600 m de rayon (clé « zone » des missions : data/mission_0X.json) au lieu des 2 400 m de la carte.
Les cartes converties gardent leurs 2 400 m de décor autour, mais :
  * les 9 points d'évacuation (grille 3 × 3) sont resserrés autour du centre de la zone ;
  * les bouches de métro sont les vraies stations des lignes 1 à 6 et 14 qui tombent dans la zone (une ou deux bouches par station),
    complétées par des carrefours (« accès » sans nom) pour atteindre ZONE_METRO bouches, car certains secteurs n'ont presque aucune
    station dans ces lignes (La Défense : une seule ; Stade de France : aucune, la station La Plaine – Stade de France est sur le RER B).

Usage autonome (corrige les cartes déjà converties, sans refaire la conversion) :
    python3 rezone.py [secteur ...] [--dir ../../data/cities] [--metro DIR]
Le script est déterministe (aucun tirage) et idempotent : le relancer ne change plus rien.
"""
import argparse
import glob
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from geo import SECTORS, Frame      # noqa: E402

ZONE_R = 600.0                      # rayon de la zone de jeu (m) : doit rester celui de la clé « zone » des missions
ZONE_METRO = 8                      # nombre de bouches de métro par secteur
# centre de la zone de chaque secteur, repère local (m) : le Stade de France est entouré d'un grand vide, la zone est décalée vers le nord
ZONE_CENTER = {"stade": (0.0, 300.0)}
DEFAULT_METRO = "/home/claude/atom-84/fluctuat-nec-mergitur-d3/metro"


def load_stations(metro_dir):
    st = {}
    for f in sorted(glob.glob(os.path.join(metro_dir, "line_*.json"))):
        d = json.load(open(f, encoding="utf-8"))
        line = os.path.basename(f).split("line_")[1].split(".")[0]
        for ft in d["features"]:
            if ft["geometry"]["type"] != "Point":
                continue
            lon, lat = ft["geometry"]["coordinates"]
            st.setdefault(ft["properties"]["station"], {"lon": lon, "lat": lat, "lines": []})["lines"].append(line)
    return st


def _graph(doc):
    nodes = doc["nodes"]
    deg = [0] * len(nodes)
    wid = [0.0] * len(nodes)
    for e in doc["edges"]:
        for k in (e[0], e[1]):
            deg[k] += 1
            wid[k] = max(wid[k], float(e[2]))
    return deg, wid


def _d(a, b):
    return math.hypot(a[0] - b[0], a[1] - b[1])


def pick_evac(doc, zc):
    """9 points en grille 3 × 3 autour du centre de la zone (±0,33 de son diamètre), sur les nœuds les plus larges."""
    nodes = doc["nodes"]
    deg, wid = _graph(doc)
    chosen = []
    side = 2.0 * ZONE_R
    for gx in (-0.33, 0.0, 0.33):
        for gz in (-0.33, 0.0, 0.33):
            want = (zc[0] + gx * side, zc[1] + gz * side)
            cand = [k for k in range(len(nodes)) if _d(nodes[k], want) <= 130.0 and _d(nodes[k], zc) <= ZONE_R - 30.0 and deg[k] >= 2]
            if not cand:
                cand = [min(range(len(nodes)), key=lambda k: _d(nodes[k], want))]
            cand.sort(key=lambda k: (-(min(wid[k], 16.0) * 10.0 - _d(nodes[k], want) * 0.05), k))
            for k in cand:
                if k not in chosen and all(_d(nodes[k], nodes[c]) > 90.0 for c in chosen):
                    chosen.append(k)
                    break
    return chosen


def pick_metro(doc, frame, stations, zc):
    """Bouches de métro de la zone : [(nœud, nom de station ou "")]."""
    nodes = doc["nodes"]
    deg, wid = _graph(doc)
    real = []
    for name, v in stations.items():
        x, z = frame.local_lonlat(v["lon"], v["lat"])
        if _d((x, z), zc) <= ZONE_R - 40.0:
            real.append((_d((x, z), zc), name, x, z, len(v["lines"])))
    real.sort()
    chosen = []                       # [(nœud, nom)]

    def free(k, gap):
        return all(_d(nodes[k], nodes[c[0]]) >= gap for c in chosen)

    # 1. l'accès principal de chaque vraie station : le nœud le plus proche (à 90 m au plus)
    for _, name, x, z, nl in real:
        order = sorted(range(len(nodes)), key=lambda k: (_d(nodes[k], (x, z)), k))
        k = order[0]
        if _d(nodes[k], (x, z)) <= 90.0 and free(k, 120.0) and _d(nodes[k], zc) <= ZONE_R - 20.0:
            chosen.append((k, name))
    # 2. un second accès par station (deux pour une correspondance), à 40-130 m du premier, tant que la zone n'est pas pleine
    for rank in (0, 1):
        for _, name, x, z, nl in real:
            if len(chosen) >= ZONE_METRO:
                break
            if rank == 1 and nl < 2:
                continue
            mine = [c for c in chosen if c[1] == name]
            if not mine:
                continue
            ring = [k for k in range(len(nodes)) if 40.0 <= _d(nodes[k], (x, z)) <= 130.0 and deg[k] >= 2 and _d(nodes[k], zc) <= ZONE_R - 20.0 and free(k, 70.0)]
            if ring:
                ring.sort(key=lambda k: (-(wid[k]), _d(nodes[k], (x, z)), k))
                chosen.append((ring[0], name))
    # 3. complément : carrefours répartis au mieux (le plus loin possible des bouches déjà choisies)
    pool = [k for k in range(len(nodes)) if deg[k] >= 3 and wid[k] >= 6.0 and 90.0 <= _d(nodes[k], zc) <= ZONE_R - 130.0]
    while len(chosen) < ZONE_METRO and pool:
        best = max(pool, key=lambda k: (min([_d(nodes[k], nodes[c[0]]) for c in chosen] or [999.0]), -k))
        if min([_d(nodes[best], nodes[c[0]]) for c in chosen] or [999.0]) < 120.0:
            break
        chosen.append((best, ""))
        pool.remove(best)
    return chosen[:ZONE_METRO]


def apply(doc, sid, stations):
    """Remplace points d'évacuation, bouches de métro et rectangles correspondants de `doc` (carte convertie, repère local)."""
    zc = ZONE_CENTER.get(sid, (0.0, 0.0))
    frame = Frame(SECTORS[sid]["lonlat"])
    nodes = doc["nodes"]
    _, wid = _graph(doc)
    evac = pick_evac(doc, zc)
    metro = pick_metro(doc, frame, stations, zc)
    areas = [a for a in doc["areas"] if a[0] not in ("evac", "metro")]
    for k in evac:
        p = nodes[k]
        half = min(max(wid[k] * 0.5, 6.0), 16.0)
        areas.append(["evac", round(p[0] - half, 1), round(p[1] - half, 1), round(p[0] + half, 1), round(p[1] + half, 1)])
    for k, _ in metro:
        p = nodes[k]
        areas.append(["metro", round(p[0] - 3, 1), round(p[1] - 3, 1), round(p[0] + 3, 1), round(p[1] + 3, 1)])
    doc["areas"] = areas
    doc["evac_nodes"] = evac
    doc["metro_nodes"] = [k for k, _ in metro]
    doc["meta"]["metro_names"] = [n for _, n in metro]
    doc["meta"]["zone"] = {"cx": zc[0], "cz": zc[1], "radius_m": ZONE_R}
    return doc


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("secteurs", nargs="*", default=list(SECTORS))
    ap.add_argument("--dir", default=os.path.join(HERE, "..", "..", "data", "cities"))
    ap.add_argument("--metro", default=os.environ.get("PNC_METRO", DEFAULT_METRO))
    a = ap.parse_args()
    stations = load_stations(a.metro)
    for sid in a.secteurs:
        path = os.path.join(a.dir, sid + ".json")
        doc = json.load(open(path, encoding="utf-8"))
        apply(doc, sid, stations)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(doc, f, ensure_ascii=False, separators=(",", ":"))
        real = sum(1 for n in doc["meta"]["metro_names"] if n)
        print("%s : %d points d'évacuation, %d bouches de métro (%d de vraies stations)" % (sid, len(doc["evac_nodes"]), len(doc["metro_nodes"]), real))


if __name__ == "__main__":
    main()
