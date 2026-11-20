-- single-instance.lua: a file mpv-single.exe hands over while another plays
-- leaves that one playing, and two corner banners ask: play it here, or in a
-- new window that waits paused (the launcher it would start is published, not
-- run: this test names one that does not exist). No click: nothing changes.
--
-- run-tests.ps1 runs this one on a real OSD surface (--vo=sixel), so notify.lua
-- draws the banners and publishes their boxes, the clicks' targets; the banners
-- stay 4 s here (banner_seconds).
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')

local LAUNCHER = H.root .. '/no-such-launcher.exe'
local IDS = { here = 'single-instance', window = 'single-instance-window' }

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

local function banner(choice)
	for _, card in ipairs((mp.get_property_native('user-data/notify') or {}).cards or {}) do
		if card.id == IDS[choice] then
			return card
		end
	end
end

local function drawn()
	local here, window = banner('here'), banner('window')
	return here ~= nil and here.box ~= nil and window ~= nil and window.box ~= nil
end

-- files started (start-file), and how many when the last file was handed over: a
-- file that plays on was not loaded again since
local starts, starts_then = 0, 0
mp.register_event('start-file', function()
	starts = starts + 1
end)

local function open(mode, ...)
	starts_then = starts
	mp.commandv('script-message-to', 'single_instance', 'open', mode, LAUNCHER, ...)
end

local function playlist()
	local names = {}
	for i, entry in ipairs(mp.get_property_native('playlist') or {}) do
		names[i] = entry.filename
	end
	return table.concat(names, ' | ')
end

local function spawned()
	return table.concat(state().spawned or {}, ' ')
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

local function middle(choice)
	local box = (banner(choice) or {}).box or { x = 0, y = 0, w = 0, h = 0 }
	return box.x + box.w / 2, box.y + box.h / 2
end

-- what plays moves on: it was not replaced, loaded again, nor paused
local function plays_on(name, file)
	local from = mp.get_property_number('time-pos') or 0
	H.check(
		name,
		H.wait_until(function()
			return path() == norm(file)
				and starts == starts_then
				and (mp.get_property_number('time-pos') or 0) > from + 0.3
		end, 5),
		string.format(
			'%s at %s, %d file(s) started since the hand-off',
			path(),
			tostring(mp.get_property_number('time-pos')),
			starts - starts_then
		)
	)
end

H.run(function()
	local clip = H.media_path('plain/clip.mkv')
	local before = H.media_path('second/clip2.mkv')
	local after = H.media_path('long/long.mkv')
	local new = H.media_path('subs/movie.mkv')

	-- what plays: [clip2, clip (here, from 3 s), long]
	mp.commandv('loadfile', before, 'insert-at', '0')
	mp.commandv('loadfile', after, 'append')
	mp.commandv('seek', '3', 'absolute', 'exact')
	-- no other banner above ours (video-info's, from the load): its end would move ours under the pointer
	H.wait_until(function()
		return #((mp.get_property_native('user-data/notify') or {}).cards or {}) == 0
	end, 6)
	local old_list = playlist()

	open('replace', new)
	H.check('a file handed over while another plays: both banners', H.wait_until(drawn, 5))
	H.eq('... the offer names the new file', ((offer() or {}).files or {})[1], new)
	H.eq('... and the one that plays', norm((offer() or {}).old), norm(clip))
	plays_on('the old file plays on meanwhile', clip)
	H.eq('... its playlist as it was', playlist(), old_list)
	H.check('... "Play here" stands above "Play in a new window"', banner('here').box.y < banner('window').box.y)

	-- a click beside the banners is still the video's (input.conf: pause)
	local paused = mp.get_property_native('pause')
	local wx, wy = middle('window')
	click_at(wx - 200, wy + 150)
	H.eq('a click beside the banners pauses or plays, as on the video', mp.get_property_native('pause'), not paused)
	H.check('... and leaves the offer', offer() ~= nil)
	mp.set_property_native('pause', false)

	-- a double click on "Play in a new window", as some hands do: the first click takes the choice
	double_click_at(middle('window'))
	H.expect(
		'"Play in a new window" starts the launcher for a window that waits paused',
		spawned,
		LAUNCHER .. ' --new-window --paused -- ' .. new
	)
	plays_on('... and the old file plays on here', clip)
	H.eq('... its playlist as it was', playlist(), old_list)
	H.eq('... and the double click did not go fullscreen', mp.get_property_native('fullscreen'), false)
	H.check('the offer is done', offer() == nil)
	H.check(
		'... and so are both banners',
		H.wait_until(function()
			return banner('here') == nil and banner('window') == nil
		end, 3)
	)
	click_at(wx, wy)
	H.eq("a click where the banner was is the video's again", mp.get_property_native('pause'), true)
	mp.set_property_native('pause', false)

	-- "Play here": the new file in place of what plays, which plays even when paused before
	open('replace', new)
	H.check('a new offer', H.wait_until(drawn, 5))
	local was = spawned()
	mp.set_property_native('pause', true)
	click_at(middle('here'))
	H.expect('"Play here" plays the new file here', path, norm(new))
	H.eq('... in place of the old playlist', mp.get_property_number('playlist-count'), 1)
	H.expect('... and plays (auto-start.lua)', function()
		return mp.get_property_native('pause')
	end, false)
	H.eq('... and starts no window', spawned(), was)
	H.check('the offer is done', offer() == nil)

	-- a burst while the old file plays: the files opened with the first one go where it goes
	H.load(clip)
	H.sleep(0.5)
	local list = playlist()
	open('replace', new)
	open('append', before)
	H.expect('a file opened together with it joins the offer', function()
		return #((offer() or {}).files or {})
	end, 2)
	H.eq('... not the playlist', playlist(), list)
	open('append', new)
	H.sleep(0.3)
	H.eq('... once', #((offer() or {}).files or {}), 2)
	H.expect('... and the banner says so', function()
		return ((banner('here') or {}).detail or ''):match('and 1 more') ~= nil
	end, true)
	mp.commandv('script-message-to', 'single_instance', 'choose', 'window')
	-- the burst's last file, after the click: the window starts once the burst is in
	mp.commandv('script-message-to', 'single_instance', 'open', 'append', LAUNCHER, after)
	H.expect(
		'the whole burst goes to the new window, a file that came after the click too',
		spawned,
		LAUNCHER .. ' --new-window --paused -- ' .. new .. ' ' .. before .. ' ' .. after
	)
	H.eq('... none of it to the playlist here', playlist(), list)
	plays_on('... and the old file plays on here', clip)

	-- the next hand-off within that second: the window chosen before starts at once, with its own files
	open('replace', new)
	H.check('a new offer', H.wait_until(offer, 2))
	mp.commandv('script-message-to', 'single_instance', 'choose', 'window')
	open('replace', before)
	H.expect(
		'a hand-off right after "Play in a new window" starts that window with its files',
		spawned,
		LAUNCHER .. ' --new-window --paused -- ' .. new,
		nil,
		0.5
	)
	H.check('... and is offered itself', H.wait_until(offer, 2))
	mp.commandv('script-message-to', 'single_instance', 'choose', 'window')
	H.expect('... in a window of its own', spawned, LAUNCHER .. ' --new-window --paused -- ' .. before, nil, 3)
	plays_on('... and the old file plays on here', clip)

	-- a newer hand-off while the pointer rests on "Play here": a click a moment after was meant for the one replaced
	open('replace', new)
	H.check('a new offer', H.wait_until(drawn, 5))
	local qx, qy = middle('here')
	mp.commandv('mouse', tostring(math.floor(qx)), tostring(math.floor(qy)))
	H.sleep(0.2)
	open('replace', before)
	H.expect('... replaced by a newer one', function()
		return ((offer() or {}).files or {})[1]
	end, before)
	mp.commandv('keydown', 'MBTN_LEFT')
	mp.commandv('keyup', 'MBTN_LEFT')
	H.sleep(0.3)
	H.check('... a click right after it takes nothing', offer() ~= nil and path() == norm(clip), path())
	plays_on('... and the old file plays on', clip)

	-- left alone, the offer goes with its banners, and nothing changes; the pointer rests on a banner meanwhile
	open('replace', new)
	H.check('a new offer', H.wait_until(drawn, 5))
	local hx, hy = middle('here')
	mp.commandv('mouse', tostring(math.floor(hx)), tostring(math.floor(hy)))
	H.check(
		'... gone after banner_seconds',
		H.wait_until(function()
			return offer() == nil and banner('here') == nil and banner('window') == nil
		end, 8)
	)
	click_at(hx, hy)
	H.eq("... and a click where it was is the video's again", mp.get_property_native('pause'), true)
	mp.set_property_native('pause', false)
	plays_on('... and the old file plays on', clip)

	-- nothing to lose: the file that plays opened again, a file at its end
	open('replace', clip)
	H.sleep(0.5)
	H.check('the file that plays, opened again: no offer', offer() == nil)
	H.load(before)
	mp.commandv('seek', tostring(mp.get_property_number('duration') - 0.3), 'absolute', 'exact')
	H.check(
		'a file plays out to its end',
		H.wait_until(function()
			return mp.get_property_native('eof-reached') == true
		end, 10)
	)
	open('replace', new)
	H.expect('a file handed over after the end plays at once', path, norm(new))
	H.check('... with no offer', offer() == nil)
	open('append', before)
	H.expect('... and one opened with it is queued', function()
		return mp.get_property_number('playlist-count')
	end, 2)

	-- what plays comes to its end while the banners ask: nothing to lose any more, the offered file plays here
	H.load(before)
	mp.commandv('seek', tostring(mp.get_property_number('duration') - 1.5), 'absolute', 'exact')
	H.sleep(0.2)
	open('replace', new)
	H.check('a file handed over near the end of what plays: an offer', H.wait_until(offer, 2))
	H.expect('... and once that ends, the offered file plays here', path, norm(new), nil, 6)
	H.check('... with the offer done', offer() == nil)
end)
