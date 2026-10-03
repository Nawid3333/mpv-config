"""Renders inputs through a shader chain with mpv's own gpu-next renderer and
grabs the result with `screenshot-to-file window` (16-bit PNG): the frame as
the player draws it into its window.

A 1920x1080 borderless window on an X server (Xvfb), Vulkan on Mesa's lavapipe
(CPU) - slow, but exact: a 1:1 render reproduces the source to 70 dB. Options
mirror portable_config/mpv.conf's renderer settings (vo=gpu-next,
profile=high-quality with scale-antiring=0.6) minus deband and dither, which add
noise to every chain alike. The shaders and options of a chain come from
chains.py; the script message path of gpu-toggles.lua is not used here (it
joins the shader list with ';', a Windows separator).
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

import common

LUA = os.path.join(common.HERE, 'render.lua')


def vulkan_device():
    """Full name of the Vulkan device to use (mpv wants the exact name)."""
    try:
        out = subprocess.run(['vulkaninfo', '--summary'], capture_output=True, text=True).stdout
    except FileNotFoundError:
        return None
    for name in re.findall(r'deviceName\s*=\s*(.+)', out):
        if common.VULKAN_DEVICE in name:
            return name.strip()
    return None


def shader(name):
    """A chain's shader by file name: the repo's own first, then the candidates."""
    for d in (common.REPO_SHADERS, common.SHADERS):
        p = os.path.join(d, name)
        if os.path.exists(p):
            return p
    raise FileNotFoundError(name + ' (run fetch_shaders.sh)')


def _args(device, cache):
    return [
        '--no-config', '--msg-level=all=error', '--vo=gpu-next', '--gpu-api=vulkan',
        '--vulkan-device=' + device, '--profile=high-quality', '--scale-antiring=0.6', '--deband=no',
        '--dither-depth=no', '--pause', '--keep-open=yes', '--audio=no', '--hwdec=no',
        '--geometry=1920x1080+0+0', '--no-border', '--osc=no', '--osd-level=0',
        '--screenshot-high-bit-depth=yes', '--screenshot-format=png', '--screenshot-png-compression=1',
        '--gpu-shader-cache-dir=' + cache,
    ]


def render(chain, jobs):
    """chain = {'shaders': [file names], 'opts': [mpv options]};
    jobs = [(input file, output png)], all rendered by one mpv process."""
    todo = [(i, o) for i, o in jobs if not os.path.exists(o)]
    if not todo:
        return []
    device = vulkan_device()
    if not device:
        raise RuntimeError('no Vulkan device matching %r (vulkaninfo --summary)' % common.VULKAN_DEVICE)
    tmp = tempfile.mkdtemp(prefix='upscale-bench-')
    pinned = common.RENDERER == 'pinned'
    path = (lambda p: 'Z:' + os.path.abspath(p)) if pinned else os.path.abspath
    pl = os.path.join(tmp, 'list.m3u')
    with open(pl, 'w') as f:
        f.write('\n'.join(path(i) for i, _ in todo) + '\n')
    cache = os.path.join(common.WORK, 'shader-cache-' + common.RENDERER)
    os.makedirs(cache, exist_ok=True)
    args = _args(device, path(cache)) + ['--script=' + path(LUA), '--script-opts=render_out=' + path(tmp)]
    if chain.get('shaders'):
        sep = ';' if pinned else ':'
        args.append('--glsl-shaders=' + sep.join(path(shader(s)) for s in chain['shaders']))
    args += chain.get('opts', []) + ['--playlist=' + path(pl)]
    env = dict(os.environ, DISPLAY=common.DISPLAY)
    if pinned:
        exe = os.path.join(common.PINNED_DIR, 'mpv.com')
        if not os.path.exists(exe):
            raise RuntimeError('pinned build missing: run fetch_pinned.sh')
        cmd = ['wine', exe] + args
        env.update(WINEDEBUG='-all', WINEPREFIX=os.environ.get('WINEPREFIX', os.path.join(common.WORK, 'wineprefix')))
    else:
        cmd = [common.LINUX_MPV] + args
        env.setdefault('XDG_RUNTIME_DIR', tempfile.gettempdir())
    r = subprocess.run(cmd, env=env, capture_output=True, text=True, cwd=common.PINNED_DIR if pinned else None)
    log = (r.stdout + r.stderr).splitlines()
    for n, (i, o) in enumerate(todo):
        src = os.path.join(tmp, '%05d.png' % n)
        if not os.path.exists(src):
            raise RuntimeError('not rendered: %s\n%s' % (i, '\n'.join(log[-30:])))
        os.makedirs(os.path.dirname(o), exist_ok=True)
        shutil.move(src, o)
    shutil.rmtree(tmp, ignore_errors=True)
    rendered = [line for line in log if line.startswith('RENDERED')]
    if not rendered:
        sys.stderr.write('\n'.join(log[-10:]) + '\n')
    return rendered
