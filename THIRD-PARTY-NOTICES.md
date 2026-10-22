# Third-party files

The files written for this repository are under the MIT license (`LICENSE`).
The files below come from other projects and keep their own licenses. The full
license texts are in `LICENSES/`.

| Files | Project | License |
|---|---|---|
| `portable_config/Scripts/uosc/` (with `bin/ziggy-windows.exe`; uosc's macOS and Linux builds of it are left out), `portable_config/fonts/uosc_textures.ttf` | [uosc](https://github.com/tomasklaen/uosc) v5.13.0 by tomasklaen. Changed locally: every change is marked `Local change` in the source | LGPL-2.1 |
| `portable_config/fonts/uosc_icons.otf` | Shipped with uosc; the icons are Google's [Material Icons](https://github.com/google/material-design-icons) | Apache-2.0 |
| `portable_config/Scripts/thumbfast.lua` | [thumbfast](https://github.com/po5/thumbfast) by po5, upstream's commit `0f711de3` (2026-06-28). Changed locally: formatted by stylua, two functions made local | MPL-2.0 |
| `portable_config/Scripts/autoload.lua` | [mpv](https://github.com/mpv-player/mpv) (`TOOLS/lua/autoload.lua`), as of upstream's commit `867990d9` (2026-10-15), unchanged | mpv's license ([Copyright](https://github.com/mpv-player/mpv/blob/master/Copyright)) |
| `doc/manual.txt` | The text of mpv's manual (`doc/manual.pdf` of the build its first line names) | GPL-2.0-or-later (as the manual states) |
| `portable_config/shaders/Anime4K_*.glsl` | [Anime4K](https://github.com/bloc97/Anime4K) v4.0.1 by bloc97 | MIT. `AutoDownscalePre_x2/x4`: public domain (Unlicense) |
| `portable_config/shaders/FSRCNNX_x2_16-0-4-1.glsl` | [FSRCNN-TensorFlow](https://github.com/igv/FSRCNN-TensorFlow) by igv | LGPL-3.0-or-later |
| `portable_config/shaders/SSimSuperRes.glsl` | SSimSuperRes by Shiandow (igv's port, as pinned from [dyphire/mpv-config](https://github.com/dyphire/mpv-config)) | LGPL-3.0-or-later |
| `portable_config/shaders/CfL_Prediction.glsl` | [glsl-chroma-from-luma-prediction](https://github.com/Artoriuz/glsl-chroma-from-luma-prediction) by Artoriuz | MIT |
| `portable_config/shaders/adaptive-sharpen.glsl` | Adaptive sharpen by bacondither, mpv port by igv. Changed locally: `curve_height` is a tunable PARAM (described in the file's header) | BSD-style (text in the file) |
| `7z/7zr.exe` | [7-Zip](https://www.7-zip.org/) by Igor Pavlov | GNU LGPL, some parts BSD-3-Clause ([license](https://www.7-zip.org/license.txt)) |
| `portable_config/Scripts/shader-cache/clips/*.mp4` | 12-frame cuts of [Jellyfin's test videos](https://repo.jellyfin.org/test-videos/), courtesy of Gnattu | CC BY-SA 4.0. The cuts are shared under the same license (`clips/README.txt`) |

**Not in this repository:** mpv itself (shinchiro's Windows builds of
[mpv](https://mpv.io/), GPL-2.0-or-later) and [yt-dlp](https://github.com/yt-dlp/yt-dlp)
(Unlicense). `updater.bat` downloads them from their own releases and checks them.

## Where the shaders come from

Each shader in `portable_config/shaders/` is committed as its source published it, with LF
line ends, except `adaptive-sharpen.glsl`, which is changed here. The SHA-256 is that of the
committed file; the static tier checks every file against it, so a shader added or updated
gets its row here.

| File | Source | SHA-256 |
|---|---|---|
| `Anime4K_Clamp_Highlights.glsl` | Anime4K v4.0.1, [`Anime4K_v4.0.zip`](https://github.com/bloc97/Anime4K/releases/download/v4.0.1/Anime4K_v4.0.zip) | `a2a9bf7fbc1d75d09660ca2e701e4d7fb0cf5457b94da47e1825032fa2b3671a` |
| `Anime4K_Upscale_Denoise_CNN_x2_VL.glsl` | the same zip | `359c48fe5a317fbc6b706ce368401eef496e84ed98abac7a43efebca2b65d79b` |
| `Anime4K_AutoDownscalePre_x2.glsl` | the same zip | `8c58291740146bd766a4d73f132775a797fe80f7d07919b5d767e27a5dc85656` |
| `Anime4K_AutoDownscalePre_x4.glsl` | the same zip | `5af62d8cd844916dc1126613e13bad3beab195787f93a71200b47c6ec78f2e41` |
| `Anime4K_Restore_CNN_M.glsl` | the same zip | `67ea3ed26539e8de3b7d307688535d2ff17e8d147e11dda0247da7770dbecf41` |
| `Anime4K_Upscale_CNN_x2_M.glsl` | the same zip | `716e02098a68f0d648761f2b96b4dd139e1cb09b174bb369fca3aa34328fff7e` |
| `Anime4K_Upscale_Denoise_CNN_x2_M.glsl` | the same zip | `8c72b042e2301fe66a45c3089720459148e2504cd72af16f9c0d5017ff14181e` |
| `Anime4K_Restore_CNN_S.glsl` | the same zip | `97c24dc370ab300c108bfaa09db7f175aeff343674842c299cf3940a3d330427` |
| `Anime4K_Upscale_CNN_x2_S.glsl` | the same zip | `4c53ec2e287908f7ee7bcb266b0170421626d663576468b7d7dafc62962649a4` |
| `FSRCNNX_x2_16-0-4-1.glsl` | [FSRCNN-TensorFlow release 1.1](https://github.com/igv/FSRCNN-TensorFlow/releases/download/1.1/FSRCNNX_x2_16-0-4-1.glsl) | `d5a24a271e5d9a3f7f7a053b150c460a44c25b3cf7f770857d57cc3a2e1c9965` |
| `SSimSuperRes.glsl` | [dyphire/mpv-config at `07619250dd3f`](https://raw.githubusercontent.com/dyphire/mpv-config/07619250dd3fcb85e1ad5843ba91f6b4cd560d21/shaders/igv/SSimSuperRes.glsl) (2023-01-24, the file's last change there; igv's own repositories are gone) | `a8b27115840c60045250411b375e0188000217258ad776eeb51724c97815460f` |
| `CfL_Prediction.glsl` | [glsl-chroma-from-luma-prediction at `066dff964b83`](https://raw.githubusercontent.com/Artoriuz/glsl-chroma-from-luma-prediction/066dff964b83aa34e893de25d590874bf8c8e94f/CfL_Prediction.glsl) (2026-08-15) | `f9d12d38d4bab4d9db266b5982c81fadca907396212e22fd8b2c1ca2f317b716` |
| `adaptive-sharpen.glsl` | [igv's port](https://gist.github.com/igv/8a77e4eb8276753b54bb94c1c50c317e), version 2021-10-17, changed here (its header says how) | `84734bc0a29e535b27aa70ef894c1563e829e8905f681ad2ab06644da3531b9c` |
