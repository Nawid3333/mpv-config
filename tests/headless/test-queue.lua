-- queue/: what plays next, queued from Explorer (single-instance.lua) or by FastStream (the helper's add-stream). The
-- queue waits right behind the entry that plays, survives a replace of it, counts down at its end like FastStream's
-- autoplay (Space stops it), and the panel bottom right lists it: hover, click, drag, x, Clear.
--
-- run-tests.ps1 runs this one on a real OSD surface (--vo=sixel): the panel draws and publishes its boxes, the
-- clicks' targets.
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')
local utils = require('mp.utils')

local function clip(color, seconds)
	return string.format('av://lavfi:color=c=%s:s=960x540:r=24:d=%d', color, seconds)
end

local function title_of(url)
	return url:match('[^/\\]+$')
end

local function queue()
	return mp.get_property_native('user-data/queue') or {}
end

local function count()
	return queue().count
end

local function titles()
	local list = {}
	for i, item in ipairs(queue().items or {}) do
		list[i] = item.title
	end
	return table.concat(list, ' | ')
end

local function panel()
	return mp.get_property_native('user-data/queue-panel') or {}
end

local function playlist()
	local list = {}
	for i, entry in ipairs(mp.get_property_native('playlist') or {}) do
		list[i] = entry.filename
	end
	return table.concat(list, ' | ')
end

local function card(id)
	for _, c in ipairs((mp.get_property_native('user-data/notify') or {}).cards or {}) do
		if c.id == id then
			return c
		end
	end
end

local function hit(what, id)
	for _, h in ipairs(panel().hits or {}) do
		if h.what == what and (id == nil or h.id == id) then
			return h
		end
	end
end

local function middle(h)
	return math.floor(h.x + h.w / 2), math.floor(h.y + h.h / 2)
end

local function point(x, y)
	mp.commandv('mouse', tostring(x), tostring(y))
	H.sleep(0.25)
end

local function id_of(title)
	for _, item in ipairs(queue().items or {}) do
		if item.title == title then
			return item.id
		end
	end
end

H.run(function()
	local first = mp.get_property('path')
	local A, B, C = clip('red', 30), clip('green', 30), clip('yellow', 30)

	H.eq(
		'FastStream can see that this mpv queues: user-data/faststream/queue',
		mp.get_property_number('user-data/faststream/queue/count'),
		0
	)
	H.eq('nothing queued at the start', count(), 0)
	H.eq("keep-open is the user's", mp.get_property('keep-open'), 'yes')
	H.eq('no panel without a queue', panel().shown, false)

	-- files from Explorer ("Add to queue" in single-instance.lua)
	mp.commandv('script-message-to', 'queue', 'add-files', A, B)
	H.expect('two files queued', count, 2)
	H.eq('... right behind what plays, in their order', playlist(), first .. ' | ' .. A .. ' | ' .. B)
	H.eq('... what plays plays on', mp.get_property('path'), first)
	H.eq('... FastStream sees the count', mp.get_property_number('user-data/faststream/queue/count'), 2)
	H.eq('... mpv now stops at the end, for the countdown', mp.get_property('keep-open'), 'always')
	H.check(
		'... the panel shows for a moment',
		H.wait_until(function()
			return panel().shown == true
		end, 3)
	)
	H.eq('... the last one added is marked', queue().added, id_of(title_of(B)))

	mp.commandv('script-message-to', 'queue', 'add-files', A)
	H.sleep(0.5)
	H.eq('a file already queued is not queued twice', count(), 2)

	-- a stream as FastStream's helper hands it over: its per-file options, the title among them
	local options = utils.format_json({ ['force-media-title'] = 'Sky Harbor – Episode 7', ['start'] = '1' })
	mp.commandv('script-message-to', 'queue', 'add-stream', C, options)
	H.expect('a stream from the helper is queued', count, 3)
	H.eq(
		'... with the title from its options',
		titles(),
		title_of(A) .. ' | ' .. title_of(B) .. ' | Sky Harbor – Episode 7'
	)

	-- a replace of what plays (Play here, the next episode, a file dropped in) keeps the queue behind the new entry
	local D = clip('blue', 120)
	H.load(D)
	H.expect('a replace of what plays keeps the queue behind it', playlist, D .. ' | ' .. A .. ' | ' .. B .. ' | ' .. C)
	H.eq('... all three still queued, in their order', count(), 3)
	H.eq('... still stopping at the end', mp.get_property('keep-open'), 'always')

	-- an entry someone else puts behind what plays (autoload's folder files) goes behind the queue
	local X = clip('gray', 5)
	mp.commandv('loadfile', X, 'insert-next')
	H.expect(
		'an entry put behind what plays goes behind the queue',
		playlist,
		D .. ' | ' .. A .. ' | ' .. B .. ' | ' .. C .. ' | ' .. X
	)
	H.eq('... and is not queued', count(), 3)

	mp.commandv('script-message-to', 'queue', 'move', tostring(id_of(title_of(B))), '1')
	H.expect(
		'a moved item takes its place',
		titles,
		title_of(B) .. ' | ' .. title_of(A) .. ' | Sky Harbor – Episode 7'
	)
	H.eq('... in the playlist too', playlist(), D .. ' | ' .. B .. ' | ' .. A .. ' | ' .. C .. ' | ' .. X)

	mp.commandv('script-message-to', 'queue', 'remove', tostring(id_of(title_of(A))))
	H.expect('a removed item leaves the queue', titles, title_of(B) .. ' | Sky Harbor – Episode 7')
	H.eq('... and the playlist', playlist(), D .. ' | ' .. B .. ' | ' .. C .. ' | ' .. X)

	-- the countdown, with the seconds FastStream's autoplay counts down (its helper sets them)
	mp.set_property_native('user-data/faststream/countdown', 2)
	mp.commandv('seek', '119', 'absolute')
	H.check(
		'at the end of what plays the countdown starts',
		H.wait_until(function()
			return queue().countdown ~= nil
		end, 6)
	)
	H.eq("... with FastStream's seconds", (queue().countdown or {}).seconds, 2)
	H.eq('... what plays stays at its end meanwhile', mp.get_property('path'), D)
	H.check(
		'... a banner counts down',
		H.wait_until(function()
			local c = card('queue')
			return c ~= nil and c.title:match('^Up next in %d s$') ~= nil and c.progress ~= nil
		end, 2)
	)
	H.check(
		'... the panel shows it',
		H.wait_until(function()
			return panel().shown == true
		end, 2)
	)
	H.expect('... then the next one plays', function()
		return mp.get_property('path')
	end, B, nil, 6)
	H.eq('... it left the queue', titles(), 'Sky Harbor – Episode 7')
	H.check(
		'... its banner goes',
		H.wait_until(function()
			return card('queue') == nil
		end, 2)
	)

	-- Space (and a click on the video) send faststream-pause with the pause: the countdown stops, nothing plays on
	mp.commandv('seek', '29', 'absolute')
	H.check(
		'at the next end the countdown starts again',
		H.wait_until(function()
			return queue().countdown ~= nil
		end, 6)
	)
	mp.commandv('script-message', 'faststream-pause')
	H.expect('Space stops it', function()
		return queue().countdown == nil
	end, true)
	H.check(
		'... its banner says so',
		H.wait_until(function()
			local c = card('queue')
			return c ~= nil and c.title == 'Up next stopped'
		end, 2)
	)
	H.sleep(3)
	H.eq('... and nothing plays on', mp.get_property('path'), B)
	H.eq('... the item still waits', count(), 1)

	-- the panel: the pointer on the card opens the list; a click on a row plays it now
	mp.commandv('script-message-to', 'queue', 'add-files', A)
	H.expect('one more queued', count, 2)
	H.check(
		'the panel peeks after it',
		H.wait_until(function()
			return panel().shown == true and hit('card') ~= nil
		end, 3)
	)
	point(middle(hit('card')))
	H.expect('the pointer on the card opens the list', function()
		return panel().expanded
	end, true)
	H.check(
		'... a row for each item',
		hit('row', id_of('Sky Harbor – Episode 7')) ~= nil and hit('row', id_of(title_of(A))) ~= nil
	)
	H.expect('... uosc keeps its bar up meanwhile', function()
		return (mp.get_property_native('user-data/uosc/bottom-ui') or {}).visibility
	end, 1, nil, 3)

	-- a drag moves an item: the second row up over the first
	local first_row = hit('row', id_of('Sky Harbor – Episode 7'))
	local second_row = hit('row', id_of(title_of(A)))
	local sx, sy = middle(second_row)
	point(sx, sy)
	mp.commandv('keydown', 'MBTN_LEFT')
	H.sleep(0.1)
	for step = 1, 4 do
		mp.commandv('mouse', tostring(sx), tostring(math.floor(sy - step * first_row.h / 4)))
		H.sleep(0.08)
	end
	mp.commandv('keyup', 'MBTN_LEFT')
	H.expect('a drag moves the row', titles, title_of(A) .. ' | Sky Harbor – Episode 7')
	H.eq('... nothing played or paused by it', mp.get_property('path'), B)
	H.sleep(0.4)

	-- the hovered row's x removes it
	local row = hit('row', id_of(title_of(A)))
	point(middle(row))
	H.check(
		'the hovered row shows its x',
		H.wait_until(function()
			return hit('remove', id_of(title_of(A))) ~= nil
		end, 2)
	)
	H.click(middle(hit('remove', id_of(title_of(A)))))
	H.expect('a click on the x removes it', titles, 'Sky Harbor – Episode 7')
	H.eq('... and plays nothing', mp.get_property('path'), B)

	-- a click on a row plays it now; the others wait behind it
	mp.commandv('script-message-to', 'queue', 'add-files', A)
	H.expect('again two', count, 2)
	H.check(
		'the list is still open under the pointer',
		H.wait_until(function()
			return hit('row', id_of(title_of(A))) ~= nil
		end, 3)
	)
	H.click(middle(hit('row', id_of(title_of(A)))))
	H.expect('a click on a row plays it now', function()
		return mp.get_property('path')
	end, A, nil, 5)
	H.eq('... the other waits behind it', titles(), 'Sky Harbor – Episode 7')
	H.eq('... right behind it', playlist(), D .. ' | ' .. B .. ' | ' .. A .. ' | ' .. C .. ' | ' .. X)

	-- Clear empties the queue, and mpv is back on the user's keep-open
	H.check(
		'Clear is there',
		H.wait_until(function()
			return panel().expanded == true and hit('clear') ~= nil
		end, 3)
	)
	H.click(middle(hit('clear')))
	H.expect('Clear empties the queue', count, 0)
	H.eq('... and the playlist of it', playlist(), D .. ' | ' .. B .. ' | ' .. A .. ' | ' .. X)
	H.eq("... keep-open is the user's again", mp.get_property('keep-open'), 'yes')
	H.expect('... the panel goes', function()
		return panel().shown
	end, false)
	H.eq('... what plays plays on', mp.get_property('path'), A)

	-- the keep-open the queue replaced comes back, not the global one: FastStream's helper holds a stream at its end
	-- for autoplay with a file-local keep-open of its own
	mp.set_property('file-local-options/keep-open', 'no')
	mp.commandv('script-message-to', 'queue', 'add-files', C)
	H.expect('a file queued again', count, 1)
	H.eq('... mpv stops at the end, for the countdown', mp.get_property('keep-open'), 'always')
	mp.commandv('script-message-to', 'queue', 'clear')
	H.expect('... and cleared', count, 0)
	H.eq('... the keep-open it replaced is back', mp.get_property('keep-open'), 'no')
	mp.set_property('file-local-options/keep-open', 'yes')

	-- a click where the panel was is the video's again (pause)
	local pause = mp.get_property_native('pause')
	H.click(sx, sy)
	H.eq("a click where the panel was is the video's", mp.get_property_native('pause'), not pause)

	-- the countdown follows the queue while mpv stands at the end: the first one queued at an end mpv already stands at
	-- (held there by FastStream's helper, say), the first one moved, the one counted down to removed
	mp.set_property_native('pause', false)
	mp.set_property('file-local-options/keep-open', 'always')
	mp.set_property_native('user-data/faststream/countdown', 5)
	mp.commandv('seek', '29', 'absolute')
	H.expect('mpv stands at the end, nothing queued', function()
		return mp.get_property_native('eof-reached')
	end, true, nil, 6)
	H.eq('... no countdown', queue().countdown, nil)
	mp.commandv('script-message-to', 'queue', 'add-files', B, C)
	H.expect('two queued at that end', count, 2)
	local b_id, c_id = id_of(title_of(B)), id_of(title_of(C))
	H.expect('... the countdown starts, for the first', function()
		return (queue().countdown or {}).id
	end, b_id, nil, 3)
	mp.commandv('script-message-to', 'queue', 'move', tostring(c_id), '1')
	H.expect('the other moved first: the countdown goes on for it', function()
		return (queue().countdown or {}).id
	end, c_id, nil, 3)
	mp.commandv('script-message-to', 'queue', 'remove', tostring(c_id))
	H.expect('it removed: the countdown goes on for the next', function()
		return (queue().countdown or {}).id
	end, b_id, nil, 3)
	H.expect('... which then plays', function()
		return mp.get_property('path')
	end, B, nil, 8)
end)
