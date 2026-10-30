#!/usr/bin/env python3
"""Synthesizes the tap sounds in assets/sounds (tap_thock.wav is recorded, not made here).

    python3 scripts/make-sounds.py

Each sound is short (under 0.15 s), mono, 44.1 kHz, and starts instantly so taps feel
immediate. Needs numpy.
"""
import os
import wave

import numpy as np

RATE = 44100
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "assets", "sounds")


def t(seconds):
    return np.arange(int(RATE * seconds)) / RATE


def env(x, attack, decay):
    a = np.minimum(1, x / max(attack, 1e-6))
    return a * np.exp(-x / decay)


def save(name, samples, gain=0.9):
    samples = samples / (np.max(np.abs(samples)) or 1) * gain
    fade = int(RATE * 0.004)
    samples[-fade:] *= np.linspace(1, 0, fade)
    with wave.open(os.path.join(OUT, f"tap_{name}.wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes((samples * 32767).astype(np.int16).tobytes())


def click():
    x = t(0.05)
    noise = np.random.default_rng(1).standard_normal(len(x))
    hp = np.diff(noise, prepend=0)
    tone = np.sin(2 * np.pi * 3200 * x)
    return (hp * 0.6 + tone * 0.5) * env(x, 0.0004, 0.006)


def pop():
    x = t(0.09)
    f = 380 + 1100 * (1 - np.exp(-x / 0.012))
    phase = 2 * np.pi * np.cumsum(f) / RATE
    return np.sin(phase) * env(x, 0.001, 0.022)


def wood():
    x = t(0.12)
    s = np.sin(2 * np.pi * 820 * x) * 1.0 + np.sin(2 * np.pi * 2350 * x) * 0.45 + np.sin(2 * np.pi * 4100 * x) * 0.15
    noise = np.random.default_rng(2).standard_normal(len(x)) * env(x, 0.0003, 0.002) * 0.4
    return s * env(x, 0.0006, 0.028) + noise


def boop():
    x = t(0.14)
    f = 260 - 70 * (x / x[-1])
    phase = 2 * np.pi * np.cumsum(f) / RATE
    return (np.sin(phase) + 0.2 * np.sin(2 * phase)) * env(x, 0.003, 0.045)


def squeak():
    x = t(0.13)
    f = 1150 + 650 * np.sin(np.pi * x / x[-1]) + 30 * np.sin(2 * np.pi * 38 * x)
    phase = 2 * np.pi * np.cumsum(f) / RATE
    shape = np.sin(np.pi * np.minimum(1, x / x[-1]))
    return (np.sin(phase) + 0.3 * np.sin(2 * phase)) * shape * np.exp(-x / 0.09)


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, fn in [("click", click), ("pop", pop), ("wood", wood), ("boop", boop), ("squeak", squeak)]:
        save(name, fn())
    print("wrote", sorted(os.listdir(OUT)))


if __name__ == "__main__":
    main()
