"""Lecteur du fichier « PAO3 » (extrait OpenStreetMap de Paris + cœur de La Défense).

Le fichier est produit par le dépôt KiK0S/paris-map-template (script generate-osm-city.mjs) à partir de
l'extrait Geofabrik Île-de-France.  Les rues, parcs et plans d'eau sont stockés en coordonnées
« monde » entières (x = (lon - 2,352) * LNG_SCALE, z = -(lat - 48,857) * 420, quantifiées à 1/800) ;
on les ramène ici en mètres Lambert-93 relatifs au centre des fichiers IGN (voir l93.py), donc
directement superposables aux bâtiments BD TOPO.

© contributeurs OpenStreetMap (ODbL).
"""
import math
import struct
import sys

import numpy as np
from pyproj import Transformer

from l93 import CENTRE

ORIGIN_LAT, ORIGIN_LON = 48.857, 2.352
LAT_SCALE = 420.0
LNG_SCALE = LAT_SCALE * math.cos(math.radians(ORIGIN_LAT))
METERS_PER_WORLD_UNIT = 110540.0 / LAT_SCALE
QUANT = 800.0

_TR = Transformer.from_crs("EPSG:4326", "EPSG:2154", always_xy=True)

# classes de voie (poids faible de « style »), voir ROAD_STYLES du script source
CLASS_NAMES = {0: "autoroute", 1: "primaire", 2: "secondaire", 3: "résidentielle", 4: "service/piéton", 5: "chemin"}
GREEN_NAMES = {0: "parc", 1: "bois", 2: "cimetière", 3: "terrain de sport", 4: "friche", 5: "verger"}


def world_to_map(pts_int: np.ndarray) -> np.ndarray:
    """int16 (N,2) [x, z] -> float64 (N,2) [est, nord] en mètres relatifs à CENTRE (Lambert-93)."""
    x = pts_int[:, 0].astype(np.float64) / QUANT
    z = pts_int[:, 1].astype(np.float64) / QUANT
    lon = ORIGIN_LON + x / LNG_SCALE
    lat = ORIGIN_LAT - z / LAT_SCALE
    ex, ny = _TR.transform(lon, lat)
    return np.column_stack([ex - CENTRE[0], ny - CENTRE[1]])


def _rings(rec_start, rec_count, ring_tbl, pts):
    out = []
    for r in range(rec_start, rec_start + rec_count):
        ps, pc, hole = int(ring_tbl["ps"][r]), int(ring_tbl["pc"][r]), int(ring_tbl["hole"][r])
        out.append((pts[ps:ps + pc], bool(hole)))
    return out


def read_osm(path):
    """Retourne un dict : streets, greens, waters, buildings (listes d'objets avec géométrie en mètres)."""
    b = open(path, "rb").read()
    assert b[:4] == b"PAO1", b[:4]
    version, quant = struct.unpack_from("<HH", b, 4)
    assert version == 3 and quant == 800, (version, quant)
    nb, nbr, nbp, ns, nsp, ng, ngr, ngp, nw, nwr, nwp = struct.unpack_from("<11I", b, 8)
    off = 52

    def take(dtype, n):
        nonlocal off
        a = np.frombuffer(b, dtype=dtype, count=n, offset=off)
        off += a.nbytes
        return a

    d_build = np.dtype([("rs", "<u4"), ("rc", "<u2"), ("h", "<u2"), ("minh", "<u2"), ("roof", "<u2"),
                        ("style", "u1"), ("rtype", "u1"), ("tile", "<u2")])
    d_ring = np.dtype([("ps", "<u4"), ("pc", "<u2"), ("hole", "u1"), ("pad", "u1")])
    d_street = np.dtype([("ps", "<u4"), ("pc", "<u2"), ("w", "u1"), ("style", "u1")])
    d_zone = np.dtype([("rs", "<u4"), ("rc", "<u2"), ("style", "u1"), ("pad", "u1")])
    d_water = np.dtype([("rs", "<u4"), ("rc", "<u2"), ("pad", "<u2")])

    builds = take(d_build, nb)
    b_rings = take(d_ring, nbr)
    b_pts = take("<i2", 2 * nbp).reshape(-1, 2)
    streets = take(d_street, ns)
    s_pts = take("<i2", 2 * nsp).reshape(-1, 2)
    greens = take(d_zone, ng)
    g_rings = take(d_ring, ngr)
    g_pts = take("<i2", 2 * ngp).reshape(-1, 2)
    waters = take(d_water, nw)
    w_rings = take(d_ring, nwr)
    w_pts = take("<i2", 2 * nwp).reshape(-1, 2)
    assert off == len(b), (off, len(b))

    # conversion globale en une passe (rapide), puis découpage
    sm = world_to_map(s_pts)
    gm = world_to_map(g_pts)
    wm = world_to_map(w_pts)
    bm = world_to_map(b_pts)

    out = {"streets": [], "greens": [], "waters": [], "buildings": []}
    for r in streets:
        ps, pc = int(r["ps"]), int(r["pc"])
        out["streets"].append({
            "pts": sm[ps:ps + pc],
            "width": float(r["w"]) / 1000.0 * METERS_PER_WORLD_UNIT,
            "cls": int(r["style"]) & 0x7F,
            "bridge": bool(int(r["style"]) & 0x80),
        })
    for r in greens:
        out["greens"].append({"style": int(r["style"]), "rings": _rings(int(r["rs"]), int(r["rc"]), g_rings, gm)})
    for r in waters:
        out["waters"].append({"rings": _rings(int(r["rs"]), int(r["rc"]), w_rings, wm)})
    for r in builds:
        out["buildings"].append({
            "h": float(r["h"]) / 1000.0 * METERS_PER_WORLD_UNIT / 2.6,   # hauteur exagérée x2,6 à l'écriture
            "style": int(r["style"]),
            "rings": _rings(int(r["rs"]), int(r["rc"]), b_rings, bm),
        })
    return out


if __name__ == "__main__":
    d = read_osm(sys.argv[1])
    for k, v in d.items():
        print(k, len(v))
    s = d["streets"]
    print("classes", {CLASS_NAMES[c]: sum(1 for x in s if x["cls"] == c) for c in range(6)})
    print("ponts", sum(1 for x in s if x["bridge"]))
    allp = np.vstack([x["pts"] for x in s])
    print("étendue rues x", allp[:, 0].min(), allp[:, 0].max(), "y", allp[:, 1].min(), allp[:, 1].max())
    print("largeurs", sorted({round(x["width"], 1) for x in s})[:20])


# Contours de la zone couverte par le fichier source (script generate-osm-city.mjs) : hors de ces polygones
# il n'y a ni rue, ni parc, ni eau OSM dans l'extrait.
MAP_BOUNDARY = [
    (48.9023, 2.3264), (48.9015, 2.3654), (48.899, 2.3975), (48.886, 2.4112), (48.862, 2.417), (48.839, 2.414),
    (48.821, 2.392), (48.8158, 2.363), (48.817, 2.323), (48.823, 2.286), (48.836, 2.263), (48.858, 2.251),
    (48.879, 2.257), (48.894, 2.281),
]
LA_DEFENSE_BOUNDARY = [
    (48.8845, 2.246), (48.887, 2.224), (48.8978, 2.224), (48.9002, 2.244), (48.894, 2.255), (48.887, 2.255),
]


def coverage_local(frame):
    """Polygones shapely de couverture OSM dans le repère local du secteur."""
    from shapely.geometry import Polygon
    out = []
    for poly in (MAP_BOUNDARY, LA_DEFENSE_BOUNDARY):
        pts = [frame.local_lonlat(lon, lat) for lat, lon in poly]
        out.append(Polygon(pts))
    return out
