# Third-party files

The files written for this repository are under the MIT license (`LICENSE`).
The files below come from other projects and keep their own licenses. The full
license texts are in `LICENSES/`.

| Files | Project | License |
|---|---|---|
| `portable_config/Scripts/uosc/` (with `bin/ziggy-*`), `portable_config/fonts/uosc_textures.ttf` | [uosc](https://github.com/tomasklaen/uosc) v5.13.0 by tomasklaen. Changed locally: every change is marked `Local change` in the source | LGPL-2.1 |
| `portable_config/fonts/uosc_icons.otf` | Shipped with uosc; the icons are Google's [Material Icons](https://github.com/google/material-design-icons) | Apache-2.0 |
| `portable_config/Scripts/thumbfast.lua` | [thumbfast](https://github.com/po5/thumbfast) by po5 | MPL-2.0 |
| `portable_config/Scripts/autoload.lua` | [mpv](https://github.com/mpv-player/mpv) (`TOOLS/lua/autoload.lua`) | mpv's license ([Copyright](https://github.com/mpv-player/mpv/blob/master/Copyright)) |
| `doc/manual.txt` | The text of mpv's manual, from the pinned build | GPL-2.0-or-later (as the manual states) |
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
