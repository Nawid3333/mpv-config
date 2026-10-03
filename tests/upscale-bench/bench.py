#!/usr/bin/env python3
"""bench.py <set> <chain,...> [ratios] [degradations] [-j N]

  set           live | anim | tv            (make_dataset.py)
  chain,...     names from chains.py
  ratios        1.33,2,3 (default: all)
  degradations  lossless,crf22,crf30 (default: all; tv has lossless only)
  -j N          N mpv renders at once (default 3)

Renders each scored frame through each chain (render.py), scores it against
the reference (metrics.py) and prints a table per ratio and degradation:
means over the clips (colour without the black-and-white clips). Per-frame
results are cached in <work>/results-<renderer>/<set>/<chain>/<ratio>_<deg>.json,
renders in <work>/out-<renderer>/, so an interrupted run resumes.
Example: python3 bench.py anim off,anime,anime_cunny4_ds 1.33 crf22
"""
import glob
import json
import os
import sys
import time
import traceback
from concurrent.futures import ProcessPoolExecutor, as_completed

import chains
import common
import metrics
import render
from make_dataset import FRAMES, GREY

KEYS = ['psnr_y', 'ssim_y', 'psnr_cb', 'psnr_cr', 'gmsd', 'sharp', 'over']


def frames(kind, ratio, deg):
    """(key, reference, input) of every scored frame of a set."""
    pick = '%02d' % FRAMES[kind][1]
    out = []
    for cdir in sorted(glob.glob(os.path.join(common.DATA, kind, '*'))):
        if not os.path.exists(os.path.join(cdir, 'info.json')):
            continue
        inp = os.path.join(cdir, 'in_%s_%s_%s.mkv' % (ratio, deg, pick))
        if os.path.exists(inp):
            out.append(('%s_%s' % (os.path.basename(cdir), pick), os.path.join(cdir, 'gt_%s.png' % pick), inp))
    return out


def run_one(kind, cname, ratio, deg):
    resf = os.path.join(common.RESULTS, kind, cname, '%s_%s.json' % (ratio, deg))
    res = json.load(open(resf)) if os.path.exists(resf) else {}
    todo = frames(kind, ratio, deg)
    if not todo:
        return None
    outs = [os.path.join(common.OUT, kind, cname, k + '_%s_%s.png' % (ratio, deg)) for k, _, _ in todo]
    if all(k in res for k, _, _ in todo) and res.get('_vmaf', {}).get('n') == len(todo):
        return resf
    t0 = time.time()
    render.render(chains.CHAINS[cname](ratio), [(inp, o) for (_, _, inp), o in zip(todo, outs)])
    for (k, gt, _), o in zip(todo, outs):
        if k not in res:
            res[k] = metrics.frame_metrics(gt, o, chroma_full=(kind == 'live'))
    v, vn = metrics.vmaf([gt for _, gt, _ in todo], outs)
    res['_vmaf'] = {'vmaf': v, 'vmaf_neg': vn, 'n': len(todo)}
    os.makedirs(os.path.dirname(resf), exist_ok=True)
    with open(resf, 'w') as f:
        json.dump(res, f, indent=1)
    print('%-26s %-5s %-8s %4.0f s' % (cname, ratio, deg, time.time() - t0), flush=True)
    return resf


def _job(args):
    try:
        run_one(*args)
    except Exception:
        return '%s %s %s %s\n%s' % (*args, traceback.format_exc()[-1500:])
    return None


def summary(kind, names, ratios, degs):
    lines = []
    for r in ratios:
        for deg in degs:
            rows = []
            for c in names:
                f = os.path.join(common.RESULTS, kind, c, '%s_%s.json' % (r, deg))
                if not os.path.exists(f):
                    continue
                d = json.load(open(f))
                fr = [v for k, v in d.items() if not k.startswith('_')]
                colour = [v for k, v in d.items() if not k.startswith('_') and not k.startswith(GREY)]
                m = {k: sum(x[k] for x in fr) / len(fr) for k in KEYS}
                for k in ('psnr_cb', 'psnr_cr'):
                    m[k] = sum(x[k] for x in colour) / len(colour)
                vm = d.get('_vmaf', {})
                rows.append('%-26s %7.3f %7.4f %7.3f %7.3f %7.4f %6.3f %6.3f %6.2f %6.2f' % (
                    c, m['psnr_y'], m['ssim_y'], m['psnr_cb'], m['psnr_cr'], m['gmsd'], m['sharp'], m['over'],
                    vm.get('vmaf', float('nan')), vm.get('vmaf_neg', float('nan'))))
            if rows:
                lines += ['', '== %s  %sx  %s  (%s renderer)' % (kind, r, deg, common.RENDERER),
                          '%-26s %7s %7s %7s %7s %7s %6s %6s %6s %6s' % (
                              'chain', 'PSNR-Y', 'SSIM', 'Cb', 'Cr', 'GMSD', 'sharp', 'over', 'VMAF', 'NEG')] + rows
    return '\n'.join(lines)


def main(argv):
    j = 3
    if '-j' in argv:
        i = argv.index('-j')
        j = int(argv[i + 1])
        del argv[i:i + 2]
    if len(argv) < 2:
        sys.exit(__doc__)
    kind, names = argv[0], argv[1].split(',')
    ratios = argv[2].split(',') if len(argv) > 2 and argv[2] else list(common.SIZES)
    degs = argv[3].split(',') if len(argv) > 3 and argv[3] else (['lossless'] if kind == 'tv' else ['lossless', 'crf22', 'crf30'])
    errors = []
    with ProcessPoolExecutor(j) as ex:
        for f in as_completed([ex.submit(_job, (kind, c, r, d)) for c in names for r in ratios for d in degs]):
            if f.result():
                errors.append(f.result())
                print('FAILED', f.result(), flush=True)
    print(summary(kind, names, ratios, degs))
    sys.exit(1 if errors else 0)


if __name__ == '__main__':
    main(sys.argv[1:])
