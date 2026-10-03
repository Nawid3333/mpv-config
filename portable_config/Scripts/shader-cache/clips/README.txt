Dolby Vision clips for the shader warm-up (shipped-cases.lua)
==============================================================

No encoder in this setup writes a Dolby Vision RPU, so the warm-up cannot
generate a DV clip the way it makes every other one. These three are real
files instead: the first 12 frames of Jellyfin's 1080p Dolby Vision test
videos, cut losslessly (ffmpeg -map 0:v:0 -c copy -frames:v 12), so mpv
draws them through the same RPU reshaping pass as a real DV film.

  dv-p5.mp4     Test Jellyfin 1080p DV P5.mp4    (profile 5, IPT-PQ-c2)
  dv-p8.1.mp4   Test Jellyfin 1080p DV P8.1.mp4  (profile 8.1, HDR10 base)
  dv-p8.4.mp4   Test Jellyfin 1080p DV P8.4.mp4  (profile 8.4, HLG base)

Source: https://repo.jellyfin.org/test-videos/ (HDR/Dolby Vision).
"These files are courtesy of Gnattu and are licensed under the Creative
Commons Attribution-Sharealike license" - CC BY-SA 4.0,
https://creativecommons.org/licenses/by-sa/4.0/. These cuts are shared under
the same licence.
