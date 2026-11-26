#!/usr/bin/env python3
"""Aperçu à plat d'un secteur extrait de la BD TOPO (bâtiments colorés par hauteur, eau en bleu).

    python3 preview.py <paris.bin> <sortie.png> <lon> <lat> [taille_m=2400] [--px=1600]

Sert à vérifier un centre de secteur avant de lancer la conversion (make_city.py).
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from l93 import to_map  # noqa: E402
from prs import read_prs  # noqa: E402


def rings(layer, cx, cy, half):
    lens, hts, sol, xy = layer
    lens64 = lens.astype(np.int64)
    off = np.concatenate([[0], np.cumsum(lens64)]).astype(np.int64)
    mx = np.add.reduceat(xy[:, 0].astype(np.float64), off[:-1]) / lens
    my = np.add.reduceat(xy[:, 1].astype(np.float64), off[:-1]) / lens
    pad = 200.0
    keep = np.nonzero((np.abs(mx - cx) < half + pad) & (np.abs(my - cy) < half + pad))[0]
    out = []
    for i in keep:
        p = xy[off[i]:off[i + 1]].astype(np.float64)
        out.append((p, float(hts[i]) if hts is not None else 0.0))
    return out


def main() -> None:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    px = 1600
    for a in sys.argv[1:]:
        if a.startswith("--px="):
            px = int(a[5:])
    src, dst, lon, lat = args[0], args[1], float(args[2]), float(args[3])
    size = float(args[4]) if len(args) > 4 else 2400.0
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.collections import PolyCollection

    head, layers, _ = read_prs(src)
    cx, cy = to_map(lon, lat)
    half = size / 2.0
    fig = plt.figure(figsize=(px / 100.0, px / 100.0), dpi=100)
    ax = fig.add_axes([0, 0, 1, 1])
    ax.set_facecolor("#10131a")
    water = rings(layers["eau"], cx, cy, half + 3000)
    ax.add_collection(PolyCollection([p for p, _ in water], facecolors="#1d3b66", edgecolors="none"))
    for name in ("batiments", "monuments"):
        rs = rings(layers[name], cx, cy, half)
        hs = np.array([h for _, h in rs])
        cols = plt.cm.inferno(np.clip(hs / 60.0, 0, 1) * 0.85 + 0.1)
        ax.add_collection(PolyCollection([p for p, _ in rs], facecolors=cols, edgecolors="none"))
        print(name, len(rs), "polygones")
    ax.set_xlim(cx - half, cx + half)
    ax.set_ylim(cy - half, cy + half)
    ax.set_aspect("equal")
    ax.set_xticks([])
    ax.set_yticks([])
    fig.savefig(dst)
    print("écrit", dst)


if __name__ == "__main__":
    main()
