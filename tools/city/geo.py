"""Secteurs de jeu et repère local.

Repère local d'un secteur (celui du jeu) : origine au centre du secteur, x vers l'est, z vers le sud (le nord est donc
vers -z), en mètres.  Les données sources sont en mètres Lambert-93 relatifs au centre des fichiers IGN (est, nord).
"""
import numpy as np

from l93 import to_map

SIZE = 2400.0       # côté d'un secteur (m), comme les villes générées
MARGIN = 80.0       # on garde un peu de décor au-delà du secteur pour que le bord ne soit pas coupé net

# Centres choisis pour que chaque secteur contienne ses repères les plus reconnaissables.
SECTORS = {
    "quartier_latin": {"name": "Quartier latin", "lonlat": (2.3480, 48.8510), "mission": "mission_01"},
    "montmartre": {"name": "Montmartre", "lonlat": (2.3420, 48.8860), "mission": "mission_02"},
    "halles": {"name": "Les Halles", "lonlat": (2.3470, 48.8670), "mission": "mission_03"},
    "defense": {"name": "La Défense", "lonlat": (2.2380, 48.8920), "mission": "mission_04"},
    "stade": {"name": "Stade de France", "lonlat": (2.3601, 48.9245), "mission": "mission_05"},
}


class Frame:
    def __init__(self, lonlat, size=SIZE, margin=MARGIN):
        self.lon, self.lat = lonlat
        self.cx, self.cy = to_map(self.lon, self.lat)
        self.size = size
        self.half = size / 2.0
        self.margin = margin
        self.ext = self.half + margin

    def local(self, xy):
        """(n,2) [est, nord] relatifs au centre IGN -> (n,2) [x est, z sud] relatifs au centre du secteur."""
        xy = np.asarray(xy, dtype=np.float64)
        return np.column_stack([xy[:, 0] - self.cx, -(xy[:, 1] - self.cy)])

    def local_lonlat(self, lon, lat):
        x, y = to_map(lon, lat)
        return x - self.cx, -(y - self.cy)

    def inside(self, p, margin=0.0):
        lim = self.half + margin
        return abs(p[0]) <= lim and abs(p[1]) <= lim
