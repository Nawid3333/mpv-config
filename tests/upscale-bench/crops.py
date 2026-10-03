#!/usr/bin/env python3
"""crops.py <set> <clip> <ratio> <deg> <x,y,w,h> <chain,...> <out.png> [zoom] [columns]

A labelled grid of the same crop from the reference ('ref'), the input scaled
by nearest neighbour ('input') and each chain's render, zoomed by nearest
neighbour (default 2x) - for judging by eye what the numbers say.
Example: python3 crops.py tv Slime 3 lossless 740,440,250,170 ref,anime,anime_cunny4_ds /tmp/slime.png
"""
import os
import subprocess
import sys

import cv2
import numpy as np
from PIL import Image, ImageDraw

import common
from make_dataset import FRAMES


def load(path):
    a = cv2.imread(path, cv2.IMREAD_UNCHANGED)
    if a is None:
        raise FileNotFoundError(path)
    a = a[..., :3][..., ::-1]
    if a.dtype == np.uint16:
        a = (a.astype(np.float64) / 257.0).round().astype(np.uint8)
    return Image.fromarray(np.ascontiguousarray(a))


def tile_path(kind, clip, ratio, deg, chain):
    pick = '%02d' % FRAMES[kind][1]
    cdir = os.path.join(common.DATA, kind, clip)
    if chain == 'ref':
        return os.path.join(cdir, 'gt_%s.png' % pick)
    if chain == 'input':
        src = os.path.join(cdir, 'in_%s_%s_%s.mkv' % (ratio, deg, pick))
        dst = src[:-4] + '.nearest.png'
        if not os.path.exists(dst):
            subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-i', src, '-vf',
                            'scale=1920:1080:flags=neighbor', '-frames:v', '1', dst], check=True)
        return dst
    return os.path.join(common.OUT, kind, chain, '%s_%s_%s_%s.png' % (clip, pick, ratio, deg))


def grid(kind, clip, ratio, deg, box, chains, out, zoom=2, cols=4):
    x, y, w, h = box
    tiles = [(c, load(tile_path(kind, clip, ratio, deg, c)).crop((x, y, x + w, y + h))
              .resize((w * zoom, h * zoom), Image.NEAREST)) for c in chains]
    cols = min(cols, len(tiles))
    rows = (len(tiles) + cols - 1) // cols
    pad, tw, th = 20, w * zoom, h * zoom
    sheet = Image.new('RGB', (cols * tw + 4 * (cols - 1), rows * (th + pad)), (255, 255, 255))
    d = ImageDraw.Draw(sheet)
    for i, (name, t) in enumerate(tiles):
        cx, cy = (i % cols) * (tw + 4), (i // cols) * (th + pad)
        sheet.paste(t, (cx, cy + pad))
        d.text((cx + 4, cy + 4), name, fill=(0, 0, 0))
    sheet.save(out)


if __name__ == '__main__':
    a = sys.argv[1:]
    if len(a) < 7:
        sys.exit(__doc__)
    grid(a[0], a[1], a[2], a[3], [int(v) for v in a[4].split(',')], a[5].split(','), a[6],
         int(a[7]) if len(a) > 7 else 2, int(a[8]) if len(a) > 8 else 4)
