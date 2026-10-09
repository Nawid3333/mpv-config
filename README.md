# mpv for Windows: anime and film setup

A portable [mpv](https://mpv.io/) setup for Windows. It has GPU upscaling
(Anime4K for anime, FSRCNNX + SSimSuperRes for films), shaders that compile in
the background before you need them, a timeline for fixing subtitle and audio
sync by eye, and a black, minimal [uosc](https://github.com/tomasklaen/uosc)
interface. Each choice was measured rather than guessed, and an automated test
suite checks every feature.

![The player: a video with the control bar, a subtitle above it and the resolution banner top right](doc/readme/player.jpg)

> **Tuned on one PC, set up for yours.** Everything was measured on a Radeon
> RX 9070 XT with a 1440p monitor on Windows 11. On your PC the player reads
> your screen and your memory, times the upscaling on your GPU, and shows you
> what it picked: press `F1`. Only that one PC has been tested so far, so
> [feedback from other PCs](#other-gpus-and-screens) helps a lot.

## Features

**Set up in the player**
- `F1` opens the **Welcome** menu: your settings at the top, with the
  recommended values marked, and then every feature with its key. It also
  opens by itself the first time you start mpv without a video.
- Right-click ▸ **Settings** has the same settings. Every option is listed,
  even when Auto picks one for you:
  - **Buffering**: how much of a stream is downloaded ahead of where you
    are watching: 150 MB to 2 GB, or the whole video (kept on disk).
  - **Start and stalls**: start at once, or wait until a few seconds are
    downloaded, before playing and after the stream runs dry (a stall).
  - **Upscaling quality**: Auto, High or Fast, with the time each one took
    on your GPU.
  - **Screen for upscaling**, **Movie sharpness**, **HDR brightness**.
  - **Subtitle and audio language**.

**Upscaling you switch on, chosen by measurement**
- **Anime** (`Shift+A`): Anime4K's "Mode C+A": denoised, cleanly inked lines.
  On slower GPUs it uses Anime4K's own lighter "Fast" set (see
  [Other GPUs and screens](#other-gpus-and-screens)).
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
- Works with a [FastStream fork](https://github.com/Nawid3333/FastStream) for
  Firefox that hands browser videos to mpv. See
  [Use with FastStream](#use-with-faststream).

**Updates that are tested first**
- [`mpv-build.json`](mpv-build.json) pins one of [shinchiro's mpv builds](https://github.com/shinchiro/mpv-winbuild-cmake).
  A daily GitHub Actions job tries each new build against the test suite and,
  when all tests pass, offers it as one pull request (`mpv-update`) for the
  owner to merge. Nothing moves the pin by itself (since 2026-10-05).
- `updater.bat` pulls this repository, installs the pinned build (checking
  every file's SHA-256) and updates yt-dlp.

![The right-click menu](doc/readme/menu.jpg)

## Install

### One click (recommended)

Open **PowerShell** (Start menu, type `PowerShell`, Enter), paste this line
and press Enter:

```powershell
irm https://raw.githubusercontent.com/Nawid3333/mpv-config/main/installer/setup.ps1 | iex
```

That line downloads the setup script and runs it (`irm` downloads, `iex`
runs). To read it first, open
[`installer/setup.ps1`](installer/setup.ps1). Or download this repository
(**Code ▸ Download ZIP**), extract it and double-click **`install.bat`**.
Either way it takes about a minute.

Everything is installed for your Windows account only, so no admin rights are
needed and nothing changes for other users of the PC. You don't need to
install Git or Node.js either. The setup:

1. checks the PC: 64-bit Windows 10 or 11 and a CPU with AVX2 (Intel from
   2013, AMD from 2015). It warns when it finds no Vulkan graphics driver
   (see [Other GPUs and screens](#other-gpus-and-screens));
2. installs this config into `%LOCALAPPDATA%\Programs\mpv`, plus mpv itself
   and yt-dlp (which mpv uses for web videos). Every download is checked
   against its known checksum, so a damaged or altered file is refused;
3. connects **FastStream**, the Firefox add-on that sends videos from the
   browser to mpv. A browser add-on cannot start programs by itself, so it
   needs a small helper program; the setup installs it, with its own private
   copy of Node.js (the runtime the helper is written for). Then it opens the
   signed FastStream add-on in Firefox: click **Add**;
4. adds mpv to the **Open with** list you get when you right-click a video or
   audio file (your default player is not changed), and a Start menu folder
   **mpv** with *mpv*, *Update mpv* and *Uninstall mpv*.

When it is done, **restart Firefox** and switch FastStream's MPV mode on (see
[Use with FastStream](#use-with-faststream), step 4). The first video then
compiles the upscaling shaders in the background, with a small banner at the
top right.

- **Update:** Start menu ▸ mpv ▸ *Update mpv* (`updater.bat`). It updates the
  config, mpv, yt-dlp and the FastStream helper. Files you changed yourself
  are kept next to the new ones as `<name>.mine-<date>`.
- **Uninstall:** Start menu ▸ mpv ▸ *Uninstall mpv* (`uninstall.bat`). The
  FastStream add-on stays in Firefox; remove it in `about:addons`.
- **Options:** another folder, or parts left out:
  `& ([scriptblock]::Create((irm https://raw.githubusercontent.com/Nawid3333/mpv-config/main/installer/setup.ps1))) -InstallDir D:\mpv -NoFastStream`
  (also `-NoFileTypes`, `-NoShortcuts`).

ffmpeg on `PATH` is optional; the sync tool uses it to read subtitle tracks
inside a video.

### With Git (to change the config yourself)

You need [Git](https://git-scm.com/) with Git LFS. PowerShell 7 is needed only
for the tests.

```powershell
# 1. Clone the repository AS the mpv folder (mpv runs in portable mode next to portable_config\).
#    Any folder works. Under Program Files this needs an admin prompt, and mpv needs write access:
git clone https://github.com/Nawid3333/mpv-config.git "C:\Program Files\mpv"
icacls "C:\Program Files\mpv" /grant "$($env:USERNAME):(OI)(CI)M"
cd "C:\Program Files\mpv"

# 2. Install mpv itself (the pinned build) and yt-dlp. Run this again later to update:
.\updater.bat

# 3. Optional: file associations
.\mpv-register.bat
```

Play any video. The first time, a small banner top right shows the shaders
compiling in the background (under a minute, once per PC and again after
a driver update). Playback does not wait for it.

The full runbook (what each script does, troubleshooting, the commit guard) is
in [`RECREATE.md`](RECREATE.md).

## Use with FastStream

[Nawid3333/FastStream](https://github.com/Nawid3333/FastStream) is a Firefox
fork of FastStream that hands a video playing in the browser to mpv. This
config is built as its mpv side:

- **Upscaling picks itself.** The fork tags every stream as anime or movie
  (from your allowlist, see step 4). This config then applies Anime4K or the
  Movie chain automatically. Local files stay without shaders until you pick
  one.
- **Resume.** A stream continues where you stopped, even though its address
  changes on every visit. Saved positions last 7 days, and `Home` starts from
  the beginning.
- **Source button.** Shows the stream URL and the page it came from, ready to
  copy or to open in the browser.
- **One window.** The next episode replaces the current one in the same mpv
  window and starts playing. A pause or a subtitle delay from the previous
  episode does not carry over.
- **Decoding.** Streams and local files both decode with `d3d11va-copy` on the
  graphics card's video engine. Vulkan decoding is off since 2026-10-04: it lost
  the graphics device on this AMD card.
- **Clear errors.** If a stream cannot be opened (for example, an expired
  link), a banner says to reload the page instead of showing an empty window.

### Setup (once)

The [one-click install](#one-click-recommended) does steps 1 to 3. After it
finishes, restart Firefox and continue with step 4.

1. **Install this config** as above. Without the one-click install, the
   fork's helper looks for `C:\Program Files\mpv\mpv.exe` first.
2. **Install the extension.** Download the signed `.xpi` from the fork's
   [Releases](https://github.com/Nawid3333/FastStream/releases) and open it in
   Firefox 142 or newer. Firefox then updates it by itself.
3. **Install the helper.** A browser extension cannot start programs by
   itself, so a small helper is registered once. It needs
   [Node.js](https://nodejs.org/) 22 or newer. Get the fork's source (Code ▸
   Download ZIP, or `git clone`), then in PowerShell:

   ```powershell
   cd FastStream\native-host
   powershell -ExecutionPolicy Bypass -File install.ps1
   # mpv somewhere else? add:  -MpvPath "D:\Apps\mpv\mpv.exe"
   ```

   Then **restart Firefox**. No admin rights are needed; it only writes to
   `%LOCALAPPDATA%\FastStreamMpvHost` and one registry key under `HKCU`.
4. **Turn it on.** In FastStream's settings, go to **MPV Mode**:
   - Tick **Open detected streams in mpv**.
   - Click **Test mpv connection**. It should say **mpv found**.
   - Add your sites to the **MPV Allowlist**, one per line. Sites count as
     movies; put `@anime` after the anime ones:

     ```
     https://movies.example.com
     https://anime.example.org @anime
     ```

### Use it

- Open a video on an allowlisted site, and mpv takes over.
- On any other site, use the player's **Open this stream in mpv** button. Right-click
  that button to set Anime or Movie for one video.

The fork's [MPV mode guide](https://github.com/Nawid3333/FastStream/blob/main/README-MPV.md)
has every option, troubleshooting (a helper log you can switch on) and how to
uninstall. Only the stream URL, the page address and three headers (`Referer`,
`Origin`, `User-Agent`) go to mpv. Cookies stay in the browser, so a stream
that needs a login session will not play in mpv.

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
| `F1` | Welcome menu: settings and every feature |
| `Q` | Quit and save the position (`Ctrl+w` quits) |

Every key and menu entry is in [`input.conf`](portable_config/input.conf).

## Settings

Right-click ▸ **Settings**, or `F1`. They are stored per PC (in
`portable_config\settings.json` and `upscale.json`, never in git):

| Setting | A new install starts with | Options |
|---|---|---|
| Buffering | Auto: by your memory (under 6 GB: 150 MB, under 12 GB: 512 MB, else 1 GB) | 150 MB, 512 MB, 1 GB, 2 GB, the whole video (streams, on disk in the temp folder) |
| Start and stalls | buffer 3 s first, and after a stall | start at once, 3 s, 5 s, 10 s |
| Upscaling quality | Auto: measured on your GPU | High, Fast |
| Screen for upscaling | Auto: the screen mpv is on | 1920x1080, 2560x1440, 3440x1440, 3840x2160 |
| Movie sharpness | Auto: by the scale | Off, Low, Medium, High |
| HDR brightness | Auto: your screen's own value | 300 to 1000 nits |
| Subtitle language | Automatic: your Windows language | English, German, French, Japanese and more, each then English |
| Audio language | Automatic: the file's default track | the same list |

A PC that ran this config before the settings existed keeps its earlier values
(German, then English; 350 nits; 1 GB; 3 s).

Decoding is fixed: everything decodes with `d3d11va-copy` on the graphics
card's video engine. Vulkan decoding dropped frames on long local files with
an AMD driver (2026-09-16) and lost the graphics device on streams with the
October 2026 builds (2026-10-04). `mpv.conf` explains it, and the static tests
refuse a vulkan or auto `hwdec`.

## Other GPUs and screens

**Screens.** The upscaling picks its chain from the real scale between the
video and your screen, so a 1080p or 4K screen gets the right one by itself:

| Video | 1080p screen | 1440p screen | 4K screen |
|---|---|---|---|
| 480p | 2.25x | 3x | 4.5x |
| 720p | 1.5x | 2x | 3x |
| 1080p | 1x (no upscaling) | 1.33x | 2x |
| 4K | 0.5x (downscaled) | 0.67x | 1x |

Movie uses SSimSuperRes below 2x and FSRCNNX + SSimSuperRes from 2x on.
Anime4K's own stages follow the scale too. The quality was compared at 1.33x,
1.5x, 2x and 3x, which covers every cell above except 480p on a 4K screen.
The background shader compile adds clip sizes for any scale your screen
reaches that the standard sizes miss, and runs again when you change screens.

**GPUs.** Every GPU computes the same picture; only the speed differs. On the
RX 9070 XT, Anime4K takes about 4.6 ms per 1080p frame on a 1440p screen, and
Movie 2-5 ms. A GPU a tenth as fast would stutter. So the first time a chain
runs, Auto reads its time from the GPU's own timers. If it needs more than
half of a frame's time, Auto switches to Anime4K's lighter "Fast" set (or
Movie without FSRCNNX) and tells you with the number. **Settings ▸ Upscaling
quality** shows what was measured, and you can still pick High.

**Requirements:** Windows 10 or 11 (64-bit) and a CPU with AVX2 (Intel from
2013, AMD from 2015). The picture is drawn with Vulkan; a PC without a working
Vulkan driver falls back to Direct3D 11, where the first use of each
upscaler compiles slowly.

**Please tell us how it runs.** Open an
[issue](https://github.com/Nawid3333/mpv-config/issues) with:
- your GPU and your screen resolution;
- what **Settings ▸ Upscaling quality** shows (Auto's pick and the
  milliseconds);
- whether anything stutters (press `i` for the stats).

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
[`doc/history/`](doc/history/) has the session logs behind them.

This repository is a published copy of a private workspace. It is updated
automatically after each change passes the tests, and every update is checked
for personal data first. Commit hashes and pull request numbers in the notes
refer to that workspace. Issues are welcome; a pull request here is applied in
the workspace by hand, because the next update would overwrite a merge.

## License

MIT for the files written for this repository ([`LICENSE`](LICENSE)). Bundled
third-party files (uosc, thumbfast, the shaders, 7-Zip and others) keep their
own licenses; see [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).
