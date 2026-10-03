"""Shared paths and settings of the upscaler benchmark (see README.md).

Everything heavy (source clips, ground truth, renders, results) lives in the
work folder, test-media/upscale-bench/ by default (gitignored, like the rest
of test-media/), or wherever MPV_BENCH_WORK points.
"""
import json
import os
import shutil

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..'))
WORK = os.path.abspath(os.environ.get('MPV_BENCH_WORK') or os.path.join(REPO, 'test-media', 'upscale-bench'))
DATA = os.path.join(WORK, 'data')
SHADERS = os.path.join(WORK, 'shaders')  # candidate shaders (fetch_shaders.sh)
REPO_SHADERS = os.path.join(REPO, 'portable_config', 'shaders')

# Renderer: 'pinned' = the Windows build mpv-build.json pins, under Wine (what
# the player really runs - default), 'linux' = the distribution's mpv. They are
# NOT interchangeable for Anime4K: libplacebo 6.338 (Ubuntu 24.04's mpv) runs
# Anime4K's chain measurably worse than the pinned build's 7.374 (2026-10-03:
# 2 dB at 2x on the same frames, while FSRCNNX/SSimSuperRes/CfL/adaptive-sharpen
# came out bit-identical or within 80 dB). Decide on 'pinned' numbers only.
RENDERER = os.environ.get('MPV_BENCH_RENDERER', 'pinned')
PINNED_DIR = os.environ.get('MPV_BENCH_PINNED') or os.path.join(WORK, 'pinned-mpv')
LINUX_MPV = os.environ.get('MPV_BENCH_MPV', 'mpv')
VULKAN_DEVICE = os.environ.get('MPV_BENCH_VULKAN_DEVICE', 'llvmpipe')  # substring of the device name
DISPLAY = os.environ.get('DISPLAY', ':99')

VMAF = os.environ.get('MPV_BENCH_VMAF') or shutil.which('vmaf') or 'vmaf'
VMAF_MODELS = os.environ.get('MPV_BENCH_VMAF_MODELS', '')  # folder with vmaf_v0.6.1.json / vmaf_v0.6.1neg.json

OUT = os.path.join(WORK, 'out-' + RENDERER)
RESULTS = os.path.join(WORK, 'results-' + RENDERER)

# The display ratios the user sees on the 2560x1440 screen, played as a
# 1920x1080 window: 1080p, 720p and 480p sources.
SIZES = {'1.33': (1440, 810), '2': (960, 540), '3': (640, 360)}
RATIO = {'1.33': 4 / 3, '2': 2.0, '3': 3.0}


def pinned_build():
    """The pinned build's archive name and SHA-256, from mpv-build.json."""
    with open(os.path.join(REPO, 'mpv-build.json')) as f:
        j = json.load(f)
    return j['url'], j['sha256']
