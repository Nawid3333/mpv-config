# mpv for Windows: anime and film setup

A portable [mpv](https://mpv.io/) setup for Windows. It has GPU upscaling
(Anime4K for anime, FSRCNNX + SSimSuperRes for films), shaders that compile in
the background before you need them, a timeline for fixing subtitle and audio
sync by eye, and a black, minimal [uosc](https://github.com/tomasklaen/uosc)
interface. Each choice was measured rather than guessed, and an automated test
suite checks every feature.

![The player: a video with the control bar, a subtitle above it and the resolution banner top right](doc/readme/player.jpg)

> **One PC, measured.** Everything here was tuned and measured on a Radeon
> RX 9070 XT with a 1440p IPS monitor (LG 27GN800-B) on Windows 11. It should
> work on any Windows PC with a Vulkan GPU, but only that machine has been
> tested. See [Settings tied to that PC](#settings-tied-to-that-pc).

## Features

**Upscaling you switch on, chosen by measurement**
- **Anime** (`Shift+A`): Anime4K's "Mode C+A" (HQ): denoised, cleanly inked lines.
- **Movie** (`Shift+Y`): picks a chain by the real display scale. Below 2x
  it uses SSimSuperRes; at 2x and above, FSRCNNX + SSimSuperRes. Chroma is
  rebuilt from luma (CfL), and adaptive sharpening runs at an automatic
  strength.
- Both were picked by scoring against original clean footage (PSNR, SSIM,
  VMAF, edge sharpness and halo). The harness is in
  [`tests/upscale-bench/`](tests/upscale-bench/) and the numbers are in the
  comment above `UPSCALE_ANIME` in
  [`gpu-toggles.lua`](portable_config/Scripts/gpu-toggles.lua). Settings that
  lost, and why, are recorded there too.
- Local files play without shaders until you pick a preset. Streams from
  FastStream (below) pick one automatically.

**Shaders compile before you need them**
- On start, mpv checks whether its shader cache matches the current driver,
  mpv build, shaders and config. If it doesn't, a second, hidden mpv draws
  every preset in every format in the background, with a small progress
  banner. Your video keeps playing and no frames are dropped.
- Shaders that real playback still had to compile are learned and replayed in
  later warm-ups.

![Banners top right: "Resumed at 12:30" and "Compiling shaders 42%" with a progress bar](doc/readme/banners.jpg)

**Subtitle and audio sync timeline** (`t`)
- Your subtitles and the audio's loudness are drawn on one timeline. Drag the
  subtitle row or the audio row until speech and text line up. `Enter` keeps
  the change, `Esc` undoes it.

![The sync tool: a time row, an audio row and a subtitle row with each line as a block](doc/readme/sync-tool.jpg)

**Interface**
- uosc with a soft control bar, Segoe UI and rounded corners, in OLED black.
  The Windows title bar is black too (Windows 11).
- Every message is a small banner top right. A resolution banner appears when
  a video starts.
- Subtitles move up above the controls while the controls are shown.
- Songs show "Artist – Title (feat. X)" in the window title, plus a details
  panel.
- A **source** button lists every link of the current file (stream URL,
  original page, local path) to copy or open.
- Right-click opens a menu with everything; see the screenshot below.

**Speed**
- Preset keys `r g b q w a y e h` (1x, 2x, 2.5x, 3x, 3.5x, 4x, 5x, 8x, 16x).
  Pressing the same key again goes back to the speed you had before.
  `s` / `d` change the speed by 0.1.
- The last speed is remembered across restarts, separately for videos and
  songs.

**Streams from the browser**
- Works with a [FastStream fork](https://github.com/Nawid3333/FastStream) that
  hands browser videos to mpv. The fork tells mpv whether a video is anime or
  a film, so Auto picks the right upscaler.
- mpv resumes where you left off (`Home` starts from the beginning), and the
  page link appears in the source menu.

**Updates that are tested first**
- [`mpv-build.json`](mpv-build.json) pins one of [shinchiro's mpv builds](https://github.com/shinchiro/mpv-winbuild-cmake).
  A daily GitHub Actions job tries each new build against the test suite and
  moves the pin only when all tests pass.
- `updater.bat` pulls this repository, installs the pinned build (checking
  every file's SHA-256) and updates yt-dlp.

![The right-click menu](doc/readme/menu.jpg)

## Install

You need Windows 10 or 11 (x64), a GPU with a Vulkan driver, and
[Git](https://git-scm.com/) with Git LFS. PowerShell 7 is needed only for the
tests. ffmpeg on `PATH` is optional; the sync tool uses it to read subtitle
tracks inside a video.

```powershell
# 1. Clone the repository AS the mpv folder (mpv runs in portable mode next to portable_config\).
#    Any folder works. Under Program Files this needs an admin prompt, and mpv needs write access:
git clone https://github.com/Nawid3333/mpv.git "C:\Program Files\mpv"
icacls "C:\Program Files\mpv" /grant "$($env:USERNAME):(OI)(CI)M"
cd "C:\Program Files\mpv"

# 2. Install mpv itself (the pinned build) and yt-dlp. Run this again later to update:
.\updater.bat

# 3. Optional: file associations
.\mpv-register.bat
```

The full runbook (what each script does, troubleshooting, the commit guard) is
in [`RECREATE.md`](RECREATE.md).

## Keys

| Key | Action |
|---|---|
| Click / double-click / right-click | Play-pause / fullscreen / menu |
| `Shift+A`, `Shift+Y` | Anime upscaling on/off, Movie upscaling on/off |
| `t` | Subtitle and audio sync timeline |
| `c` | Subtitles on/off (selects a track if none is chosen) |
| `r g b q w a y e h` | Speed 1x, 2x, 2.5x, 3x, 3.5x, 4x, 5x, 8x, 16x (again: back) |
| `s` / `d` | Speed -0.1 / +0.1 |
| `←` `→` / `j` `k` / `z` `x` | Seek 5 s / 10 s / 60 s |
| `0`-`9` | Jump to 0 %-90 % |
| `↑` `↓`, wheel, `m` | Volume ±10, ±2, mute |
| `i`, `I` | Stats |
| `Q` | Quit and save the position (`Ctrl+w` quits) |

Every key and menu entry is in [`input.conf`](portable_config/input.conf).

## Settings tied to that PC

- `target-peak=350` in [`mpv.conf`](portable_config/mpv.conf) is the measured
  peak brightness of the monitor above. It applies to HDR videos only; set it to
  your display's peak or remove it.
- `slang=de,en` / `alang=de,en`: German first, then English. Change them to
  your languages.
- `hwdec`: local files decode with `d3d11va-copy`, and only streams use Vulkan
  decoding. Vulkan decoding dropped frames on long local files with this AMD
  driver. `mpv.conf` explains it.

## Tests

```powershell
pwsh tests/run-tests.ps1             # static + headless, ~1 min, no window
pwsh tests/run-tests.ps1 -Tier gpu   # the real renderer, fullscreen, ~5 min (close mpv first)
```

The headless tier runs a copy of mpv on a copy of the config, so your
settings, history and shader cache are never touched. It drives mpv with its
own input commands and checks that the banners are really drawn. CI runs
static + headless on every push. See [`tests/README.md`](tests/README.md).

## For contributors and AI agents

[`AGENTS.md`](AGENTS.md) holds detailed engineering notes: every feature,
why it is built that way, what was measured and what was rejected.
[`doc/history/`](doc/history/) has the session logs behind them. This
repository was re-created on 2026-10-03 without its earlier history. Commit
hashes and pull request numbers mentioned in those notes refer to that earlier
repository.

## License

MIT for the files written for this repository ([`LICENSE`](LICENSE)). Bundled
third-party files (uosc, thumbfast, the shaders, 7-Zip and others) keep their
own licenses; see [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).
