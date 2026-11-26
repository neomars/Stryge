"""Aperçu à plat d'une ville au format pnc-city-2 (même rendu que le moteur : trottoirs, chaussées, eau, parcs, immeubles)."""
import json
import math
import sys

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.collections import PatchCollection
from matplotlib.patches import Polygon as MP, Rectangle


def _corners(cx, cz, w, d, yaw):
    c, s = math.cos(yaw), math.sin(yaw)
    ax = np.array([c, -s]) * w / 2
    az = np.array([s, c]) * d / 2
    p = np.array([cx, cz])
    return np.array([p - ax - az, p + ax - az, p + ax + az, p - ax + az])


def render(doc, path, view=(-1200, 1200, -1200, 1200), dpi=100, size=12, labels=True):
    x0, x1, z0, z1 = view
    fig, ax = plt.subplots(figsize=(size, size))
    ax.set_xlim(x0, x1)
    ax.set_ylim(z1, z0)
    ax.set_aspect("equal")
    ax.set_xticks([])
    ax.set_yticks([])
    ax.set_facecolor("#262626")
    mesh = doc.get("mesh", {})
    for kind, col in (("water", "#27506f"), ("park", "#2f5a32")):
        m = mesh.get(kind)
        if not m:
            continue
        v = np.array(m["v"]).reshape(-1, 2)
        t = np.array(m["i"]).reshape(-1, 3)
        ax.add_collection(PatchCollection([MP(v[tri], closed=True) for tri in t], facecolor=col, edgecolor=col, linewidth=0.3, zorder=1 if kind == "water" else 1.5))
    nodes = np.array(doc["nodes"])
    edges = doc["edges"]
    hw = np.zeros(len(nodes))
    for e in edges:
        hw[e[0]] = max(hw[e[0]], e[2] / 2)
        hw[e[1]] = max(hw[e[1]], e[2] / 2)

    def strip(a, b, half, ea, eb):
        d = b - a
        l = np.hypot(*d)
        if l < 1e-6:
            return None
        d = d / l
        n = np.array([-d[1], d[0]]) * half
        a2, b2 = a - d * ea, b + d * eb
        return np.array([a2 - n, b2 - n, b2 + n, a2 + n])
    side, road, path_ = [], [], []
    for e in edges:
        a, b = nodes[e[0]], nodes[e[1]]
        if e[3] == 2:
            s = strip(a, b, e[2] / 2, 0, 0)
            if s is not None:
                path_.append(MP(s, closed=True))
            continue
        s = strip(a, b, e[2] / 2 + 3, hw[e[0]] + 3, hw[e[1]] + 3)
        if s is not None:
            side.append(MP(s, closed=True))
        r = strip(a, b, e[2] / 2, hw[e[0]], hw[e[1]])
        if r is not None:
            road.append(MP(r, closed=True))
    ax.add_collection(PatchCollection(side, facecolor="#4a4a4a", edgecolor="none", zorder=2))
    ax.add_collection(PatchCollection(road, facecolor="#7a7a7a", edgecolor="none", zorder=3))
    ax.add_collection(PatchCollection(path_, facecolor="#7a7a7a", edgecolor="none", zorder=3))
    polys, cols = [], []
    for b in doc["buildings"]:
        if not (x0 - 80 < b[0] < x1 + 80 and z0 - 80 < b[1] < z1 + 80):
            continue
        polys.append(MP(_corners(*b[:5]), closed=True))
        occ = b[6]
        cols.append("#e8e8e8" if occ >= 20 else ("#c8c8c8" if occ > 0 else "#9a9a9a"))
    ax.add_collection(PatchCollection(polys, facecolor=cols, edgecolor="#3a3a3a", linewidth=0.15, zorder=4))
    for a in doc["areas"]:
        if a[0] == "evac":
            ax.add_patch(Rectangle((a[1], a[2]), a[3] - a[1], a[4] - a[2], facecolor="#3ad07a", edgecolor="none", alpha=0.85, zorder=5))
        elif a[0] == "metro":
            ax.add_patch(Rectangle((a[1] - 6, a[2] - 6), a[3] - a[1] + 12, a[4] - a[2] + 12, facecolor="#4fd8ff", edgecolor="none", zorder=5))
    if labels:
        for p in doc.get("places", []):
            ax.text(p["x"], p["z"], p["n"], color="#ffd84a", fontsize=8, ha="center", va="center", zorder=9,
                    bbox=dict(boxstyle="round,pad=0.15", fc="#000000", ec="none", alpha=0.6))
    plt.tight_layout(pad=0.2)
    plt.savefig(path, dpi=dpi)
    plt.close(fig)


if __name__ == "__main__":
    doc = json.load(open(sys.argv[1], encoding="utf-8"))
    view = tuple(float(v) for v in sys.argv[3:7]) if len(sys.argv) >= 7 else (-1200, 1200, -1200, 1200)
    render(doc, sys.argv[2], view)
