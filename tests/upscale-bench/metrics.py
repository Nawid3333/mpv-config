#!/usr/bin/env python3
"""Full-reference metrics, all computed on BT.709 Y'CbCr derived the same way
from the reference RGB and from the rendered RGB (both gamma-encoded).

psnr_y / ssim_y   luma fidelity
psnr_cb / psnr_cr colour fidelity (at 4:2:0 resolution where the reference's
                  colour only exists there - the 2D-animation and TV sets)
gmsd              gradient magnitude similarity deviation (lower = better)
sharp             mean edge strength relative to the reference (1.00 = as crisp)
over              halo/ringing: how far the render overshoots the reference's
                  local 5x5 range near edges, in 8-bit levels (lower = better)
vmaf / vmaf_neg   Netflix VMAF v0.6.1 and its no-enhancement-gain variant
                  (VMAF rewards plain sharpening; NEG does not)
"""
import json
import os
import subprocess
import tempfile

import cv2
import numpy as np
from skimage.metrics import structural_similarity

import common


def load_rgb(path):
    a = cv2.imread(path, cv2.IMREAD_UNCHANGED)
    if a is None:
        raise FileNotFoundError(path)
    if a.ndim == 2:
        a = np.stack([a] * 3, -1)
    a = a[..., :3][..., ::-1]  # BGR(A) -> RGB
    scale = 65535.0 if a.dtype == np.uint16 else 255.0
    return a.astype(np.float64) / scale


def ycbcr(rgb):
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    y = 0.2126 * r + 0.7152 * g + 0.0722 * b
    return y, (b - y) / 1.8556, (r - y) / 1.5748


def psnr(a, b):
    mse = np.mean((a - b) ** 2)
    return 99.0 if mse <= 1e-12 else 10 * np.log10(1.0 / mse)


def sobel_mag(y):
    gx = cv2.Sobel(y, cv2.CV_64F, 1, 0, ksize=3)
    gy = cv2.Sobel(y, cv2.CV_64F, 0, 1, ksize=3)
    return np.sqrt(gx * gx + gy * gy)


def gmsd(ref, dst):
    # Gradient Magnitude Similarity Deviation (Xue et al. 2014), lower = better
    k = np.array([[1, 0, -1], [1, 0, -1], [1, 0, -1]], np.float64) / 3.0
    def gm(x):
        x = cv2.blur(x, (2, 2))[::2, ::2]
        gx = cv2.filter2D(x, -1, k)
        gy = cv2.filter2D(x, -1, k.T)
        return np.sqrt(gx * gx + gy * gy)
    g1, g2 = gm(ref * 255), gm(dst * 255)
    c = 170.0
    gms = (2 * g1 * g2 + c) / (g1 * g1 + g2 * g2 + c)
    return float(np.std(gms))


def overshoot(ref, dst):
    """Ringing/halo beyond what the reference has locally: mean of the output's
    excursion above the 5x5 max / below the 5x5 min of the reference, in
    8-bit code values, over the pixels near edges (where halos live)."""
    k = np.ones((5, 5), np.uint8)
    hi = cv2.dilate(ref, k)
    lo = cv2.erode(ref, k)
    exc = np.maximum(dst - hi, 0) + np.maximum(lo - dst, 0)
    edges = sobel_mag(ref) > 0.08
    edges = cv2.dilate(edges.astype(np.uint8), np.ones((7, 7), np.uint8)) > 0
    return float(exc[edges].mean() * 255) if edges.any() else 0.0


def subsample(c):
    """Colour at 4:2:0 resolution (box 2x2), for references whose colour only
    exists there."""
    h, w = c.shape
    return c[: h // 2 * 2, : w // 2 * 2].reshape(h // 2, 2, w // 2, 2).mean((1, 3))


def frame_metrics(gt_path, out_path, chroma_full=True):
    g = load_rgb(gt_path)
    o = load_rgb(out_path)
    if g.shape != o.shape:
        raise ValueError('size mismatch %s %s' % (g.shape, o.shape))
    gy, gb, gr = ycbcr(g)
    oy, ob, orr = ycbcr(o)
    if not chroma_full:
        gb, gr, ob, orr = subsample(gb), subsample(gr), subsample(ob), subsample(orr)
    gs = sobel_mag(gy).mean()
    return {
        'psnr_y': psnr(gy, oy),
        'ssim_y': structural_similarity(gy, oy, data_range=1.0, gaussian_weights=True, sigma=1.5,
                                        use_sample_covariance=False),
        'psnr_cb': psnr(gb, ob),
        'psnr_cr': psnr(gr, orr),
        'gmsd': gmsd(gy, oy),
        'sharp': float(sobel_mag(oy).mean() / gs),
        'over': overshoot(gy, oy),
    }


def _y4m(paths, out, w, h):
    """10-bit 4:4:4 Y'CbCr (limited range) of RGB stills, for VMAF."""
    with open(out, 'wb') as f:
        f.write(b'YUV4MPEG2 W%d H%d F24:1 Ip A1:1 C444p10 XYSCSS=444P10\n' % (w, h))
        for p in paths:
            y, cb, cr = ycbcr(load_rgb(p))
            Y = np.clip(np.round((16 + 219 * y) * 4), 0, 1023).astype('<u2')
            U = np.clip(np.round((128 + 224 * cb) * 4), 0, 1023).astype('<u2')
            V = np.clip(np.round((128 + 224 * cr) * 4), 0, 1023).astype('<u2')
            f.write(b'FRAME\n')
            for pl in (Y, U, V):
                f.write(pl.tobytes())


def vmaf(gt_paths, out_paths):
    """Mean VMAF and VMAF-NEG (v0.6.1 models) over the frames."""
    h, w = load_rgb(gt_paths[0]).shape[:2]
    with tempfile.TemporaryDirectory() as d:
        ref, dst, js = os.path.join(d, 'r.y4m'), os.path.join(d, 'd.y4m'), os.path.join(d, 'o.json')
        _y4m(gt_paths, ref, w, h)
        _y4m(out_paths, dst, w, h)
        models = common.VMAF_MODELS
        subprocess.run([common.VMAF, '-r', ref, '-d', dst, '--threads', '4', '--json', '-o', js, '-q',
                        '-m', 'path=%s:name=vmaf' % os.path.join(models, 'vmaf_v0.6.1.json'),
                        '-m', 'path=%s:name=vmaf_neg' % os.path.join(models, 'vmaf_v0.6.1neg.json')],
                       check=True, capture_output=True)
        r = json.load(open(js))['pooled_metrics']
        return r['vmaf']['mean'], r['vmaf_neg']['mean']
