# Design pass 2026-10-02: before / after

Screenshots for the design-pass pull request (what changed and why: AGENTS.md,
"Design pass" bullet). Each image shows the same moment BEFORE and AFTER.

| Image | What it shows |
|---|---|
| `01-control-bar.jpg` | the control row on a bright picture: one soft bar instead of a black tile per button; the subtitle above the controls instead of under them; no buffer hatching on a local file; one remaining time at 1x; the source badge `File` instead of the overflowing "local file" |
| `02-player-day.jpg`, `03-player-night.jpg` | the whole window, bright and dark picture |
| `04-banners.jpg`, `05-banners-zoom.jpg` | banners: rounded, hairline edge, the toolbar button's icon in the accent colour, an accent progress bar; mpv's own OSD text ("Contrast: 2") now the banners' size and right edge instead of small and overlapping the last banner |
| `06-menu.jpg`, `07-small-menus.jpg` | menus in Segoe UI at the same text size, corners 6 |
| `08-sync-tool.jpg` | the sync tool: rounded panel, Segoe UI, the subtitle shown above the panel |

How they were made: the pinned Windows build itself (shinchiro 20261002,
`mpv-build.json`) with this repo's `portable_config`, under Wine on Linux with
Mesa's software Vulkan (llvmpipe), 1920x1080 window, `screenshot-to-file
<file> window`. Microsoft's fonts cannot be installed there, so metric
stand-ins were registered under their names: Open Sans as "Segoe UI" (same
designer, near-identical metrics) and Liberation Sans as "Arial" (metric
clone). On Windows the real fonts are used. The pictures are synthetic test
clips (a dusk and a daylight landscape, made for this), not films.
