#!/usr/bin/env python3
"""Builds the ground-truth test set (~4 GB in the work folder, ~15 min).

live  10 live-action clips from the YouTube UGC dataset (Google, CC BY 4.0,
      storage.googleapis.com/ugc-dataset - raw, uncompressed): 2160p ->
      1920x1080 RGB48 reference (spline36), so the reference has full-resolution
      colour (4:4:4). Low-res inputs are made FROM that reference.
anim  7 2D-animation clips of the same dataset at 1080p: the clip IS the
      reference (4:2:0, so colour is scored at 960x540); inputs are downscaled
      straight from it. Two are black-and-white (no colour to score).
tv    4 TV-anime frames (Anime4K's own comparison screenshots, 1080p JPEG) -
      only 'lossless' inputs (single frames, no sequence to encode).

Inputs are the display ratios of the user's 2560x1440 screen played as 1920x1080:
1.33x (1080p source), 2x (720p) and 3x (480p): 1440x810, 960x540, 640x360,
4:2:0 8-bit BT.709 limited range. Degradations: 'lossless' (the downscale only)
and two real x264 encodes of a CONTIGUOUS sequence, so frames are P/B frames as
in a stream: 'crf22' (a good web encode) and 'crf30' (a poor one). One frame per
clip is scored, deep inside the sequence (never the IDR frame).

Needs ffmpeg with zscale and libx264, curl, and network access to
storage.googleapis.com and github.com (raw files).
"""
import json
import os
import subprocess
import sys

import common

UGC = 'https://storage.googleapis.com/ugc-dataset/original_videos/'
LIVE = ['Vlog/2160P/Vlog_2160P-255c', 'Vlog/2160P/Vlog_2160P-4419', 'Vlog/2160P/Vlog_2160P-3019',
        'Vlog/2160P/Vlog_2160P-5874', 'Vlog/2160P/Vlog_2160P-6f92', 'Vlog/2160P/Vlog_2160P-408f',
        'Sports/2160P/Sports_2160P-2626', 'Sports/2160P/Sports_2160P-7af8', 'Sports/2160P/Sports_2160P-3a9a',
        'Vlog/2160P/Vlog_2160P-4f98']
ANIM = ['Animation/1080P/Animation_1080P-0c4f', 'Animation/1080P/Animation_1080P-3dbf',
        'Animation/1080P/Animation_1080P-209f', 'Animation/1080P/Animation_1080P-4be3',
        'Animation/1080P/Animation_1080P-3e01', 'Animation/1080P/Animation_1080P-18f5',
        'Animation/1080P/Animation_1080P-05f8']
# black-and-white clips: excluded from the colour averages (bench.py)
GREY = ('Animation_1080P-0c4f', 'Animation_1080P-209f')
TV = 'https://raw.githubusercontent.com/bloc97/Anime4K/7684e9586f8dcc738af08a1cdceb024cc184f426/results/Comparisons/Screenshots/%s_1080p.jpg'
TV_FRAMES = ['Fate', 'Maxed', 'Quin', 'Slime']
FRAMES = {'live': (24, 19), 'anim': (48, 37), 'tv': (1, 0)}  # sequence length, scored frame
CRFS = [22, 30]
TAGS = ['-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709', '-color_range', 'tv']


def ff(*args):
    r = subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', *args], capture_output=True, text=True)
    if r.returncode:
        sys.exit('ffmpeg failed: %s\n%s' % (' '.join(args), r.stderr[-2000:]))


def fetch(url, dst, nbytes=None):
    if os.path.exists(dst):
        return
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    cmd = ['curl', '-sSfL', '--max-time', '900', '-o', dst + '.part', url]
    if nbytes:
        cmd[1:1] = ['-r', '0-%d' % nbytes]  # raw clips: the first frames are enough
    subprocess.run(cmd, check=True)
    os.replace(dst + '.part', dst)


def build(kind, name, src):
    nframes, pick = FRAMES[kind]
    cdir = os.path.join(common.DATA, kind, name)
    if os.path.exists(os.path.join(cdir, 'info.json')):
        return
    os.makedirs(cdir, exist_ok=True)
    gt_seq = os.path.join(cdir, 'gt_seq.mkv')
    if kind == 'live':
        ff('-i', src, '-frames:v', str(nframes), '-vf',
           'zscale=w=1920:h=1080:filter=spline36:min=709:m=709:rin=tv:r=full:cin=left,format=gbrp16le',
           '-c:v', 'ffv1', '-level', '3', gt_seq)
        lr_src, lr_vf = gt_seq, 'zscale=w=%d:h=%d:filter=spline36:min=gbr:m=709:rin=full:r=tv:c=left,format=yuv420p'
    elif kind == 'anim':
        ff('-i', src, '-frames:v', str(nframes), '-vf',
           'zscale=filter=spline36:min=709:m=709:rin=tv:r=full:cin=left,format=gbrp16le',
           '-c:v', 'ffv1', '-level', '3', gt_seq)
        lr_src, lr_vf = src, 'zscale=w=%d:h=%d:filter=spline36:min=709:m=709:rin=tv:r=tv:cin=left:c=left,format=yuv420p'
    else:
        ff('-i', src, '-vf', 'format=gbrp16le', '-c:v', 'ffv1', '-level', '3', gt_seq)
        lr_src, lr_vf = gt_seq, 'zscale=w=%d:h=%d:filter=spline36:min=gbr:m=709:rin=full:r=tv:c=left,format=yuv420p'
    ff('-i', gt_seq, '-vf', 'select=eq(n\\,%d)' % pick, '-frames:v', '1', os.path.join(cdir, 'gt_%02d.png' % pick))
    info = {}
    for ratio, (w, h) in common.SIZES.items():
        seq = os.path.join(cdir, 'lr_%s_seq.mkv' % ratio)
        ff('-i', lr_src, '-frames:v', str(nframes), '-vf', lr_vf % (w, h), '-c:v', 'ffv1', '-level', '3', *TAGS, seq)
        variants = {'lossless': seq}
        if kind != 'tv':
            for crf in CRFS:
                enc = os.path.join(cdir, 'lr_%s_crf%d.mp4' % (ratio, crf))
                ff('-i', seq, '-c:v', 'libx264', '-preset', 'slow', '-crf', str(crf), '-pix_fmt', 'yuv420p', *TAGS,
                   '-x264-params', 'keyint=250:min-keyint=25', enc)
                info['%s_crf%d_kbit' % (ratio, crf)] = round(os.path.getsize(enc) * 8 / 1000)
                variants['crf%d' % crf] = enc
        for vname, vfile in variants.items():
            ff('-i', vfile, '-vf', 'select=eq(n\\,%d)' % pick, '-frames:v', '1', '-c:v', 'ffv1', '-pix_fmt', 'yuv420p',
               *TAGS, os.path.join(cdir, 'in_%s_%s_%02d.mkv' % (ratio, vname, pick)))
    with open(os.path.join(cdir, 'info.json'), 'w') as f:
        json.dump(info, f, indent=1)
    print(kind, name, info, flush=True)


def main():
    raw = os.path.join(common.WORK, 'raw')
    for path in LIVE:
        name = path.rsplit('/', 1)[1]
        dst = os.path.join(raw, name + '.mkv')
        fetch(UGC + path + '.mkv', dst, 400_000_000)  # ~32 frames of raw 2160p
        build('live', name, dst)
    for path in ANIM:
        name = path.rsplit('/', 1)[1]
        dst = os.path.join(raw, name + '.mkv')
        fetch(UGC + path + '.mkv', dst, 160_000_000)  # ~51 frames of raw 1080p
        build('anim', name, dst)
    for name in TV_FRAMES:
        dst = os.path.join(raw, name + '_1080p.jpg')
        fetch(TV % name, dst)
        build('tv', name, dst)


if __name__ == '__main__':
    main()
