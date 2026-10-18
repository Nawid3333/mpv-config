-- faststream-quality.lua: the fs-quality= fragment item becomes a published quality
-- list, the managed uosc button shows only for a file with a valid list, the menu opens
-- as a real uosc menu (callback mode, type faststream-quality), activating the playing
-- entry loads nothing, and a switch loads the other entry with the same fragment, the
-- position and the file's request headers - asserted through
-- user-data/faststream-quality/last-load, since no second real file is behind it.
-- Phase variants (below): the stream's own qualities, editions and tracks.
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
-- item's value: its url.
local function activate(value)
	mp.commandv(
		'script-message-to',
		'faststream_quality',
		'menu-callback',
		utils.format_json({ type = 'activate', value = value })
	)
end

-- Phase late-uosc: mpv loads no scripts but this one, and uosc only after 2 s, as on a slow
-- start where uosc listens late. The button reached it only by the one retry after 0.5 s.
local function late_uosc()
	local clip = H.media_path('fs-anime/ep1#fs-content=anime&fs-id=a1b2c3d4e5f60718.mkv')
	local name = 'faststream-quality-late#fs-id=t1&fs-quality='
		.. encode(utils.format_json({
			{ label = '1080p', height = 1080, url = 'faststream-quality-late' },
			{ label = '720p', height = 720, url = 'faststream-quality-late_720' },
		}))
	mp.add_hook('on_load', 9, function()
		local opened = mp.get_property('stream-open-filename') or ''
		if opened:find('faststream-quality-late', 1, true) then
			mp.set_property('stream-open-filename', clip)
		end
	end)
	H.check('the stream loads', H.load(name))
	H.expect('its list is read', function()
		local list = mp.get_property_native('user-data/faststream-quality/list')
		return type(list) == 'table' and #list
	end, 2, nil, 3)
	H.eq('no uosc yet: the button is not shown', mp.get_property_native('user-data/faststream-quality/shown'), false)
	H.sleep(2)
	mp.commandv('load-script', mp.command_native({ 'expand-path', '~~/Scripts/uosc' }))
	H.expect('uosc started late: the button reaches it', function()
		return mp.get_property_native('user-data/faststream-quality/shown')
	end, true, nil, 5)
end

-- The rows' labels, highest first, as one string ("360p60,180p"), or nil without a list.
local function labels()
	local list = mp.get_property_native('user-data/faststream-quality/list')
	if type(list) ~= 'table' then
		return nil
	end
	local out = {}
	for _, entry in ipairs(list) do
		out[#out + 1] = entry.label
	end
	return table.concat(out, ',')
end

local function row_value(index)
	local list = mp.get_property_native('user-data/faststream-quality/list') or {}
	return list[index] and list[index].value
end

-- Plays from 5 s on, switches to row `index`, and checks that the picture changed size
-- and the position stayed.
local function switch_keeps_position(what, index, height)
	mp.commandv('seek', '5', 'absolute+exact')
	H.wait_until(function()
		return (mp.get_property_number('time-pos') or 0) >= 5
	end, 8)
	activate(row_value(index))
	H.expect(what .. ': the picture is the other size', function()
		return mp.get_property_number('video-params/h')
	end, height, nil, 8)
	H.expect(what .. ': that row is the current one', function()
		return mp.get_property_native('user-data/faststream-quality/current')
	end, index, nil, 3)
	-- an HLS variant starts over at 0, and the script seeks back once that restart is done
	H.expect(what .. ': from the same position, not the start', function()
		return (mp.get_property_number('time-pos') or 0) >= 4.5
	end, true, nil, 5)
	-- a seek of the user's after the switch is never taken back for the switch's restart
	mp.commandv('seek', '1', 'absolute+exact')
	H.sleep(1)
	local after = mp.get_property_number('time-pos') or 99
	H.check(what .. ': a seek after the switch stays', after < 4, ('time-pos %.2f'):format(after))
end

-- Phase variants: the stream's own qualities, no page list. media's variants/ holds one
-- video in two sizes: an HLS master (lavf's variant editions), an EDL whose streams have a
-- program_id each (ytdl_hook's YouTube formats), and v360.ts, added to a 180p clip as a
-- second video track (variants mpv lists as tracks).
local function variants()
	H.check('the HLS master loads', H.load(H.media_path('variants/master.m3u8')))
	H.expect('its variants are the qualities, highest first', labels, '360p60,180p', nil, 3)
	H.eq('they come from its editions', mp.get_property_native('user-data/faststream-quality/source'), 'editions')
	H.eq(
		'the highest bitrate plays (hls-bitrate=max)',
		mp.get_property_native('user-data/faststream-quality/current'),
		1
	)
	H.expect('the button is shown', function()
		return mp.get_property_native('user-data/faststream-quality/shown')
	end, true, nil, 3)
	H.eq(
		'its badge is the playing height (360p60 is cut to it, not to 360p6)',
		(mp.get_property_native('user-data/faststream-quality/button') or {}).badge,
		'360p'
	)
	H.eq("uosc's Editions button hides", mp.get_property_native('user-data/faststream-quality/editions'), true)
	switch_keeps_position('HLS', 2, 180)
	H.expect('the badge follows the switch', function()
		return (mp.get_property_native('user-data/faststream-quality/button') or {}).badge
	end, '180p', nil, 3)

	-- the switch was the one file's: the next starts at its own default edition (the first),
	-- not at the index picked here
	H.check('the EDL loads', H.load(H.media_path('variants/two.edl')))
	H.expect("its streams' programs are the qualities", labels, '360p60,180p', nil, 3)
	H.eq('they come from its editions', mp.get_property_native('user-data/faststream-quality/source'), 'editions')
	H.eq('it starts at its own default, not the last pick', mp.get_property_number('current-edition'), 0)
	switch_keeps_position('EDL', 2, 180)

	-- variants as tracks: two video tracks of different sizes, no programs
	H.check('a 180p clip loads', H.load(H.media_path('plain/clip.mkv')))
	H.eq('one size is no choice', labels(), nil)
	H.eq('the button is not shown', mp.get_property_native('user-data/faststream-quality/shown'), false)
	H.eq("uosc's Editions button shows again", mp.get_property_native('user-data/faststream-quality/editions'), false)
	mp.commandv('video-add', H.media_path('variants/v360.ts'), 'auto')
	H.expect('a second size added: its tracks are the qualities', labels, '360p60,180p', nil, 3)
	H.eq('they come from its tracks', mp.get_property_native('user-data/faststream-quality/source'), 'tracks')
	H.eq("the clip's own track plays", mp.get_property_native('user-data/faststream-quality/current'), 2)
	H.eq("uosc's Editions button stays", mp.get_property_native('user-data/faststream-quality/editions'), false)
	switch_keeps_position('tracks', 1, 360)

	-- the menu is the same one, and follows the switch while open
	mp.commandv('script-message-to', 'faststream_quality', 'open-menu')
	H.wait_until(function()
		return menu_type() ~= nil
	end, 3)
	H.eq('open-menu opens the quality menu', menu_type(), 'faststream-quality')
	close_menu()
end

H.run(function()
	if os.getenv('MPV_TEST_PHASE') == 'late-uosc' then
		late_uosc()
		return
	end
	if os.getenv('MPV_TEST_PHASE') == 'variants' then
		variants()
		return
	end
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
	H.eq("the list is the page's", mp.get_property_native('user-data/faststream-quality/source'), 'page')
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
	activate(list[1].url)
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
	activate(list[2].url)
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

	-- paused, with a subtitle delay: the other quality loads paused and keeps the delay
	-- (issue #96: auto-start.lua unpaused it, and put the delay back to 0 at the unload)
	H.check('the stream loads again', H.load(main_name))
	local switched = stem .. '_720' .. fragment
	mapped[switched] = clip
	mp.set_property_native('pause', true)
	mp.set_property_number('sub-delay', 0.5)
	-- the button stays up over the switch (it hid at the old file's end and showed again:
	-- two pushes that repaint uosc's whole UI, and a relayout of the bar)
	local hidden = 0
	local function count_hidden(_, shown)
		if shown == false then
			hidden = hidden + 1
		end
	end
	mp.observe_property('user-data/faststream-quality/shown', 'native', count_hidden)
	activate(list[2].url)
	H.wait_until(function()
		local path = mp.get_property('path') or ''
		return path:sub(-#switched) == switched and mp.get_property_native('duration') ~= nil
	end, 8)
	H.sleep(0.5)
	H.eq('the switch loaded the other quality', (mp.get_property('path') or ''):sub(-#switched), switched)
	H.eq('a switch made while paused stays paused', mp.get_property_native('pause'), true)
	H.eq('a switch keeps the subtitle delay', mp.get_property_number('sub-delay'), 0.5)
	H.eq('the keep-pause note is used up', mp.get_property_native('user-data/auto-start/keep-pause'), nil)
	mp.unobserve_property(count_hidden)
	H.eq('the button stayed up over the switch', hidden, 0)
	mp.set_property_number('sub-delay', 0)
	mp.set_property_native('pause', false)

	-- a row of the last file's menu (uosc keeps a callback menu open over a file change,
	-- the next episode after autoplay): a url this file's list does not have does nothing
	local loads_before = utils.format_json(mp.get_property_native('user-data/faststream-quality/last-load'))
	activate('https://cdn.example/another-episode/720.mp4')
	H.sleep(0.3)
	H.eq(
		"a url not in this file's list loads nothing",
		utils.format_json(mp.get_property_native('user-data/faststream-quality/last-load')),
		loads_before
	)

	-- a label a web page wrote in another script: the badge is cut between whole UTF-8
	-- characters (issue #96: a cut by bytes left half of one)
	local wide = stem
		.. '_wide#fs-id=t2&fs-quality='
		.. encode(utils.format_json({
			{ label = '高清 1080P', height = 1080, url = prefix .. stem .. '_wide' },
			{ label = '720p', height = 720, url = prefix .. stem .. '_w720' },
		}))
	mapped[wide] = clip
	H.check('a stream with a wide label loads', H.load(wide))
	H.expect('its badge is cut between whole characters', function()
		return (mp.get_property_native('user-data/faststream-quality/button') or {}).badge
	end, '高清 10', nil, 3)

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
