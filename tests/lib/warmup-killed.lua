-- tests/lib/warmup-killed.lua - stands in for warmup.lua in the "interrupted"
-- phase: exits at once with code 1, as a warm-up mpv killed with taskkill /F
-- does (the FastStream e2e tests kill every mpv.exe started during a spec).
mp.command('quit 1')
