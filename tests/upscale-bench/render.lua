-- Upscaler benchmark renderer (tests/upscale-bench/render.py): for every
-- playlist entry, wait until the paused first frame is up, take a 'window'
-- screenshot (gpu-next re-renders the frame with the whole shader chain at the
-- window size) as <render_out>/<playlist index>.png, then go to the next entry.
local outdir = mp.get_opt('render_out')
local done = {}

local function shoot()
	local p = mp.get_property('path')
	if not p or done[p] then
		return
	end
	done[p] = true
	local passes = mp.get_property_native('vo-passes')
	local n = passes and passes.fresh and #passes.fresh or -1
	local pos = mp.get_property_number('playlist-pos', 0)
	local ok, err = mp.commandv('screenshot-to-file', string.format('%s/%05d.png', outdir, pos), 'window')
	io.stderr:write(string.format('RENDERED %d passes=%d ok=%s %s\n', pos, n, tostring(ok), tostring(err or '')))
	if pos + 1 >= mp.get_property_number('playlist-count', 0) then
		mp.command('quit')
	else
		mp.command('playlist-next')
	end
end

mp.register_event('playback-restart', function()
	-- one real draw first, so vo-passes reflects this file's chain
	mp.add_timeout(0.2, shoot)
end)
