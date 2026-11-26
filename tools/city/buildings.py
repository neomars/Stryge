"""Bâtiments réels (IGN BD TOPO) -> rectangles orientés du jeu.

Le jeu ne sait afficher et simuler que des rectangles orientés (centre, largeur, profondeur, lacet, hauteur).
Chaque emprise réelle est donc ramenée à un ou plusieurs rectangles :
  1. si l'emprise est presque un rectangle (rempli à 80 % de son rectangle englobant minimal) : un seul rectangle ;
  2. sinon (L, U, trapèze, îlot irrégulier, tribune courbe) : on rastérise l'emprise dans le repère du rectangle
     englobant et on en extrait, de façon gloutonne, le plus grand rectangle plein, puis le suivant, jusqu'à couvrir
     93 % de la surface (ou atteindre le nombre maximal de rectangles) ; deux orientations sont essayées (axe du
     rectangle englobant, axe de la plus longue arête) et la meilleure est gardée ;
  3. en dernier recours : le rectangle englobant minimal.
Convention du jeu : x vers l'est, z vers le sud ; le rectangle est d'abord orienté selon x (largeur) et z
(profondeur), puis tourné de `yaw` autour de la verticale (Basis(UP, yaw) de Godot) : l'axe « largeur » pointe
donc vers (cos yaw, -sin yaw) dans le plan (x, z).
"""
import math

import numpy as np
from numba import njit
from shapely.geometry import Polygon
from skimage.draw import polygon as sk_polygon

FILL_OK = 0.80          # remplissage au-dessus duquel un rectangle suffit
MIN_RECT_AREA = 14.0    # m² : on ignore les miettes
MIN_RECT_SIDE = 2.2     # m : pas de lamelles
COVER_TARGET = 0.93


@njit(cache=True)
def _max_rect(mask):
    """Plus grand rectangle plein d'une matrice booléenne (histogrammes + pile) -> (aire, r0, r1, c0, c1), bornes hautes exclues."""
    nv, nu = mask.shape
    heights = np.zeros(nu, np.int32)
    st_i = np.empty(nu + 2, np.int32)
    st_h = np.empty(nu + 2, np.int32)
    best = 0
    br0 = 0
    br1 = 0
    bc0 = 0
    bc1 = 0
    for r in range(nv):
        for c in range(nu):
            if mask[r, c]:
                heights[c] += 1
            else:
                heights[c] = 0
        sp = 0
        for c in range(nu + 1):
            h = heights[c] if c < nu else 0
            start = c
            while sp > 0 and st_h[sp - 1] >= h:
                sp -= 1
                hh = st_h[sp]
                ss = st_i[sp]
                area = hh * (c - ss)
                if area > best:
                    best = area
                    br1 = r + 1
                    br0 = r + 1 - hh
                    bc0 = ss
                    bc1 = c
                start = ss
            st_i[sp] = start
            st_h[sp] = h
            sp += 1
    return best, br0, br1, bc0, bc1


def ring_table(layer):
    """(lens, hts, sol, xy) -> (starts, centroids float64 (n,2))"""
    lens, hts, sol, xy = layer
    starts = np.concatenate([[0], np.cumsum(lens.astype(np.int64))[:-1]])
    sums = np.add.reduceat(xy.astype(np.float64), starts, axis=0)
    return starts, sums / lens.astype(np.float64)[:, None]


def select_rings(layer, frame, margin=0.0):
    """Anneaux (en coordonnées locales du secteur) dont le centroïde est dans la fenêtre ; avec leur hauteur."""
    lens, hts, sol, xy = layer
    starts, cent = ring_table(layer)
    lim = frame.half + margin
    lx = cent[:, 0] - frame.cx
    lz = -(cent[:, 1] - frame.cy)
    sel = np.nonzero((np.abs(lx) <= lim) & (np.abs(lz) <= lim))[0]
    out = []
    for k in sel:
        s, n = int(starts[k]), int(lens[k])
        pts = xy[s:s + n].astype(np.float64)
        loc = np.column_stack([pts[:, 0] - frame.cx, -(pts[:, 1] - frame.cy)])
        out.append({"pts": loc, "h": float(hts[k]) if hts is not None else 0.0, "idx": int(k)})
    return out


def _greedy(ring, ang, area, k_max):
    """Décomposition gloutonne dans le repère d'angle `ang` -> (liste de rectangles (cu, cv, w, d), couverture)."""
    u = np.array([math.cos(ang), math.sin(ang)])
    v = np.array([-u[1], u[0]])
    U = ring @ u
    V = ring @ v
    umin, vmin = U.min(), V.min()
    lu, lv = U.max() - umin, V.max() - vmin
    cs = min(max(math.sqrt(area) / 55.0, 0.45), 2.0)
    nu = max(int(math.ceil(lu / cs)), 1)
    nv = max(int(math.ceil(lv / cs)), 1)
    rr, cc = sk_polygon((V - vmin) / cs, (U - umin) / cs, shape=(nv, nu))
    mask = np.zeros((nv, nu), dtype=np.bool_)
    mask[rr, cc] = True
    total = int(mask.sum())
    if total == 0:
        return [], 0.0
    covered = 0
    rects = []
    min_cells = max(MIN_RECT_AREA / (cs * cs), 2.0)
    min_side = max(MIN_RECT_SIDE / cs, 1.0)
    for _ in range(k_max):
        best, r0, r1, c0, c1 = _max_rect(mask)
        if best < min_cells or min(r1 - r0, c1 - c0) < min_side:
            break
        mask[r0:r1, c0:c1] = False
        covered += best
        rects.append((umin + (c0 + c1) * 0.5 * cs, vmin + (r0 + r1) * 0.5 * cs, (c1 - c0) * cs, (r1 - r0) * cs))
        if covered >= COVER_TARGET * total:
            break
    return rects, covered / total


def decompose(pts, fill_ok=FILL_OK):
    """pts : (n,2) anneau local (x, z). Retourne une liste de (cx, cz, w, d, yaw)."""
    try:
        P = Polygon(pts)
        if not P.is_valid:
            P = P.buffer(0)
            if P.geom_type == "MultiPolygon":
                P = max(P.geoms, key=lambda g: g.area)
        if P.is_empty or P.geom_type != "Polygon":
            return []
    except Exception:
        return []
    area = P.area
    if area < 10.0:
        return []
    mrr = P.minimum_rotated_rectangle
    if mrr.geom_type != "Polygon":
        return []
    c = np.array(mrr.exterior.coords)[:4]
    e0, e1 = c[1] - c[0], c[2] - c[1]
    l0, l1 = float(np.linalg.norm(e0)), float(np.linalg.norm(e1))
    e = e0 if l0 >= l1 else e1
    ang0 = math.atan2(e[1], e[0])
    ring = np.array(P.exterior.coords)[:-1]

    def pack(ang, rects):
        u = np.array([math.cos(ang), math.sin(ang)])
        v = np.array([-u[1], u[0]])
        yaw = math.atan2(-u[1], u[0])
        out = []
        for (cu, cv, w, d) in rects:
            p = u * cu + v * cv
            out.append((float(p[0]), float(p[1]), float(w), float(d), yaw))
        return out

    U = ring @ np.array([math.cos(ang0), math.sin(ang0)])
    V = ring @ np.array([-math.sin(ang0), math.cos(ang0)])
    lu, lv = U.max() - U.min(), V.max() - V.min()
    whole = pack(ang0, [((U.max() + U.min()) / 2, (V.max() + V.min()) / 2, lu, lv)])
    fill = area / max(lu * lv, 1e-6)
    if fill >= fill_ok or area < 60.0 or min(lu, lv) < 4.0:
        return whole

    k_max = int(min(max(3 + area / 350.0, 3), 16))
    cands = [ang0]
    d = np.diff(np.vstack([ring, ring[:1]]), axis=0)
    ln = np.hypot(d[:, 0], d[:, 1])
    ang1 = math.atan2(d[ln.argmax(), 1], d[ln.argmax(), 0])
    diff = abs((ang1 - ang0 + math.pi / 2) % math.pi - math.pi / 2)
    if diff > math.radians(4.0):
        cands.append(ang1)
    best = None
    for ang in cands:
        rects, cov = _greedy(ring, ang, area, k_max)
        if not rects:
            continue
        score = cov - 0.012 * len(rects)
        if best is None or score > best[0]:
            best = (score, ang, rects, cov)
    if best is None or best[3] < 0.55:
        return whole
    return pack(best[1], best[2])


def rect_corners(r):
    cx, cz, w, d, yaw = r
    c, s = math.cos(yaw), math.sin(yaw)
    ax = np.array([c, -s])
    az = np.array([s, c])
    ctr = np.array([cx, cz])
    return np.array([ctr - ax * w / 2 - az * d / 2, ctr + ax * w / 2 - az * d / 2,
                     ctr + ax * w / 2 + az * d / 2, ctr - ax * w / 2 + az * d / 2])


if __name__ == "__main__":
    # contrôle de la convention de lacet : un rectangle tourné doit se retrouver à l'identique
    for ang in (0.0, 0.5, 1.2, -0.7):
        r0 = (10.0, -5.0, 30.0, 12.0, ang)
        pts = rect_corners(r0)
        out = decompose(pts)
        assert len(out) == 1, out
        back = rect_corners(out[0])
        err = max(min(np.linalg.norm(back - p, axis=1)) for p in pts)
        print("lacet", ang, "->", round(out[0][4], 3), "w,d", round(out[0][2], 2), round(out[0][3], 2), "écart max", round(float(err), 6))
    L = np.array([[0, 0], [40, 0], [40, 12], [12, 12], [12, 30], [0, 30]], float)
    print("L:", [tuple(round(x, 1) for x in r) for r in decompose(L)])
    T = np.array([[0, 0], [40, 0], [20, 30]], float)
    print("triangle:", len(decompose(T)), "rectangles")
