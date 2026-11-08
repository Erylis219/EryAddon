"""Fabrique un petit « ting » doux (clochette) au format OGG pour WoW."""
import sys
import numpy as np
import soundfile as sf

out = sys.argv[1]
rate = 44100
dur = 0.6
t = np.arange(int(rate * dur)) / rate

# Clochette : fondamentale + partiels inharmoniques légers, chacun avec sa décroissance.
partials = [
    (1760.0, 1.00, 7.0),   # La6
    (4400.0, 0.25, 12.0),
    (6990.0, 0.10, 18.0),
]
sig = np.zeros_like(t)
for freq, amp, decay in partials:
    sig += amp * np.sin(2 * np.pi * freq * t) * np.exp(-decay * t)

# Attaque très courte (3 ms) pour éviter le « clic », fin en fondu.
attack = int(rate * 0.003)
sig[:attack] *= np.linspace(0, 1, attack)
fade = int(rate * 0.08)
sig[-fade:] *= np.linspace(1, 0, fade)

# Volume discret : crête à -14 dB.
sig = sig / np.max(np.abs(sig)) * 10 ** (-14 / 20)
sf.write(out, np.column_stack([sig, sig]).astype(np.float32), rate, format="OGG", subtype="VORBIS")
print("ok", out)
