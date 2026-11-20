-- auto-start.lua - every newly loaded file starts playing, with no leftover delays

local mp = require('mp')

local o = {
	start_paused = false, -- the first file stays paused (--pause): a window that waits (mpv-single.exe --paused)
}
require('mp.options').read_options(o, 'auto_start')

local KEEP_PAUSE = 'user-data/auto-start/keep-pause'

mp.register_event('file-loaded', function()
	if o.start_paused then
		o.start_paused = false
		return
	end
	local keep = mp.get_property_native(KEEP_PAUSE)
	if keep ~= nil then
		mp.del_property(KEEP_PAUSE)
		if keep == mp.get_property('path') then
			return
		end
	end
	if mp.get_property_native('pause') then
		mp.set_property_native('pause', false)
	end
end)

-- a first file that never loads (an error) ends the wait too: the next one plays; a playlist file's own end
-- (redirect) comes before its first entry loads
mp.register_event('end-file', function(event)
	if event.reason ~= 'redirect' then
		o.start_paused = false
	end
end)

mp.add_hook('on_unload', 50, function()
	for _, name in ipairs({ 'sub-delay', 'audio-delay' }) do
		if (mp.get_property_number(name) or 0) ~= 0 then
			mp.set_property_number(name, 0)
		end
	end
end)
