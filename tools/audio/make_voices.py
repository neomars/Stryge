#!/usr/bin/env python3
"""Banque de voix radio de Stryge : synthèse vocale française + effets « radio d'avion ».

Usage :  python3 tools/audio/make_voices.py [--models DOSSIER] [--out audio/radio] [--check DOSSIER_DE_CONTROLE] [--reuse]

--reuse : la synthèse étant déterministe (une phrase donne toujours le même son), on peut ne synthétiser que les phrases
absentes de la banque déjà présente dans --out. À éviter après un changement de voix, de profils d'effets ou de réglages.

1. lit data/radio_script.json (toutes les répliques des trois intervenants : station directrice « Lutèce »,
   radio de l'avion « Nocturne 2-1 », « Tireur ») et en déduit la liste des phrases courtes (« atomes »),
   y compris les valeurs de distance, de direction et d'effectif ;
2. synthétise chaque atome avec Piper (voix françaises « siwis » CC-BY 4.0 et « gilles » CC0, téléchargées au besoin),
   de façon déterministe ; sur les phrases très courtes, Piper ajoute parfois un silence puis un marmonnement parasite :
   on essaie plusieurs prises, on garde la première dont la durée de parole est plausible et on coupe tout ce qui suit ;
3. rend les voix NON NATURELLES, comme sur une radio tactique chiffrée : changement de hauteur, vocodeur robotique,
   bande étroite, résonance de masque ou de haut-parleur, compression et saturation, peigne numérique, quantification,
   souffle, micro-coupures et craquements ;
4. écrit audio/radio/voices.wav (PCM 16 bits, 8 kHz) et audio/radio/voices.json (index clé -> [début, longueur]).
Le jeu assemble les phrases à l'exécution (scripts/core/radio.gd), sans jamais relire de fichier par phrase.
"""
import argparse
import json
import os
import re
import sys
import tarfile
import unicodedata
import urllib.request
import zlib
from pathlib import Path

import numpy as np
from scipy import signal

import dsp

RELEASE = "https://github.com/rhasspy/piper/releases/download/v0.0.2/"
MODELS = {"siwis": "fr-siwis-medium", "gilles": "fr-gilles-low"}
SR_WORK = 16000     # cadence interne de traitement
SR_OUT = 8000       # cadence de la banque (bande téléphonique)
TARGET_DB = -19.0   # niveau RMS actif de chaque phrase (le jeu règle ensuite le niveau de bus)

# Caractère de chaque radio. Valeurs choisies pour garder la voix compréhensible tout en la rendant « pas normale ».
PROFILES = {
    # Station directrice : liaison satellite lointaine, voix chiffrée très « codée »
    "base": dict(f0=172.0, wet=0.50, bands=22, hp=420, lp=2900, peak=(1700, 5.0, 1.2), comp=(-30.0, 6.0), drive=2.0, asym=0.10,
                 comb=(0.0024, 0.30), ring=None, wow=(0.0006, 2.3), bits=7, snr=27.0, drop=0.7, crackle=1.5),
    # Radio de l'avion : interphone de cockpit, voix médium nasillarde
    "avion": dict(f0=112.0, wet=0.40, bands=22, hp=330, lp=3100, peak=(1250, 6.0, 1.4), comp=(-30.0, 5.0), drive=2.6, asym=0.12,
                  comb=None, ring=None, wow=None, bits=8, snr=30.0, drop=0.25, crackle=0.8),
    # Tireur : voix grave, étouffée par le masque à oxygène, vibration de cellule
    "tireur": dict(f0=82.0, wet=0.32, bands=22, hp=220, lp=2500, peak=(650, 8.0, 1.1), comp=(-30.0, 5.0), drive=3.0, asym=0.15,
                   comb=(0.0007, 0.38), ring=(61.0, 0.20), wow=None, bits=8, snr=24.0, drop=0.12, crackle=0.5),
}


# ================================================================ nombres en toutes lettres

_U = ["zéro", "un", "deux", "trois", "quatre", "cinq", "six", "sept", "huit", "neuf", "dix", "onze", "douze", "treize",
      "quatorze", "quinze", "seize", "dix-sept", "dix-huit", "dix-neuf"]
_T = {2: "vingt", 3: "trente", 4: "quarante", 5: "cinquante", 6: "soixante"}


def fr_words(n):
    """Entier 0..9999 en français (orthographe soignée ; seule la prononciation compte pour la synthèse)."""
    if n < 20:
        return _U[n]
    if n < 70:
        t, u = divmod(n, 10)
        if u == 0:
            return _T[t]
        return _T[t] + (" et un" if u == 1 else "-" + _U[u])
    if n < 80:
        return "soixante" + (" et " if n == 71 else "-") + _U[n - 60]
    if n < 100:
        r = n - 80
        return "quatre-vingts" if r == 0 else "quatre-vingt-" + _U[r]
    if n < 1000:
        c, r = divmod(n, 100)
        head = "cent" if c == 1 else _U[c] + " cent" + ("s" if r == 0 else "")
        return head if r == 0 else head + " " + fr_words(r)
    m, r = divmod(n, 1000)
    head = "mille" if m == 1 else fr_words(m) + " mille"
    return head if r == 0 else head + " " + fr_words(r)


# ================================================================ script -> atomes

def slot_values(sl):
    if "values" in sl:
        return list(range(len(sl["values"])))
    lo, hi, st = sl["range"]
    return list(range(lo, hi + 1, st))


def slot_texts(name, sl, val):
    """(texte lu, texte affiché) pour la valeur val d'un slot."""
    if "values" in sl:
        v = sl["values"][val]
        return sl["tts"].replace("{v}", v), sl["text"].replace("{v}", v)
    if val == 1 and "one" in sl:
        return sl["one"]["tts"], sl["one"]["text"]
    return sl["tts"].replace("{w}", fr_words(val)), sl["text"].replace("{v}", str(val))


def collect_atoms(script):
    """Dictionnaire clé -> (intervenant, texte lu). Les clés sont celles que scripts/core/radio.gd reconstruit."""
    atoms = {}
    for ev in script["events"].values():
        for variant in ev["variants"]:
            for line in variant:
                who = line["who"]
                for a in line["say"]:
                    m = re.fullmatch(r"\{(\w+)\}", a)
                    if m:
                        name = m.group(1)
                        sl = script["slots"][name]
                        for val in slot_values(sl):
                            atoms[f"{who}|{{{name}}}={val}"] = (who, slot_texts(name, sl, val)[0])
                    else:
                        tts = a.split("|")[0]
                        atoms[f"{who}|{tts}"] = (who, tts)
    return atoms


# ================================================================ synthèse Piper

def find_model(models_dir, name):
    for cand in (models_dir / name, models_dir / f"voice-{name}"):
        onnx = cand / f"{name}.onnx"
        if onnx.exists():
            return onnx
    models_dir.mkdir(parents=True, exist_ok=True)
    url = f"{RELEASE}voice-{name}.tar.gz"
    tgz = models_dir / f"voice-{name}.tar.gz"
    print(f"téléchargement de {url} …", flush=True)
    urllib.request.urlretrieve(url, tgz)
    with tarfile.open(tgz) as t:
        t.extractall(models_dir / f"voice-{name}", filter="data")
    tgz.unlink()
    return models_dir / f"voice-{name}" / f"{name}.onnx"


class Synth:
    def __init__(self, models_dir):
        from piper import PiperVoice, SynthesisConfig
        self.SynthesisConfig = SynthesisConfig
        self.voices = {}
        for key, name in MODELS.items():
            onnx = find_model(models_dir, name)
            self.voices[key] = PiperVoice.load(str(onnx), config_path=str(onnx) + ".json")

    def say(self, voice, text, length_scale, seed, noise_scale=0.40):
        np.random.seed(seed)
        # noise_w_scale = 0 : durées déterministes (sinon les mots très courts partent parfois en marmonnement interminable)
        cfg = self.SynthesisConfig(length_scale=length_scale, noise_scale=noise_scale, noise_w_scale=0.0)
        parts, sr = [], None
        for ch in self.voices[voice].synthesize(text, syn_config=cfg):
            parts.append(ch.audio_float_array)
            parts.append(np.zeros(int(0.12 * ch.sample_rate)))
            sr = ch.sample_rate
        x = np.concatenate(parts[:-1]) if len(parts) > 1 else parts[0]
        return x.astype(np.float64), sr

    def n_phonemes(self, voice, text):
        """Nombre de phonèmes (sans accents toniques ni ponctuation) : sert à juger si une durée est plausible."""
        n = 0
        for sentence in self.voices[voice].phonemize(text):
            for p in "".join(sentence):
                if unicodedata.category(p).startswith("L") and p not in "ˈˌː":
                    n += 1
        return n


# ================================================================ effets

def vocoder(x, sr, f0, rng, nb, fmin=180.0, fmax=5200.0, noise_from=2600.0, env_hz=45.0, hiss=0.15):
    """Vocodeur à bandes : l'enveloppe de chaque bande de la voix module une porteuse monotone (dent de scie à f0,
    bruit pour les bandes aiguës) -> voix de robot / codec de radio chiffrée ; la hauteur naturelle disparaît."""
    n = len(x)
    drift = 1.0 + 0.012 * dsp.smooth(rng.standard_normal(n), sr, 0.08) * 6.0
    saw = 2.0 * ((np.cumsum(f0 * drift) / sr) % 1.0) - 1.0
    noise = rng.standard_normal(n)
    edges = np.geomspace(fmin, min(fmax, sr * 0.48), nb + 1)
    out = np.zeros(n)
    for k in range(nb):
        lo, hi = edges[k], edges[k + 1]
        sos = signal.butter(2, [lo, hi], "bandpass", fs=sr, output="sos")
        env = dsp.smooth(np.abs(signal.sosfilt(sos, x)), sr, 1.0 / (2.0 * np.pi * env_hz))
        car = noise if np.sqrt(lo * hi) > noise_from else saw * (1.0 - hiss) + noise * hiss
        cb = signal.sosfilt(sos, car)
        out += cb / (np.std(cb) + 1e-9) * env
    return out * (dsp.rms(x) / (dsp.rms(out) + 1e-12))


def comb(x, sr, delay, gain):
    d = max(int(round(delay * sr)), 1)
    y = x.copy()
    y[d:] += gain * x[:-d]
    return y / (1.0 + gain * 0.6)


def wow(x, sr, depth, rate, rng):
    t = np.arange(len(x)) / sr
    shift = depth * np.sin(2 * np.pi * rate * t + rng.uniform(0, 6.28))
    return np.interp(t + shift, t, x)


def dropouts(x, sr, rate_per_s, rng):
    """Micro-coupures de la liaison : 20-45 ms atténuées, jamais deux coups de suite, jamais sur les 12 premiers % ."""
    n = len(x)
    dur_s = n / sr
    k = rng.poisson(rate_per_s * dur_s)
    g = np.ones(n)
    last = -1.0
    for _ in range(min(int(k), 3)):
        d = rng.uniform(0.020, 0.045)
        t0 = rng.uniform(0.12 * dur_s, max(0.12 * dur_s + 1e-3, dur_s - d - 0.05))
        if t0 - last < 0.5:
            continue
        last = t0
        a, b = int(t0 * sr), int((t0 + d) * sr)
        g[a:b] = 0.06
        r = int(0.004 * sr)
        g[max(a - r, 0):a] = np.linspace(1.0, 0.06, a - max(a - r, 0))
        g[b:b + r] = np.linspace(0.06, 1.0, len(g[b:b + r]))
    return x * g


def crackles(x, sr, rate_per_s, rng, level):
    n = len(x)
    y = x.copy()
    for p in rng.integers(0, n, rng.poisson(rate_per_s * n / sr)):
        w = rng.standard_normal(int(rng.uniform(0.001, 0.004) * sr)) * rng.uniform(0.4, 1.0) * level
        k = min(len(w), n - p)
        y[p:p + k] += w[:k]
    return y


def process(x16, prof, rng, drops=True):
    """Chaîne d'effets complète à 16 kHz ; x16 = voix propre déjà recalée en hauteur (drops=False : pas de micro-coupures)."""
    x = dsp.hp(x16, 110, SR_WORK, 2)
    x = x / (dsp.rms(x) + 1e-12) * 0.1
    voc = vocoder(x, SR_WORK, prof["f0"], rng, prof["bands"])
    y = (1.0 - prof["wet"]) * x + prof["wet"] * voc
    y = dsp.hp(y, prof["hp"], SR_WORK, 2)
    y = dsp.lp(y, prof["lp"], SR_WORK, 4)
    f, g, q = prof["peak"]
    y = dsp.peaking(y, f, g, q, SR_WORK)
    if prof["comb"]:
        y = comb(y, SR_WORK, *prof["comb"])
    if prof["wow"]:
        y = wow(y, SR_WORK, prof["wow"][0], prof["wow"][1], rng)
    if prof["ring"]:
        rf, depth = prof["ring"]
        t = np.arange(len(y)) / SR_WORK
        y = y * (1.0 - depth + depth * np.sin(2 * np.pi * rf * t))
    y = dsp.compress(y, SR_WORK, prof["comp"][0], prof["comp"][1], 0.003, 0.06, makeup_db=12.0)
    y = dsp.soft_clip(y / (np.max(np.abs(y)) + 1e-9), prof["drive"], prof["asym"])
    y = dsp.bitcrush(y, prof["bits"], rng)
    # souffle de la liaison, calé sur le niveau actif de la voix
    act = dsp.active_rms(y, SR_WORK)
    nz = dsp.bp(rng.standard_normal(len(y)), 300, 3200, SR_WORK, 2)
    y = y + nz / (dsp.rms(nz) + 1e-12) * act * dsp.from_db(-prof["snr"])
    if drops:
        y = dropouts(y, SR_WORK, prof["drop"], rng)
    y = crackles(y, SR_WORK, prof["crackle"], rng, act * 0.9)
    y = dsp.hp(y, 260, SR_WORK, 2)
    return y


def active_runs(x, sr, floor_db=-34.0, frame=0.010):
    """Plages actives [début, fin[ en trames de 10 ms : la voix dépasse floor_db sous son maximum. Retourne (plages, trame)."""
    fr = int(frame * sr)
    m = len(x) // fr
    lv = np.sqrt(np.mean(x[: m * fr].reshape(m, fr) ** 2, axis=1) + 1e-18)
    act = lv > lv.max() * dsp.from_db(floor_db)
    runs, i = [], 0
    while i < m:
        if act[i]:
            j = i
            while j + 1 < m and act[j + 1]:
                j += 1
            runs.append([i, j + 1])
            i = j + 1
        else:
            i += 1
    return runs, fr


def speech_bounds(x, sr, gap_ok, pre=0.020, post=0.050):
    """Début et fin (indices) de la phrase parlée, mesurés sur la voix propre : on suit les plages actives tant que le
    silence qui les sépare reste <= gap_ok ; ce qui vient après (silence, puis marmonnement parasite que Piper ajoute
    parfois derrière un mot isolé) est écarté."""
    runs, fr = active_runs(x, sr)
    first, last = runs[0]
    for a, b in runs[1:]:
        if (a - last) * fr / sr > gap_ok:
            break
        last = b
    return max(int(first * fr - pre * sr), 0), min(int(last * fr + post * sr), len(x))


# Prises essayées, dans l'ordre, pour un texte court : (facteur de longueur, bruit, ponctuation finale forcée).
# Sur certains mots isolés (« J'engage. ») le point final déclenche le marmonnement, pas le point d'exclamation.
VARIANTS = [(1.00, 0.40, None), (1.00, 0.40, " !"), (1.12, 0.40, " !"), (0.90, 0.40, None), (1.00, 0.667, None)]
MARGINS_S = 0.070   # pre + post de speech_bounds


def plausible_speech(nph):
    """Durée (s) plausible de la parole pour nph phonèmes : mesurée sur la banque, médiane 0,085 s/phonème, p90 0,106."""
    return 0.045 * nph, 0.135 * nph + 0.15


def clean_take(synth, voice, text, base_ls, f, seed):
    """Synthétise un texte, en cherchant pour les phrases courtes une prise sans défaut. Retourne
    (voix propre 16 kHz, début, fin, numéro de prise, plausible, durée de parole écartée en s)."""
    nph = synth.n_phonemes(voice, text)
    short = nph <= 12
    gap_ok = (0.70 if "," in text else 0.25) if short else (0.80 if "," in text else 0.50)
    lo, hi = plausible_speech(nph)
    target = (lo * hi) ** 0.5
    best, tried = None, set()
    for k, (lsm, ns, punct) in enumerate(VARIANTS if short else VARIANTS[:1]):
        t = text if punct is None else text.rstrip(".!?…") + punct
        if (t, lsm, ns) in tried:
            continue
        tried.add((t, lsm, ns))
        raw, sr = synth.say(voice, t, base_ls * lsm, seed, ns)
        x16 = dsp.resample(raw, sr * f, SR_WORK)
        a, b = speech_bounds(dsp.hp(x16, 110, SR_WORK, 2), SR_WORK, gap_ok)
        dur = (b - a) / SR_WORK - MARGINS_S
        runs, fr = active_runs(dsp.hp(x16, 110, SR_WORK, 2), SR_WORK)
        spare = sum(r1 - r0 for r0, r1 in runs if r0 * fr >= b) * fr / SR_WORK
        if lo <= dur <= hi:
            return x16, a, b, k, True, spare
        off = abs(np.log(max(dur, 1e-3) / target))
        if best is None or off < best[0]:
            best = (off, x16, a, b, k, dur, spare)
    off, x16, a, b, k, dur, spare = best
    if dur > hi:                                   # aucune prise plausible : on coupe à la durée maximale
        b = min(a + int((hi + MARGINS_S) * SR_WORK), b)
    return x16, a, b, k, False, spare


def tighten(x, sr, max_pause=0.24, floor_db=-34.0):
    """Raccourcit à max_pause les silences internes plus longs (pause de virgule du modèle ≈ 0,45 s) : débit radio vif."""
    runs, fr = active_runs(x, sr, floor_db)
    pieces, start = [], 0
    for (a0, b0), (a1, b1) in zip(runs[:-1], runs[1:]):
        if (a1 - b0) * fr > max_pause * sr:
            keep = int(max_pause * sr)
            pieces.append(x[start:b0 * fr + keep // 2])
            start = a1 * fr - (keep - keep // 2)
    if not pieces:
        return x
    pieces.append(x[start:])
    n = int(0.004 * sr)
    return np.concatenate([dsp.fade_edges(p, n if i > 0 else 0, n if i < len(pieces) - 1 else 0) for i, p in enumerate(pieces)])


def fade_and_level(x, sr):
    y = dsp.fade_edges(x, int(0.006 * sr), int(0.015 * sr))
    y = y / (dsp.active_rms(y, sr) + 1e-12) * dsp.from_db(TARGET_DB)
    return 0.92 * np.tanh(y / 0.92)


# ================================================================ indicateur d'intelligibilité (type STOI simplifié)

def intel_proxy(ref, test, sr=SR_OUT):
    """Corrélation moyenne des enveloppes en bandes de tiers d'octave (250-3150 Hz) entre la voix propre et la voix traitée,
    sur des segments de 300 ms. 1 = identique ; au-dessus de ~0,75 la parole reste très intelligible."""
    n = min(len(ref), len(test))
    ref, test = ref[:n], test[:n]
    cs = [250, 315, 400, 500, 630, 800, 1000, 1250, 1600, 2000, 2500, 3150]
    step = int(sr / 100)
    corrs = []
    for c in cs:
        lo, hi = c / 2 ** (1 / 6), min(c * 2 ** (1 / 6), sr * 0.49)
        e = []
        for s in (ref, test):
            b = dsp.bp(s, lo, hi, sr, 2)
            e.append(dsp.lp(np.abs(b), 20.0, sr, 2)[::step])
        a, b = e
        L = 30
        for i in range(0, len(a) - L, 5):
            sa, sb = a[i:i + L], b[i:i + L]
            if sa.std() < 1e-6 or sb.std() < 1e-6:
                continue
            corrs.append(np.corrcoef(sa, sb)[0, 1])
    return float(np.mean(corrs)) if corrs else 0.0


# ================================================================ programme principal

def main():
    root = Path(__file__).resolve().parents[2]
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--script", default=str(root / "data" / "radio_script.json"))
    ap.add_argument("--out", default=str(root / "audio" / "radio"))
    ap.add_argument("--models", default=os.environ.get("PIPER_MODELS", str(root / "tools" / "audio" / "models")))
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--only", default="", help="ne traiter que les atomes contenant ce texte (mise au point)")
    ap.add_argument("--reuse", action="store_true", help="réutiliser les phrases déjà présentes dans la banque de sortie")
    ap.add_argument("--check", default="", help="dossier de contrôle (spectrogrammes, indicateurs)")
    a = ap.parse_args()

    script = json.loads(Path(a.script).read_text(encoding="utf-8"))
    atoms = collect_atoms(script)
    if a.only:
        atoms = {k: v for k, v in atoms.items() if a.only in k}
    print(f"{len(atoms)} phrases à synthétiser", flush=True)
    synth = Synth(Path(a.models))
    spk = script["speakers"]

    clips = {}
    clean_ref = {}
    stats = {}
    notes = []                                       # prises de remplacement, échecs, parasites écartés
    pad = int(0.12 * SR_WORK)
    kept = {}
    if a.reuse and (Path(a.out) / "voices.json").exists():
        from scipy.io import wavfile
        sr0, w0 = wavfile.read(str(Path(a.out) / "voices.wav"))
        idx0 = json.loads((Path(a.out) / "voices.json").read_text(encoding="utf-8"))["clips"]
        x0 = w0.astype(np.float64) / 32767.0          # même échelle que dsp.write_wav : aller-retour exact
        for k0, (p0, n0) in idx0.items():
            if k0 in atoms:
                kept[k0] = x0[p0:p0 + n0]
        print(f"{len(kept)} phrases reprises de la banque existante, {len(atoms) - len(kept)} à synthétiser", flush=True)
    for i, key in enumerate(sorted(atoms)):
        if key in kept:
            clips[key] = kept[key]
            continue
        who, text = atoms[key]
        cfg = spk[who]
        f = 2.0 ** (cfg["pitch_st"] / 12.0)
        seed = zlib.crc32(key.encode("utf-8")) & 0x7FFFFFFF
        x16, a0, b0, take, ok, spare = clean_take(synth, cfg["voice"], text, f / cfg["rate"], f, seed)
        if not ok:
            notes.append(f"  ÉCHEC   {key!r} : aucune prise plausible, coupée à la durée maximale")
        elif take > 0:
            notes.append(f"  prise {take}  {key!r}")
        if spare > 0.25:
            notes.append(f"  écarté {spare:4.1f} s de parasite après {key!r}")
        xc = tighten(dsp.hp(x16, 110, SR_WORK, 2)[a0:b0], SR_WORK)       # voix propre : phrase seule, pauses resserrées
        rng = np.random.default_rng(seed)
        y = process(np.concatenate([np.zeros(pad), xc, np.zeros(pad)]), PROFILES[who], rng,
                    drops=len(xc) / SR_WORK >= 0.8)[pad:-pad]                # pas de micro-coupure sur un mot isolé
        y8 = dsp.lp(dsp.resample(y, SR_WORK, SR_OUT), 3600, SR_OUT, 4)
        y8 = fade_and_level(y8, SR_OUT)
        clips[key] = y8
        if a.check:
            r8 = dsp.lp(dsp.resample(xc, SR_WORK, SR_OUT), 3600, SR_OUT, 4)
            clean_ref[key] = r8
            stats[key] = (who, intel_proxy(r8, y8), len(y8) / SR_OUT)
        if (i + 1) % 50 == 0:
            print(f"  {i + 1}/{len(atoms)}", flush=True)
    if notes:
        print("\n".join(notes))

    # --- banque : toutes les phrases à la suite, avec une garde de silence
    guard = np.zeros(int(0.03 * SR_OUT))
    pos = 0
    chunks, index = [], {}
    for key in sorted(clips):
        index[key] = [pos, len(clips[key])]
        chunks += [clips[key], guard]
        pos += len(clips[key]) + len(guard)
    bank = np.concatenate(chunks)
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    dsp.write_wav(out / "voices.wav", bank, SR_OUT)
    meta = {"rate": SR_OUT, "gap_s": script.get("gap_s", 0.13), "clips": index}
    (out / "voices.json").write_text(json.dumps(meta, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"banque : {len(index)} phrases, {len(bank) / SR_OUT:.0f} s, {(out / 'voices.wav').stat().st_size / 1e6:.2f} Mo -> {out}")

    if a.check:
        check(Path(a.check), clips, clean_ref, stats)


def check(chk, clips, clean_ref, stats):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    chk.mkdir(parents=True, exist_ok=True)
    print("--- intelligibilité (corrélation d'enveloppes, 1 = voix propre) ---")
    for who in ("base", "avion", "tireur"):
        v = [s[1] for k, s in stats.items() if s[0] == who]
        d = [s[2] for k, s in stats.items() if s[0] == who]
        if v:
            print(f"{who:7s} n={len(v):3d}  moyenne {np.mean(v):.3f}  min {np.min(v):.3f}  durée moyenne {np.mean(d):.2f} s")
    worst = sorted(stats.items(), key=lambda kv: kv[1][1])[:6]
    print("plus bas :", [(k, round(s[1], 2)) for k, s in worst])
    levels = [dsp.db(dsp.active_rms(c, SR_OUT)) for c in clips.values()]
    peaks = [dsp.db(np.max(np.abs(c))) for c in clips.values()]
    print(f"niveaux RMS actifs : {min(levels):.1f} .. {max(levels):.1f} dBFS ; crêtes max {max(peaks):.1f} dBFS")
    picks = [k for k in sorted(clips) if k.startswith("base|Nouveau groupe")][:1] \
        + [k for k in sorted(clips) if k.startswith("avion|Tireur, nouvel objectif")][:1] \
        + [k for k in sorted(clips) if k.startswith("tireur|Je les ai")][:1]
    picks = [k for k in picks if k in clean_ref]      # (phrases reprises de la banque : pas de voix propre à comparer)
    if not picks:
        return
    fig, ax = plt.subplots(len(picks), 2, figsize=(11, 3.1 * len(picks)), squeeze=False)
    for i, k in enumerate(picks):
        for j, (title, sig) in enumerate((("voix propre", clean_ref[k]), ("voix radio", clips[k]))):
            ax[i, j].specgram(sig, NFFT=256, Fs=SR_OUT, noverlap=192, cmap="magma", vmin=-120)
            ax[i, j].set_title(f"{k[:44]} — {title}", fontsize=8)
            ax[i, j].set_ylim(0, 4000)
    fig.tight_layout()
    fig.savefig(chk / "voix_spectrogrammes.png", dpi=80)
    plt.close(fig)


if __name__ == "__main__":
    main()
