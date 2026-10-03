-- gpu-toggles.lua, process 2 of 2 (see test-sharpness-save.lua): a fresh mpv
-- starts with the remembered Movie sharpness.
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')

local function curve_height()
	return (mp.get_property_native('glsl-shader-opts') or {})['adaptive-sharpen/curve_height']
end

H.run(function()
	mp.commandv('script-message-to', 'gpu_toggles', 'set-upscale', '3')
	H.expect('a fresh process starts with the remembered sharpness (1.5)', curve_height, '1.500')
	mp.commandv('script-message-to', 'gpu_toggles', 'set-upscale', '0')
end)
