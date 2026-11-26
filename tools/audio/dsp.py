"""Outils de traitement du signal partagés par les générateurs audio (numpy / scipy uniquement)."""
import wave

import numpy as np
from scipy import signal


# ---------------------------------------------------------------- entrées / sorties

def write_wav(path, x, sr):
    """Écrit un WAV mono PCM 16 bits (x en flottants, borné à [-1, 1])."""
    pcm = np.round(np.clip(x, -1.0, 1.0) * 32767.0).astype("<i2")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(int(sr))
        w.writeframes(pcm.tobytes())


def read_wav(path):
    with wave.open(str(path), "rb") as w:
        sr = w.getframerate()
        ch = w.getnchannels()
        raw = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float64) / 32768.0
    if ch > 1:
        raw = raw.reshape(-1, ch).mean(axis=1)
    return raw, sr


# ---------------------------------------------------------------- niveaux

def rms(x):
    return float(np.sqrt(np.mean(np.square(x)) + 1e-18))


def db(v):
    return 20.0 * np.log10(max(float(v), 1e-12))


def from_db(d):
    return 10.0 ** (d / 20.0)


def active_rms(x, sr, floor_db=-40.0):
    """RMS mesuré seulement sur les fenêtres de 20 ms dont le niveau dépasse floor_db sous le pic."""
    n = max(int(0.02 * sr), 1)
    m = len(x) // n
    if m == 0:
        return rms(x)
    fr = x[: m * n].reshape(m, n)
    lv = np.sqrt(np.mean(fr * fr, axis=1) + 1e-18)
    thr = lv.max() * from_db(floor_db)
    sel = lv[lv >= thr]
    return float(np.sqrt(np.mean(sel * sel))) if sel.size else rms(x)


# ---------------------------------------------------------------- filtres

def lp(x, fc, sr, order=2):
    return signal.sosfilt(signal.butter(order, min(fc, sr * 0.49), "lowpass", fs=sr, output="sos"), x)


def hp(x, fc, sr, order=2):
    return signal.sosfilt(signal.butter(order, fc, "highpass", fs=sr, output="sos"), x)


def bp(x, lo, hi, sr, order=2):
    return signal.sosfilt(signal.butter(order, [lo, min(hi, sr * 0.49)], "bandpass", fs=sr, output="sos"), x)


def peaking(x, f0, gain_db, q, sr):
    """Filtre en cloche (RBJ) : crée une résonance (gain > 0) ou un creux (gain < 0)."""
    a = 10.0 ** (gain_db / 40.0)
    w0 = 2.0 * np.pi * f0 / sr
    al = np.sin(w0) / (2.0 * q)
    b = np.array([1 + al * a, -2 * np.cos(w0), 1 - al * a])
    aa = np.array([1 + al / a, -2 * np.cos(w0), 1 - al / a])
    return signal.lfilter(b / aa[0], aa / aa[0], x)


def smooth(x, sr, tau):
    """Lissage passe-bas d'ordre 1 de constante de temps tau (s)."""
    al = np.exp(-1.0 / (tau * sr))
    return signal.lfilter([1.0 - al], [1.0, -al], x)


def resample(x, sr_in, sr_out):
    if sr_in == sr_out:
        return np.asarray(x, dtype=np.float64)
    n_out = int(round(len(x) * sr_out / sr_in))
    return signal.resample(np.asarray(x, dtype=np.float64), n_out)


# ---------------------------------------------------------------- dynamique, distorsion

def compress(x, sr, thr_db=-28.0, ratio=4.0, attack=0.004, release=0.07, makeup_db=0.0):
    """Compresseur à gain calculé sur une enveloppe lissée (attaque rapide, relâchement plus lent)."""
    lev = np.abs(x)
    # enveloppe : suivi de crête rapide puis lissage lent (approximation attaque / relâchement)
    env = np.maximum(smooth(lev, sr, attack), 0.0)
    env = np.maximum(env, smooth(lev, sr, release) * 0.9)
    env_db = 20.0 * np.log10(env + 1e-9)
    over = np.maximum(env_db - thr_db, 0.0)
    gain_db = -over * (1.0 - 1.0 / ratio) + makeup_db
    return x * (10.0 ** (gain_db / 20.0))


def soft_clip(x, drive=2.0, asym=0.0):
    """Saturation douce, avec un peu d'asymétrie (harmoniques paires) pour le grain « micro à charbon »."""
    y = np.tanh(drive * (x + asym * x * x)) / np.tanh(drive)
    return y - np.mean(y)


def bitcrush(x, bits, rng, dither=0.5):
    q = 2.0 ** (bits - 1)
    d = (rng.random(len(x)) - rng.random(len(x))) * dither / q
    return np.round((x + d) * q) / q


# ---------------------------------------------------------------- bruits et réverbération

def periodic_noise(rng, n, sr, shape):
    """Bruit exactement périodique sur n échantillons (boucles sans raccord) ; shape(f) = module du spectre."""
    k = np.arange(n // 2 + 1)
    f = k * sr / n
    mag = np.asarray(shape(f), dtype=np.float64)
    ph = rng.uniform(0.0, 2.0 * np.pi, len(k))
    spec = mag * np.exp(1j * ph)
    spec[0] = 0.0
    if n % 2 == 0:
        spec[-1] = abs(spec[-1])
    x = np.fft.irfft(spec, n)
    return x / (np.std(x) + 1e-12)


def reverb_ir(rng, sr, rt60, lp_fc=1800.0, predelay=0.004):
    n = int(rt60 * sr)
    t = np.arange(n) / sr
    ir = rng.standard_normal(n) * np.exp(-6.9078 * t / rt60)
    ir = lp(ir, lp_fc, sr)
    pre = np.zeros(int(predelay * sr))
    ir = np.concatenate([pre, ir])
    ir[0] = 1.0
    return ir / np.sqrt(np.sum(ir * ir))


def add_reverb(x, rng, sr, rt60=0.5, wet=0.25, lp_fc=1800.0):
    ir = reverb_ir(rng, sr, rt60, lp_fc)
    y = signal.fftconvolve(x, ir)[: len(x) + int(rt60 * sr * 0.5)]
    out = np.zeros(len(y))
    out[: len(x)] += x * (1.0 - wet)
    out += y * wet * np.sqrt(np.sum(x * x) / (np.sum(y * y) + 1e-12))
    return out


def decay_bands(rng, n, sr, bands):
    """Bruit dont chaque bande (lo, hi, tau, amp) décroît à son rythme : le grave dure plus que l'aigu."""
    t = np.arange(n) / sr
    out = np.zeros(n)
    for lo, hi, tau, amp in bands:
        nz = rng.standard_normal(n)
        nz = lp(nz, hi, sr, 3) if lo <= 0 else bp(nz, lo, hi, sr, 2)
        out += nz * np.exp(-t / tau) * amp
    return out


def damped_sines(n, sr, parts, rng, delay=0.0):
    """Somme de sinusoïdes amorties (fréquence, amplitude, constante de temps) : métal, caisse, cloche."""
    t = np.arange(n) / sr - delay
    out = np.zeros(n)
    m = t >= 0
    for f, a, tau in parts:
        out[m] += a * np.sin(2 * np.pi * f * t[m] + rng.uniform(0, 2 * np.pi)) * np.exp(-t[m] / tau)
    return out


def add_at(buf, w, pos, circular=False):
    """Ajoute w dans buf à partir de l'échantillon pos (avec rebouclage si circular)."""
    n = len(buf)
    pos = int(pos)
    if circular:
        pos %= n
        k = min(len(w), n - pos)
        buf[pos:pos + k] += w[:k]
        rest = w[k:]
        while len(rest):
            m = min(len(rest), n)
            buf[:m] += rest[:m]
            rest = rest[m:]
    else:
        if pos >= n:
            return
        k = min(len(w), n - pos)
        buf[pos:pos + k] += w[:k]


def fade_edges(x, n_in, n_out):
    y = x.copy()
    if n_in > 0:
        y[:n_in] *= np.linspace(0.0, 1.0, n_in)
    if n_out > 0:
        y[-n_out:] *= np.linspace(1.0, 0.0, n_out)
    return y


def normalize_peak(x, peak=0.9):
    m = np.max(np.abs(x))
    return x * (peak / m) if m > 0 else x
