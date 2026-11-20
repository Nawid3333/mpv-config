-- faststream-offer.lua: a stream FastStream sends while the window plays. The extension's offer shows two banners
-- top right, "Play here" and "Play in a new window"; a click on one goes back as faststream-choice <id> here|window,
-- no click as none. The script loads, pauses and stops nothing: what plays plays on under the banners.
--
-- run-tests.ps1 runs this one on a real OSD surface (--vo=sixel), so notify.lua draws the banners and publishes their
-- boxes, the clicks' targets.
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')

local IDS = { here = 'faststream-here', window = 'faststream-window' }

-- what the helper's IPC client would hear: the script's answers, and input.conf's click on the video
local answers, answered_at = {}, nil
mp.register_script_message('faststream-choice', function(...)
	answers[#answers + 1] = table.concat({ ... }, ' ')
	answered_at = mp.get_time()
end)
local helper_pauses = 0
mp.register_script_message('faststream-pause', function()
	helper_pauses = helper_pauses + 1
end)

local function heard()
	return table.concat(answers, ', ')
end

local starts = 0
mp.register_event('start-file', function()
	starts = starts + 1
end)

local function state()
	return mp.get_property_native('user-data/faststream/offer-state') or {}
end

local function cards()
	return (mp.get_property_native('user-data/notify') or {}).cards or {}
end

-- both banners from one read: notify.lua runs on a thread of its own and may publish between two
local function shown()
	local found = {}
	for _, card in ipairs(cards()) do
		for choice, id in pairs(IDS) do
			if card.id == id then
				found[choice] = card
			end
		end
	end
	return found
end

local function banner(choice)
	return shown()[choice]
end

local function drawn()
	local b = shown()
	return b.here ~= nil and b.here.box ~= nil and b.window ~= nil and b.window.box ~= nil
end

local function gone()
	return banner('here') == nil and banner('window') == nil
end

local function offer(id, seconds, here_title, here_detail, window_title, window_detail)
	mp.commandv(
		'script-message',
		'faststream-offer',
		id,
		seconds,
		here_title or 'Play here',
		here_detail or 'Episode 2, in place of Episode 1',
		window_title or 'Play in a new window',
		window_detail or 'Episode 1 plays on'
	)
end

local function cancel(...)
	mp.commandv('script-message', 'faststream-offer-cancel', ...)
end

-- a pointer at rest over a spot, then a click there, as a hand does
local function click_at(x, y)
	mp.commandv('mouse', tostring(math.floor(x)), tostring(math.floor(y)))
	H.sleep(0.2)
	H.click(math.floor(x), math.floor(y))
end

-- ... and a double click: its second press comes well within --input-doubleclick-time (300 ms)
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

local function unpause()
	mp.set_property_native('pause', false)
end

H.run(function()
	local path = mp.get_property('path')
	local starts_then = starts

	-- what plays moves on: not replaced, loaded again, nor paused
	local function plays_on(name)
		local from = mp.get_property_number('time-pos') or 0
		H.check(
			name,
			H.wait_until(function()
				return mp.get_property('path') == path
					and starts == starts_then
					and mp.get_property_native('pause') == false
					and (mp.get_property_number('time-pos') or 0) > from + 0.3
			end, 5),
			string.format(
				'%s at %s, paused %s, %d file(s) started since the test began',
				tostring(mp.get_property('path')),
				tostring(mp.get_property_number('time-pos')),
				tostring(mp.get_property_native('pause')),
				starts - starts_then
			)
		)
	end

	H.eq(
		'the marker for the extension: user-data/faststream/offer = 1',
		mp.get_property('user-data/faststream/offer'),
		'1'
	)
	H.eq('no offer at the start', state().shown, false)
	-- no other banner above ours (video-info's, from the load): its end would move ours under the pointer
	H.check(
		'no other banner up before the first offer',
		H.wait_until(function()
			return #cards() == 0
		end, 6)
	)

	offer('o1', '10')
	H.check('an offer shows both banners', H.wait_until(drawn, 5))
	H.eq(
		'... "Play here" with its texts as given',
		banner('here').title .. ' | ' .. banner('here').detail,
		'Play here | Episode 2, in place of Episode 1'
	)
	H.eq(
		'... and "Play in a new window"',
		banner('window').title .. ' | ' .. banner('window').detail,
		'Play in a new window | Episode 1 plays on'
	)
	H.eq('... with their icons', banner('here').icon .. ' ' .. banner('window').icon, 'play_arrow open_in_new')
	H.check('... "Play here" stands above "Play in a new window"', banner('here').box.y < banner('window').box.y)
	H.eq('... the offer is published', state().id, 'o1')
	plays_on('what plays plays on under them')

	-- a click beside the banners is the video's (input.conf: pause)
	local wx, wy = middle('window')
	click_at(wx - 200, wy + 150)
	H.eq('a click beside the banners pauses, as on the video', mp.get_property_native('pause'), true)
	H.check('... and leaves the offer', state().id == 'o1' and heard() == '', heard())
	unpause()

	-- a double click on "Play in a new window", as some hands do: the first click answers, the second does nothing
	local pauses_then = helper_pauses
	double_click_at(wx, wy)
	H.expect('"Play in a new window" answers window', heard, 'o1 window')
	H.eq('... and the double click did not go fullscreen', mp.get_property_native('fullscreen'), false)
	H.eq('... nor reach the helper as a click on the video', helper_pauses, pauses_then)
	H.check('... both banners go', H.wait_until(gone, 3))
	H.eq('... and the offer', state().shown, false)
	plays_on('... what plays plays on')
	click_at(wx, wy)
	H.eq("a click where the banner was is the video's again", mp.get_property_native('pause'), true)
	unpause()

	answers = {}
	offer('o2', '10')
	H.check('a new offer', H.wait_until(drawn, 5))
	click_at(middle('here'))
	H.expect('"Play here" answers here', heard, 'o2 here')
	H.check('... both banners go', H.wait_until(gone, 3))
	plays_on('... and nothing is loaded here: the extension loads the stream')

	-- left alone, the offer ends with none; the pointer rests on a banner meanwhile
	answers, answered_at = {}, nil
	offer('o3', '2')
	local offered_at = mp.get_time()
	H.check('an offer for 2 s', H.wait_until(drawn, 5))
	local hx, hy = middle('here')
	mp.commandv('mouse', tostring(math.floor(hx)), tostring(math.floor(hy)))
	H.check(
		'... no click: answered none',
		H.wait_until(function()
			return heard() == 'o3 none'
		end, 5),
		heard()
	)
	H.check(
		'... once its time is up',
		answered_at and answered_at - offered_at >= 1.8,
		string.format('after %.2f s', (answered_at or 0) - offered_at)
	)
	H.check('... both banners go', H.wait_until(gone, 3))
	H.eq('... and the offer', state().shown, false)
	click_at(hx, hy)
	H.eq("... a click where they were is the video's again", mp.get_property_native('pause'), true)
	unpause()

	answers = {}
	offer('o4', '10', 'Play here', 'first')
	H.check('an offer', H.wait_until(drawn, 5))
	local rx, ry = middle('here')
	mp.commandv('mouse', tostring(math.floor(rx)), tostring(math.floor(ry)))
	H.sleep(0.2)
	offer('o5', '10', 'Play here', 'second')
	H.expect('a new offer replaces it, and the replaced one is answered none', heard, 'o4 none')
	-- a click on its way for the old one, landing a moment after
	mp.commandv('keydown', 'MBTN_LEFT')
	mp.commandv('keyup', 'MBTN_LEFT')
	H.sleep(0.3)
	H.eq('... a click right after it takes nothing: it was meant for the one replaced', heard(), 'o4 none')
	H.eq('... nor pauses', mp.get_property_native('pause'), false)
	H.expect('... its banners show the new one', function()
		return (banner('here') or {}).detail
	end, 'second')
	H.eq('... which is up', state().id, 'o5')
	offer('o5', '10', 'Play here', 'second, again')
	H.expect('the same offer again changes its texts', function()
		return (banner('here') or {}).detail
	end, 'second, again')
	H.sleep(0.3)
	H.eq('... and answers nothing', heard(), 'o4 none')

	cancel('o4')
	H.sleep(0.5)
	H.check('a cancel for another offer leaves this one up', state().id == 'o5' and drawn())
	cancel('o5')
	H.check('a cancel for this offer hides both banners', H.wait_until(gone, 3))
	H.eq('... ends the offer', state().shown, false)
	offer('o6', '2')
	H.check('a new offer', H.wait_until(drawn, 5))
	cancel()
	H.check('a cancel without an id hides it too', H.wait_until(gone, 3))
	H.eq('... ends the offer', state().shown, false)
	H.sleep(2.5)
	H.eq('... and no cancelled offer is answered, not even once its time is up', heard(), 'o4 none')

	-- whole seconds 1..60, else 15
	for i, case in ipairs({ { '60', 60 }, { '0', 15 }, { '61', 15 }, { '2.5', 15 }, { '-5', 15 }, { 'soon', 15 } }) do
		local id = 's' .. i
		offer(id, case[1])
		H.expect(string.format('an offer for "%s" seconds stays %d s', case[1], case[2]), function()
			local s = state()
			return s.id == id and s.seconds
		end, case[2])
	end
	cancel()
	H.check('... and a cancel ends it', H.wait_until(gone, 3))

	-- the extension's texts are plain text: ASS tags and ${...} come out as they are
	local tagged = '{\\b1}Play here'
	offer('t1', '10', tagged, 'x', 'Play here', 'x')
	H.check('a title with an ASS tag', H.wait_until(drawn, 5))
	local b = shown()
	H.eq('... reaches its banner as given', b.here.title, tagged)
	local wider = b.here.box.w - b.window.box.w
	H.info('{\\b1} widens its banner by ' .. wider .. ' px')
	H.check('... and is drawn as text, not read as a bold tag', wider >= 15, 'wider by ' .. wider .. ' px')
	cancel()
	H.check('... and goes with a cancel', H.wait_until(gone, 3))
	offer('t2', '10', 'T', '${path} plays on', 'T', '$ plays on')
	H.check('a detail with ${path}', H.wait_until(drawn, 5))
	b = shown()
	H.eq('... reaches its banner as given, not expanded', b.here.detail, '${path} plays on')
	wider = b.here.box.w - b.window.box.w
	H.info('{path} widens its banner by ' .. wider .. ' px')
	H.check('... and is drawn as text', wider >= 15, 'wider by ' .. wider .. ' px')
	cancel()
	H.check('... and goes with a cancel', H.wait_until(gone, 3))

	-- Both scripts' banners at once: single-instance.lua offers a local file beneath FastStream's. A double click takes
	-- FastStream's "Play here"; its banners go and single-instance's move up under the pointer, where the second press
	-- lands. It takes nothing: banner-click.lua's guard after a click holds for every script's banners.
	answers = {}
	offer('c1', '10')
	H.check('an offer', H.wait_until(drawn, 5))
	mp.commandv(
		'script-message-to',
		'single_instance',
		'open',
		'replace',
		H.root .. '/no-such-launcher.exe',
		H.media_path('plain/clip.mkv')
	)
	local function local_here()
		for _, card in ipairs(cards()) do
			if card.id == 'single-instance' then
				return card.box
			end
		end
	end
	H.check(
		'... and a local file offered beneath it',
		H.wait_until(function()
			return local_here() ~= nil and drawn()
		end, 5)
	)
	local top = banner('here').box
	-- near the right edge, where the banners line up whatever their widths
	local px, py = math.floor(top.x + top.w - 20), math.floor(top.y + top.h / 2)
	local function local_here_under_pointer()
		local box = local_here()
		return box ~= nil and px >= box.x and px <= box.x + box.w and py >= box.y and py <= box.y + box.h
	end
	H.check('... not under the pointer yet', not local_here_under_pointer())
	mp.commandv('mouse', tostring(px), tostring(py))
	H.sleep(0.2)
	mp.commandv('keydown', 'MBTN_LEFT')
	mp.commandv('keyup', 'MBTN_LEFT')
	local first = mp.get_time()
	local moved = H.wait_until(local_here_under_pointer, 0.3, 0.01)
	-- late in the half second, so single-instance.lua has surely raised its section over the moved banner
	H.sleep(math.max(0.07, 0.38 - (mp.get_time() - first)))
	mp.commandv('keydown', 'MBTN_LEFT')
	mp.commandv('keyup', 'MBTN_LEFT')
	local second = mp.get_time() - first
	H.expect('the first press of a double click answers here', heard, 'c1 here')
	H.check(
		"... the local file's banner moved under the pointer before the second press",
		moved and second < 0.5,
		string.format('second press %.2f s after the first', second)
	)
	H.sleep(0.6)
	H.check(
		'... which took nothing: the local file is still only offered',
		((mp.get_property_native('user-data/single-instance') or {}).offer or {}).files ~= nil
	)
	mp.commandv('script-message-to', 'single_instance', 'choose', 'window')

	H.eq('through it all nothing was loaded', starts - starts_then, 0)
	H.eq('... the playlist as it was', mp.get_property_number('playlist-count'), 1)
	plays_on('... and what plays plays on')

	-- what plays comes to its end while the banners ask: nothing to lose any more, so the answer is here
	answers = {}
	mp.commandv('seek', tostring(mp.get_property_number('duration') - 1.5), 'absolute', 'exact')
	H.sleep(0.2)
	offer('e1', '10')
	H.check('an offer near the end of what plays', H.wait_until(drawn, 5))
	H.expect('... once that ends, it answers here by itself', heard, 'e1 here', nil, 6)
	H.check('... and its banners go', H.wait_until(gone, 3))
	H.eq('... and the offer', state().shown, false)
end)
