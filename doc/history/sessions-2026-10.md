# Session history: this mpv config repo, October 2026

Continues [`sessions-2026-09.md`](sessions-2026-09.md) (same rules: this is the
engineering log; `AGENTS.md` holds the current state and is read first).

---

## 2026-10-03 - every upscaler against ground truth, on the player's own build

The ask: look at the upscalers again - better models, more of the RX 9070 XT,
better picture for movies and anime - "it works really good at the moment",
so anything new must be measurably better, every drawback named, and each
change a pull request that can be reverted.

### What this session could and could not do

It ran in a cloud container, **not on the player PC**: no RX 9070 XT, no
Windows, no display. So the quality work used mpv's real renderer on Mesa's
lavapipe (Vulkan on the CPU), which reproduces a GPU's output exactly but not
its speed. GPU cost was estimated from the real `vo-passes` numbers already
measured on the card (2026-09-13, Vulkan: Anime4K C+A HQ 3.40 ms, FSRCNNX +
SSimSuperRes 4.07 ms, SSimSuperRes 1.12 ms, ArtCNN C4F32 8.43 ms at 1080p ->
1440p) and published numbers; the real check is `tests/run-tests.ps1 -Tier gpu`
on the PC (gpu-pacing now covers Anime at 480p/720p/1080p, below).

### Method (`tests/upscale-bench/`, committed)

- **Reference material** - nothing of it is in the repo. The YouTube UGC
  dataset (Google, CC BY 4.0, raw uncompressed clips; `storage.googleapis.com`
  was reachable when download.blender.org, media.xiph.org and archive.org were
  not): 10 live-action 2160p clips (vlogs, sport: faces, foliage, text, water,
  crowds) -> 1920x1080 references with full-resolution colour; 7 2D-animation
  1080p clips (anime-style line art, flat-colour cartoon, sand animation,
  painted 2D, two black-and-white); 4 TV-anime frames from Anime4K's own
  comparisons (Fate, Maxed, Quin, Slime).
- **Inputs** at the ratios this screen really gets: 1080p, 720p and 480p on
  2560x1440 = 1.33x, 2x, 3x (played as 1440x810 / 960x540 / 640x360 into a
  1920x1080 window). Each as a lossless downscale and as two real x264 encodes
  of a contiguous sequence (P/B frames as in a stream): CRF 22 (a good web
  encode: median ~3.6 Mbps at 1080p-class, ~2 Mbps at 720p-class) and CRF 30 (a
  poor one: ~1.4 / ~0.7 Mbps). One frame per clip, deep in the sequence.
- **Renderer**: mpv's gpu-next, the chain's own shaders and options
  (profile=high-quality incl. scale-antiring 0.6; deband and dither off),
  grabbed with `screenshot-to-file window`. A 1:1 render reproduces the
  source to 70 dB.
- **Metrics**: luma PSNR/SSIM, colour PSNR (Cb/Cr; at 4:2:0 resolution where
  the reference's colour only exists there; black-and-white clips excluded),
  GMSD, edge sharpness relative to the reference, halo (overshoot past the
  reference's local range near edges), VMAF and VMAF-NEG (Netflix v0.6.1;
  VMAF rewards plain sharpening, NEG does not). Plus crops judged by eye.

### The trap that almost shipped a wrong change

The first runs used Ubuntu's mpv 0.37 / **libplacebo 6.338**. There, dropping
Anime4K's AutoDownscalePre passes looked like a clear win (+1.2 dB at 1.33x and
3x on real encodes, VMAF-NEG +3 at 3x, half the halo) and was implemented.
Re-rendering with the **pinned Windows build** (mpv 0.41 / libplacebo 7.374,
`mpv-build.json`, under Wine on the same lavapipe) changed the picture:

- FSRCNNX, SSimSuperRes, CfL, adaptive-sharpen, CuNNy and mpv's own scalers
  render bit-identically (or to 78-80 dB) on both builds - every Movie
  finding transfers.
- **Anime4K does not**: the shipped Anime chain scored 1 to 2.7 dB better on
  the pinned build at every ratio, at exactly 2x too (where AutoDownscalePre
  does not run). Isolated: Upscale_Denoise alone is identical on both; with
  AutoDownscalePre_x2 the old libplacebo lost 3.6 dB in that resize, the new
  one ~0.3.
- On the pinned build the AutoDownscalePre "fix" is +0.3 dB at 1.33x and
  -0.2 to -0.8 dB with MORE halo at 3x: no gain, for ~1.5x the GPU work. The
  draft was dropped.

Rule kept in the harness: decide on `MPV_BENCH_RENDERER=pinned` numbers.

### Movie: the shipped chain stays

Live action, real encodes (10 clips; luma PSNR / VMAF-NEG; `movie_nosharp` =
the shipped chain without adaptive-sharpen, to compare the upscalers alone):

| CRF 22 | 1.33x | 2x | 3x |
|---|---|---|---|
| plain (no shaders) | 39.33 / 98.02 | 36.94 / 96.68 | 34.72 / 91.54 |
| shipped, no sharpening | 39.19 / 98.24 | **37.27 / 97.36** | 34.96 / **94.66** |
| FSRCNNX alone (+CfL) | 39.44 / 98.27 | 37.28 / 97.36 | 35.06 / 94.11 |
| AiUpscale HQ (2x / native 3x, +CfL) | (not run <1.4x) | 37.07 / 97.41 | 34.84 / 94.30 |
| AiUpscale HQ Sharp | - | 36.95 / 97.47 | - |
| shipped (with Auto sharpening) | 37.06 / 97.97 | 35.25 / 97.25 | 32.98 / 93.81 |

- Nothing beats FSRCNNX + SSimSuperRes at 2x/3x; at 1.33x everything is
  within +-0.25 dB of plain scaling (a 1080p source has little left to gain).
  AiUpscale (Alexkral, FSRCNNX-based "photo" models, incl. a native 3x) looks
  a bit sharper but is not more faithful, and its 3x model loses to FSRCNNX's
  2x + SSimSuperRes. RAVU/NNEDI3/FSR/ArtCNN were already rejected 2026-09-21.
- **CfL chroma** re-checked on true 4:4:4 references: +0.1 to +0.5 dB on every
  real encode (all ratios, both qualities), but -0.3 to -1.8 dB on pristine
  lossless 4:2:0 - real files and streams are always compressed, so it stays.
- **Sharpening** (2026-09-25 design) behaves as designed: edge sharpness
  0.95-1.10 of the reference on CRF 22 sources, VMAF up, PSNR down. Unchanged.

### Anime: the shipped Anime4K C+A (HQ) stays; CuNNy offered as an option

Pinned build. TV frames (lossless) and 2D clips (real encodes); luma PSNR /
VMAF-NEG / halo:

| | TV 1.33x | TV 2x | TV 3x | 2D CRF22 1.33x | 2D CRF22 2x | 2D CRF22 3x |
|---|---|---|---|---|---|---|
| plain | 45.58 / 98.84 / .01 | 38.32 / 97.79 / .03 | 32.78 / 94.73 / .09 | 34.69 / 96.60 / .07 | 31.12 / 93.46 / .08 | 28.59 / 87.44 / .10 |
| **shipped Anime4K C+A HQ** | 33.70 / 97.66 / .51 | 32.23 / 97.23 / .66 | 30.01 / 94.44 / .99 | 31.34 / 96.93 / .24 | 29.55 / 95.48 / .24 | 27.57 / 91.80 / .37 |
| same, no AutoDownscalePre | 34.95 / 97.96 / .45 | = | 29.20 / 95.06 / 1.36 | 31.62 / 97.13 / .25 | = | 27.34 / 92.59 / .47 |
| bigger: Upscale_Denoise UL + L | 34.25 / 97.88 / .40 | 32.80 / 97.47 / .54 | 30.63 / 95.17 / .76 | 31.49 / 96.97 / .20 | 29.76 / 95.49 / .19 | 27.82 / 91.65 / .28 |
| **CuNNy-4x32-DS** | 40.28 / 98.54 / .14 | 37.64 / 98.15 / .09 | 35.69 / 97.21 / .11 | 34.20 / 97.39 / .13 | 31.35 / 95.16 / .09 | 29.31 / 91.74 / .12 |
| CuNNy-8x32-DS | 40.01 / 98.53 / .14 | 37.51 / 98.16 / .10 | 35.94 / 97.33 / .11 | 34.32 / 97.41 / .14 | 31.51 / 95.09 / .09 | 29.36 / 91.65 / .11 |
| Ani4K v2 (ArtCNN C4F32) | 42.24 / 98.20 / .03 | 36.99 / 96.30 / .03 | 31.79 / 83.44 / .06 | (Linux) 33.83 / 96.55 | 30.50 / 92.05 | 28.09 / 77.65 |

At CRF 30 the order is the same, but there Anime4K's clean-up wins the
perceptual scores a little (VMAF-NEG 2x: Anime4K 91.91, CuNNy 91.19).

- **Anime4K's look is a style, not an error**: its C+A chain denoises and
  restores lines - background texture (tatami weave, paper grain) is wiped
  flat, outlines get crisper and darker, at 3x lines thicken. That costs
  fidelity (-12 dB on clean TV frames) and VMAF-NEG likes it on bad sources.
  The user compared it against ArtCNN and preferred it, so it stays the
  default.
- **Anime4K variants** (pinned): no AutoDownscalePre - see the trap above; the
  bigger UL/L networks - +0.1 to +0.6 dB, less halo, but slightly softer, 2-4
  dB worse red-difference colour on the TV frames (colour fringes at
  edges) and twice the GPU work: not worth it. Measured on libplacebo 6.338
  only: CfL in front - +0.1 dB colour on encodes, -2.4 dB on clean frames: no;
  Mode A (HQ): worse everywhere.
- **CuNNy-4x32-DS** (funnyplanter, LGPL 3, trained on visual-novel CG; 2x,
  luma, compute shaders in fp16 - RDNA4 runs packed FP16 at twice the FP32
  rate): far more faithful (+1 to +6.6 dB), a tenth to a half of the halo, keeps
  texture, sharpness close to the reference on clean frames (0.92-1.02), the best VMAF-NEG on
  clean frames and on good encodes at 1.33x; on poor encodes it is a little
  behind Anime4K on VMAF/VMAF-NEG. A different look, not a strict upgrade -
  offered as a separate pull request so it can be judged by eye and closed
  or reverted. 8x32 is no better than 4x32 at about twice the cost.
  **Outcome: rejected by the user the same day - see the last section.**
- **Ani4K v2** and **AnimeJaNai V3** (GLSL ports, dyphire/mpv-config): faithful
  at 1.33x but soft at 2x/3x (one 2x stage; VMAF-NEG at 3x 71-83 and 78-91,
  Anime4K 82-94). No.

GPU cost, estimated (not measured - see above; **the real cost, measured
later the same day on the card, was about twice this - see the last
section**): CuNNy's own figures (RTX 4090,
1080p input) are 3.05 ms for 4x32-fp16, Anime4K_Upscale_VL 1.7 ms; the RX 9070
XT's packed-FP16 rate is about the 4090's, so ~3-5 ms at 1080p input (Anime4K
C+A HQ: 3.40 ms measured), ~1.5-2.5 ms at 720p, ~1 ms at 480p - well inside
the 13.9 ms a 24 fps video leaves at the 3x speed key. lavapipe CPU timings
could not serve as a proxy: their ratio to the real GPU spread 1,300x-9,900x
across shader styles (fragment vs compute) and repeated runs of one pass
differed 2x.

### Other changes made

- `gpu-toggles.lua` publishes the preset family on screen
  (`user-data/gpu-toggles/preset` = anime / movie / off); the shader cache's
  capture (`shader-cache/main.lua`) and the gap hunt label what they learn by
  it. They guessed from the shader file names ("Anime4K", "SSimSuperRes"), so
  any chain built from other files would have been learned as "no upscaler"
  and replayed without its shaders. test-upscale checks the value; a break
  (no publish after a switch) turns it red.
- gpu-pacing plays Anime at 1080p and 480p too (only 720p = exactly 2x, the
  cheapest path, was covered): 1.33x is the most common FastStream anime
  stream and the costliest Anime path, 3x the one that runs both Anime4K
  stages.

### Harness traps (cost a cycle each)

- `--no-config` makes mpv's `~~/` empty: gpu-toggles then resolves its
  shaders to bare `shaders/...` and loads none - the render is plain scaling
  and looks like a valid result. Probe the script with a real `--config-dir`.
- gpu-toggles joins `glsl-shaders` with `;` (Windows): a Linux mpv takes the
  whole list as one missing file. Drive the script on the pinned build.
- A cached VMAF from a one-clip smoke test survived into the full run;
  results now record the frame count they were computed on.
- Uncompressed 16-bit PNG renders (16 MB each) filled the disk mid-run.
- `pkill -f <pattern>` matched the shell running it (exit 144) - match a
  pattern the command line itself does not contain.

---

## 2026-10-03 (later) - re-run on the player PC; decision: Anime4K stays

The user asked for both pull requests to be tested "really good" on the PC
itself - is CuNNy better, should it replace Anime4K or be added as an option -
with screenshots and a side-by-side video, and then decided: **Anime4K C+A
(HQ) stays the Anime preset. CuNNy is not used, neither as a replacement nor
as a menu option; PR #31 was closed.** In the user's words: "anime4k is better
... so we do not ever test it again". Do not re-run this comparison or
re-propose CuNNy - or another "faithful" 2x CNN of its kind; ArtCNN lost the
same way in 2026-09 - for the Anime preset.

### What was measured (RX 9070 XT, pinned build 20261002, Windows)

- **Quality**: the `tests/upscale-bench` harness with its rendering done
  natively on the card - the pinned mpv.exe in a window that is created but
  never shown (shader-cache/host.ps1's trick), `screenshot-to-file window`,
  VMAF through ffmpeg's libvmaf with the same v0.6.1 models. Every number
  matched the cloud's lavapipe run to within ~0.07 dB (TV 2x: Anime4K 32.22 vs
  32.23, CuNNy 37.71 vs 37.64; 2D CRF 22 at 1.33x: 31.33 vs 31.34 and 34.19 vs
  34.20): CuNNy's fp16 maths on RDNA4 change nothing, the tables above stand.
  The Movie candidates too (AiUpscale HQ / HQ Sharp, FSRCNNX alone): no
  better than the shipped chain, as above.
- **At 1080p -> 1440p** (1.33x, most FastStream anime) plain scaling with no
  shader is the most faithful of all: TV frames 45.58 dB vs CuNNy 40.34 vs
  Anime4K 33.70; 2D CRF 22 34.64 / 34.19 / 31.33. A 1080p anime source has
  almost nothing left to recover at that ratio, so there every shader is a
  look, not a restoration.
- **GPU cost, measured** (vo-passes summed, 2560x1440 output, mpv.conf's
  renderer settings, Vulkan decode, 3 runs; ms per frame at 1x / 3x - the
  card clocks down at 1x):

  | source | Off | Anime4K | CuNNy 4x32 | CuNNy 8x32 | Movie |
  |---|---|---|---|---|---|
  | 1080p | 1.1 / 0.7 | 4.6 / 3.8 | 8.6 / 6.6 | 12.6 / 11.4 | 2.4 / 1.5 |
  | 720p | 0.9 / 0.5 | 2.9 / 2.2 | 4.6 / 3.0 | 7.0 / 5.1 | 2.9 / 2.2 |
  | 480p | 0.9 / 0.6 | 1.6 / 1.2 | 3.1 / 2.0 | 4.6 / 3.1 | 2.6 / 2.0 |

  The estimate above (~3-5 ms at 1080p) was half the real cost. The
  fullscreen gpu tier agreed (gpu-pacing, Anime at 1080p: CuNNy 7.99 ms, peak
  16.0; Anime4K 4.73 ms) with 0 dropped/late frames at 1x and 3x on both
  branches.
- **Shader gap hunt** on the CuNNy branch: 4 gaps of 324 (720p AV1 with film
  grain, 1712x720, 1440x1080, 8K - all of them the Anime chain), main 0: #31
  had not adapted the warm-up's shipped cases.
- **By eye**: crops of the test frames (with the original) and a
  side-by-side video from Morevna Episode 3 (an open-source anime, CC BY-SA
  3.0; its near-lossless 1080p master encoded like a 1080p and a 720p stream,
  played through the real player frame by frame at 2560x1440). At 1080p CuNNy
  looks like Off, slightly crisper; Anime4K gives bold, inked lines and clean
  flat colour; at 720p Anime4K also removes the stream's compression noise
  around lines, which CuNNy sharpens along with the picture. The user
  preferred Anime4K.

Result page (private to the user):
a private claude.ai artifact - it keeps the crops and
the web versions of the videos. The full-size videos and the benchmark data
(~20 GB in the gitignored `test-media/upscale-bench/`) were deleted after the
decision, at the user's request; `tests/upscale-bench/make_dataset.py`
rebuilds the data if it is ever needed.

### Notes for the next test run on this PC

- The 4 clipboard checks of `source-info` (`clipboard/text` reads back nil)
  fail on this PC when the suite is started from an agent's shell - on main
  too; they pass on CI. Not a regression.
- `-Tier gpu` run from a git worktree fails `gpu-warm-cache`: the worktree
  has no `portable_config/cache`, so the check sees a cold cache. Check
  against a copy of the real cache instead (`installer/warm-shader-cache.ps1
  -CacheDir <copy> -Check`).

---

## 2026-10-03 (evening) - lint to zero; mpv's build pinned instead of committed

**Lint.** PSScriptAnalyzer had 25 warnings on CI: 24 in shinchiro's
`installer/updater.ps1`, one in `tests/lib/gap-media.ps1` (`New-GapClip` ->
`Build-GapClip`). A verb-rename of updater.ps1 was made, proven behaviour-equal
(old and new script run side by side with stubbed download/extract/delete in a
scratch folder: identical output on the up-to-date, update-available, yt-dlp and
FFmpeg paths) - and then the user's next `updater.bat` run put upstream's copy
straight back: the archive ships it, and refresh-mpv-build.ps1 wanted every
archive file byte for byte. So `powershell-lint.yml` skips the paths in
`mpv-build.json`'s `upstream_files` instead (0 warnings). lua-language-server over
every tracked file: one problem, the `lua-api` stub of `mp.get_opt` without its
`key` parameter. The user keeps `ubuntu-latest` unpinned ("if an issue arises I
will fix it").

**Pin only.** The user, after that updater run left mpv.exe changed in git:
"every time I update I have to push to main ... only code changes need a GitHub
commit and push from me". Of three options (pin only; CI pushes builds to main;
keep the pull request) they chose pin only:

- mpv's own files and yt-dlp.exe left git (`.gitignore`); `mpv-build.json` pins
  the build. shinchiro's `updater.bat` / `installer/updater.ps1` / `settings.xml`
  went too: `updater.bat` is ours (`installer/update.ps1`: `git pull --ff-only`,
  `installer/install-mpv.ps1`, `yt-dlp -U`).
- `install-mpv.ps1` checks every pinned file by SHA-256 and installs from the
  archive only what differs; tested for real (an empty folder, again, a
  tampered file found by `-Check` and repaired, Windows PowerShell 5.1) and in
  the static tier with a stand-in archive.
- `mpv-auto-update.yml` commits only the json, on `mpv/<tag>`, runs the suite
  there and on green pushes the pin to main by itself; the "only another mpv"
  rule (LFS storage) went with the binaries. `mpv-update.yml`,
  `ytdlp-update.yml`, `refresh-mpv-build.ps1` and the old commit guards (three
  rules about committed binaries, `pre-merge-commit`, post-merge's restore)
  were removed; `pre-commit` now refuses a forced add of the binaries,
  `post-merge` says "run updater.bat" when the installed mpv.exe is not the pin.
- `regression-tests.yml` installs the pinned build with install-mpv.ps1, so CI
  proves the installer on the real archive on every run.

---

## 2026-10-04 - is mpv using the hardware? (FastStream decoding check)

The ask: "is MPV making full usage of my hardware, for example my GPU" for
FastStream, then "are you sure I have the VCN5 chip". Nothing changed in the
config; the answer and the facts behind it are in AGENTS.md ("Hardware decoding
on this PC").

**What was read, not assumed.**

- `mpv.conf`: `vo=gpu-next`, `gpu-context=winvk`, `hwdec=d3d11va-copy,no`
  globally and `vulkan,d3d11va-copy,no` in `[faststream-hwdec]`.
- The FastStream fork's `native-host/faststream-mpv-host.mjs` (main): mpv gets
  `--input-ipc-server`, `--fullscreen`, `--force-window=immediate`,
  `--no-terminal` and a per-file group (headers, title, start, subtitle files,
  the URL) - no GPU, hwdec or VO option. `mpvTargetUrl()` adds `fs-content=`
  whenever the content type is anime or movie, and `background.mjs`'s
  `resolveMpvContentType()` returns `movie` when neither the sender nor the
  allowlist names one, so every FastStream send matches the profile.
- libplacebo `src/vulkan/context.c`, `pl_vulkan_choose_device()`: without a
  device name or UUID the highest type wins - discrete 5, integrated 4, virtual
  3, software 2. The 9070 XT is picked over the Ryzen's iGPU every time (the
  47 iGPU blobs in the shader cache are from a one-off run on 2026-09-22;
  nothing in this config names a device).
- Linux amdgpu `soc24.c` (the RDNA 4 family; `amdgpu_discovery.c` uses it for
  GC 12.0.1): its only video block is VCN 5.0.0, decode list H.264 (up to
  4096x4096, level 5.2), HEVC, VP9 and AV1 (up to 8192x4352), JPEG - no MPEG-2,
  no VC-1. pci.ids: `1002:7550` = "Navi 48 [Radeon RX 9070/9070 XT/9070 GRE]",
  the device id the shader cache's pipeline blobs record.
- AMD's Adrenalin 25.10.2 release notes (2025-10-29): `VK_KHR_video_decode_vp9`
  for the RX 7000 and 9000 series. Vulkan AV1 decode came to AMD's Windows driver
  in 2024 (Khronos' AV1 decode announcement).

**`vulkaninfo` on the PC** (run by the user; Adrenalin 26.8.1):

| | RX 9070 XT | Ryzen iGPU |
|---|---|---|
| device id / type | `0x7550`, discrete | `0x164e`, integrated |
| Vulkan driver / API | 2.0.395 (LLPC) / 1.4.349 | 2.0.353 / 1.4.315 |
| decode extensions | h264, h265, av1, vp9 | h264, h265, av1 |
| decode queue | 1 queue: H.264, H.265, AV1, VP9 | 1 queue: H.264, H.265, AV1, VP9 |
| VRAM heap | 15.92 GiB, all host-visible (Resizable BAR on) | - |

The 9070 XT's decode profiles: H.264 4:2:0 8-bit Baseline/Main/High,
progressive and interlaced; H.265 Main, Main 10 (8- and 10-bit), Main Still
Picture; VP9 profile 0 (8-bit) and 2 (10-bit); AV1 Main 8/10-bit and Professional
12-bit 4:2:0, each with and without film grain. Encode: H.264, H.265 8-bit, AV1
8/10-bit. Queue families: graphics x8, compute x8, transfer x1, video encode x1,
video decode x1. Correction made in the session: 12-bit AV1 IS hardware-decoded
(the first answer had put all 12-bit on the CPU); what stays on the CPU is 10-bit
H.264, HEVC 4:2:2/4:4:4/12-bit, MPEG-2/VC-1 and VVC.

**Load, in numbers already measured** (2026-10-03, 2560x1440 output, Vulkan
decode): Anime4K at 1080p 4.6 ms per frame, Off 1.1 ms, Movie 2.4 ms - 3-11 % of
a 24 fps frame (41.7 ms), under a third at 3x. Heavier shaders are the only way
to load the GPU more, and the ones measured (CuNNy 8x32, 12.6 ms) lost to
Anime4K by the user's eye. `vd-queue-enable` (the manual: not with hardware
decoding), `display-resample` (fights FreeSync/LFC) and RIFE stay out.

**Loader warnings `vulkaninfo` printed, both harmless.** (1) "Removing layer
VK_LAYER_AMD_switchable_graphics ... because it is a duplicate": two AMD driver
packages in the driver store register the same implicit layer (the two GPUs
report different Vulkan driver builds, above); the loader keeps one. (2)
"VK_LAYER_OBS_HOOK uses API version 1.3 which is older than the application
specified API version of 1.4": OBS's own layer manifest
(`plugins/win-capture/graphics-hook/obs-vulkan64.json`) declares `api_version`
1.3.216 on OBS master as well - the first answer's "update OBS" was wrong, the
user's OBS was already the latest. The layer is implicit (loads into every Vulkan
program, mpv included), only works while OBS captures, and
`DISABLE_VULKAN_OBS_CAPTURE=1` keeps it out.

---

## 2026-10-15 - build 20261015's gpu tier: the test copy's own AMD cache

The rolling build PR (#104) pinned shinchiro's 20261015. Its libplacebo moved from
`1dd0226` to `804dc71`: the AMD proprietary driver marked `host_ptr_slow`, a layout
transition from UNDEFINED kept for transfers, the safety clamp in
`pl_color_delinearize`, deband grain no longer scaled by the SDR white level. The gpu
tier was due (a new pinned build) and had not run since the pink UI of 2026-10-12. The
owner agreed to it.

**First run** (a worktree with the build installed, a copy of the live shader cache):
1095 passed, 4 failed.

- `gpu-warm-cache`: 4 compiles, all for `dv-p8.1.mp4` (Dolby Vision). Every other chain
  hit the 20261014 cache. Expected for a new libplacebo; the fingerprint's `libplacebo`
  field makes the player warm up by itself after `updater.bat`.
- `gpu-auto-warm` phase 1 (empty mpv cache): `VK_ERROR_DEVICE_LOST` 0.9 s after the
  Anime chain began compiling, the D3D11 decoder's device removed with it (`887a0005`),
  and the warm-up then compiled nothing. Windows logged no driver reset; both display
  devices stayed OK. No further GPU run without the owner (AGENTS.md).

**Why not the build.** Every GPU test with a warm mpv cache passed on it, and the Anime4K
shaders were byte-identical to 20261014's (they hit its cache), so the device was lost
compiling what the previous build compiles too. AMD's per-application cache is keyed by
exe path, and the suite always runs `%TEMP%\mpv-regression\root\mpv.exe`. Its files
(the only ones in `%LOCALAPPDATA%\AMD\VkCache` the run wrote) dated from 2026-09-26,
the main one at exactly 16 MiB: the 2026-10-12 clean-up had cleared only the live path's.
The cold-cache test is the only one in which nothing comes from mpv's cache, which fits
the 2026-10-12 mechanism.

**Second run**, on the owner's go-ahead: those four `.parc` files deleted, `-Tier gpu
-Filter gpu-auto-warm` once. 169 passed: 153 compiles into the empty cache in 29 s with
no device loss, no dropped frames beside it, and phase 2 fresh. #104 was merged.

### Notes for the next gpu tier from a worktree

- A worktree made with `GIT_LFS_SKIP_SMUDGE=1` has an LFS pointer for `7z\7zr.exe`, and
  `installer/install-mpv.ps1 -Root <worktree>` then finds no 7-Zip: copy the real one in.
- Copy the live `portable_config/cache` into the worktree first (see 2026-10-03 above).

## 2026-10-17 - the UI that showed by itself

The owner: while watching, the UI sometimes flashed although he had neither pressed a
key nor moved the mouse - "maybe it is too sensitive". Worked from the cloud: no access
to his PC, so the mechanism was traced in the code and reproduced in a real mpv.

**The cause.** mpv's Windows window (`video/out/w32_common.c`) tracks the pointer with
`TrackMouseEvent`. When any other window covers the pointer for a moment - a
notification, an overlay, a popup - Windows sends `WM_MOUSELEAVE`; mpv turns it into
`MOUSE_LEAVE` (`mouse-pos`'s `hover` false). The next `WM_MOUSEMOVE` - Windows sends one
whenever the window under the pointer changes, at the same position - finds tracking off
and makes `MOUSE_ENTER`, while mpv drops the position itself as unchanged. So
`mouse-pos` changes its `hover` alone, back to true. uosc 5.13's `lib/cursor.lua` took
every change back to `hover` for a move and showed the whole UI (timeline, controls,
volume) until cursor-autohide (1 s). mpv itself does not count `MOUSE_ENTER` as mouse
activity (`MP_KEY_DEPENDS_ON_MOUSE_POS` is clicks and moves only), so the cursor stayed
hidden: a UI flash with nothing moving. Unchanged in uosc's main branch.

**Reproduced** in mpv 0.37 on Linux with this config and uosc (`--vo=sixel`, an OSD
surface without a window): pointer moved, UI hidden by autohide, then `keypress
MOUSE_LEAVE` + `keypress MOUSE_ENTER` (input.c's `feed_key`, the same branch the
Windows events reach): `user-data/uosc/bottom-ui` visibility 0 -> 1 for a second.

**The fix** (a marked local change in `uosc/lib/cursor.lua`, guarded by a static check):
a `mouse-pos` whose `hover` turns true again at the pixel of the last event is no move;
the UI stays as it is. A real move after it, a return at another place, a click, all
show the UI as before. `tests/headless/test-ui-hover.lua` (11 checks): green with the
fix; with upstream's cursor.lua 3 of them red.

**Not fixed, cannot be told apart from here**: a mouse that reports a real move of a
pixel or two (a high-DPI sensor and a bumped desk). Then the cursor appears with the UI -
mpv shows it on any move. If the owner still sees flashes WITH the cursor, a small
movement threshold for showing a hidden UI is the next step; it is not built blind.

## 2026-10-17 (later) - the UI that never went

The owner, after the flash fix: sometimes the UI stays up for good while he does not
touch the mouse. Reproduced in mpv 0.37 with this config (the same `--vo=sixel` set-up,
the pointer moved by mpv's `mouse` command, then left still for 3 s):

| the pointer rests | after 3 s |
|---|---|
| over the video | hidden after 1 s (cursor-autohide) |
| on the bottom edge (the timeline), on the control row | **still shown**, mpv's cursor too |
| anywhere, after Tab | still shown (cursor hidden): Tab is `uosc/toggle-ui`, a pin |
| a right-click menu opened and closed with Esc | hidden |

**The cause.** uosc's `cursor:is_autohide_allowed()` refused while `is_dragging_prevented`,
i.e. whenever the pointer is on something clickable (`decide_keybinds()`: a primary
zone without `window_drag`). The comment in uosc says so: "anything that disables
dragging also implicitly disables cursor autohide". And uosc's mouse sections there
carry no `allow-hide-cursor`, so mpv (`test_mouse_active()`) kept the cursor up too. A
pointer parked on the bottom edge in fullscreen is on the timeline; one left on a button
just clicked is on that button: the whole UI stayed for the rest of the film.

**The fix** (a marked local change in `uosc/lib/cursor.lua`, a new uosc option
`autohide_over_controls`, default 0 = uosc's way, 3000 in uosc.conf): on the UI itself the
UI now hides after 3 s of a still pointer - longer than the 1 s over the video, so a
tooltip can be read - and never while the left button is held there (a timeline or
volume drag; mpv sends a release to the binding that got the press and releases all
buttons when the window loses the focus, so "held" cannot stick) or while a menu is
open. Once uosc has let go, its sections go off and mpv hides the cursor 1 s later. A
click after that, without a move first, reaches input.conf (pause), as anywhere over a
hidden UI. Tab keeps pinning: that is what it is for (AGENTS.md, Troubleshooting).

**Checked**: `test-ui-hover.lua` grew 11 checks (the timeline and the volume slider stay
past 1 s and go within the next 3 s; 4 s with the left button held keeps the UI, and
after the release the rest time starts again); 22 pass, with the change reverted 3 are
red, with the held-button guard dropped 2. The probe above again: everything goes within
4 s except Tab; a right-click menu stays open 5 s under a still pointer. The test clip
needs a sound track: without audio uosc draws no volume slider.

## 2026-10-17: Space stops the autoplay countdown

**The wish**: at an episode's end, Space (the easiest key) should stop FastStream's
countdown to the next episode. **Before**: only the autoplay button / Ctrl+a stopped it,
and that switched autoplay off for good (saved). Space at the end did nothing: with
keep-open mpv stays paused on the last frame, and a second Space changes no property, so
the extension could not see it.

**Now**: input.conf's Space and `mbtn_left` send `script-message faststream-pause` along
with `cycle pause`. FastStream's relay watch (host 15, no host change) maps it to a
`pause` request; the extension cancels a running countdown, says "Autoplay: stopped (n:
next episode)" and leaves autoplay on for the next end. With no countdown, or no helper,
nothing more happens (faststream-episodes.lua has no banner for it). The countdown notice
now reads "next episode in 5 s (n: now, Space: stop)". Tests: test-faststream-episodes.lua
(the bindings, Space sends it and pauses, no banner without a helper); FastStream's
backgroundMpv/MpvRelayWatch unit tests.

## 2026-10-18: one Quality button

**His question**: mpv had two stream quality buttons, one that worked and one that "is just
there" - a mistake, or both needed?

**What it was**: uosc's own `stream-quality` button had been in the bar since the setup
began (2026-09-10), without uosc's `<stream>` condition, so on every file. On 2026-09-12 its
menu was rewritten to list the file's video tracks by height instead of uosc's fixed
ytdl-format list (unmarked, unguarded: a uosc update would have undone it). But this mpv
build makes an HLS master's variants editions (`--flatten-editions=no`, mpv since
2026-05-01) and shows only the playing one's tracks, and ytdl_hook's `all_formats` (its
default) makes YouTube's formats editions too: that menu had one row nearly everywhere,
and the rewrite had taken YouTube's size choice away. `faststream-quality.lua` (2026-10-13)
then added the page's own files (FastStream's `fs-quality=`), with the same icon.

**Now** (his pick, option C): one Quality button. The page's files when FastStream sent
them, else the stream's own variants: editions (HLS, YouTube) switched as a file-local
`edition` - `edition` itself would carry its index into the next file - or video tracks
(DASH) as a file-local `vid`; one row per height and frame rate ("1080p60"; the badge
then shows the height). An edition's size is read from the title mpv composes ("Bitrate:
900 kbps (h264 640x360 60 fps)", yt-dlp's "134 - 640x360 (360p60) (h264)"); a Matroska
film's editions (cuts) name no size and their tracks no program, so they stay editions.
uosc's `stream-quality` left the bar and its menu is uosc's own code again; Editions hides
while its editions are a stream's variants. Video > Quality in the right-click menu.

**Measured** (headless, the pinned build, local fixtures): an HLS edition change restarts
playback at 0 (mpv resets playback for formats whose timestamps may reset); `seeking` is
true right after the set, and the script seeks back to the old position once that restart
is done. The EDL's and the tracks' switches keep their place and send no restart, so the
seek-back is armed only when `seeking` says one is coming. The test media's `variants/`
(test-faststream-quality.lua, phase `variants`) covers all three kinds. glm reviewed it
twice: the file-local `vid`, no pick while a file loads and the badge cut came from it
(its "no picture on the next file" for a global `vid` was wrong: mpv resets a track
option naming a missing track to auto).

**The CI flake on its PR**: config-load failed once on CI ("client removed during hook
handling"; main and two local runs passed). mpv prints it when a client it awaits for a
hook is gone (`command.c`, `mp_hook_test_completion`). The quality script has no hooks;
mpv's built-in auto_profiles registers four at start and `exit()`s on its first
`profile-list` notification when no profile has a condition, so a hook sent in between
(on_before_start_file, at once with `--frames=1`) went unanswered. No profile here has one:
mpv.conf now has `load-auto-profiles=no`, and the static tier checks that no
`profile-cond=` comes in beside it.

**Build 20261018** (#110, merged the same evening on his word; mpv's changes were macOS-only
and a Matroska DiscardPadding fix, libplacebo unchanged): the gpu tier, run from the updated
live install with no mpv open, 1137 passed, 0 failed, no device loss.

## 2026-10-18 (late): TODO.md closed, CI skips docs-only changes

**TODO.md** was removed by the owner after the hand tests (commit "delete todo done"). What it
still listed stays as it was: 16x plays silent (scaletempo2 mutes above 8x, `max-speed=8`);
Movie upscaling judged by eye on his own 1080p films; real 4K output never measured; FastStream's
helper as a release asset; and the three left on purpose (a live stream's one pointless seek on
reopening, two windows from two streams within a second, stream-buffer's "window" mode never
reported with disk buffering off). Its previous version: `doc/history/todo-until-2026-10-12.md`
and git.

**CI** (his wish: deleting a Markdown file ran every workflow). regression-tests.yml has a first
job, "what changed" (ubuntu, seconds): a push or pull request that changes only `*.md` and
`doc/` skips the Windows suite, and the run still ends green, so publish.yml - which waits for
it on main - publishes the docs as before. A run by hand (mpv-auto-update dispatches one), or a
push whose earlier commit is unknown, runs the suite, and so does a diff that fails (glm's
double check: a `|| true` over the whole pipe had read a git error as docs-only). lint-lua.yml,
powershell-lint.yml and mpv-auto-update.yml's push trigger ignore docs-only changes the same
way (`paths-ignore`); lint-lua keeps running for every other change, as he asked on 2026-09-24.
glm's recheck found the hole that remained: a newer push cancels a running suite
(`cancel-in-progress`), so a docs push right after a code push compared only with that code
commit, skipped, ended green - and publish.yml would have published the untested code. A push
now compares with the newest commit whose run of this workflow passed (`gh run list --status
success`, an ancestor of the push), so a cancelled commit stays in the range; a pull request
compares its whole range anyway.
Checked on the history: the TODO deletion and #105 come out docs-only, #111 not.

## 2026-10-20: one window for the files opened from Explorer

**Report:** a song opened from Explorer while another played opened a second mpv window.
**Cause:** the defaults the owner had picked (`.mp3`, `.wav`, `.mkv`, `.mp4`, `.avi`) are
mpv's own file types from `installer/mpv-install.bat` (`io.mpv.<ext>` for the whole PC;
Windows 11 names the choice in `UserChoiceLatest`), whose `play` and `open` verbs start
`mpv.exe` itself. `mpv-single.exe` was only a separate "Open with" entry (`mpv-single.File`)
that never was the default.

**His decisions:** an opened file replaces what plays, as in Windows Media Player; the second
window is a corner banner offered after the replace, and Ctrl (no ask-every-time dialog);
with several windows, the one used last; and local with local - a window playing a stream
(FastStream's, HLS, YouTube, any URL) never gets a local file, which then gets its own window.

**What changed:** `mpv-single-register.ps1` gives mpv's own file types (`io.mpv.*`,
`mpv.File`, `Applications\mpv.exe`, this folder's mpv only) a per-user command that starts the
launcher, the old one kept in `mpv-single-was` for the unregister; the one-click setup runs it
after `mpv --register`, its uninstall undoes it. The launcher gives every mpv it starts its own
pipe and hands a file to the front-most one that plays a local file or nothing (`path` over
IPC), through `single-instance.lua`, which snapshots the old playlist and shows the banner;
a click puts it back (same second, pause kept via auto-start's keep-pause) and starts
`mpv-single.exe --new-window --start=<s>` for the new file. Measured before relying on it: a
per-user command over a PC-wide ProgId (`io.mpv.ay`, then removed) resolved through
AssocQueryString to the user's command for both verbs, while the PC's default verb, type name
and icon still applied.

**Found on the way:** WIN32_FIND_DATA declared with `long` times is padded, so every pipe name
read from `\.\pipe\` was shifted and no window was ever found (the burst check passed only
because a burst uses the remembered pipe); mpv reports a local path with `\` (the script and
the test compare paths normalized); a test read `pause` before auto-start's `file-loaded`
handler had run (tests/README now says to wait for the settled value).

**Reviews**, glm-5.3-flash and, at the owner's request, a Claude subagent, each checked against
the code and the other. Fixed: a Ctrl open within a second of a plain one joined its playlist;
a launcher whose gate wait timed out (a 15-file burst takes its last one about 11 s) ran
unlocked - now 60 s, then a window of its own; the launcher started mpv.com, whose mpv is not
in GUI mode (pseudo-gui) - a song without a picture would have had no window at all; a double
click on the banner also toggled pause and fullscreen; the unregister restored over a command
another mpv registered since; files of a burst came twice into the playlist after autoload.lua
had queued their folder (also before this change); the test players' pipes now have a prefix
of their own (`MPV_SINGLE_PIPE_PREFIX`), so a file opened meanwhile never lands in one; a start
check that could not fail; a Ctrl check (`MPV_SINGLE_CTRL`). Refuted: `WaitForPipeDrain`
throwing on an asynchronous pipe (the check of an mpv without the script passed with no extra
player); per-user keys hiding the PC's values (measured above). Left: a window that was not
started by the launcher (the Start menu's mpv, mpv.exe directly) gets no files - put to the
owner. Each new check went red with its fix taken out (GUI mode, start position, double click,
the duplicate). Not covered by the suite: which of several windows is in front (no window under
`vo=null`): checked by hand after the merge.

## 2026-10-20 (later): a flaky HLS check was a real race; reviews of CI

**faststream-quality "HLS: a seek after the switch stays"** failed once on CI (time-pos 6.04
for a seek to 1). Reproduced on purpose: while an HLS variant switch's restart is pending,
mpv starts a seek only once the restart is done - after the script's `playback-restart`, whose
seek back to the old position then replaced it. So a user seeking within the second after a
quality switch lost the seek. The script now seeks back 0.1 s later, and only when no seek came
meanwhile; it publishes `user-data/faststream-quality/returning` while its way back is to come,
which the test waits for (time-pos still shows the old position during the restart, so the
old wait passed too early). A new check seeks during the restart: with the old seek back it
fails as CI did (time-pos 6.10), with the fix it passes.

**glm-5.3-flash reviewed the CI and update flow** (checked against the code): a build whose
suite run ended without a test result (queued past the wait, cancelled) kept its `mpv/<tag>`
branch, which reads as "failed its tests", so it was never tried again - now the branch goes,
the next run retries, and the workflow-failure issue says what happened. `mpv-single.exe` now
carries its source (`/resource:mpv-single.cs`), and the static tier checks that it is the
committed `mpv-single.cs` (a pointer on CI, so locally). Refuted: GitHub disabling the daily
schedule after 60 quiet days (public repositories only); the shader installer and `//!` rules
(the static tier checks both). Left: the Actions minutes of this private repository (not
readable with this login's token scope) and a mirror of the pinned build against shinchiro
pruning it after about 30 releases (only matters if updates go unmerged for a month; the
failure issue warns).

## 2026-10-20 (evening): no mpv build merged untested on the GPU

The owner asked how a problematic mpv build is kept from being merged: shinchiro builds
mpv's newest commit every day, not releases. What the suite covers (static + headless on
CI, ~1100 checks against the exact binary: options, scripts, playback, streams, IPC) and
what it cannot (no GPU: Vulkan, d3d11va, the shader chains) stayed as they were; two guards
came beside them, at his choice ("upstream CI + GPU check first", over automatic GPU runs on
his PC - unattended GPU runs are what crashed Windows on 2026-10-12).

- **mpv's own CI**: the build's commit is in its asset name, and mpv tests every commit on
  GitHub (51 check runs on 6a262d11f6, the 20261020 build: 46 passed, 5 skipped). A build of
  a commit with a failed check is not offered; one still being tested waits a day.
- **The GPU flag** (`gpu-flag.yml`, `.github/scripts/gpu-flag.ps1`; his wish: "info in the
  pull request's title when something in the GPU pipeline changed"): a pull request that
  changes shaders, gpu-toggles, the shader cache, renderer/hwdec options in mpv.conf or in a
  script's quoted option names, or an mpv build whose upstream diff reaches video output
  (vulkan, gpu-next, d3d11, hwdec, the window, frame timing), libplacebo, or FFmpeg's D3D11
  decoding, gets `[GPU: <areas>]` in its title, the label gpu, a comment listing why, and the
  pending check "GPU tier (local)". `tests/try-gpu.ps1 -Pr <n>` installs the pull request's
  commit and pinned build into %TEMP% (a worktree; the live folder untouched), runs the gpu
  tier there and sets the check; a lost device marks the commit so it is not run again
  without -Force. The 20261018 -> 20261020 update would have read `[GPU: vulkan, hwdec,
  libplacebo]` (hwdec_vulkan.c and vulkan/context.c changed upstream; FFmpeg's 117 commits
  had none in D3D11 decoding). The bot's pull requests start no pull_request workflow, so
  mpv-auto-update.yml calls the script itself.

## 2026-10-20 (night): the final checks on the PC

**GPU tier** on #116 with mpv 20261020 (tests/try-gpu.ps1's first run): 1234 passed, no
device loss; every chain decoded with d3d11va-copy and rendered with no dropped, late or
mistimed frames at 1x and 3x. The one failure, "shader cache is warm", was the script's own:
a fresh folder has an empty cache, so try-gpu.ps1 now warms it first (rerun: 0 compiles).

**Single window with real windows** (the suite has none): a file went to the front-most mpv,
and Ctrl opened a new one - but with the front one minimized, the next file still went there:
a minimized window keeps its place in the z-order. The launcher now takes the front-most
window that is not minimized, a minimized one only when all are. The same check showed the
banner drawn from x=-57 in a 320x180 clip's window: notify.lua's cards were never narrower
than their text; they now fit the window (test-notify-narrow.lua, red without the fix).

## 2026-10-21: the GPU flag, wider; an all-clear for mpv builds

The owner: every mpv update pull request must say whether it can be merged on green, or
needs the GPU tested here - he will not read code per update. The first real flag (#118,
20261021: only stream_curl.c changed upstream, FFmpeg's 159 commits none in D3D11 decoding)
was right. Reviewed against "anything GPU-related", two areas were missing: mpv's decoder
choice (`video/decode/`, vd_lavc picks d3d11va-copy) and its colour and pixel-format code
(csputils, mp_image, img_format, fmt-conversion, repack); and in FFmpeg the hardware
decoding layer under D3D11 (hwaccel, hwconfig, decode.c, hwcontext.c). Both count now
(static tier: 18 cases). An mpv build with nothing GPU-related gets a comment saying so in
so many words - merge it when every check is green.

## 2026-10-21: Shift+S, and the episode keys for local files and media keys

The owner wanted Anime lines and Movie sharpness without the menu, and Shift+N / Shift+P
for the episodes. Of the options put to him (one smart key, a numbered quick menu, a toolbar
button) he took the smart key: **Shift+S** steps the setting of what runs - Anime's lines
(Crisp <-> As drawn), Movie's sharpness in the menu's order (Auto, Off, Low, Medium, High) -
with a banner listing every choice, the one now in brackets; with no chain running it only
says how to start one (a setting changed unseen would surprise later). It replaces mpv's
default Shift+S (a screenshot without subtitles). **Episodes**: Shift+N next, Shift+P
previous (N was previous until now; n stays next), and, at his question, the keyboard's media
keys Next / Previous track (NEXT / PREV: mpv gets them focused, and in the background through
Windows' media controls, `media-controls=yes` by default). Without a FastStream helper they
play the playlist's neighbour - for a local file the next file of its folder, which
autoload.lua queues - and say when there is none; a FastStream video keeps its banner (its
episodes are the page's). Tests: test-upscale (Shift+S in Movie, Anime and with nothing on),
test-faststream-episodes (the folder's next / previous, the media keys, the banners),
test-keys (every episode key's message), the tour's keys checked against input.conf.

**An eaten backslash.** An editing tool read `tests\try-gpu.ps1` as an escape, so AGENTS.md
and the description of the "GPU tier (local)" check (gpu-flag.ps1) said
`tests<TAB>ry-gpu.ps1`. Both are fixed, and the static tier now fails on any TAB in Markdown,
PowerShell, workflow, C#, `.conf` or `.bat` files: none of them holds one on purpose. The
check was red on the damaged tree.

**No cancelled runs on main.** Regression tests, Lua style and PowerShell lint cancelled a
running run when another started on the same branch. On main that happened when two merges
came minutes apart, and on 2026-10-21 when a delayed push run met one started by hand. GitHub
then showed the commit with a red X, which reads as a failure. Now only a pull request's newer
push cancels its older run; every other run has a group of its own (`github.run_id`) and runs
to its end.

## 2026-10-21: mpv-config is the only repository

Until now the work happened in a private workspace (`Nawid3333/mpv`), and a workflow
published its tracked files to this repository as one commit per change, after checking
them for personal data. The owner asked whether to make the workspace public instead of
keeping two. Not that: its history holds commits with his private words and his Windows
user path, plus 122 pull requests and issues and their Actions logs. He chose to keep this
repository, whose history was clean and whose URL the installers, the updaters already
installed on other PCs and FastStream's docs use, as the only one, and to archive the
workspace.

What changed with it: the publish workflow, its script and `.publishignore` are gone, and
Dependabot and the stylua update (until now workspace-only, since the next publish would
have overwritten their pull requests here) run here. As the history is public now too, a
**push guard** (`.githooks/pre-push`, sharing its rules with the commit guard through
`.githooks/privacy.sh`) checks every commit a push sends before anything leaves the clone:
identities, messages, added lines, file names, forced-in ignored files - each commit, not
just the last, since a word one commit adds and the next removes is still published. It also
covers commits the commit guard never saw (`--no-verify`, a clone without the hooks), the
branch or tag name the remote gets, and an annotated tag's message; a push whose commits git
cannot list is refused. CI's new **privacy job** runs `tests/lib/privacy.ps1` on every push,
docs included (the suite itself skips docs-only changes), with the `PRIVATE_WORDS` secret:
every tracked file, and the new commits' identities and messages and a pull request's branch
name, for a push made without the hooks. A private word inside a reported path is printed as
`***`. glm's review found those gaps; it also led to finding that both guards refused mpv's
manual (its example path `users\USERNAME`), which the static check had always left out:
pushing this repository's whole history to an empty remote was refused for it, and passes
now (37 s). The GPU flag skips a fork's pull request and Dependabot's runs, whose token
cannot set the label or status. Pull
request and issue texts are public and checked by nothing: AGENTS.md says so. Pull request
numbers in these notes up to this entry are the workspace's.

**The final review (glm-5.3).** Two gaps remained after the move. Neither hook checked an
added line for an e-mail address; only CI did, after the push had made it public. And the
hook took GitHub's older noreply form without the numeric id, which CI's identity check
refuses. Both hooks now apply the e-mail rule to added lines (mpv's manual, which names its
authors' addresses, stays out, as in the static check), and both sides want
`<id>+<login>@users.noreply.github.com`. The stylua update's pull request now gets the
regression suite as well as the Lua lint (its token's pull request starts no workflow by
itself, and a reformat can move what the static tier's text checks look for), RECREATE.md's
inventory lists the whole tree again, and the repository runs an action only when it is
pinned to a full commit SHA (a setting; every action already was). What stays as it is: the
guards read text only, so binary and LFS content is checked by eye; a fork's pull request
gets no GPU flag (AGENTS.md says to look yourself).

## 2026-10-21 (evening): the seek keys show the timeline

The owner: after a skip with the arrows, `x`, `j`/`k` or `z`, only the picture changed, and
nothing showed where in the video (or the song) it had landed. Since 2026-09-25 the seek keys
flashed nothing, to match FastStream. Every seek key (`z x j k`, Left/Right, `0`-`9`) now
sends `script-message-to uosc flash-elements timeline 2500`: the timeline with its times
for 2.5 s ("2 seconds, 3 seconds"), then it fades as uosc's flashes do. uosc's flashes all
last `flash_duration` (1 s, the volume's and the pause's, which stay), so `flash-elements`
takes a duration of its own: a local uosc change in `main.lua`, `Elements:flash()` and
`Element:flash()`. The static tier checks every seek key carries the same flash and the
local change is there; `tests/headless/test-seek-flash.lua` (`--vo=sixel`, as ui-hover) sees
the timeline still up at 1.6 s and gone after.

## 2026-10-21 (night): yt-dlp on Node.js, not Deno

The owner asked what Deno on the PC was for. It was yt-dlp's: newer yt-dlp solves YouTube's
JavaScript challenges with an external runtime, and Deno is its only default
(`yt-dlp -v`: "JS runtimes: deno-2.9.7"; Deno came by winget on 2026-09-17). Cloudflare is
buying Deno (announced 2026-10-09; the runtime gets fixes only for a year). mpv.conf now
passes `js-runtimes=node` to yt-dlp (`ytdl-raw-options-append`): measured with Deno left out
(`--no-js-runtimes --js-runtimes node`), yt-dlp solved a public YouTube video's challenges
with Node.js 26 and found its video and audio formats. With Deno still installed both are
enabled; once it is uninstalled Node.js does it alone. A static check keeps the option.

## 2026-10-21/22: glm reviews both repositories, rounds 1 and 2

The owner asked for glm-5.3-flash reviews of mpv-config and FastStream (security, bugs,
logic and data flow, optimization), round after round until it finds nothing real, and
then a final review with the Anthropic API. Each round packs both repositories into
pieces of about 250 KB (whole files, the handoff document as the specification) and sends
each to glm; every finding is checked against the code before anything changes, and a fix
comes with a test that fails without it. About half of each round's findings were false
(an API read wrongly, code outside the piece assumed); those go into the next round's
prompt with the reason, so they are not sent again.

Round 1 (#4): try-gpu.ps1's public posts go through ConvertTo-PublicText, a gpu tier
skipped as a whole leaves the check pending; mpv-auto-update re-reads the open pull request
before editing it, and a cancelled run deletes its branch; the privacy rules find a user
folder in any script and claude.ai's artifact links; uninstall.ps1 stops the helper's
node.exe first; the upscale button is remembered only once uosc took it; subtitle-sync's
ffmpeg read stops with the tool; welcome.json through state-file.lua; J disabled like the
other re-bound keys; destination_time=total shows the total again (the local dual end time
had covered it); lua-language-server's one warning.

Round 2: running the one-click updater again on the same commit puts back a file this
install wrote that is gone (an antivirus), and leaves a changed one alone; the FastStream
helper is installed again when one of its files is gone; branch names are checked for
claude.ai links (hook and CI); a pull request that only renames a script is no GPU work;
a refused loadfile (quality switch, source menu) says so; a banner that had a progress bar
wraps its detail again; a custom value a setting does not take says so instead of closing
silently; the static stall-limit guard also sees `Invoke-WebRequest` followed by a backtick.
AGENTS.md: the file-loaded re-evaluation counts in gpu-toggles' `applied` on purpose (the
warm-up counts it in).

## 2026-10-22: mpv's own keys off

The owner: "no mpv bindings, only my own, so I know which keys do what" (asked twice, the
same answer: all of mpv's off). It came from a trap: after `g` (2x) mpv's built-in `g-p`
playlist menu took a `p` pressed any time later. mpv.conf has `input-default-bindings=no`;
input.conf binds the basics itself, by his pick ("mute, Ctrl+w, Alt+s, what a player
generally needs, not the specialist stuff"): the window's X / Alt+F4 (`CLOSE_WIN`, without
which the window would not close), Ctrl+w / Ctrl+c, f / Esc, PgUp / PgDn chapters,
Ctrl+s, Ctrl+v, and the media keys (Play/Pause as Space, with faststream-pause). About 140 of
mpv's keys went (zoom, pan, rotate, align, track and delay steps, `[ ] { }`, its g-menus,
the console, F8/F9, Ctrl+h hwdec "auto", Ctrl+r, the mouse side buttons); their functions
stay in the right-click menu and uosc's buttons. The "Disabled defaults" ignore lines (BS,
Z, R, W, J) went with them. The static tier checks the option, the quit lines, `q` = 3x
and that no key is bound twice; test-keys.lua presses dropped keys (nothing happens) and
the kept basics.

Caps Lock (his question: "with Caps Lock on, a speed key or quit?"): mpv reads a letter
as the character Windows makes, so Caps Lock + q arrived as Q, mpv's quit-and-save, which
quit the player instead of 3x (always so, not new with the keys off). Quit-and-save moved
to Ctrl+q; Q is unbound (a static check). Capitals doing what their letters do were tried
and taken out again: mpv reads Shift+r as R too, so they put Shift keys on his speed keys
that he had not asked for. Alt+s is gone too (he uses Windows' own screenshot tool).

## 2026-10-22: hardening - everything the review found, fixed

The owner, on the list of findings left as low or accepted: "if we found it and can fix it,
fix it - even once in a million". Here: the one-click installer runs the FastStream helper's
two files only when they match the release's `native-host.sha256` (FastStream publishes it
with every release since its hardening PR), and node.exe only when the OpenJS Foundation
signed it - the zip's SHA-256 came from a list nodejs.org serves the same way, which proved
only that the two agreed. The installer drops PowerShell 7's module folders as FastStream's
update tool does (Get-AuthenticodeSignature's module did not load in Windows PowerShell
started from pwsh). The static guard on reading the FastStream fragment sees every Lua search
(find, match, gmatch, gsub) in both spellings of a tag (fs- and fs%-), not one anchored on an
item; uosc publishes bottom-ui also with the controls and the timeline both switched off (it
kept its last value, and bottom-bar.lua drew a scrim over a bar that was gone). Checked and
not a bug: video-info.lua's rotate swap (measured: mpv's dw/dh leave the rotation out).

## 2026-10-22 (evening): yt-dlp's private Node.js, a leaner repository, lls in CI

The work was split: a FastStream session took FastStream, this one mpv-config only, the two
sharing the three glm workers through a local queue.

- **#10**: mpv.conf has yt-dlp solve YouTube's challenges with Node.js, which it looks for on
  PATH; the one-click install keeps its FastStream helper's node.exe private, so a PC without
  a Node.js of its own had none. settings.lua points yt-dlp at that node.exe when it is there
  (headless ytdl-node, two processes with a LOCALAPPDATA of their own).
- **#11, leaner**: uosc's `bin/ziggy-darwin` and `ziggy-linux` (11.8 MB of LFS every install
  and update fetched) are gone, with a static check after uosc's local changes;
  `install-shaders.ps1` and `install-uosc.ps1` are retired (nothing called them; the
  committed files are the source). Each shader's source and SHA-256 moved into
  THIRD-PARTY-NOTICES.md, which the static tier checks every file against. Both new checks
  were broken once (a byte added to a shader, a ziggy-linux put back): red, then green.
  Left on purpose: gpu-toggles.lua's comment still places CfL's pin in install-shaders.ps1,
  since any change to that file needs a GPU tier run; it goes with the next real change there.
- **#12**: CI's Lua lint (lint-lua.yml) runs lua-language-server 3.19.2 too, pinned with the
  release asset's SHA-256, in directory mode. A planted undefined global failed it (the log
  named the file and line), its removal passed.
- **#13**: autoload.lua is upstream's 867990d9 (it was 8364b122, unchanged). Measured with an
  instrumented copy: the old file, given a folder, scanned the folder's parent - in a bare mpv
  with `directory_mode=recursive` that queued 26 files from the neighbouring folders. Our
  autoload.conf sets only `same_type=yes`, so it scans without recursion, never finds the
  opened file there and stops: nothing visible changes here, and no test can fail without the
  update. A first explanation of that (timing) had been a guess and went into the PR text; the
  measurement showed it wrong and the text was corrected.
- **#14**: doc/manual.txt was the manual of 2026-09-27 while the pin had moved on; the pinned
  build's manual differs (a new `ytdl-format` default, `aes-ctr://`, DSD passthrough, the
  ANGLE renderer). Made again with pypdf, the tool that made the first copy (its layout
  matched exactly); its first line names the build, and RECREATE.md section 5 has the command,
  which reproduced the file byte for byte in PowerShell. Its branch was rebased with
  `git rebase ... | tail -1 && git push --force-with-lease`: the rebase stopped on a conflict,
  the pipe hid it, and main's commit went to the branch, so GitHub closed the PR. Repaired,
  reopened and explained on the PR; main was not touched.
- glm reviewed #11 (no findings) and #12-#14: one finding, that RECREATE.md had no section 5
  for the manual command - false, the command sits in "5. Updating".

The owner, the same evening: work from data, not guesses or assumptions, and learn from
mistakes without being told each step; glm's answers are leads to check, never facts; PRs may
be merged here once every check is green.
