#!/bin/sh
# Downloads and unpacks the Windows mpv build mpv-build.json pins (the player's
# own build) into <work>/pinned-mpv, after checking its SHA-256, for
# MPV_BENCH_RENDERER=pinned (the default): render.py runs it under Wine.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
work=${MPV_BENCH_WORK:-$here/../../test-media/upscale-bench}
dst=${MPV_BENCH_PINNED:-$work/pinned-mpv}
read -r url sha <<EOF
$(python3 -c "import json,sys; j=json.load(open('$here/../../mpv-build.json')); print(j['url'], j['sha256'])")
EOF
mkdir -p "$dst"
if [ ! -s "$dst/mpv.com" ]; then
	curl -sSfL --max-time 900 -o "$dst/mpv.7z" "$url"
	echo "$sha  $dst/mpv.7z" | sha256sum -c -
	(cd "$dst" && 7z x -y mpv.7z >/dev/null && rm mpv.7z)
fi
WINEDEBUG=-all WINEPREFIX=${WINEPREFIX:-$work/wineprefix} wine "$dst/mpv.com" --version | head -2
