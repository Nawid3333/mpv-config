#!/bin/sh
# Downloads the CANDIDATE shaders chains.py names (the shipped ones are read from
# portable_config/shaders) into <work>/shaders, each from a pinned upstream
# commit - the exact files measured on 2026-10-03.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
work=${MPV_BENCH_WORK:-$here/../../test-media/upscale-bench}
dst=$work/shaders
mkdir -p "$dst"
get() { # <url> <file name>
	[ -s "$dst/$2" ] || curl -sSfL --max-time 300 -o "$dst/$2" "$1"
}
a4k=https://raw.githubusercontent.com/bloc97/Anime4K/7684e9586f8dcc738af08a1cdceb024cc184f426/glsl
for f in Upscale+Denoise/Anime4K_Upscale_Denoise_CNN_x2_UL Restore/Anime4K_Restore_CNN_L Restore/Anime4K_Restore_CNN_VL \
	Upscale/Anime4K_Upscale_CNN_x2_L Upscale/Anime4K_Upscale_CNN_x2_VL; do
	get "$a4k/$f.glsl" "$(basename "$f").glsl"
done
cunny=https://raw.githubusercontent.com/funnyplanter/CuNNy/906031bb00c15dd6a6bbbaa21c0eb0b724ca8437/mpv/ds
get "$cunny/CuNNy-4x32-DS.glsl" CuNNy-4x32-DS.glsl
get "$cunny/CuNNy-8x32-DS.glsl" CuNNy-8x32-DS.glsl
dyp=https://raw.githubusercontent.com/dyphire/mpv-config/132e1982ef47269118bd125b20aefd87dc646ab1/shaders
get "$dyp/Ani4k/Ani4Kv2_ArtCNN_C4F32_i2_CMP.glsl" Ani4Kv2_ArtCNN_C4F32_i2_CMP.glsl
get "$dyp/AnimeJaNai/AnimeJaNaiV3L1_HD_x2.glsl" AnimeJaNaiV3L1_HD_x2.glsl
get "$dyp/igv/KrigBilateral.glsl" KrigBilateral.glsl
get https://raw.githubusercontent.com/Artoriuz/ArtCNN/7d6955141b88047a983e3a424e87c5a5e3df3e3c/GLSL/ArtCNN_C4F32_DS.glsl ArtCNN_C4F32_DS.glsl
aiu="https://raw.githubusercontent.com/Alexkral/AviSynthAiUpscale/d04cf8154e4ba9914f3ead0dec9f7a4a7df7369f/mpv%20user%20shaders/Photo"
for f in 2x/AiUpscale_HQ_2x_Photo 2x/AiUpscale_HQ_Sharp_2x_Photo 3x/AiUpscale_HQ_3x_Photo 3x/AiUpscale_HQ_Sharp_3x_Photo; do
	get "$aiu/$f.glsl" "$(basename "$f").glsl"
done
ls "$dst"
