"""Conversion longitude/latitude (WGS84) <-> Lambert-93 (m), formules de l'IGN (GRS80), sans dépendance."""
import math

E = 0.0818191910428158      # première excentricité de GRS80
N = 0.7256077650532670      # exposant de la projection
C = 11754255.426096         # constante de la projection (m)
XS, YS = 700000.0, 12655612.049876
LON0 = 3.0 * math.pi / 180.0

# Centre des fichiers de Paris de l'IGN extraits par le dépôt source : coordonnées relatives à ce point
CENTRE = (652000.0, 6862000.0)


def _lat_iso(phi: float) -> float:
    s = math.sin(phi)
    return math.log(math.tan(math.pi / 4 + phi / 2) * ((1 - E * s) / (1 + E * s)) ** (E / 2))


def to_l93(lon: float, lat: float):
    """(longitude, latitude) en degrés -> (x, y) Lambert-93 en mètres"""
    r = C * math.exp(-N * _lat_iso(math.radians(lat)))
    g = N * (math.radians(lon) - LON0)
    return XS + r * math.sin(g), YS - r * math.cos(g)


def from_l93(x: float, y: float):
    """(x, y) Lambert-93 -> (longitude, latitude) en degrés"""
    dx, dy = x - XS, y - YS
    r, g = math.hypot(dx, dy), math.atan2(dx, -dy)
    lg = -math.log(r / C) / N
    phi = 2 * math.atan(math.exp(lg)) - math.pi / 2
    for _ in range(12):
        s = math.sin(phi)
        nxt = 2 * math.atan(((1 + E * s) / (1 - E * s)) ** (E / 2) * math.exp(lg)) - math.pi / 2
        if abs(nxt - phi) < 1e-13:
            phi = nxt
            break
        phi = nxt
    return math.degrees(LON0 + g / N), math.degrees(phi)


def to_map(lon: float, lat: float):
    """(lon, lat) -> coordonnées de la carte du dépôt source (m, relatives à CENTRE)"""
    x, y = to_l93(lon, lat)
    return x - CENTRE[0], y - CENTRE[1]


if __name__ == "__main__":
    # contrôle : la Tour Eiffel du dépôt source est en (-3781, 257)
    print([round(v) for v in to_map(2.29451, 48.85826)])
    print([round(v, 5) for v in from_l93(648219, 6862257)])
