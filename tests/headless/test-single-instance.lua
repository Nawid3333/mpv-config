-- single-instance.lua: a file mpv-single.exe hands over replaces what plays,
-- and the corner banner puts it back - the old playlist, the old file at its
-- second, paused as it was - while the new file goes to a new window (the
-- launcher it would start is published, not run: this test names one that
-- does not exist).
--
-- run-tests.ps1 runs this one on a real OSD surface (--vo=sixel), so notify.lua
-- draws the banner and publishes its box, the click's target; the banner stays
-- 2 s here (banner_seconds).
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')

local LAUNCHER = H.root .. '/no-such-launcher.exe'

-- mpv reports a local path with \ (Windows): compare paths that way
local function norm(p)
	return p and (p:gsub('/', '\\'))
end

local function path()
	return norm(mp.get_property('path'))
end

local function state()
	return mp.get_property_native('user-data/single-instance') or {}
end

local function offer()
	return state().offer
end

local function banner()
	for _, card in ipairs((mp.get_property_native('user-data/notify') or {}).cards or {}) do
		if card.id == 'single-instance' then
			return card
		end
	end
end

local function open(mode, ...)
	mp.commandv('script-message-to', 'single_instance', 'open', mode, LAUNCHER, ...)
end

local function playlist()
	local names = {}
	for i, entry in ipairs(mp.get_property_native('playlist') or {}) do
		names[i] = entry.filename
	end
	return table.concat(names, ' | ')
end

-- a pointer at rest over a spot, then a click there, as a hand does
local function click_at(x, y)
	mp.commandv('mouse', tostring(math.floor(x)), tostring(math.floor(y)))
	H.sleep(0.2)
	H.click(math.floor(x), math.floor(y))
end

-- ... and a double click: its second press comes well within
-- --input-doubleclick-time (300 ms)
local function double_click_at(x, y)
	mp.commandv('mouse', tostring(math.floor(x)), tostring(math.floor(y)))
	H.sleep(0.2)
	for _ = 1, 2 do
		mp.commandv('keydown', 'MBTN_LEFT')
		mp.commandv('keyup', 'MBTN_LEFT')
		H.sleep(0.08)
	end
	H.sleep(0.6)
end

H.run(function()
	local clip = H.media_path('plain/clip.mkv')
	local before = H.media_path('second/clip2.mkv')
	local after = H.media_path('long/long.mkv')
	local new = H.media_path('subs/movie.mkv')

	-- what plays: [clip2, clip (here, 3 s, paused), long]
	mp.commandv('loadfile', before, 'insert-at', '0')
	mp.commandv('loadfile', after, 'append')
	mp.commandv('seek', '3', 'absolute', 'exact')
	H.sleep(0.5)
	mp.set_property_native('pause', true)
	H.sleep(0.3)
	local old_list = playlist()

	open('replace', new)
	H.expect('the file handed over plays here', path, norm(new))
	H.eq('... in place of the old playlist', mp.get_property_number('playlist-count'), 1)
	H.expect('... and plays (auto-start.lua)', function()
		return mp.get_property_native('pause')
	end, false)
	H.eq('the banner offers the old file back', norm((offer() or {}).old), norm(clip))
	H.check(
		'notify draws the banner',
		H.wait_until(function()
			local card = banner()
			return card ~= nil and card.box ~= nil
		end, 5)
	)
	local box = (banner() or {}).box or { x = 0, y = 0, w = 0, h = 0 }

	-- a click elsewhere is still the video's (input.conf: pause)
	local paused = mp.get_property_native('pause')
	click_at(box.x - 200, box.y + box.h + 150)
	H.eq('a click beside the banner pauses or plays, as on the video', mp.get_property_native('pause'), not paused)
	H.check('... and leaves the offer', offer() ~= nil)

	-- a double click, as some hands do: the first click takes the offer
	local played = mp.get_property_number('time-pos') or 0
	double_click_at(box.x + box.w / 2, box.y + box.h / 2)
	local spawned = state().spawned or {}
	H.eq('a click on the banner starts the launcher for a new window', spawned[2], '--new-window')
	local start = tonumber(((spawned[3] or ''):match('^%-%-start=(.*)$')))
	H.check(
		'... with the new file where it got to',
		start ~= nil and start >= played - 0.5 and spawned[4] == '--' and spawned[5] == new,
		table.concat(spawned, ' ')
	)
	H.expect('... and the old file comes back here', path, norm(clip))
	H.expect('... at its second', function()
		return mp.get_property_number('time-pos')
	end, 3, 0.5)
	-- auto-start.lua's file-loaded handler may still be on its way
	H.sleep(0.3)
	H.eq(
		"... paused, as it was (the double click's second press played nothing)",
		mp.get_property_native('pause'),
		true
	)
	H.eq('... and the double click did not go fullscreen', mp.get_property_native('fullscreen'), false)
	H.eq('... with its whole playlist, in order', playlist(), old_list)
	H.eq('... at its place in it', mp.get_property_number('playlist-pos'), 1)
	H.check('the offer is done', offer() == nil)
	H.check(
		'... and so is the banner',
		H.wait_until(function()
			return banner() == nil
		end, 3)
	)

	-- a burst: the files opened with the first one go with it to the new window
	mp.set_property_native('pause', false)
	H.sleep(0.5)
	open('replace', new)
	open('append', before)
	H.expect('a file opened together with it joins the playlist', function()
		return mp.get_property_number('playlist-count')
	end, 2)
	H.eq('... and what a click would move', #((offer() or {}).files or {}), 2)
	-- autoload.lua queues the first file's folder before the rest of a burst comes
	open('append', new)
	H.sleep(0.3)
	H.eq('a file of the burst that is queued already is not queued twice', mp.get_property_number('playlist-count'), 2)
	H.eq('... nor moved twice', #((offer() or {}).files or {}), 2)
	mp.commandv('script-message-to', 'single_instance', 'accept')
	H.expect('the burst goes to the new window, from its start', function()
		return table.concat(state().spawned or {}, ' ')
	end, LAUNCHER .. ' --new-window -- ' .. new .. ' ' .. before)
	H.expect('... and the old file plays on here', path, norm(clip))
	H.eq('... not paused, as it was', mp.get_property_native('pause'), false)

	-- nothing to offer back: the same file again, a file at its end
	open('replace', clip)
	H.sleep(0.5)
	H.check('the file that plays, opened again: no offer', offer() == nil)
	H.load(H.media_path('second/clip2.mkv'))
	mp.commandv('seek', tostring(mp.get_property_number('duration') - 0.3), 'absolute', 'exact')
	H.check(
		'a file plays out to its end',
		H.wait_until(function()
			return mp.get_property_native('eof-reached') == true
		end, 10)
	)
	open('replace', new)
	H.sleep(0.5)
	H.check('a file at its end, replaced: no offer', offer() == nil)

	-- left alone, the offer goes with its banner
	H.load(clip)
	H.sleep(0.5)
	open('replace', new)
	H.check('a new offer', H.wait_until(offer, 3))
	H.check(
		'... gone after banner_seconds',
		H.wait_until(function()
			return offer() == nil and banner() == nil
		end, 5)
	)
	H.eq('... and the new file plays on', path(), norm(new))
end)
