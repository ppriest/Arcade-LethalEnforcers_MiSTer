#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The whole-board bench's audio against MAME's, sample for sample.

    python scripts/compare_audio.py debug/system/lethalen/audio.txt debug/audio/lethalen_mame.wav

RTL: "left right" a line, one per 48 kHz sample from reset (sim/system_tb +audio).
MAME: -wavwrite at -samplerate 48000 from power-on. The two start at different points,
so the RTL's sound is aligned on MAME's by cross-correlation (FFT), then compared over
the overlap: exact samples, samples within +-1, correlation and level ratio, per channel.
"""
import argparse
import sys
import wave

import numpy as np


def load_wav(path):
    w = wave.open(str(path))
    if w.getsampwidth() != 2 or w.getnchannels() != 2:
        sys.exit("expected 16-bit stereo")
    d = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").reshape(-1, 2)
    return d.astype(np.int64), w.getframerate()


def best_lag(a, b):
    """The lag L maximising sum a[n + L] * b[n]."""
    n = 1 << int(np.ceil(np.log2(len(a) + len(b))))
    c = np.fft.irfft(np.fft.rfft(a, n) * np.conj(np.fft.rfft(b, n)), n)
    c = np.concatenate([c[-(len(b) - 1):], c[:len(a)]])
    return int(np.argmax(c)) - (len(b) - 1)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("rtl")
    ap.add_argument("mame")
    a = ap.parse_args()
    rtl = np.loadtxt(a.rtl, dtype=np.int64).reshape(-1, 2)
    mame, rate = load_wav(a.mame)
    print(f"RTL {len(rtl)} samples ({len(rtl) / 48000:.2f} s), MAME {len(mame)} at {rate} Hz")
    for name, x in (("RTL", rtl), ("MAME", mame)):
        nz = np.nonzero(np.any(x != 0, axis=1))[0]
        print(f"  {name}: first non-zero sample {nz[0] if len(nz) else '-'}, peak {np.abs(x).max()}")
    if not np.any(rtl):
        sys.exit("the RTL is silent")
    lag = best_lag(mame[:, 0] + mame[:, 1], rtl[:, 0] + rtl[:, 1])
    print(f"lag: MAME sample n + {lag} is the RTL's n")
    lo, hi = max(0, -lag), min(len(rtl), len(mame) - lag)
    r, m = rtl[lo:hi], mame[lo + lag:hi + lag]
    print(f"overlap {hi - lo} samples")
    ok = True
    for ch, side in enumerate(("left", "right")):
        d = r[:, ch] - m[:, ch]
        exact = np.mean(d == 0) * 100
        near = np.mean(np.abs(d) <= 1) * 100
        sr, sm = r[:, ch].std(), m[:, ch].std()
        corr = np.corrcoef(r[:, ch], m[:, ch])[0, 1] if sr and sm else float("nan")
        print(f"  {side:5}: exact {exact:6.2f}%  within 1 {near:6.2f}%  corr {corr:.5f}  level RTL/MAME {sr / sm if sm else float('nan'):.4f}")
        ok &= near > 99.0
    # Each 0.1 s window with sound, aligned on its own (within +-50 ms of the global lag):
    # a waveform error shows as a low correlation here, a sound started a little earlier or
    # later than in MAME does not
    W, S = 4800, 2400
    print(f"windows of {W} samples, each aligned within +-{S}:")
    for ch, side in enumerate(("left", "right")):
        cs, lags, exact = [], [], []
        for w0 in range(lo + S, hi - W - S, W):
            x = r[w0 - lo:w0 - lo + W, ch]
            if x.std() < 20:
                continue
            y = mame[w0 + lag - S:w0 + lag + W + S, ch]
            l = best_lag(y, x)
            if not 0 <= l <= 2 * S:
                continue
            yy = y[l:l + W]
            if yy.std() == 0:
                continue
            cs.append(np.corrcoef(x, yy)[0, 1])
            lags.append(l - S)
            exact.append(np.mean(np.abs(x - yy) <= 1) * 100)
        cs = np.array(cs)
        if len(cs):
            print(f"  {side:5}: {len(cs)} windows, correlation median {np.median(cs):.5f} min {cs.min():.5f}, "
                  f"samples within 1 median {np.median(exact):.1f}%, local lag {min(lags)}..{max(lags)}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
