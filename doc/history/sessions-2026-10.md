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
