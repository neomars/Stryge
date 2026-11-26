"""Réseau de rues déduit des vides entre les bâtiments (là où OpenStreetMap ne couvre pas le secteur).

Principe : l'espace libre (hors bâtiments et eau) est rastérisé à 1 m ; on ne garde que les couloirs d'au moins
5 m de large (les cours intérieures, reliées à la rue par un porche étroit, s'en détachent et disparaissent),
puis on en prend le squelette (axe médian).  Chaque branche devient une rue dont la largeur vient de la distance
mesurée aux façades.  Les traversées d'eau (canal) sont rétablies par des ponts entre bouts de rue qui se font face.
"""
import math

import numpy as np
from scipy import ndimage
from scipy.spatial import cKDTree
from shapely.geometry import LineString
from skan import Skeleton
from skimage.morphology import skeletonize

from numba import njit

from streets import SIDEWALK

DIRS = [(0, 1), (1, 1), (1, 0), (1, -1)]      # quatre axes ; chacun est testé dans les deux sens


@njit(cache=True)
def _ray(img, dy, dx, maxd):
    """Distance (en pixels, borne maxd) au premier obstacle en partant de chaque pixel dans la direction (dy, dx)."""
    h, w = img.shape
    out = np.full((h, w), maxd, np.float32)
    step = np.sqrt(float(dy * dy + dx * dx))
    ys = range(h - 1, -1, -1) if dy > 0 else range(h)
    for y in ys:
        xs = range(w - 1, -1, -1) if (dx > 0 and dy == 0) or dx > 0 else range(w)
        for x in xs:
            ny = y + dy
            nx = x + dx
            if ny < 0 or ny >= h or nx < 0 or nx >= w:
                out[y, x] = maxd
            elif img[ny, nx] != 0:
                out[y, x] = step
            else:
                v = out[ny, nx] + step
                out[y, x] = v if v < maxd else maxd
    return out


def corridor_mask(img, maxd=30.0):
    """Pixels libres bordés d'obstacles des deux côtés (à moins de maxd) selon au moins un des quatre axes."""
    ok = np.zeros(img.shape, bool)
    for dy, dx in DIRS:
        a = _ray(img, dy, dx, maxd)
        b = _ray(img, -dy, -dx, maxd)
        ok |= (a < maxd) & (b < maxd)
    return ok


def void_pieces(grid, region, r_core=2.5, r_max=20.0, min_area=3000, simplify=3.5):
    """Tracés (liste de dict comme osm_pieces) dans la zone `region` (masque booléen de la taille de la grille)."""
    edt = grid.edt
    core = (edt >= r_core) & (edt <= r_max) & region & corridor_mask(grid.img, 2.0 * r_max)
    lab, n = ndimage.label(core)
    if n == 0:
        return []
    sizes = ndimage.sum(core, lab, index=np.arange(1, n + 1))
    keep = np.zeros(n + 1, bool)
    keep[1:] = sizes >= min_area
    core = keep[lab]
    skel = skeletonize(core)
    sk = Skeleton(skel, spacing=1.0, keep_images=False)
    out = []
    res, lim = grid.res, grid.lim
    for i in range(sk.n_paths):
        c = sk.path_coordinates(i)          # (m, 2) = (ligne, colonne)
        if len(c) < 4:
            continue
        pts = np.column_stack([c[:, 1] * res - lim, c[:, 0] * res - lim])
        ln = LineString(pts)
        if ln.length < 6.0:
            continue
        if len(pts) > 3:
            ln = ln.simplify(simplify, preserve_topology=False)
        pts = np.array(ln.coords)
        w = 2.0 * float(np.median(edt[c[:, 0].astype(int), c[:, 1].astype(int)])) - 2.0 * SIDEWALK
        w = float(np.clip(w, 4.0, 40.0))
        out.append({"pts": pts, "width": w, "cls": 1 if w >= 18.0 else 3, "bridge": False, "src": "void"})
    return out


def _components(nodes, edges):
    par = list(range(len(nodes)))

    def find(x):
        while par[x] != x:
            par[x] = par[par[x]]
            x = par[x]
        return x
    for e in edges:
        ra, rb = find(e["a"]), find(e["b"])
        if ra != rb:
            par[ra] = rb
    comp = np.array([find(i) for i in range(len(nodes))]) if len(nodes) else np.zeros(0, int)
    return comp


def _crosses_water(grid, p, q, tol=0.5):
    n = max(int(np.hypot(*(q - p)) / 3.0), 2)
    t = np.linspace(0, 1, n)[:, None]
    pts = p[None, :] * (1 - t) + q[None, :] * t
    return float(grid.sample(grid.water, pts).mean())


def add_water_bridges(nodes, edges, grid, max_len=110.0, min_water=0.45, width=11.0):
    """Ponts entre deux bouts de rue (feuilles du graphe) qui se font face de part et d'autre d'une pièce d'eau."""
    if len(nodes) == 0:
        return edges
    deg = np.zeros(len(nodes), int)
    nb = {i: [] for i in range(len(nodes))}
    for e in edges:
        deg[e["a"]] += 1
        deg[e["b"]] += 1
        nb[e["a"]].append(e["b"])
        nb[e["b"]].append(e["a"])
    dwater = ndimage.distance_transform_edt(grid.water == 0) * grid.res
    leaves = [i for i in range(len(nodes)) if deg[i] == 1 and float(grid.sample(dwater, nodes[i])) <= 14.0]
    if len(leaves) < 2:
        return edges
    comp = _components(nodes, edges)
    pts = nodes[leaves]
    tree = cKDTree(pts)
    cand = []
    for a, b in tree.query_pairs(max_len):
        i, j = leaves[a], leaves[b]
        if comp[i] == comp[j]:
            continue
        d = nodes[j] - nodes[i]
        dist = float(np.hypot(*d))
        if dist < 6.0:
            continue
        u = d / dist
        di = nodes[i] - nodes[nb[i][0]]
        dj = nodes[j] - nodes[nb[j][0]]
        di /= max(np.hypot(*di), 1e-6)
        dj /= max(np.hypot(*dj), 1e-6)
        if float(np.dot(di, u)) < math.cos(math.radians(35)) or float(np.dot(dj, -u)) < math.cos(math.radians(35)):
            continue
        if _crosses_water(grid, nodes[i], nodes[j]) < min_water:
            continue
        cand.append((dist, i, j))
    used = set()
    out = list(edges)
    for dist, i, j in sorted(cand):
        if i in used or j in used:
            continue
        used.add(i)
        used.add(j)
        out.append({"a": i, "b": j, "width": width, "w": width, "cls": 3, "bridge": True})
    return out


def stitch_components(nodes, edges, grid, max_gap=70.0, min_len=100.0, width=7.0):
    """Relie les morceaux du graphe qui se frôlent (raccords manquants), sans traverser l'eau."""
    for _ in range(6):
        comp = _components(nodes, edges)
        if len(nodes) == 0:
            return edges
        length = {}
        for e in edges:
            length[comp[e["a"]]] = length.get(comp[e["a"]], 0.0) + float(np.hypot(*(nodes[e["a"]] - nodes[e["b"]])))
        order = sorted(length, key=lambda c: -length[c])
        main = order[0]
        main_idx = np.nonzero(comp == main)[0]
        tree = cKDTree(nodes[main_idx])
        added = 0
        for c in order[1:]:
            if length[c] < min_len:
                continue
            idx = np.nonzero(comp == c)[0]
            d, k = tree.query(nodes[idx])
            order_k = np.argsort(d)
            for o in order_k[:6]:
                if d[o] > max_gap:
                    break
                i, j = int(idx[o]), int(main_idx[k[o]])
                if _crosses_water(grid, nodes[i], nodes[j]) > 0.1:
                    continue
                edges.append({"a": i, "b": j, "width": width, "w": width, "cls": 3, "bridge": False})
                added += 1
                break
        if not added:
            break
    return edges
