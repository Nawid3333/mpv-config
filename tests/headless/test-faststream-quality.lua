-- faststream-quality.lua: the fs-quality= fragment item becomes a published quality
-- list, the managed uosc button shows only for a file with a valid list, the menu opens
-- as a real uosc menu (callback mode, type faststream-quality), activating the playing
-- entry loads nothing, and a switch loads the other entry with the same fragment, the
-- position and the file's request headers - asserted through
-- user-data/faststream-quality/last-load, since no second real file is behind it.
--
-- The stream names are made up here: a stem without '#' (the "URL" each entry names)
-- plus the fragment the native host appends. They are no files on disk: an on_load hook
-- has mpv open the shared ep1 clip under them, so `path` is exactly what a FastStream
-- stream's would be. The stems are relative and hold no slash: mpv writes a local
-- path's slashes as backslashes on Windows (a stream's https:// address it leaves
-- alone), which made the stems in the list differ from `path`. The runner starts mpv
-- with faststream_quality-test_local=yes, so that entries without a scheme (these
-- stems) are taken; outside the tests only http(s) entries are.
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')
local utils = require('mp.utils')

-- The fs-quality value as the native host writes it: encodeURIComponent of the JSON,
-- every byte but A-Z a-z 0-9 - _ . ! ~ * ' ( ) percent-encoded.
local function encode(s)
	return (s:gsub("[^%w%-_%.!~%*'%(%)]", function(c)
		return ('%%%02X'):format(c:byte())
	end))
end

local function menu_type()
	return mp.get_property_native('user-data/uosc/menu/type')
end

local function close_menu()
	mp.commandv('script-message-to', 'uosc', 'close-menu')
	H.wait_until(function()
		return menu_type() == nil
	end, 3)
	H.eq('the menu closed again', menu_type(), nil)
end

-- One event, exactly what uosc's callback mode produces for this menu:
-- "script-message-to faststream_quality menu-callback <event json>", with the activated
-- item's 1-based index as the value.
local function activate(value)
	mp.commandv(
		'script-message-to',
		'faststream_quality',
		'menu-callback',
		utils.format_json({ type = 'activate', value = value })
	)
end

H.run(function()
	local clip = H.media_path('fs-anime/ep1#fs-content=anime&fs-id=a1b2c3d4e5f60718.mkv')
	local stem = 'faststream-quality-film'
	-- made-up name (as loaded) -> the clip mpv opens instead; mpv may hand the hook the
	-- name made absolute (it did on the Windows runner), so the end of it is matched
	local mapped = {}
	mp.add_hook('on_load', 9, function()
		local opened = mp.get_property('stream-open-filename') or ''
		for name, real in pairs(mapped) do
			local tail = opened:sub(-(#name + 1))
			if opened == name or tail == '/' .. name or tail == '\\' .. name then
				mp.set_property('stream-open-filename', real)
				return
			end
		end
	end)

	-- How mpv writes a relative name in `path` (made absolute? its slashes?): the list's
	-- entries must name the files that way, as the host's do for a stream's address.
	local probe = stem .. '_probe#fs-id=t0'
	mapped[probe] = clip
	H.check('a probe name loads', H.load(probe))
	local seen = mp.get_property('path') or ''
	local prefix = seen:sub(-#probe) == probe and seen:sub(1, #seen - #probe) or ''
	H.info('mpv writes ' .. probe .. ' as ' .. seen)

	local fragment = '#fs-id=t1&fs-quality='
		.. encode(utils.format_json({
			{ label = '1080p', height = 1080, url = prefix .. stem .. '_1080' },
			{ label = '720p', height = 720, url = prefix .. stem .. '_720' },
		}))
	local main_name = stem .. '_1080' .. fragment
	mapped[main_name] = clip

	H.check('the stream loads', H.load(main_name))

	local list
	H.wait_until(function()
		list = mp.get_property_native('user-data/faststream-quality/list')
		return type(list) == 'table' and #list == 2
	end, 3)
	H.check('the two entries are published', type(list) == 'table' and #list == 2)
	H.eq('entry 1 is the stream itself', list and list[1].url, prefix .. stem .. '_1080')
	H.eq('entry 1 keeps its label', list and list[1].label, '1080p')
	H.eq('the playing entry is the current one', mp.get_property_native('user-data/faststream-quality/current'), 1)
	H.expect('the button is shown', function()
		return mp.get_property_native('user-data/faststream-quality/shown')
	end, true, nil, 3)
	H.eq(
		'its badge is the playing quality',
		(mp.get_property_native('user-data/faststream-quality/button') or {}).badge,
		'1080p'
	)

	-- the menu is a real uosc menu with its own type
	mp.commandv('script-message-to', 'faststream_quality', 'open-menu')
	H.wait_until(function()
		return menu_type() ~= nil
	end, 3)
	H.eq('open-menu opens the quality menu', menu_type(), 'faststream-quality')
	close_menu()

	-- the playing entry: nothing loads
	activate(1)
	H.sleep(0.3)
	H.eq(
		'activating the playing entry loads nothing',
		mp.get_property_native('user-data/faststream-quality/last-load'),
		nil
	)

	-- another one: from where the video is, with the same fragment and the headers
	mp.commandv('seek', '2', 'absolute+exact')
	H.wait_until(function()
		return (mp.get_property_number('time-pos') or 0) >= 1
	end, 8)
	mp.set_property_native('http-header-fields', { 'Referer: https://site.example/watch' })
	activate(2)
	local last
	H.wait_until(function()
		last = mp.get_property_native('user-data/faststream-quality/last-load')
		return last ~= nil
	end, 3)
	H.eq('the switch keeps the fragment', last and last.url, prefix .. stem .. '_720' .. fragment)
	H.check(
		'the switch starts where the video was',
		last and last.options and tonumber(last.options.start) ~= nil and tonumber(last.options.start) >= 1
	)
	H.eq(
		'the switch carries the request headers',
		last and last.options and last.options['http-header-fields'],
		'Referer: https://site.example/watch'
	)

	-- a bad tag: an entry with another scheme and one without a url are left out, one
	-- entry is no list, the button hides
	local bad_name = stem
		.. '_bad#fs-id=t1&fs-quality='
		.. encode(
			'[{"label":"720p","url":"https://cdn.example/720.mp4"},{"label":"x","url":"file:///C:/x.mp4"},{"label":"1080p"}]'
		)
	mapped[bad_name] = clip
	H.check('the stream with a bad tag loads', H.load(bad_name))
	H.eq('no list for it', mp.get_property_native('user-data/faststream-quality/list'), nil)
	H.eq('the button hides', mp.get_property_native('user-data/faststream-quality/shown'), false)
	H.eq('nothing is current', mp.get_property_native('user-data/faststream-quality/current'), nil)
end)
