#!/usr/bin/env python3
"""Synthesizes the Claude Chimes notification sounds with the Python standard library.

Usage: python3 generate.py [output_dir]   (default: the directory this script is in)
"""
import math, os, struct, sys, wave

SR = 44100
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))
os.makedirs(OUT, exist_ok=True)

def note(freq, dur, partials, attack=0.004):
    """partials: list of (ratio, amp, decay_per_sec)."""
    n = int(SR * dur)
    out = [0.0] * n
    for i in range(n):
        t = i / SR
        env_a = min(1.0, t / attack) if attack else 1.0
        s = 0.0
        for ratio, amp, decay in partials:
            s += amp * math.exp(-decay * t) * math.sin(2 * math.pi * freq * ratio * t)
        out[i] = s * env_a
    return out

# Timbres
MARIMBA = [(1, 1.0, 7), (4.0, 0.35, 28), (9.9, 0.08, 60)]
KALIMBA = [(1, 1.0, 4.5), (2.0, 0.25, 9), (5.9, 0.12, 30)]
BELL    = [(1, 1.0, 3.2), (2.0, 0.45, 5), (2.76, 0.3, 7), (5.4, 0.12, 14), (8.93, 0.05, 22)]
WOOD    = [(1, 1.0, 30), (2.3, 0.4, 55), (4.1, 0.15, 90)]
WARM    = [(1, 1.0, 2.2), (2, 0.3, 3.5), (3, 0.12, 5)]
GLINT   = [(1, 1.0, 9), (3.01, 0.25, 18)]

def mix(events, total):
    buf = [0.0] * int(SR * total)
    for start, samples, gain in events:
        o = int(SR * start)
        for i, v in enumerate(samples):
            if o + i < len(buf):
                buf[o + i] += v * gain
    return buf

def write(name, buf, peak=0.85):
    m = max(abs(v) for v in buf) or 1
    # 15 ms fade-out to avoid clicks
    fade = int(SR * 0.015)
    for i in range(fade):
        buf[-1 - i] *= i / fade
    with wave.open(os.path.join(OUT, name), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(b"".join(struct.pack("<h", int(v / m * peak * 32767)) for v in buf))
    print("wrote", name)

hz = lambda midi: 440 * 2 ** ((midi - 69) / 12)

# ---------- "needs your input" sounds (rising / questioning) ----------
# nudge: two soft marimba notes, a gentle "hey?" upward fourth
write("input-nudge.wav", mix([
    (0.00, note(hz(76), 0.5, MARIMBA), 0.8),   # E5
    (0.13, note(hz(81), 0.6, MARIMBA), 1.0),   # A5
], 0.8))

# query: three quick glassy bell notes rising, ending unresolved on the 9th
write("input-query.wav", mix([
    (0.00, note(hz(84), 0.9, BELL), 0.6),   # C6
    (0.09, note(hz(88), 0.9, BELL), 0.6),   # E6
    (0.18, note(hz(86), 1.0, BELL), 0.8),   # D6 (unresolved, "...?")
], 1.2))

# knock: two muted wooden taps, like a polite knock on the door
write("input-knock.wav", mix([
    (0.00, note(hz(67), 0.25, WOOD, attack=0.001), 1.0),
    (0.16, note(hz(67), 0.25, WOOD, attack=0.001), 0.85),
], 0.45))

# ---------- "finished" sounds (resolving / settling) ----------
# spark: a bright upward sparkle that blooms into a soft major chord
spark = [(0.00 + k * 0.035, note(hz(m), 0.35, GLINT), 0.35) for k, m in enumerate([84, 88, 91, 96])]
spark += [(0.16, note(hz(m), 1.4, WARM, attack=0.03), 0.5) for m in (72, 76, 79)]
spark += [(0.16, note(hz(96), 1.2, BELL), 0.25)]
write("done-spark.wav", mix(spark, 1.6))

# settle: descending kalimba G5-E5-C5, like setting something down
write("done-settle.wav", mix([
    (0.00, note(hz(79), 0.9, KALIMBA), 0.8),
    (0.12, note(hz(76), 0.9, KALIMBA), 0.85),
    (0.24, note(hz(72), 1.3, KALIMBA), 1.0),
], 1.5))

# bloom: slow warm arpeggio C-G-E-C that rings out
write("done-bloom.wav", mix([
    (0.00, note(hz(60), 1.8, WARM, attack=0.02), 0.7),
    (0.07, note(hz(67), 1.7, WARM, attack=0.02), 0.6),
    (0.14, note(hz(76), 1.6, WARM, attack=0.02), 0.55),
    (0.21, note(hz(84), 1.5, BELL), 0.35),
], 1.9))

# ---------- "turn failed" sound (low and soft, clearly different from the others) ----------
# dip: two muted marimba notes stepping down a minor third, low in the register
write("error-dip.wav", mix([
    (0.00, note(hz(64), 0.45, MARIMBA), 0.9),   # E4
    (0.14, note(hz(61), 0.70, MARIMBA), 1.0),   # C#4
], 0.9))

