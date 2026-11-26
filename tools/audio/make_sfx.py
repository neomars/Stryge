#!/usr/bin/env python3
"""Synthèse des bruitages de Stryge (numpy / scipy, aucun échantillon externe).

Usage :  python3 tools/audio/make_sfx.py [--out audio/sfx] [--check /tmp/dossier_de_controle]

Sons produits (tous entendus DEPUIS L'AVION : ni impacts, ni effondrements, l'appareil est trop haut) :
  - GAU-12 25 mm : rafale à 30 coups/s (1 800 cps/min) = départ + boucle d'1 s sans raccord, + fin de rafale ;
  - Bofors L60 40 mm : 3 variantes de coup isolé + claquement du chargeur automatique ;
  - Obusier M102 105 mm : 2 variantes de coup + éjection de la douille, chargement, verrou de culasse ;
  - sélecteur d'armes (3 variantes) et déclic à vide ;
  - ronronnement de 4 turbopropulseurs (boucle de 8 s) ;
  - fonds de radio (3 canaux) et clics d'émission / réception (8 kHz, comme les voix).
Les points de bouclage et les gains sont décrits dans audio/sfx/sfx.json.
"""
import argparse
import json
from pathlib import Path

import numpy as np

import dsp
from dsp import add_at, bp, damped_sines, decay_bands, hp, lp, normalize_peak, periodic_noise

SR = 44100          # armes
SR_ENG = 22050      # moteurs
SR_RADIO = 8000     # radio (même cadence que la banque de voix)
RATE_GAU = 30.0     # coups par seconde (1 800 cps/min dans data/weapons.json)


# ================================================================ GAU-12 25 mm

def gau_shot(rng, amp=1.0, pitch=1.0):
    """Un coup de GAU-12 perçu dans la cabine : poussée grave, souffle, claquement atténué, caisse qui résonne."""
    n = int(0.24 * SR)
    t = np.arange(n) / SR
    body = lp(rng.standard_normal(n), 1500, SR) * np.exp(-t / 0.011)
    crack = bp(rng.standard_normal(n), 1500, 6500, SR) * np.exp(-t / 0.0021)
    f = (52.0 + 46.0 * np.exp(-t / 0.010)) * pitch
    thump = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / 0.018)
    ring = damped_sines(n, SR, [(182 * pitch, 0.20, 0.045), (311 * pitch, 0.16, 0.040), (517 * pitch, 0.12, 0.030), (890 * pitch, 0.08, 0.025)], rng)
    x = 1.30 * body + 0.90 * crack + 0.55 * thump + ring
    k = int(0.0004 * SR)
    x[:k] *= np.linspace(0.0, 1.0, k)
    return x * amp


BARREL = [1.00, 0.90, 1.07, 0.95, 1.03]   # 5 canons : léger défaut d'égalité => grondement à 6 Hz


def render_gau(rng):
    period = SR / RATE_GAU
    # --- boucle : exactement 30 coups en 1 s, queues rebouclées => aucun raccord audible
    n_loop = SR
    loop = np.zeros(n_loop)
    for k in range(int(RATE_GAU)):
        jitter = rng.normal(0.0, 0.35e-3) * SR
        w = gau_shot(rng, BARREL[k % 5] * float(np.exp(rng.normal(0.0, 0.06))), 1.0 + rng.normal(0.0, 0.015))
        add_at(loop, w, k * period + jitter, circular=True)
    # --- départ : la cadence monte de 9 à 30 coups/s en ~0,35 s ; le dernier coup précède d'une période exacte
    #     le début de la boucle (les queues du dernier coup sont fournies par le rebouclage de la boucle)
    onsets = [0.0]
    while True:
        r = min(RATE_GAU, 9.0 + (RATE_GAU - 9.0) * onsets[-1] / 0.35)
        onsets.append(onsets[-1] + 1.0 / r)
        if r >= RATE_GAU - 1e-6:
            break
    t_end = onsets[-1] + 1.0 / RATE_GAU                      # début de la boucle
    intro = np.zeros(int(round(t_end * SR)))
    for i, o in enumerate(onsets):
        a = min(1.0, 0.55 + 0.45 * i / max(len(onsets) - 3, 1)) * BARREL[i % 5]
        add_at(intro, gau_shot(rng, a, 1.0 + rng.normal(0.0, 0.015)), o * SR)
    # lente montée du moteur d'entraînement des canons
    ti = np.arange(len(intro)) / SR
    intro += 0.05 * np.sin(2 * np.pi * np.cumsum(30.0 + 150.0 * (ti / t_end) ** 1.5) / SR) * np.linspace(0.2, 1.0, len(intro))
    # --- fin de rafale : les canons ralentissent, quelques coups espacés, la cabine résonne un instant
    tail = np.zeros(int(0.75 * SR))
    for o, a in [(0.0, 0.95), (0.042, 0.72), (0.092, 0.52), (0.150, 0.36), (0.220, 0.22), (0.305, 0.12)]:
        add_at(tail, gau_shot(rng, a, 1.0 + rng.normal(0.0, 0.015)), o * SR)
    tt = np.arange(len(tail)) / SR
    tail += 0.06 * np.sin(2 * np.pi * np.cumsum(150.0 * np.exp(-tt / 0.25) + 30.0) / SR) * np.exp(-tt / 0.28)
    tail = dsp.add_reverb(tail, rng, SR, 0.35, 0.22, 1400.0)[: len(tail)]
    # gain commun pour garder la cohérence des niveaux
    g = 0.80 / np.max(np.abs(loop))
    return intro * g, loop * g, tail * g * 0.95


# ================================================================ Bofors L60 40 mm

def bofors_shot(rng, tone=1.0):
    n = int(1.6 * SR)
    t = np.arange(n) / SR
    crack = bp(rng.standard_normal(n), 1100, 7000, SR) * np.exp(-t / 0.0035) * 1.0
    blast = decay_bands(rng, n, SR, [(0, 320, 0.20, 0.30), (320, 1100, 0.085, 1.30), (1100, 3500, 0.040, 0.90)])
    f = (40.0 + 85.0 * np.exp(-t / 0.030)) * tone
    thump = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / 0.115)
    clank = damped_sines(n, SR, [(1480 * tone, 0.20, 0.050), (2330 * tone, 0.14, 0.040), (3720 * tone, 0.08, 0.030)], rng, delay=0.034)
    rumble = lp(rng.standard_normal(n), 150, SR) * np.exp(-t / 0.33) * 0.20
    x = crack + blast + 0.55 * thump + clank + rumble
    k = int(0.0004 * SR)
    x[:k] *= np.linspace(0.0, 1.0, k)
    return dsp.add_reverb(x, rng, SR, 0.50, 0.24, 1500.0)


def bofors_clack(rng):
    """Chargeur automatique : « tchak-tchunk » mécanique entre deux coups (cadence 100 cps/min)."""
    n = int(0.22 * SR)
    t = np.arange(n) / SR
    a = bp(rng.standard_normal(n), 1800, 6000, SR) * np.exp(-t / 0.006) * 0.8
    a += damped_sines(n, SR, [(920, 0.5, 0.025), (1630, 0.45, 0.020), (2710, 0.30, 0.016)], rng)
    b = np.sin(2 * np.pi * 150 * t) * np.exp(-t / 0.030) * 0.8
    x = a + b
    y = np.zeros(n)
    add_at(y, x[: int(0.10 * SR)], 0)
    add_at(y, x[: int(0.12 * SR)] * 0.7, int(0.085 * SR))      # deuxième temps du mécanisme
    return y


# ================================================================ Obusier M102 105 mm

def m102_shot(rng, tone=1.0):
    n = int(2.9 * SR)
    t = np.arange(n) / SR
    crack = bp(rng.standard_normal(n), 500, 5000, SR) * np.exp(-t / 0.007) * 1.0
    f = (28.0 + 52.0 * np.exp(-t / 0.065)) * tone
    boom = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / 0.34)
    air = decay_bands(rng, n, SR, [(0, 260, 0.55, 0.65), (260, 800, 0.32, 1.30), (800, 2000, 0.18, 0.90), (2000, 5000, 0.08, 0.40)])
    rattle = damped_sines(n, SR, [(92 * tone, 0.28, 0.50), (138 * tone, 0.20, 0.45), (231 * tone, 0.14, 0.38), (412 * tone, 0.07, 0.28)], rng, delay=0.012)
    panel = bp(rng.standard_normal(n), 150, 900, SR) * np.exp(-t / 0.40) * (0.5 + 0.5 * np.sin(2 * np.pi * 23.0 * t + rng.uniform(0, 6.28))) * 0.18
    x = crack + 0.70 * boom + air + 1.4 * rattle + panel
    k = int(0.0006 * SR)
    x[:k] *= np.linspace(0.0, 1.0, k)
    return dsp.add_reverb(x, rng, SR, 1.0, 0.30, 1200.0)


def m102_eject(rng):
    """Douille de 105 mm éjectée : un coup de gong métallique et deux rebonds sur le plancher."""
    n = int(0.9 * SR)
    t = np.arange(n) / SR
    ring = damped_sines(n, SR, [(780, 0.6, 0.20), (1250, 0.45, 0.16), (2100, 0.30, 0.11), (3300, 0.18, 0.07)], rng)
    ring += bp(rng.standard_normal(n), 1500, 5500, SR) * np.exp(-t / 0.008) * 0.7
    y = np.zeros(n)
    add_at(y, ring, 0)
    add_at(y, ring[: int(0.5 * SR)] * 0.38, int(0.13 * SR))
    add_at(y, ring[: int(0.4 * SR)] * 0.16, int(0.23 * SR))
    return y


def m102_load(rng):
    """Chargement : glissement de l'obus sur le refouloir, puis choc sourd en fin de course."""
    n = int(0.9 * SR)
    t = np.arange(n) / SR
    slide = bp(rng.standard_normal(n), 300, 2200, SR) * np.clip(t / 0.05, 0, 1) * np.exp(-((t - 0.28) / 0.22) ** 2) * 0.55
    slide *= 0.6 + 0.4 * np.sin(2 * np.pi * 28 * t)
    thud = np.sin(2 * np.pi * 70 * t) * np.exp(-t / 0.06)
    hit = np.zeros(n)
    add_at(hit, thud[: int(0.3 * SR)] * 0.9, int(0.52 * SR))
    add_at(hit, damped_sines(int(0.4 * SR), SR, [(640, 0.4, 0.05), (1180, 0.3, 0.04)], rng), int(0.52 * SR))
    return slide + hit


def m102_latch(rng):
    """Culasse refermée : gros « ka-chunk » qui verrouille."""
    n = int(0.6 * SR)
    t = np.arange(n) / SR
    x = np.sin(2 * np.pi * 62 * t) * np.exp(-t / 0.09) * 1.0
    x += damped_sines(n, SR, [(1100, 0.5, 0.080), (2020, 0.35, 0.060), (3300, 0.2, 0.040)], rng)
    x += bp(rng.standard_normal(n), 900, 4500, SR) * np.exp(-t / 0.010) * 0.8
    y = np.zeros(n)
    add_at(y, x, 0)
    add_at(y, x * 0.35, int(0.075 * SR))
    return y


# ================================================================ sélecteur, déclic à vide

def selector(rng, variant):
    n = int(0.55 * SR)
    t = np.arange(n) / SR
    base = 380.0 + 70.0 * variant
    servo = np.sin(2 * np.pi * np.cumsum(base + 520.0 * np.clip(t / 0.22, 0, 1)) / SR) * np.clip(t / 0.03, 0, 1) * np.exp(-((t - 0.13) / 0.11) ** 2) * 0.10
    servo += np.sin(2 * np.pi * np.cumsum(0.5 * (base + 520.0 * np.clip(t / 0.22, 0, 1))) / SR) * np.exp(-((t - 0.13) / 0.11) ** 2) * 0.05
    click = bp(rng.standard_normal(n), 1400, 6000, SR) * np.exp(-t / 0.004) * 0.7
    click += damped_sines(n, SR, [(1900 + 140 * variant, 0.45, 0.015), (3100, 0.25, 0.010)], rng)
    thunk = np.sin(2 * np.pi * 105 * t) * np.exp(-t / 0.03) * 0.7
    y = servo + click + thunk
    add_at(y, (click + thunk)[: int(0.12 * SR)] * 0.55, int(0.255 * SR))   # fin de course
    return y


def dry_click(rng):
    n = int(0.12 * SR)
    t = np.arange(n) / SR
    x = bp(rng.standard_normal(n), 1700, 6500, SR) * np.exp(-t / 0.003) * 0.9
    x += damped_sines(n, SR, [(2400, 0.5, 0.010), (1300, 0.35, 0.012)], rng)
    x += np.sin(2 * np.pi * 120 * t) * np.exp(-t / 0.02) * 0.5
    return x


# ================================================================ moteurs

def engine_loop(rng):
    """4 turbopropulseurs : passage de pale ~68 Hz, battements lents entre moteurs, souffle et grondement de fuselage.
    Toutes les fréquences sont des multiples de 1/8 Hz : la boucle de 8 s se referme sans raccord."""
    n = SR_ENG * 8
    t = np.arange(n) / SR_ENG
    x = np.zeros(n)
    for fb in (68.0, 68.125, 67.875, 68.375):
        for h in range(1, 11):
            a = 1.0 / h ** 1.25
            x += a * np.sin(2 * np.pi * fb * h * t + rng.uniform(0, 2 * np.pi))
    x *= 0.34 / dsp.rms(x)
    whine = 0.012 * np.sin(2 * np.pi * 1480.0 * t + 1.0) + 0.009 * np.sin(2 * np.pi * 1496.0 * t + 2.0) \
        + 0.006 * np.sin(2 * np.pi * 2976.0 * t + 0.5)
    flow = periodic_noise(rng, n, SR_ENG, lambda f: np.where(f < 40, 0.0, 1.0 / np.sqrt(1.0 + (f / 700.0) ** 3)))
    rumble = periodic_noise(rng, n, SR_ENG, lambda f: np.where((f < 18) | (f > 160), 0.0, 1.0 / np.sqrt(1.0 + (f / 70.0) ** 4)))
    mod = 1.0 + 0.18 * np.sin(2 * np.pi * 0.375 * t + 0.7) + 0.08 * np.sin(2 * np.pi * 1.125 * t + 2.2)
    y = (x * mod + 0.15 * flow + 0.22 * rumble) + whine
    y -= np.mean(y)
    return y * (0.14 / dsp.rms(y))


# ================================================================ radio : fonds et clics (8 kHz)

def radio_beds(rng):
    n = SR_RADIO * 4
    t = np.arange(n) / SR_RADIO
    out = {}
    # Base : liaison lointaine, souffle large, QSB lent, grésillements et un sifflement qui dérive
    hiss = periodic_noise(rng, n, SR_RADIO, lambda f: np.where((f < 250) | (f > 3300), 0.0, 1.0))
    qsb = 1.0 + 0.30 * np.sin(2 * np.pi * 0.25 * t + 0.4) + 0.12 * np.sin(2 * np.pi * 0.75 * t + 1.9)
    crackle = np.zeros(n)
    for p in rng.integers(0, n, 26):
        add_at(crackle, rng.standard_normal(int(rng.uniform(0.001, 0.004) * SR_RADIO)) * rng.uniform(0.3, 1.0), p, circular=True)
    whistle = 0.10 * np.sin(2 * np.pi * np.cumsum(1100.0 + 40.0 * np.sin(2 * np.pi * 0.5 * t)) / SR_RADIO)
    b = 0.55 * hiss * qsb + 0.9 * bp(crackle, 400, 3200, SR_RADIO) + whistle * 0.5
    out["static_base"] = b
    # Avion : ronflement électrique 400 Hz de l'avion + souffle léger de l'interphone
    hum = sum(a * np.sin(2 * np.pi * 400.0 * h * t + h) for h, a in [(1, 1.0), (2, 0.45), (3, 0.28), (4, 0.10)])
    hiss2 = periodic_noise(rng, n, SR_RADIO, lambda f: np.where((f < 200) | (f > 2800), 0.0, 1.0 / np.sqrt(1.0 + (f / 1500.0) ** 2)))
    out["static_avion"] = 0.30 * hum + 0.38 * hiss2
    # Tireur : respiration dans le masque à oxygène (3 s par cycle), souffle étouffé, 400 Hz plus discret
    breath = 0.35 + 0.65 * np.clip(np.sin(2 * np.pi * t / 3.0 * 1.0 + 0.3), 0, 1) ** 2
    hiss3 = periodic_noise(rng, n, SR_RADIO, lambda f: np.where((f < 350) | (f > 2400), 0.0, 1.0))
    out["static_tireur"] = 0.50 * hiss3 * breath + 0.12 * hum
    for k in out:
        v = out[k]
        out[k] = v * (0.10 / dsp.rms(v))        # -20 dBFS : le jeu règle ensuite le niveau
    return out


def radio_clicks(rng):
    out = {}
    sr = SR_RADIO

    def squelch(length, lo, hi, tau, level):
        n = int(length * sr)
        t = np.arange(n) / sr
        return bp(rng.standard_normal(n), lo, hi, sr) * np.exp(-t / tau) * level

    def tone(f, dur, level):
        n = int(dur * sr)
        t = np.arange(n) / sr
        return np.sin(2 * np.pi * f * t) * np.minimum(np.minimum(t / 0.004, 1.0), (dur - t) / 0.006) * level

    # Base : ouverture du squelch « tchk » puis, à la fin, queue de bruit « kshh » et bip de courtoisie
    on = squelch(0.09, 500, 3300, 0.025, 0.9)
    on[:12] *= np.linspace(0, 1, 12)
    out["ptt_base_on"] = on
    off = np.concatenate([tone(1760.0, 0.07, 0.35), np.zeros(int(0.03 * sr)), squelch(0.26, 400, 3300, 0.075, 0.9)])
    out["ptt_base_off"] = off
    # Avion / tireur (interphone) : simples clics de manipulateur
    for who, f in (("avion", 1250.0), ("tireur", 900.0)):
        n = int(0.05 * sr)
        t = np.arange(n) / sr
        c = np.sin(2 * np.pi * f * t) * np.exp(-t / 0.006) * 0.8 + squelch(0.05, 600, 3200, 0.008, 0.6)[:n]
        out[f"ptt_{who}_on"] = c
        n2 = int(0.12 * sr)
        t2 = np.arange(n2) / sr
        c2 = np.sin(2 * np.pi * (f * 0.8) * t2) * np.exp(-t2 / 0.005) * 0.6 + squelch(0.12, 500, 3000, 0.03, 0.5)[:n2]
        out[f"ptt_{who}_off"] = c2
    for k in out:
        out[k] = normalize_peak(out[k], 0.35)
    return out


# ================================================================ programme principal

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    root = Path(__file__).resolve().parents[2]
    ap.add_argument("--out", default=str(root / "audio" / "sfx"))
    ap.add_argument("--seed", type=int, default=2026)
    ap.add_argument("--check", default="", help="dossier où écrire des spectrogrammes de contrôle (optionnel)")
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(a.seed)
    index = {}

    def save(name, x, sr, gain_db=0.0, **extra):
        x = np.asarray(x, dtype=np.float64)
        dsp.write_wav(out / f"{name}.wav", x, sr)
        index[name] = {"rate": int(sr), "samples": int(len(x)), "gain_db": gain_db, **extra}

    # --- GAU-12 : un seul fichier « départ + boucle » ; bouclage entre loop_begin et loop_end
    intro, loop, tail = render_gau(rng)
    save("gau_burst", np.concatenate([intro, loop]), SR, 0.0, loop_begin=int(len(intro)), loop_end=int(len(intro) + len(loop)))
    save("gau_tail", tail, SR, 0.0)

    # --- coups isolés (niveau relatif conservé entre armes : le 105 mm est le plus fort)
    shots = {}
    for i in range(3):
        shots[f"bofors_{i + 1}"] = bofors_shot(rng, 1.0 + (i - 1) * 0.05)
    for i in range(2):
        shots[f"m102_{i + 1}"] = m102_shot(rng, 1.0 + (i - 0.5) * 0.06)
    ref = max(np.max(np.abs(v)) for v in shots.values())
    for k, v in shots.items():
        gain = 0.86 if k.startswith("m102") else 0.72
        v = v / np.max(np.abs(v)) * gain
        save(k, v, SR, 0.0)
    for name, fn, lvl in (("bofors_clack", bofors_clack, 0.55), ("m102_eject", m102_eject, 0.45),
                          ("m102_load", m102_load, 0.45), ("m102_latch", m102_latch, 0.55), ("dry_click", dry_click, 0.40)):
        save(name, normalize_peak(fn(rng), lvl), SR, 0.0)
    for i in range(3):
        save(f"selector_{i + 1}", normalize_peak(selector(rng, i), 0.5), SR, 0.0)

    # --- ambiance
    save("engine_loop", engine_loop(rng), SR_ENG, 0.0, loop_begin=0, loop_end=SR_ENG * 8)

    # --- radio
    for k, v in radio_beds(rng).items():
        save(k, v, SR_RADIO, 0.0, loop_begin=0, loop_end=len(v))
    for k, v in radio_clicks(rng).items():
        save(k, v, SR_RADIO, 0.0)

    (out / "sfx.json").write_text(json.dumps(index, indent=1, ensure_ascii=False, sort_keys=True), encoding="utf-8")
    tot = sum(p.stat().st_size for p in out.glob("*.wav"))
    print(f"{len(index)} fichiers, {tot / 1e6:.2f} Mo -> {out}")

    if a.check:
        check(out, Path(a.check), index)


def check(out, chk, index):
    """Contrôles objectifs (je ne peux pas écouter) : niveaux, bouclage, spectrogrammes."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    chk.mkdir(parents=True, exist_ok=True)
    print("--- niveaux (crête / RMS actif, dBFS) ---")
    for name in sorted(index):
        x, sr = dsp.read_wav(out / f"{name}.wav")
        print(f"{name:16s} {len(x) / sr:6.2f} s  crête {dsp.db(np.max(np.abs(x))):6.1f}  rms {dsp.db(dsp.active_rms(x, sr)):6.1f}")
    # raccord des boucles : écart entre la fin du segment bouclé et son début, comparé au pas moyen du signal
    print("--- boucles ---")
    for name in ("gau_burst", "engine_loop", "static_base", "static_avion", "static_tireur"):
        x, sr = dsp.read_wav(out / f"{name}.wav")
        b, e = index[name]["loop_begin"], index[name]["loop_end"]
        seg = x[b:e]
        jump = abs(seg[0] - seg[-1])
        step = np.mean(np.abs(np.diff(seg)))
        print(f"{name:14s} saut au raccord {jump:.5f}  pas moyen {step:.5f}  rapport {jump / (step + 1e-12):.2f}")
    for name, rng_t in (("gau_burst", (0.0, 1.3)), ("bofors_1", (0.0, 1.0)), ("m102_1", (0.0, 2.5)), ("engine_loop", (0.0, 8.0)),
                        ("selector_1", (0, 0.5)), ("m102_eject", (0, 0.8))):
        x, sr = dsp.read_wav(out / f"{name}.wav")
        fig, ax = plt.subplots(2, 1, figsize=(9, 5), gridspec_kw={"height_ratios": [1, 2]})
        t = np.arange(len(x)) / sr
        ax[0].plot(t, x, lw=0.4)
        ax[0].set_xlim(*rng_t)
        ax[0].set_title(name)
        ax[1].specgram(x, NFFT=1024, Fs=sr, noverlap=768, cmap="magma", vmin=-110)
        ax[1].set_ylim(0, 6000 if sr > 20000 else sr / 2)
        ax[1].set_xlim(*rng_t)
        fig.tight_layout()
        fig.savefig(chk / f"sfx_{name}.png", dpi=80)
        plt.close(fig)


if __name__ == "__main__":
    main()
