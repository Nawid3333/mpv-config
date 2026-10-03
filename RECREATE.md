# Recreating this mpv setup on another PC

This document is the **single source of truth** for reproducing this exact
mpv installation: speed keys, uosc UI, and the Anime4K / FSRCNNX /
SSimSuperRes GLSL upscale presets. (Frame interpolation - RIFE via VapourSynth
+ vs-mlrt - was removed 2026-09-20; its files are in git history, see
AGENTS.md.) Everything else in the repo (configs, scripts) is
meant to be committed as-is; the few things that **cannot** be committed are
re-created by the scripts in `installer/`.

---

## 1. What lives in the repo (just works after clone)

| Path | What it is |
|---|---|
| `portable_config/mpv.conf` | Player config: subs, uosc, GPU quality (heavily commented) |
| `portable_config/input.conf` | All keybinds + uosc right-click menu (`#!` comments) |
| `portable_config/Scripts/*.lua` | Ours: `gpu-toggles.lua`, `speed-button.lua`, `speed-presets.lua`, `remember-speed.lua`, `auto-start.lua`, `subtitle-toggle.lua`, `subtitle-sync.lua`, `stream-resume.lua`, `notify.lua` (draws every message as a small banner top right), `title-bar.lua` (the native title bar in black), `music-info.lua` (song details: window title + the panel above uosc's bottom bar), `video-info.lua` (a resolution banner when a video starts), `source-info.lua` (a "source" toolbar button: every link the current file has, ready to copy or open - behavior in AGENTS.md). Vendored: `autoload.lua` (upstream mpv), `thumbfast.lua` |
| `portable_config/Scripts/shader-cache/` | Ours: the startup shader-cache check and its progress banner (`main.lua`, drawn by `notify.lua`), what it compares (`fingerprint.lua`), the warm-up it runs in the background when the cache is stale (`warmup.lua`) and the hidden window that warm-up runs in (`host.ps1`) |
| `portable_config/Scripts/uosc/` | uosc UI (v5.13.0, incl. LFS-tracked ziggy binaries) |
| `portable_config/shaders/*.glsl` | The 10 shaders the presets use: 6 Anime4K v4.0.1 files (Anime preset), FSRCNNX, SSimSuperRes, CfL_Prediction and adaptive-sharpen (Movie presets; adaptive-sharpen is a locally modified copy, not downloaded by the installer) - committed, licenses permit redistribution. Trimmed 2026-09-21 from the full Anime4K pack + ArtCNN + SSimDownscaler, none of which any preset used |
| `portable_config/script-opts/uosc.conf` | uosc settings |
| `lua-api/` | mpv API stubs for Lua language server (editor support only) |
| `tests/` | Regression suite: `pwsh tests/run-tests.ps1` (see `tests/README.md`) |
| `installer/warm-shader-cache.ps1` | Runs that warm-up on request, hidden, progress in the terminal (mpv also runs it by itself in the background whenever the cache is stale) |
| `doc/manual.txt` | Version-matched mpv manual (extracted text, for grepping) |
| `mpv-build.json` | Which shinchiro mpv build this setup uses (tag, download URL, SHA-256 of the archive and of every file in it). CI moves it to each new build that passes the regression tests |
| `updater.bat`, `installer/update.ps1`, `installer/install-mpv.ps1` | Ours: `updater.bat` pulls the repo, installs the pinned mpv build and keeps yt-dlp current |

## 2. What is generated, and how mpv's own files are kept

| Artifact | In the repo? | Re-created by |
|---|---|---|
| Shader cache `portable_config/cache/` | no: auto-generated (gitignored) | mpv: the startup check warms it in the background after the first video starts (~8 s, once) |
| `speed.json`, `stream-resume.json`, `movie-sharpness.json`, `shader-misses.log` in `portable_config/` | no: personal state (gitignored) | the scripts, as you use mpv |
| mpv's own files: `mpv.exe`, `mpv.com`, `d3dcompiler_43.dll`, `doc/manual.pdf`, `doc/mpbindings.png`, `mpv-register.bat` / `mpv-unregister.bat`, `installer/mpv-install.bat` / `mpv-uninstall.bat` / `mpv-icon.ico`, `mpv/fonts.conf` | no (gitignored, since 2026-10-03): `mpv-build.json` pins the build | `updater.bat` (installer\install-mpv.ps1): downloads the pinned archive, checks every file's SHA-256 |
| `yt-dlp.exe` | no (gitignored, since 2026-10-03) | `updater.bat`: `yt-dlp -U`, or a fresh download checked against GitHub's SHA-256 |

> `d3dcompiler_43.dll` is only used by mpv's D3D11/ANGLE render path, which
> this config does not take (`gpu-context=winvk`). It is kept anyway: it ships
> with the upstream build, it is what the `d3d11va-copy` entry in `hwdec`
> falls back onto if Vulkan video decode ever regresses, and 4.4 MB is not
> worth the risk of pruning a player DLL. Don't "clean it up".

> Nothing needs Python or VapourSynth any more. A `.venv` folder next to
> `mpv.exe` (and a user PATH entry pointing into it) may still exist from the
> removed RIFE setup; both are unused and safe to delete.
>
> Shaders and uosc **are** committed — but if they ever drift from upstream,
> the installers can rebuild them: `install-uosc.ps1` re-fetches uosc v5.13.0
> + thumbfast, `install-shaders.ps1` re-downloads the 8 used shaders (the Anime4K v4.0.1
> files the Anime preset needs, FSRCNNX, SSimSuperRes) with pinned URLs.

## 3. Quick start on a fresh PC

```powershell
# 0) Prerequisites (check boxes):
#    - Git (with Git LFS)  - the ziggy binaries, fonts, 7z\7zr.exe and mpv-single.exe are LFS
#    - PowerShell 7 (pwsh) on PATH - the regression suite and warm-shader-cache.ps1 need it
#      (updater.bat also runs in Windows PowerShell 5.1)
#    - ffmpeg on PATH (the validation test; and the sync tool (t) uses it to list
#      the lines of a subtitle track INSIDE a video - without it that row fills
#      in as playback reads the lines; playback itself never needs it)
#    - AMD GPU with Vulkan driver (RX 9070 XT here), latest Adrenalin

# 1) Clone the repo AS the mpv folder (portable layout: mpv.exe and portable_config\
#    side by side - mpv.exe arrives in step 2). git clone wants a new or empty folder;
#    under Program Files that takes an admin prompt, and mpv then needs write access
#    for its state and shader cache in portable_config\:
git clone https://github.com/Nawid3333/mpv.git "C:\Program Files\mpv"
icacls "C:\Program Files\mpv" /grant "$($env:USERNAME):(OI)(CI)M"
#    C:\Program Files\mpv\
#      mpv.exe, mpv.com, d3dcompiler_43.dll   <- the player (step 2 installs it; not in git)
#      portable_config\                        <- config, scripts, shaders

# 2) mpv itself and yt-dlp: the build mpv-build.json pins, downloaded and checked
#    (also what you run later to update - it pulls the repo first):
.\updater.bat
#    Then switch on the commit guard (once per clone; it also carries git-lfs's hooks):
git config core.hooksPath .githooks
#    The repository is public: commit under your GitHub login and its noreply address
#    (GitHub > Settings > Emails), whatever git's global user.name says - the guard refuses
#    anything else. Optional: words that must never be committed (real name, user name,
#    PC name), one per line, in this clone's .git/info/private-words (never committed):
git config user.name "<login>"
git config user.email "<id>+<login>@users.noreply.github.com"

# 3) uosc + thumbfast (UI): committed, with local changes - nothing to do in a clone.
#    install-uosc.ps1 is for a folder without them (it fetches upstream's copies,
#    which lack those changes; it says so):
# powershell -ExecutionPolicy Bypass -File installer\install-uosc.ps1

# 4) GLSL shaders (the 8 files the presets use):
powershell -ExecutionPolicy Bypass -File installer\install-shaders.ps1

# 5) File associations / App Paths (optional, admin not required):
.\mpv-register.bat

# 6) Optional - mpv does this by itself in the background. Pre-compile now (~8 s, nothing on screen):
pwsh -File installer\warm-shader-cache.ps1

# 7) Check everything (static + headless; add -Tier gpu for the renderer):
pwsh -File tests\run-tests.ps1
```

Each installer script is **idempotent** — safe to re-run; it skips what
already exists and always verifies results at the end.

## 4. How to verify everything works

0. **Regression suite**: `pwsh tests/run-tests.ps1` (and `-Tier gpu` with no mpv open) - it covers
   every feature; see `tests/README.md`. The manual checks below are the quick visual ones.
1. **Configs parse**: `mpv.com --idle` → no error spam about mpv.conf/input.conf.
2. **Shaders**: play anything → `Shift+A` (Anime) / `Shift+Y` (Movie) toggle the
   upscale presets and the OSD confirms each step; `I` (stats) → page 2 shows shader passes running.
   The current cycle shape, preset names, and default state are documented
   in **AGENTS.md's "Key runtime features" / "Current status"** - not
   repeated here on purpose (both this doc and AGENTS.md had to be updated
   in lockstep for the same fact more than once on 2026-09-14; the cycle
   shape lives in exactly one place now, see the note at the end of
   section 5).
3. **uosc**: right-click = settings menu; bottom bar appears on mouse near bottom.

## 5. Updating

| Component | How |
|---|---|
| uosc | in the repository, by hand: a new uosc must get the local changes AGENTS.md lists carried over (the static tests check them). Not uosc's own updater (it replaces `Scripts/uosc` and drops them; the menu entry is gone) |
| Anime4K etc. | re-run `install-shaders.ps1` (re-downloads) |
| mpv.exe, yt-dlp | Run `updater.bat`. It pulls the repo (CI moves `mpv-build.json` to each new mpv build that passes the regression suite, by itself), installs exactly that build, and updates yt-dlp - nothing to commit. A build that fails the suite is not pinned (CI opens one "mpv update failed" issue); the pin, and your mpv, stay where they were. The next mpv start re-checks the shader cache by itself in the background (a quick check for a new mpv, a full warm-up for a new libplacebo) |
| This doc | keep **sections 1-3** (repo layout tables, install steps) in sync when files/scripts are added or removed - they change rarely and are specific to this doc. Section 4 deliberately POINTS to AGENTS.md for cycle shapes/defaults/policy instead of restating them - if you're updating a preset name or default state, that edit belongs in AGENTS.md only; leave this doc's wording as "see AGENTS.md" rather than reintroducing a specific claim that can go stale again (see AGENTS.md's "Notes for future agents" for the full reasoning) |