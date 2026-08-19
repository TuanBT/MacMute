#!/usr/bin/env python3
"""Generates the feedback tones into Resources/Sounds/.

Four packs with deliberately different character, because what reads as "clear
confirmation" to one person reads as "annoying" to the next. Within every pack the
mute tone falls and the unmute tone rises, so the two are told apart without looking.

All of them are short and quiet on purpose: the unmute tone plays as the microphone
opens, so on laptop speakers it has to be over before it could be mistaken for speech.

Re-run only when the tones change; the .wav files are committed so a normal build
needs no Python.
"""
import math, os, random, struct, wave

RATE = 44100
random.seed(7)          # reproducible noise, so rebuilds do not churn the files


def render(samples, name, folder="Sounds"):
    path = os.path.join("Resources", folder, name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with wave.open(path, "w") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(RATE)
        out.writeframes(b"".join(
            struct.pack("<h", max(-32767, min(32767, int(s * 32767)))) for s in samples))
    print(f"  {path:44s} {len(samples) / RATE * 1000:5.0f} ms")


def attack(i, ms=3.0):
    """Short fade-in; without it every tone starts with an audible click."""
    n = ms * RATE / 1000
    return min(1.0, i / n)


def sweep(f0, f1, ms, gain=0.28, release=30.0):
    """Sine gliding between two pitches. Smooth and neutral."""
    n = int(RATE * ms / 1000)
    r = release * RATE / 1000
    out, phase = [], 0.0
    for i in range(n):
        phase += 2 * math.pi * (f0 + (f1 - f0) * (i / n)) / RATE
        env = attack(i) * min(1.0, (n - i) / r)
        out.append(math.sin(phase) * env * gain)
    return out


def click(freq, ms=34, gain=0.42):
    """A damped resonance plus a noise transient: a switch being flipped."""
    n = int(RATE * ms / 1000)
    out = []
    for i in range(n):
        decay = math.exp(-i / (RATE * 0.006))
        tone = math.sin(2 * math.pi * freq * i / RATE) * decay
        # The noise is what makes it read as mechanical rather than musical.
        noise = random.uniform(-1, 1) * math.exp(-i / (RATE * 0.0016)) * 0.5
        out.append((tone + noise) * attack(i, 0.4) * gain)
    return out


def pluck(freq, ms=220, gain=0.30):
    """Fundamental with two harmonics and an exponential decay: a marimba note."""
    n = int(RATE * ms / 1000)
    partials = [(1.0, 1.0), (2.0, 0.34), (3.0, 0.12)]
    out = []
    for i in range(n):
        t = i / RATE
        value = sum(amp * math.sin(2 * math.pi * freq * mult * t) * math.exp(-t / (0.055 * amp + 0.02))
                    for mult, amp in partials)
        out.append(value * attack(i, 1.5) * gain * 0.6)
    return out


def chime(freq, ms=420, gain=0.24):
    """Inharmonic partials, the way a small bell actually rings."""
    n = int(RATE * ms / 1000)
    partials = [(1.0, 1.0, 0.30), (2.76, 0.45, 0.16), (5.40, 0.22, 0.09), (8.93, 0.10, 0.05)]
    out = []
    for i in range(n):
        t = i / RATE
        value = sum(amp * math.sin(2 * math.pi * freq * mult * t) * math.exp(-t / tau)
                    for mult, amp, tau in partials)
        out.append(value * attack(i, 2.0) * gain * 0.55)
    return out


def silence(ms):
    return [0.0] * int(RATE * ms / 1000)


PACKS = {
    # Smooth glide. The original, and the least attention-seeking.
    "soft":  (sweep(784, 523, 85),          sweep(523, 784, 85)),
    # Shortest of the four; nothing to hear but the switch.
    "click": (click(700),                    click(1180)),
    # Musical but dry, no ringing tail.
    "pluck": (pluck(392),                    pluck(587)),
    # Longest and most present; carries over background noise.
    "chime": (chime(523),                    chime(784)),
}

for name, (mute, unmute) in PACKS.items():
    render(mute, "mute.wav", os.path.join("Sounds", name))
    render(unmute, "unmute.wav", os.path.join("Sounds", name))

# One failure tone for every pack: three flat low blips, clearly neither of the above.
render(click(320, ms=55) + silence(30) + click(320, ms=55) + silence(30) + click(320, ms=55),
       "error.wav")
