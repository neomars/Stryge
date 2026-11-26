"""Réseau de rues d'un secteur.

Deux sources :
  - OpenStreetMap (osm.py) là où le fichier source couvre le secteur : tracés réels, classes, ponts ;
  - à défaut (Stade de France, pourtour de La Défense), le réseau est déduit des vides entre les bâtiments
    réels (squelette de l'espace libre) : voir voids.py.
Dans les deux cas la largeur de chaussée est recalée sur la distance réelle entre façades, mesurée sur
les rectangles de bâtiments du jeu, pour que la chaussée remplisse la rue sans déborder.
"""
import math

import cv2
import numpy as np
from scipy import ndimage
from scipy.spatial import cKDTree
from shapely import STRtree
from shapely.geometry import LineString, MultiLineString, Point, box
from shapely.ops import substring

SIDEWALK = 3.0           # trottoir de chaque côté, ajouté par le moteur de rendu à la largeur de chaussée
RES = 1.0                # résolution de la grille d'obstacles (m)

# classes OSM (osm.py) -> (largeur mini, largeur maxi) de chaussée en mètres
CLS_LIMITS = {0: (7.0, 36.0), 1: (6.0, 30.0), 2: (5.0, 24.0), 3: (3.8, 16.0), 4: (3.0, 12.0), 5: (1.6, 3.0)}


# ---------------------------------------------------------------- grille d'obstacles

class Grid:
    """Grille d'obstacles (bâtiments, eau) autour du secteur, avec distance à l'obstacle le plus proche."""

    def __init__(self, frame, rects, water_polys=(), res=RES):
        self.res = res
        self.lim = frame.half + frame.margin + 40.0
        self.n = int(math.ceil(2 * self.lim / res))
        self.img = np.zeros((self.n, self.n), np.uint8)
        polys = []
        for (cx, cz, w, d, yaw) in rects:
            c, s = math.cos(yaw), math.sin(yaw)
            ax = np.array([c, -s]) * w / 2
            az = np.array([s, c]) * d / 2
            ctr = np.array([cx, cz])
            pts = np.array([ctr - ax - az, ctr + ax - az, ctr + ax + az, ctr - ax + az])
            polys.append(self.to_px(pts))
        if polys:
            cv2.fillPoly(self.img, polys, 1)
        self.bld = self.img.copy()
        self.water = np.zeros_like(self.img)
        for poly in water_polys:
            for g in getattr(poly, "geoms", [poly]):
                if g.is_empty:
                    continue
                cv2.fillPoly(self.water, [self.to_px(np.array(g.exterior.coords))], 1)
                for hole in g.interiors:
                    cv2.fillPoly(self.water, [self.to_px(np.array(hole.coords))], 0)
        self.img |= self.water
        self._edt = None

    def to_px(self, pts):
        q = (np.asarray(pts, np.float64) + self.lim) / self.res
        return np.round(q).astype(np.int32).reshape(-1, 1, 2)

    @property
    def edt(self):
        """Distance (m) à l'obstacle le plus proche (0 sur les obstacles)."""
        if self._edt is None:
            self._edt = ndimage.distance_transform_edt(self.img == 0).astype(np.float32) * self.res
        return self._edt

    def sample(self, arr, p):
        i = np.clip(np.round((np.asarray(p, np.float64) + self.lim) / self.res).astype(int), 0, self.n - 1)
        return arr[i[..., 1], i[..., 0]]


# ---------------------------------------------------------------- tracés OSM -> morceaux

def osm_pieces(osm_streets, frame, lim=None, keep_paths=True):
    """Polylignes OSM découpées à la fenêtre du secteur : liste de dict(pts (n,2) local, width, cls, bridge)."""
    lim = lim if lim is not None else frame.half
    win = box(-lim, -lim, lim, lim)
    out = []
    for s in osm_streets:
        p = frame.local(s["pts"])
        if p[:, 0].max() < -lim or p[:, 0].min() > lim or p[:, 1].max() < -lim or p[:, 1].min() > lim:
            continue
        g = LineString(p).intersection(win)
        parts = [g] if g.geom_type == "LineString" else list(getattr(g, "geoms", []))
        for q in parts:
            if q.geom_type != "LineString" or q.length < 2.0:
                continue
            out.append({"pts": np.array(q.coords), "width": s["width"], "cls": s["cls"], "bridge": s["bridge"]})
    return out


def _forced_points(lines, snap=1.6):
    """Prolonge les extrémités qui frôlent une autre ligne (jonctions en T non fermées) : points de coupure forcés."""
    tree = STRtree(lines)
    force = {i: [] for i in range(len(lines))}
    ext = {}
    for i, ln in enumerate(lines):
        for end, pt in ((0, Point(ln.coords[0])), (1, Point(ln.coords[-1]))):
            cand = [j for j in tree.query(pt.buffer(snap)) if j != i]
            if not cand:
                continue
            dists = [(lines[j].distance(pt), j) for j in cand]
            d, j = min(dists)
            if d <= 1e-6:
                continue
            if d <= snap:
                q = lines[j].interpolate(lines[j].project(pt))
                force[j].append(lines[j].project(pt))
                ext.setdefault(i, []).append((end, (q.x, q.y)))
    return force, ext


def _points_of(geom):
    """Points remarquables d'une intersection : points isolés, extrémités des segments communs."""
    out = []
    if geom.is_empty:
        return out
    if geom.geom_type == "Point":
        out.append(geom)
    elif geom.geom_type == "LineString":
        out += [Point(geom.coords[0]), Point(geom.coords[-1])]
    elif hasattr(geom, "geoms"):
        for g in geom.geoms:
            out += _points_of(g)
    return out


def build_graph(pieces, node_merge=2.5, snap_bridge=7.0):
    """Découpe les tracés à leurs intersections et retourne (nodes (n,2), edges [(a, b, width, cls, bridge)]).

    Les ponts ne sont pas « nodés » avec les voies qu'ils enjambent : seules leurs extrémités sont raccordées.
    """
    flat = [p for p in pieces if not p["bridge"]]
    brid = [p for p in pieces if p["bridge"]]
    if not pieces:
        return np.zeros((0, 2)), []
    lines = [LineString(p["pts"]) for p in flat]
    force, ext = _forced_points(lines) if lines else ({}, {})
    for i, lst in ext.items():
        c = list(lines[i].coords)
        for end, q in lst:
            if end == 0:
                c.insert(0, q)
            else:
                c.append(q)
        lines[i] = LineString(c)
    splits = {i: set(force.get(i, [])) for i in range(len(lines))}
    pairs = STRtree(lines).query(np.array(lines, dtype=object), predicate="intersects") if lines else np.zeros((2, 0), int)
    for a, b in zip(pairs[0].tolist(), pairs[1].tolist()):
        if a >= b:
            continue
        pts = _points_of(lines[a].intersection(lines[b]))
        for q in pts:
            splits[a].add(lines[a].project(q))
            splits[b].add(lines[b].project(q))
    segs = []   # (coords, attrs)
    for i, ln in enumerate(lines):
        cuts = sorted(set([0.0, ln.length] + [d for d in splits[i] if 0.05 < d < ln.length - 0.05]))
        for d0, d1 in zip(cuts[:-1], cuts[1:]):
            if d1 - d0 < 0.05:
                continue
            s = substring(ln, d0, d1)
            if s.geom_type == "LineString" and len(s.coords) >= 2:
                segs.append((np.array(s.coords), flat[i]))

    # ponts : leurs extrémités s'accrochent au réseau (nœud ou tronçon le plus proche)
    seg_lines = [LineString(c) for c, _ in segs]
    stree = STRtree(seg_lines) if seg_lines else None
    for b in brid:
        c = [tuple(x) for x in b["pts"]]
        extra = []
        for end in (0, -1):
            pt = Point(c[end])
            if stree is None:
                continue
            cand = stree.query(pt.buffer(snap_bridge))
            if len(cand) == 0:
                continue
            d, j = min((seg_lines[j].distance(pt), j) for j in cand)
            q = seg_lines[j].interpolate(seg_lines[j].project(pt))
            extra.append((end, (q.x, q.y), j))
        for end, q, j in extra:
            if end == 0:
                c.insert(0, q)
            else:
                c.append(q)
        segs.append((np.array(c), b))
        # coupe aussi le tronçon visé au point de raccord
        for end, q, j in extra:
            ln = seg_lines[j]
            d = ln.project(Point(q))
            if 0.5 < d < ln.length - 0.5:
                s1, s2 = substring(ln, 0, d), substring(ln, d, ln.length)
                a = segs[j]
                segs[j] = (np.array(s1.coords), a[1])
                segs.append((np.array(s2.coords), a[1]))
                seg_lines[j] = s1
                seg_lines.append(s2)
                stree = STRtree(seg_lines)

    # nœuds : fusion des extrémités proches
    ends = []
    for c, _ in segs:
        ends.append(c[0])
        ends.append(c[-1])
    ends = np.array(ends)
    parent = list(range(len(ends)))

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x
    if len(ends):
        for i, j in cKDTree(ends).query_pairs(node_merge):
            ri, rj = find(i), find(j)
            if ri != rj:
                parent[ri] = rj
    groups = {}
    for i in range(len(ends)):
        groups.setdefault(find(i), []).append(i)
    node_of = {}
    nodes = []
    for r, mem in groups.items():
        for m in mem:
            node_of[m] = len(nodes)
        nodes.append(ends[mem].mean(axis=0))
    nodes = np.array(nodes)
    edges = []
    for k, (c, at) in enumerate(segs):
        a, b = node_of[2 * k], node_of[2 * k + 1]
        c = c.copy()
        c[0], c[-1] = nodes[a], nodes[b]
        edges.append({"a": a, "b": b, "pts": c, "width": at["width"], "cls": at["cls"], "bridge": at["bridge"]})
    return nodes, edges


def straighten(nodes, edges, tol=2.0):
    """Remplace chaque tronçon courbe par une suite de segments droits (RDP) ; crée des nœuds aux sommets conservés."""
    nodes = [tuple(n) for n in nodes]
    out = []
    for e in edges:
        pts = e["pts"]
        if len(pts) > 2:
            keep = np.array(LineString(pts).simplify(tol, preserve_topology=False).coords)
        else:
            keep = pts
        if len(keep) < 2:
            continue
        ids = [e["a"]]
        for q in keep[1:-1]:
            nodes.append((float(q[0]), float(q[1])))
            ids.append(len(nodes) - 1)
        ids.append(e["b"])
        for u, v in zip(ids[:-1], ids[1:]):
            if u != v:
                out.append({"a": u, "b": v, "width": e["width"], "cls": e["cls"], "bridge": e["bridge"]})
    return np.array(nodes), out


def clean(nodes, edges, min_spur=18.0, min_component=250.0):
    """Supprime doublons, boucles, petites impasses et petits îlots déconnectés ; réindexe les nœuds."""
    best = {}
    for e in edges:
        if e["a"] == e["b"]:
            continue
        k = (min(e["a"], e["b"]), max(e["a"], e["b"]))
        if k not in best or e["width"] > best[k]["width"]:
            best[k] = e
    edges = list(best.values())

    def length(e):
        return float(np.hypot(*(nodes[e["a"]] - nodes[e["b"]])))

    for _ in range(3):
        deg = {}
        for e in edges:
            deg[e["a"]] = deg.get(e["a"], 0) + 1
            deg[e["b"]] = deg.get(e["b"], 0) + 1
        keep = []
        for e in edges:
            leaf = deg[e["a"]] == 1 or deg[e["b"]] == 1
            if leaf and not e["bridge"] and e["cls"] >= 2 and length(e) < min_spur:
                continue
            keep.append(e)
        if len(keep) == len(edges):
            break
        edges = keep

    # composantes connexes
    par = {}

    def find(x):
        par.setdefault(x, x)
        while par[x] != x:
            par[x] = par[par[x]]
            x = par[x]
        return x
    for e in edges:
        ra, rb = find(e["a"]), find(e["b"])
        if ra != rb:
            par[ra] = rb
    tot = {}
    for e in edges:
        r = find(e["a"])
        tot[r] = tot.get(r, 0.0) + length(e)
    if tot:
        biggest = max(tot.values())
        edges = [e for e in edges if tot[find(e["a"])] >= min(min_component, biggest)]
    used = sorted({e["a"] for e in edges} | {e["b"] for e in edges})
    remap = {o: i for i, o in enumerate(used)}
    nn = np.array([nodes[o] for o in used]) if used else np.zeros((0, 2))
    for e in edges:
        e["a"], e["b"] = remap[e["a"]], remap[e["b"]]
    return nn, edges


def refine_widths(nodes, edges, grid, step=4.0):
    """Largeur de chaussée = distance mesurée entre façades - 2 trottoirs, bornée par la classe de la voie."""
    edt = grid.edt
    for e in edges:
        lo, hi = CLS_LIMITS.get(e["cls"], (3.0, 12.0))
        w_osm = max(e["width"], lo * 0.8)
        pa, pb = nodes[e["a"]], nodes[e["b"]]
        n = max(int(np.hypot(*(pb - pa)) / step), 1)
        t = (np.arange(n) + 0.5) / n
        pts = pa[None, :] * (1 - t)[:, None] + pb[None, :] * t[:, None]
        if e["bridge"] or e["cls"] == 5:
            e["w"] = float(np.clip(w_osm, lo, hi))
            continue
        # mesure sur la grille « bâtiments seulement » + eau (les quais sont bornés par l'eau d'un côté)
        q = np.percentile(grid.sample(edt, pts), 30)
        w = 2.0 * float(q) - 2.0 * SIDEWALK
        e["w"] = float(np.clip(max(w, w_osm * 0.85), lo, hi))
    return edges


def pack(nodes, edges):
    """Format du jeu : nodes [[x, z]], edges [[a, b, largeur, classe, drapeaux]]."""
    cls_game = {0: 1, 1: 1, 2: 0, 3: 0, 4: 0, 5: 2}
    n = [[round(float(p[0]), 2), round(float(p[1]), 2)] for p in nodes]
    e = []
    for ed in edges:
        c = cls_game.get(ed["cls"], 0)
        if ed.get("w", 0) >= 22.0 and c == 0:
            c = 1
        e.append([int(ed["a"]), int(ed["b"]), round(float(ed["w"]), 1), c, 1 if ed["bridge"] else 0])
    return n, e
