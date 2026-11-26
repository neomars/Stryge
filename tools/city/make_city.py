#!/usr/bin/env python3
"""Génère les cartes réelles des cinq secteurs : data/cities/<secteur>.json (format « pnc-city-2 »).

Sources (voir tools/city/README.md) :
  - bâtiments, hauteurs, eau : IGN BD TOPO (Licence Ouverte 2.0), via l'extrait « paris.bin » (dépôt Nave20/foundry-wod-control-room) ;
  - rues, ponts, parcs, eau : OpenStreetMap (ODbL), via l'extrait « paris-osm.bin » (dépôt KiK0S/paris-map-template) ;
  - stations de métro : dépôt atom-84/fluctuat-nec-mergitur-d3 (lignes 1 à 6 et 14) ;
  - là où OpenStreetMap ne couvre pas le secteur (Stade de France, pourtour de La Défense), les rues sont déduites des
    vides entre les bâtiments (voids.py).

Usage : python3 make_city.py [secteur ...] [--out DIR] [--prs paris.bin] [--osm paris-osm.bin] [--metro DIR] [--preview DIR]
"""
import argparse
import glob
import json
import math
import os
import pickle
import sys
import time

import cv2
import numpy as np
from mapbox_earcut import triangulate_float64
from scipy import ndimage
from scipy.spatial import cKDTree
from shapely import STRtree
from shapely.geometry import LineString, MultiPolygon, Point, Polygon, box
from shapely.ops import unary_union

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import streets as S          # noqa: E402
import voids as V            # noqa: E402
from buildings import decompose, rect_corners, select_rings   # noqa: E402
from geo import SECTORS, SIZE, Frame        # noqa: E402
import rezone                                # noqa: E402
from landmarks import LANDMARKS             # noqa: E402
from osm import coverage_local, read_osm    # noqa: E402
from prs import read_prs                    # noqa: E402

FORMAT = "pnc-city-2"

# Réglages par secteur : multiplicateur d'habitants, plafond par immeuble, graine
# Habitants d'un immeuble = niveaux x facteur d'emprise (racine de l'emprise / 180 m², borné à 0,45..1,8) x tirage 0,6..1,5
# x occ_mult, plafonné à occ_max.  occ_mult est calé pour que chaque secteur compte à peu près autant d'habitants, et autant
# d'immeubles à 8 ou 20 habitants, que l'ancienne ville générée qu'il remplace (les missions en dépendent : objectifs
# « tenir l'immeuble », « évacuer », tribunes du stade). Équilibrage de novembre 2026 (jeu trop difficile sur les vraies cartes) :
# La Défense moins peuplée, tribunes du stade à 100 / 100 / 70 / 70 habitants au lieu de 240 / 240 / 160 / 160.
CFG = {
    "quartier_latin": {"seed": 1914, "occ_mult": 0.92, "occ_max": 40},
    "montmartre": {"seed": 1871, "occ_mult": 0.72, "occ_max": 40},
    "halles": {"seed": 1969, "occ_mult": 0.72, "occ_max": 40, "metro": 12},
    "defense": {"seed": 1958, "occ_mult": 0.64, "occ_max": 24},
    "stade": {"seed": 1998, "occ_mult": 1.85, "occ_max": 28, "stadium": True},
}
STAND_OCC = (100, 100, 70, 70)   # habitants des quatre grandes tribunes (les assauts du secteur 5 les visent : min_occ 60)
MAX_DOOR_GAP = 38.0      # m : au-delà, la porte est dans une cour intérieure -> immeuble sans habitants
MAX_DOOR_DRIFT = 8.0     # m : écart toléré entre la porte et l'endroit où le jeu place les gens qui en sortent
SOURCES = ("Bâtiments, hauteurs, eau : IGN BD TOPO (Licence Ouverte 2.0). "
           "Rues, ponts, parcs, eau : © contributeurs OpenStreetMap (ODbL). "
           "Stations de métro : positions des lignes 1 à 6 et 14 (dépôt atom-84/fluctuat-nec-mergitur-d3).")


# ---------------------------------------------------------------- utilitaires géométriques

def poly_from_rings(rings, frame):
    """rings : [(pts_map, hole)] -> Polygon shapely local (trous compris)."""
    outer = None
    holes = []
    for pts, hole in rings:
        loc = frame.local(pts)
        if len(loc) < 3:
            continue
        if hole and outer is not None:
            holes.append(loc)
        elif outer is None:
            outer = loc
    if outer is None:
        return None
    try:
        p = Polygon(outer, holes).buffer(0)
    except Exception:
        return None
    return None if p.is_empty else p


def triangulate(geoms):
    """Liste de polygones shapely -> (sommets (n,2), indices (m,3))."""
    verts = []
    tris = []
    for g in geoms:
        for p in getattr(g, "geoms", [g]):
            if p.is_empty or p.geom_type != "Polygon" or p.area < 4.0:
                continue
            rings = [np.array(p.exterior.coords)[:-1]] + [np.array(r.coords)[:-1] for r in p.interiors]
            rings = [r for r in rings if len(r) >= 3]
            v = np.vstack(rings)
            ends = np.cumsum([len(r) for r in rings]).astype(np.uint32)
            idx = triangulate_float64(v, ends).reshape(-1, 3)
            tris.append(idx + len(verts))
            verts.extend(v.tolist())
    if not tris:
        return np.zeros((0, 2)), np.zeros((0, 3), int)
    return np.array(verts), np.vstack(tris)


def mesh_json(geoms, tol=0.0):
    v, t = triangulate(geoms)
    return {"v": [round(float(c), 1) for c in v.reshape(-1)], "i": [int(i) for i in t.reshape(-1)]}


# ---------------------------------------------------------------- sources

class Sources:
    def __init__(self, prs, osm, metro_dir):
        t = time.time()
        self.head, self.layers, _ = read_prs(prs)
        self.osm = read_osm(osm)
        self.stations = load_stations(metro_dir) if metro_dir else {}
        print("sources chargées en %.1f s" % (time.time() - t))


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


# ---------------------------------------------------------------- étapes

def water_polygons(src, frame, rects):
    """Eau du secteur.  OpenStreetMap là où le fichier source le couvre (ses polygones ont des trous pour les îles),
    IGN ailleurs (ses polygones recouvrent les îles : on en retranche les bâtiments qui s'y trouvent)."""
    win = box(-frame.ext, -frame.ext, frame.ext, frame.ext)
    cov = unary_union(coverage_local(frame))
    ign = []
    lens, _, _, xy = src.layers["eau"]
    starts = np.concatenate([[0], np.cumsum(lens.astype(np.int64))[:-1]])
    for k in range(len(lens)):
        s, n = int(starts[k]), int(lens[k])
        loc = frame.local(xy[s:s + n].astype(float))
        if loc[:, 0].max() < -frame.ext or loc[:, 0].min() > frame.ext or loc[:, 1].max() < -frame.ext or loc[:, 1].min() > frame.ext:
            continue
        if len(loc) >= 3:
            q = Polygon(loc).buffer(0)
            if not q.is_empty:
                ign.append(q)
    osm = []
    for w in src.osm["waters"]:
        q = poly_from_rings(w["rings"], frame)
        if q is not None:
            osm.append(q)
    parts = []
    if osm:
        parts.append(unary_union(osm).intersection(cov).intersection(win))
    if ign:
        u = unary_union(ign).intersection(win).difference(cov)
        if not u.is_empty:
            isl = []
            for (cx, cz, w, d, yaw, h) in rects:
                if abs(cx) < frame.ext and abs(cz) < frame.ext and u.contains(Point(cx, cz)):
                    isl.append(Polygon(rect_corners((cx, cz, w, d, yaw))))
            if isl:
                u = u.difference(unary_union(isl).buffer(6.0))
            parts.append(u)
    if not parts:
        return None
    u = unary_union(parts).simplify(0.8)
    return None if u.is_empty else u


def park_polygons(src, frame, water):
    """Parcs et jardins OSM de la fenêtre (hors eau)."""
    win = box(-frame.ext, -frame.ext, frame.ext, frame.ext)
    polys = []
    for z in src.osm["greens"]:
        p = poly_from_rings(z["rings"], frame)
        if p is None or not p.intersects(win):
            continue
        polys.append(p)
    if not polys:
        return None
    u = unary_union(polys).intersection(win)
    if water is not None:
        u = u.difference(water)
    u = u.simplify(0.8)
    parts = [g for g in getattr(u, "geoms", [u]) if g.geom_type == "Polygon" and g.area >= 60.0]
    return unary_union(parts) if parts else None


def stadium_rects(rect, rng):
    """Remplace l'emprise pleine du stade par un anneau (tribunes), la pelouse restant libre. Retourne (rects, pelouse)."""
    cx, cz, w, d, yaw = rect[:5]
    c, s = math.cos(yaw), math.sin(yaw)
    ax = np.array([c, -s])
    az = np.array([s, c])
    ctr = np.array([cx, cz])

    def ell(ka, kb, n=72):
        t = np.linspace(0, 2 * math.pi, n, endpoint=False)
        return np.array([ctr + ax * (w / 2 * ka) * math.cos(a) + az * (d / 2 * kb) * math.sin(a) for a in t])
    outer = Polygon(ell(1.0, 1.0))
    pitch = Polygon(ell(0.62, 0.60))
    ring = outer.difference(pitch)
    pts = np.array(ring.exterior.coords)[:-1]
    # trous : decompose() travaille sur l'anneau extérieur ; on rastérise donc à la main l'anneau = ext - pelouse
    from buildings import _greedy
    u = ax
    v = az
    ang = math.atan2(u[1], u[0])
    rr, _ = _greedy_ring(outer, pitch, ang)
    return rr, pitch


def _greedy_ring(outer, pitch, ang):
    """Décomposition gloutonne de (ext - pelouse) dans le repère d'angle ang."""
    from buildings import _max_rect
    from skimage.draw import polygon as skpoly
    u = np.array([math.cos(ang), math.sin(ang)])
    v = np.array([-u[1], u[0]])
    ring = np.array(outer.exterior.coords)[:-1]
    U, V_ = ring @ u, ring @ v
    umin, vmin = U.min(), V_.min()
    cs = 1.0
    nu, nv = int(math.ceil(U.max() - umin)) + 1, int(math.ceil(V_.max() - vmin)) + 1
    mask = np.zeros((nv, nu), np.bool_)
    rr, cc = skpoly((V_ - vmin) / cs, (U - umin) / cs, shape=(nv, nu))
    mask[rr, cc] = True
    pr = np.array(pitch.exterior.coords)[:-1]
    rr, cc = skpoly((pr @ v - vmin) / cs, (pr @ u - umin) / cs, shape=(nv, nu))
    mask[rr, cc] = False
    total = int(mask.sum())
    out = []
    got = 0
    yaw = math.atan2(-u[1], u[0])
    for _ in range(10):
        best, r0, r1, c0, c1 = _max_rect(mask)
        if best < 500:
            break
        mask[r0:r1, c0:c1] = False
        got += best
        cu, cv = umin + (c0 + c1) / 2 * cs, vmin + (r0 + r1) / 2 * cs
        p = u * cu + v * cv
        out.append((float(p[0]), float(p[1]), float((c1 - c0) * cs), float((r1 - r0) * cs), yaw))
        if got >= 0.95 * total:
            break
    return out, got / max(total, 1)


def _rect_poly(r):
    cx, cz, w, d, yaw = r[:5]
    c, s = math.cos(yaw), math.sin(yaw)
    ax = np.array([c, -s]) * w / 2
    az = np.array([s, c]) * d / 2
    ctr = np.array([cx, cz])
    return Polygon([ctr - ax - az, ctr + ax - az, ctr + ax + az, ctr - ax + az])


def stadium_service_ring(grid, rects, stands, pieces, offset=28.0, width=9.0, n_links=4):
    """Anneau de service autour des tribunes, relié par quelques raccords aux rues déduites les plus proches.
    Le stade est entouré d'esplanades trop larges pour le squelette des vides : sans cet anneau, les tribunes
    n'auraient aucune rue à moins de 60-190 m (les civils sortiraient d'une porte qui n'est pas la leur)."""
    from skimage.graph import route_through_array
    hull = unary_union([_rect_poly(rects[i]) for i in stands]).convex_hull.buffer(offset)
    ring = hull.exterior.simplify(3.0)
    out = [{"pts": np.array(ring.coords), "width": width, "cls": 3, "bridge": False, "src": "void"}]
    pool = np.vstack([pc["pts"] for pc in pieces if len(pc["pts"])]) if pieces else np.zeros((0, 2))
    if not len(pool):
        return out
    far = np.array([not hull.buffer(25.0).contains(Point(q)) for q in pool])
    pool = pool[far]
    if not len(pool):
        return out
    tree = cKDTree(pool)
    cost = np.where(grid.bld > 0, 60.0, 1.0) + np.where(grid.water > 0, 400.0, 0.0)
    n_added = 0
    for k in range(n_links):
        a = ring.interpolate((k + 0.5) / n_links, normalized=True)
        p0 = np.array([a.x, a.y])
        dist, idx = tree.query(p0, k=12)
        for dd, ii in zip(np.atleast_1d(dist), np.atleast_1d(idx)):
            if not np.isfinite(dd) or dd > 450.0:
                break
            q = pool[ii]
            lo = np.minimum(p0, q) - 80.0
            hi = np.maximum(p0, q) + 80.0
            i0 = np.clip(np.floor((lo + grid.lim) / grid.res).astype(int), 0, grid.n - 1)
            i1 = np.clip(np.ceil((hi + grid.lim) / grid.res).astype(int), 1, grid.n)
            sub = cost[i0[1]:i1[1], i0[0]:i1[0]]
            sp = np.clip(np.round((p0 + grid.lim) / grid.res).astype(int) - i0, 0, np.array(sub.shape[::-1]) - 1)
            sq = np.clip(np.round((q + grid.lim) / grid.res).astype(int) - i0, 0, np.array(sub.shape[::-1]) - 1)
            path, c = route_through_array(sub, (sp[1], sp[0]), (sq[1], sq[0]), fully_connected=True, geometric=True)
            path = np.array(path, dtype=np.float64)
            length = float(np.hypot(*np.diff(path, axis=0).T).sum()) if len(path) > 1 else 0.0
            if length < 10.0 or c > length * 4.0:        # trop de bâtiments ou d'eau en travers : on essaie le point suivant
                continue
            pts = np.column_stack([path[:, 1] + i0[0], path[:, 0] + i0[1]]) * grid.res - grid.lim
            pts[0], pts[-1] = p0, q
            ln = LineString(pts).simplify(4.0)
            out.append({"pts": np.array(ln.coords), "width": 7.0, "cls": 3, "bridge": False, "src": "void"})
            n_added += 1
            break
    print("  stade : anneau de service (%.0f m) et %d raccords" % (ring.length, n_added))
    return out


# ---------------------------------------------------------------- construction d'un secteur

def build_sector(sid, src, cfg, log=print):
    sec = SECTORS[sid]
    fr = Frame(sec["lonlat"])
    rng = np.random.default_rng(cfg["seed"])
    t0 = time.time()

    # --- bâtiments
    rings = select_rings(src.layers["batiments"], fr, margin=fr.margin)
    # La couche « monuments » (Notre-Dame, Louvre, Sacré-Cœur, Opéra, Pompidou…) n'est pas dans « bâtiments »
    mrings = [r for r in select_rings(src.layers["monuments"], fr, margin=fr.margin) if r["h"] >= 4.0]
    if mrings:
        mp = [Polygon(r["pts"]).buffer(0) for r in mrings]
        mtree = STRtree(mp)
        kept = []
        for r in rings:
            q = Polygon(r["pts"]).buffer(0)
            hit = any(q.intersection(mp[j]).area > 0.5 * q.area for j in mtree.query(q))
            if not hit:
                kept.append(r)
        rings = kept + mrings
    rects = []                       # (cx, cz, w, d, yaw, h)
    for r in rings:
        h = r["h"] if r["h"] >= 3.0 else 9.0
        for q in decompose(r["pts"]):
            rects.append(q + (float(min(h, 330.0)),))
    log("  bâtiments : %d emprises (dont %d monuments) -> %d rectangles" % (len(rings), len(mrings), len(rects)))

    # --- stade : anneau de tribunes à la place de l'emprise pleine
    stands = []
    pitch = None
    if cfg.get("stadium"):
        big = max(range(len(rects)), key=lambda i: rects[i][2] * rects[i][3] * (1.0 if math.hypot(rects[i][0], rects[i][1]) < 200 else 0.0))
        base = rects[big]
        ring_rects, pitch = stadium_rects(base, rng)
        h0 = base[5]
        rects.pop(big)
        ring_rects.sort(key=lambda r: -r[2] * r[3])
        stands = [len(rects) + k for k in range(len(ring_rects))]
        for r in ring_rects:
            rects.append(r + (max(h0, 30.0),))
        log("  stade : emprise %.0f x %.0f m -> %d tribunes/anneau" % (base[2], base[3], len(ring_rects)))

    # --- eau et parcs
    water = water_polygons(src, fr, rects)
    parks = park_polygons(src, fr, water)
    if pitch is not None:
        parks = unary_union([parks, pitch]) if parks is not None else pitch
    log("  eau %.1f ha, parcs %.1f ha" % ((water.area if water is not None else 0) / 1e4, (parks.area if parks is not None else 0) / 1e4))

    # --- grille d'obstacles (bâtiments du jeu + eau)
    grid = S.Grid(fr, [r[:5] for r in rects], [water] if water is not None else [])

    # --- rues : OSM dans la zone couverte, vides ailleurs
    cov = unary_union(coverage_local(fr)).buffer(-8)
    covered_any = (not cov.is_empty) and cov.intersects(box(-fr.half, -fr.half, fr.half, fr.half))
    pieces = S.osm_pieces(src.osm["streets"], fr) if covered_any else []
    mask = np.zeros_like(grid.img)
    if covered_any:
        for g in getattr(cov, "geoms", [cov]):
            if not g.is_empty:
                cv2.fillPoly(mask, [grid.to_px(np.array(g.exterior.coords))], 1)
    full_cov = bool(mask[grid.n // 2 - int(fr.half): grid.n // 2 + int(fr.half), grid.n // 2 - int(fr.half): grid.n // 2 + int(fr.half)].mean() > 0.995)
    if not full_cov:
        pieces += V.void_pieces(grid, mask == 0)
    kept = []
    for pc in pieces:
        if not pc["bridge"] and pc.get("src") != "void":
            ln = np.hypot(*np.diff(pc["pts"], axis=0).T).sum()
            if ln > 30.0:
                n = int(ln / 3.0) + 2
                seg = np.linspace(0, 1, n)[:, None]
                q = pc["pts"][0] * (1 - seg) + pc["pts"][-1] * seg
                if float(grid.sample(grid.water, q).mean()) > 0.6:
                    continue
        kept.append(pc)
    pieces = kept
    if stands:
        pieces += stadium_service_ring(grid, rects, stands, pieces)
    log("  tracés : %d (OSM %d)" % (len(pieces), sum(1 for p in pieces if p.get("src") != "void")))
    nodes, edges = S.build_graph(pieces)
    nodes, edges = S.straighten(nodes, edges, 2.5)
    nodes, edges = S.clean(nodes, edges, min_spur=30.0 if not full_cov else 18.0)
    S.refine_widths(nodes, edges, grid)
    if not full_cov:
        edges = V.stitch_components(nodes, edges, grid)
        edges = V.add_water_bridges(nodes, edges, grid)
        edges = V.stitch_components(nodes, edges, grid, max_gap=400.0, min_len=0.0, width=5.0)
    nodes, edges = S.clean(nodes, edges, min_spur=0.0, min_component=1e9)    # ne garde que la plus grande composante
    for e in edges:
        e.setdefault("w", e["width"])
    log("  réseau : %d nœuds, %d tronçons, %d ponts (%.1f s)" % (len(nodes), len(edges), sum(1 for e in edges if e["bridge"]), time.time() - t0))

    return {"frame": fr, "rects": rects, "stands": stands, "water": water, "parks": parks, "grid": grid,
            "nodes": nodes, "edges": edges, "cfg": cfg, "sid": sid, "rings": rings}


def assign_occupancy(sec, rng, far=None):
    """Habitants par immeuble : niveaux x emprise, calibrés sur le total de l'ancien générateur.
    far : masque des immeubles dont la porte est trop loin d'une rue (cours intérieures) : personne n'y habite."""
    cfg = sec["cfg"]
    rects = sec["rects"]
    occ = np.zeros(len(rects), int)
    raw = np.zeros(len(rects))
    for i, r in enumerate(rects):
        cx, cz, w, d, yaw, h = r
        area = w * d
        if h < 6.0 or area < 45.0:
            continue
        lv = max(1.0, round(h / 3.1))
        raw[i] = lv * float(np.clip(math.sqrt(area / 180.0), 0.45, 1.8)) * rng.uniform(0.6, 1.5) * cfg["occ_mult"]
        if rng.random() < 0.08:
            raw[i] = 0.0
    occ = np.clip(np.round(raw), 0, cfg["occ_max"]).astype(int)
    occ[(raw > 0) & (occ == 0)] = 1
    if far is not None:
        occ[np.asarray(far, bool)] = 0
    for j, i in enumerate(sec["stands"]):
        occ[i] = STAND_OCC[j] if j < 4 else 0
    return occ


def compute_doors(nodes, edges, rects, slack=8.0):
    """Porte de chaque immeuble, calculée comme StreetGraph.snap_doors du jeu (tronçon proche du centre, point de la façade
    tourné vers la rue), avec une nuance : parmi les tronçons à moins de `slack` m du plus proche, on préfère un tronçon où la
    porte se projette *dans* le segment, car le jeu place les gens à (tronçon, t, décalage latéral) et un t tronqué à 0 ou 1
    les éloignerait de la porte. Précalculé ici (arbre spatial exact) plutôt que 20 000 recherches en GDScript.
    Retourne (tronçon, position de la porte (x, z), distance de la porte au bord de chaussée)."""
    import shapely
    from shapely import STRtree
    nodes = np.asarray(nodes, dtype=np.float64)
    ea = np.array([e[0] for e in edges])
    eb = np.array([e[1] for e in edges])
    wid = np.array([e[2] for e in edges], dtype=np.float64)
    a, b = nodes[ea], nodes[eb]
    tree = STRtree(shapely.linestrings(np.stack([a, b], axis=1)))
    r = np.asarray(rects, dtype=np.float64)
    n = len(r)
    c_all = r[:, :2]
    pts = shapely.points(c_all)
    pair0 = tree.query_nearest(pts, all_matches=False, return_distance=True)
    order = np.argsort(pair0[0][0])
    dmin = pair0[1][order]
    # candidats : tous les tronçons à moins de dmin + slack du centre
    cand = tree.query(shapely.buffer(pts, dmin + slack), predicate="intersects")
    bi, ei = cand[0], cand[1]
    c = c_all[bi]
    ab = b[ei] - a[ei]
    l2 = np.maximum((ab ** 2).sum(1), 1e-4)
    t = np.clip(((c - a[ei]) * ab).sum(1) / l2, 0.0, 1.0)
    q = a[ei] + ab * t[:, None]
    dist = np.hypot(*(q - c).T)
    dv = q - c
    cs, sn = np.cos(r[bi, 4]), np.sin(r[bi, 4])
    lx = dv[:, 0] * cs - dv[:, 1] * sn
    lz = dv[:, 0] * sn + dv[:, 1] * cs
    big = np.full(len(bi), np.inf)
    tb = np.minimum(np.where(np.abs(lx) > 1e-4, (r[bi, 2] * 0.5) / np.maximum(np.abs(lx), 1e-4), big),
                    np.where(np.abs(lz) > 1e-4, (r[bi, 3] * 0.5) / np.maximum(np.abs(lz), 1e-4), big))
    tb = np.where(np.isinf(tb), 0.0, np.minimum(tb, 1.0))
    dlx, dlz = lx * tb, lz * tb
    door = c + np.column_stack([dlx * cs + dlz * sn, -dlx * sn + dlz * cs])
    tu = ((door - a[ei]) * ab).sum(1) / l2                       # projection non tronquée
    clamped = (tu < 0.0) | (tu > 1.0)
    cost = dist + np.where(clamped, 1000.0, 0.0)
    # meilleur candidat par immeuble
    best = np.full(n, -1)
    best_cost = np.full(n, np.inf)
    for k in np.argsort(cost, kind="stable")[::-1]:               # du pire au meilleur : le dernier écrit gagne
        best[bi[k]] = k
    sel = best
    e = ei[sel]
    t2 = np.clip(tu[sel], 0.0, 1.0)
    door = door[sel]
    foot = a[e] + (b[e] - a[e]) * t2[:, None]
    gap = np.hypot(*(door - foot).T) - wid[e] * 0.5               # distance réelle de la porte au bord de la chaussée
    # point où le jeu place réellement les gens (tronçon, t, décalage latéral) : s'il est loin de la porte, on ne s'en sert pas
    edir = (b[e] - a[e]) / np.maximum(np.sqrt(((b[e] - a[e]) ** 2).sum(1)), 0.001)[:, None]
    orth = np.column_stack([edir[:, 1], -edir[:, 0]])
    off = ((door - foot) * orth).sum(1)
    spawn = foot + orth * off[:, None]
    drift = np.hypot(*(spawn - door).T)
    return e, door, gap, drift


def pick_evac(sec, rng):
    nodes = sec["nodes"]
    grid = sec["grid"]
    edt = grid.edt
    size = SIZE
    chosen = []
    free = grid.sample(edt, nodes)
    for gx in (-0.33, 0.0, 0.33):
        for gz in (-0.33, 0.0, 0.33):
            want = np.array([gx, gz]) * size
            d = np.hypot(*(nodes - want).T)
            cand = np.nonzero(d <= 260.0)[0]
            if len(cand) == 0:
                cand = np.array([int(d.argmin())])
            score = np.minimum(free[cand], 16.0) * 10.0 - d[cand] * 0.05
            order = cand[np.argsort(-score)]
            for k in order:
                if int(k) not in chosen and all(np.hypot(*(nodes[k] - nodes[c])) > 120.0 for c in chosen):
                    chosen.append(int(k))
                    break
    return chosen


def pick_metro(sec, src, n):
    fr = sec["frame"]
    nodes = sec["nodes"]
    lim = SIZE * 0.44
    st = []
    for name, v in src.stations.items():
        x, z = fr.local_lonlat(v["lon"], v["lat"])
        if abs(x) <= lim and abs(z) <= lim:
            st.append((name, x, z))
    chosen = []
    names = []
    for name, x, z in sorted(st, key=lambda s: math.hypot(s[1], s[2])):
        d = np.hypot(*(nodes - np.array([x, z])).T)
        k = int(d.argmin())
        if d[k] > 90.0 or k in chosen or any(np.hypot(*(nodes[k] - nodes[c])) < 140.0 for c in chosen):
            continue
        chosen.append(k)
        names.append(name)
        if len(chosen) >= n:
            break
    return chosen, names


def _water_points(sec, spacing=260.0):
    """Points répartis le long des nappes d'eau principales (au large des berges), pour nommer un fleuve sur toute sa longueur."""
    import shapely
    from shapely.geometry import box
    w = sec["water"]
    if w is None or w.is_empty:
        return []
    lim = SIZE * 0.46
    inner = w.intersection(box(-lim, -lim, lim, lim))
    if inner.is_empty:
        return []
    parts = [g for g in getattr(inner, "geoms", [inner]) if g.geom_type == "Polygon" and g.area > 6000.0]
    if not parts:
        return []
    amax = max(g.area for g in parts)
    out = []
    for g in parts:
        if g.area < 0.4 * amax:
            continue
        x0, z0, x1, z1 = g.bounds
        xs = np.arange(x0, x1 + 1.0, 30.0)
        zs = np.arange(z0, z1 + 1.0, 30.0)
        gx, gz = np.meshgrid(xs, zs)
        gx, gz = gx.ravel(), gz.ravel()
        inside = shapely.contains_xy(g, gx, gz)
        gx, gz = gx[inside], gz[inside]
        if not len(gx):
            continue
        dist = shapely.distance(g.boundary, shapely.points(gx, gz))
        order = np.argsort(-dist)           # d'abord les points les plus au large (ligne médiane)
        chosen = []
        for k in order:
            if dist[k] < 12.0:
                break
            if all((gx[k] - cx) ** 2 + (gz[k] - cz) ** 2 >= spacing ** 2 for cx, cz in chosen):
                chosen.append((float(gx[k]), float(gz[k])))
        out += chosen
    return out


def pick_places(sec, src):
    """Repères nommés du secteur : placés sur la donnée (bâtiment, parc ou eau) la plus proche, sinon abandonnés."""
    fr = sec["frame"]
    out = []
    rects = np.array([r[:6] for r in sec["rects"]]) if sec["rects"] else np.zeros((0, 6))
    for lm in LANDMARKS.get(sec["sid"], []):
        x, z = fr.local_lonlat(lm["lon"], lm["lat"])
        kind = lm.get("kind", "monument")
        if kind != "auto_eau" and (abs(x) > SIZE / 2 - 30 or abs(z) > SIZE / 2 - 30):
            continue
        px, pz, ok = x, z, True
        if kind == "stade" and sec["stands"]:
            st = np.array([rects[i][:2] for i in sec["stands"]])
            px, pz = float(st[:, 0].mean()), float(st[:, 1].mean())
        elif kind in ("monument", "gare", "tour"):
            area = rects[:, 2] * rects[:, 3]
            d = np.hypot(rects[:, 0] - x, rects[:, 1] - z)
            near = np.nonzero((d < 130.0) & (area > lm.get("min_area", 250.0)))[0]
            if len(near):
                j = near[np.argmax(area[near] / (1.0 + d[near] / 60.0))]
                px, pz = float(rects[j, 0]), float(rects[j, 1])
            else:
                ok = False
        elif kind == "parc":
            from shapely.geometry import Point
            ok = sec["parks"] is not None and sec["parks"].distance(Point(x, z)) < 40.0
        elif kind == "eau":
            from shapely.geometry import Point
            ok = sec["water"] is not None and sec["water"].distance(Point(x, z)) < 30.0
        elif kind == "auto_eau":
            pts = _water_points(sec)
            if not pts:
                print("    repère écarté (pas de donnée à proximité) :", lm["name"])
            for wx, wz in pts:
                out.append({"n": lm["name"], "x": round(wx, 1), "z": round(wz, 1), "k": "eau", "r": lm.get("r", 200)})
            continue
        if not ok:
            print("    repère écarté (pas de donnée à proximité) :", lm["name"])
            continue
        out.append({"n": lm["name"], "x": round(px, 1), "z": round(pz, 1), "k": kind, "r": lm.get("r", 90)})
    return out


def export(sec, src, out_dir, log=print):
    fr = sec["frame"]
    cfg = sec["cfg"]
    rng = np.random.default_rng(cfg["seed"] + 1)
    rects = sec["rects"]
    nodes_j, edges_j = S.pack(sec["nodes"], sec["edges"])
    # géométrie exportée (arrondie) : les portes sont calculées dessus
    rq = [[round(r[0], 2), round(r[1], 2), round(r[2], 2), round(r[3], 2), round(r[4], 4), round(r[5], 2)] for r in rects]
    d_e, d_door, d_gap, d_drift = compute_doors(nodes_j, edges_j, rq)
    far = (d_gap > MAX_DOOR_GAP) | (d_drift > MAX_DOOR_DRIFT)
    occ = assign_occupancy(sec, rng, far)
    # hauteurs légèrement décalées (évite le scintillement de toits coplanaires voisins)
    hj = (np.arange(len(rects)) * 0.6180339887) % 1.0 * 0.14

    b = []
    for i, r in enumerate(rects):
        cx, cz, w, d, yaw, h = r
        b.append([round(cx, 2), round(cz, 2), round(w, 2), round(d, 2), round(yaw, 4), round(h + float(hj[i]), 2), int(occ[i])])
    doors = []
    for i in range(len(rects)):
        doors += [int(d_e[i]), round(float(d_door[i, 0]), 2), round(float(d_door[i, 1]), 2)]

    areas = []
    evac = pick_evac(sec, rng)
    edt = sec["grid"].edt
    for k in evac:
        p = sec["nodes"][k]
        half = float(np.clip(sec["grid"].sample(edt, p) - 1.0, 6.0, 16.0))
        areas.append(["evac", round(p[0] - half, 1), round(p[1] - half, 1), round(p[0] + half, 1), round(p[1] + half, 1)])
    metro, metro_names = ([], [])
    if cfg.get("metro"):
        metro, metro_names = pick_metro(sec, src, cfg["metro"])
        for k in metro:
            p = sec["nodes"][k]
            areas.append(["metro", round(p[0] - 3, 1), round(p[1] - 3, 1), round(p[0] + 3, 1), round(p[1] + 3, 1)])
    places = pick_places(sec, src)

    mesh = {}
    if sec["water"] is not None:
        mesh["water"] = mesh_json([sec["water"]])
    if sec["parks"] is not None:
        mesh["park"] = mesh_json([sec["parks"]])
    doc = {
        "format": FORMAT,
        "meta": {"name": SECTORS[sec["sid"]]["name"], "seed": cfg["seed"], "size": [SIZE, SIZE],
                 "origin_lonlat": [fr.lon, fr.lat], "style": "real", "sector": sec["sid"], "sources": SOURCES,
                 "metro_names": metro_names},
        "nodes": nodes_j, "edges": edges_j, "buildings": b, "areas": areas, "mesh": mesh,
        "evac_nodes": evac, "metro_nodes": metro, "places": places, "doors": doors,
    }
    # zone de jeu (600 m de rayon) : points d'évacuation et bouches de métro resserrés autour du centre de la zone (voir rezone.py)
    rezone.apply(doc, sec["sid"], src.stations)
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, sec["sid"] + ".json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, separators=(",", ":"))
    tot = int(occ.sum())
    log("  portes : écart médian %.1f m ; %d immeubles vidés (rue à plus de %.0f m ou porte décalée de plus de %.0f m du point de sortie)" % (
        float(np.median(d_gap)), int(far.sum()), MAX_DOOR_GAP, MAX_DOOR_DRIFT))
    log("  écrit %s (%.1f Mo) : %d bâtiments, occupants %d, >=8: %d, >=20: %d, >=150: %d" % (
        path, os.path.getsize(path) / 1e6, len(b), tot, int((occ >= 8).sum()), int((occ >= 20).sum()), int((occ >= 150).sum())))
    return doc


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("secteurs", nargs="*", default=list(SECTORS))
    ap.add_argument("--out", default=os.path.join(HERE, "..", "..", "data", "cities"))
    ap.add_argument("--prs", default=os.environ.get("PNC_PRS", "/home/claude/nave20/foundry-wod-control-room/data/paris.bin"))
    ap.add_argument("--osm", default=os.environ.get("PNC_OSM", "/home/claude/kik0s/paris-map-template/public/data/paris-osm.bin"))
    ap.add_argument("--metro", default=os.environ.get("PNC_METRO", "/home/claude/atom-84/fluctuat-nec-mergitur-d3/metro"))
    ap.add_argument("--preview", default="")
    a = ap.parse_args()
    src = Sources(a.prs, a.osm, a.metro)
    for sid in a.secteurs:
        print("== %s" % sid)
        sec = build_sector(sid, src, CFG[sid])
        doc = export(sec, src, a.out)
        if a.preview:
            from preview_city import render
            render(doc, os.path.join(a.preview, sid + ".png"))


if __name__ == "__main__":
    main()
