# Upscaler benchmark (ground truth, mpv's own renderer)

Scores the upscale chains against a clean reference: a high-resolution
original is shrunk to what you would really play (a 1080p, 720p or 480p
source on the 2560x1440 screen), optionally encoded with x264 like a stream,
played through the chain in mpv, and the result is compared with the original.
Built on 2026-10-03 to answer "can the upscalers be made better?" - the
results and what they mean are in
[doc/history/sessions-2026-10.md](../../doc/history/sessions-2026-10.md).

It runs on **Linux** (a cloud session or WSL), not on the player PC: mpv
renders on Mesa's lavapipe (Vulkan on the CPU) in an Xvfb window, so no GPU is
needed and nothing touches the live setup. Slow (a heavy chain takes seconds
per frame) but exact: a 1:1 render reproduces the source to 70 dB. GPU *cost*
is not measured here - the regression suite's `-Tier gpu` (`gpu-pacing`)
reports real render times on the real card.

## The renderer matters

`MPV_BENCH_RENDERER=pinned` (default) runs the **Windows build
`mpv-build.json` pins** under Wine - the player's own mpv/libplacebo.
`linux` runs the distribution's mpv. For FSRCNNX, SSimSuperRes, CfL and
adaptive-sharpen both agree (bit-identical to 78 dB), but **not for Anime4K**:
Ubuntu 24.04's libplacebo 6.338 ran the Anime chain 1-2.7 dB worse than the
pinned 7.374 at every ratio, and its AutoDownscalePre resize much worse (a
"fix" measured there - dropping AutoDownscalePre - turned out to be no gain on
the real build). Decide on `pinned` numbers.

## Setup (Ubuntu 24.04, ~10 min)

```sh
sudo apt-get install -y ffmpeg mesa-vulkan-drivers vulkan-tools xvfb wine64 p7zip-full mpv \
    meson ninja-build nasm xxd
pip install numpy opencv-python-headless scikit-image pillow
git clone --depth 1 https://github.com/Netflix/vmaf && (cd vmaf/libvmaf && meson setup build --buildtype release && ninja -C build)
export MPV_BENCH_VMAF=$PWD/vmaf/libvmaf/build/tools/vmaf MPV_BENCH_VMAF_MODELS=$PWD/vmaf/model
Xvfb :99 -screen 0 2560x1440x24 & export DISPLAY=:99
cd tests/upscale-bench
sh fetch_pinned.sh          # the pinned Windows build, SHA-256 checked
sh fetch_shaders.sh         # candidate shaders from pinned upstream commits
python3 make_dataset.py     # ~4 GB: references + inputs (network: storage.googleapis.com, github)
```

The work folder is `test-media/upscale-bench/` (gitignored); `MPV_BENCH_WORK`
moves it.

## Running

```sh
python3 bench.py anim off,anime,anime_cunny4_ds 1.33,2,3 crf22,crf30
python3 bench.py live off,movie,movie_nosharp '' crf22
python3 bench.py tv off,anime 3
python3 crops.py tv Slime 3 lossless 740,440,250,170 ref,input,anime,anime_cunny4_ds slime.png
```

Sets: `live` (10 live-action clips, 2160p -> 1080p reference with full
colour), `anim` (7 2D-animation clips, 1080p), `tv` (4 TV-anime frames,
lossless inputs only). Chains: `chains.py` (`movie` and `anime` are the shipped
presets - keep them in step with `gpu-toggles.lua`). Columns: luma PSNR/SSIM,
colour PSNR (Cb/Cr), GMSD, edge sharpness relative to the reference (1.00 = as
crisp), halo (overshoot past the reference's local range, 8-bit levels), VMAF
and VMAF-NEG (VMAF rewards plain sharpening; NEG does not). Results are cached
per frame; an interrupted run resumes.

Sources: the YouTube UGC dataset (Google, CC BY 4.0, raw clips; the clip list
and credits are in `make_dataset.py`) and Anime4K's own comparison frames
(`bloc97/Anime4K`, pinned commit). Disk: renders are ~10 MB each (16-bit PNG);
a full run of ten chains needs ~15 GB.

Traps met while building it: mpv's `--no-config` makes `~~/` empty, so
`gpu-toggles.lua` resolves its shaders to bare `shaders/...` and loads none -
probes that go through the script need a real `--config-dir`; and the script
joins `glsl-shaders` with `;`, the Windows separator, so only the pinned build
(not the Linux mpv) can run it as-is.
