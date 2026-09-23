#!/usr/bin/env python3
"""Convert a CAMSS RDI capture (MIPI-packed 10-bit GRBG) to a preview PNG.

Half-resolution debayer, black level 64, gray-world white balance, gamma
2.2. For eyeballing only, not image quality.
Usage: raw2png.py in.raw out.png [width height stride]
"""
import sys
import numpy as np
from PIL import Image

src, dst = sys.argv[1], sys.argv[2]
W, H, S = (int(x) for x in sys.argv[3:6]) if len(sys.argv) > 5 else (2104, 1184, 2640)
d = np.fromfile(src, dtype=np.uint8)
n = len(d) // (S * H)
f = d[(n - 1) * S * H:n * S * H].reshape(H, S)[:, :W * 5 // 4]
b = f.reshape(H, -1, 5).astype(np.uint16)
px = np.empty((H, W), np.uint16)
for i in range(4):
    px[:, i::4] = (b[:, :, i] << 2) | ((b[:, :, 4] >> (2 * i)) & 3)
g1, r = px[0::2, 0::2], px[0::2, 1::2]
bl, g2 = px[1::2, 0::2], px[1::2, 1::2]
rgb = np.dstack([r, (g1.astype(float) + g2) / 2, bl]).astype(float) - 64
rgb = np.clip(rgb, 0, None)
rgb *= rgb[..., 1].mean() / np.maximum(rgb.reshape(-1, 3).mean(0), 1e-6)
rgb = np.clip(rgb / max(1.0, np.percentile(rgb, 99.5)), 0, 1) ** (1 / 2.2)
Image.fromarray((rgb * 255).astype(np.uint8)).save(dst)
print(f"{n} frames, last one: min {px.min()} mean {px.mean():.1f} max {px.max()} -> {dst}")
