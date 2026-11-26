-- queue/panel.lua's Up next card for what comes next without a queue too: the playlist's next local file, with its
-- picture (a frame a third into a video, a song's cover: queue/picture.lua's hidden mpv) - while uosc's bar shows and
-- in a file's last 5 seconds; a click on it plays it. A queued stream gets the queue's icon, a stream next in the
-- playlist no card. While a song plays, the card sits in music-info.lua's panel, in the place it keeps for it, and
-- that panel's "Up next:" line goes.
--
-- run-tests.ps1 runs this one on a real OSD surface (--vo=sixel): uosc publishes its bar, the panel draws and
-- publishes its card, and overlay-add shows the picture.
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')
local utils = require('mp.utils')

local function panel()
	return mp.get_property_native('user-data/queue-panel') or {}
end

local function upcoming()
	return (mp.get_property_native('user-data/queue') or {}).next or {}
end

local function music()
	return mp.get_property_native('user-data/music-info') or {}
end

local function shown()
	return panel().shown
end

local function card_text(key)
	return function()
		return (panel().text or {})[key]
	end
end

local function visibility()
	return (mp.get_property_native('user-data/uosc/bottom-ui') or {}).visibility or 0
end

--- uosc's bar on or off, as the panel itself keeps it up (set-min-visibility); the pointer stays off the bar.
local function bar(on)
	mp.commandv('script-message-to', 'uosc', 'set-min-visibility', on and '1' or '0', 'timeline,controls,volume')
end

local function hit(what)
	for _, h in ipairs(panel().hits or {}) do
		if h.what == what then
			return h
		end
	end
end

local function middle(h)
	return math.floor(h.x + h.w / 2), math.floor(h.y + h.h / 2)
end

local function seek_to(seconds)
	mp.commandv('seek', tostring(seconds), 'absolute+exact')
	H.expect('... at ' .. seconds .. ' s', function()
		return mp.get_property_number('time-pos')
	end, seconds, 0.3)
end

local function ends_with(path, tail)
	return path ~= nil and path:gsub('\\', '/'):sub(-#tail) == tail
end

H.run(function()
	mp.set_property_bool('pause', true)
	mp.commandv('mouse', '480', '60')
	H.expect('autoload put the next episode behind this one', function()
		return mp.get_property_number('playlist-count')
	end, 2)
	H.expect("the card knows what comes next: the playlist's next local file", function()
		return upcoming().title
	end, 'episode2')
	H.eq('... no queued item', upcoming().queued, nil)
	H.eq('... with the file to take its picture from', ends_with(upcoming().path, 'autoload/episode2.mkv'), true)

	-- uosc's bar hidden, 9 s left: no card (only the last 5 s show it). The pointer leaves the window, which hides the
	-- bar at once (test-ui-hover.lua): resting in it, the bar was still up on CI after 6 s (2026-11-26, 'bar 1.00'),
	-- and an earlier run read it hidden before uosc had shown it. Both are waited for together; a failure names both.
	seek_to(1)
	bar(false)
	mp.commandv('keypress', 'MOUSE_LEAVE')
	H.expect('no card while the bar is hidden and more than 5 s are left', function()
		return string.format('bar %.2f, card %s', visibility(), tostring(shown() == true))
	end, 'bar 0.00, card false', nil, 6)
	-- back at the same pixel: no move, the bar stays hidden (uosc/lib/cursor.lua)
	mp.commandv('keypress', 'MOUSE_ENTER')

	-- the bar shows: the card, with the next episode's frame
	bar(true)
	H.expect('the card shows with the bar', shown, true)
	H.eq('... on its own above the controls', panel().place, 'card')
	H.eq('... says Up next', card_text('label')(), 'Up next')
	H.eq('... names the next file', card_text('title')(), 'episode2')
	H.expect('... its length and folder, once its hidden mpv read it', card_text('detail'), '0:10 · autoload', nil, 20)
	local framed = H.check(
		'... and shows its frame',
		H.wait_until(function()
			return panel().picture ~= nil
		end, 20),
		utils.format_json(panel().picture_state or {})
	)
	if not framed then
		return
	end
	local picture, box = panel().picture, panel().box
	H.eq('... a 16:9 frame', picture.w / picture.h, 16 / 9, 0.1)
	H.check(
		'... inside the card',
		picture.x >= box.x
			and picture.y >= box.y
			and picture.x + picture.w <= box.x + box.w
			and picture.y + picture.h <= box.y + box.h,
		utils.format_json({ picture = picture, box = box })
	)
	-- the pointer on it opens no list (nothing is queued); a click plays the next file now
	local cx, cy = middle(hit('card'))
	mp.commandv('mouse', tostring(cx), tostring(cy))
	H.sleep(0.5)
	H.eq('the pointer on the card opens no list without a queue', panel().expanded, false)
	H.click(cx, cy)
	H.expect('a click on the card plays the next file now', function()
		return ends_with(mp.get_property('path'), 'autoload/episode2.mkv')
	end, true, nil, 10)
	H.expect('... the last one: no card any more', shown, false, nil, 5)
	H.eq('... nothing next', upcoming().title, nil)
	H.eq('... and its picture is gone', panel().picture, nil)
	mp.commandv('mouse', '480', '60')

	-- the last 5 s show the card with the bar hidden
	H.load(H.media_path('autoload/episode1.mkv'))
	mp.set_property_bool('pause', true)
	bar(false)
	H.expect("uosc's bar hidden again", visibility, 0, nil, 5)
	H.expect('the next episode is next again', function()
		return upcoming().title
	end, 'episode2')
	seek_to(7)
	H.expect('3 s left: the card shows without the bar', shown, true)
	seek_to(2)
	H.expect('8 s left: it goes', shown, false)

	-- a stream next in the playlist is no card; a queued one is, with the queue's icon and no picture
	local stream = 'av://lavfi:color=c=gray:s=640x360:r=24:d=30'
	mp.commandv('loadfile', stream, 'insert-next')
	H.expect('a stream next in the playlist', function()
		return mp.get_property('playlist/1/filename')
	end, stream)
	bar(true)
	H.expect('... is not shown as next', function()
		return upcoming().title
	end, nil)
	H.sleep(0.5)
	H.eq('... no card for it', shown(), false)
	mp.commandv('playlist-remove', '1')
	mp.commandv(
		'script-message-to',
		'queue',
		'add-stream',
		stream,
		utils.format_json({ ['force-media-title'] = 'Sky Harbor – Episode 8' })
	)
	H.expect('a queued stream comes before the playlist', card_text('title'), 'Sky Harbor – Episode 8')
	H.eq('... as a queued item', upcoming().queued, true)
	H.sleep(1)
	H.eq('... with the icon, no picture', panel().picture, nil)
	mp.commandv('script-message-to', 'queue', 'clear')
	H.expect('Clear: the playlist next is back', card_text('title'), 'episode2')

	-- a song: the card goes into music-info's panel, with the next song's cover
	local song = H.media_path('music-tagged/Nova Lane - Paper Lanterns.mp3')
	H.load(song)
	mp.set_property_bool('pause', true)
	mp.commandv('loadfile', song, 'append')
	H.expect('the next song', function()
		return mp.get_property_number('playlist-count')
	end, 2)
	bar(true)
	H.expect("music-info's panel shows with the bar", function()
		return music().visibility
	end, 1, nil, 5)
	H.expect('... and keeps a place for the card', function()
		return music().slot ~= nil
	end, true)
	H.expect('the card sits in it', function()
		return panel().place
	end, 'slot')
	local slot = music().slot
	local function edges(r)
		return r and string.format('%d,%d %dx%d', r.x, r.y, r.w, r.h) or 'none'
	end
	H.eq('... exactly there', edges(panel().box), edges(slot))
	H.expect("... the next song's title from its tags", card_text('title'), 'Paper Lanterns', nil, 20)
	H.eq('... artist and album', card_text('detail')(), 'Nova Lane feat. Test Artist · Night Signals')
	H.check(
		'... and its cover',
		H.wait_until(function()
			local p = panel().picture
			return p ~= nil and p.w == p.h
		end, 20),
		utils.format_json({ picture = panel().picture, state = panel().picture_state })
	)
	local column = table.concat(music().column or {}, ' | ')
	H.check("music-info's own Up next line goes", not column:find('Up next', 1, true), column)
	H.check('... its format and playlist lines stay', column:find('Playlist 1 / 2', 1, true) ~= nil, column)
	H.eq('... its data still names what comes next', music().next, 'Nova Lane – Paper Lanterns')
	-- nothing next any more: music-info gives the card's place back
	mp.commandv('playlist-remove', '1')
	H.expect('nothing next: no card', function()
		return panel().card == nil and not panel().shown
	end, true)
	H.expect("... and music-info's panel keeps no place for it", function()
		return music().slot == nil
	end, true)
	mp.commandv('loadfile', song, 'append')
	H.expect('a next song again: its place is back', function()
		return music().slot ~= nil and panel().place
	end, 'slot', nil, 5)
	bar(false)
	H.expect('the bar hidden: the panel and the card go', shown, false, nil, 5)
	H.eq('... and its cover', panel().picture, nil)
end)
