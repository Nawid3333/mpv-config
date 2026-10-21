-- faststream-episodes.lua: the previous / next episode buttons and the autoplay
-- switch in uosc's bar (2026-10-11). The FastStream helper's side is played by
-- this test: it sets user-data/faststream/connected and .../autoplay as the
-- helper does over JSON IPC, and hears the script messages the buttons and
-- Ctrl+a send (a script message goes to every client, this script too). The
-- runner's clip FILE NAME carries the #fs-content=...&fs-id=... fragment, as in
-- the stream-resume and upscale tests. What uosc draws is not readable here; the
-- script publishes what it pushed (user-data/faststream-episodes/buttons) and
-- the flag uosc.conf's disposition reads (.../shown).
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')

local FS_MOVIE = 'fs-movie/film#fs-content=movie&fs-id=0f0f0f0f0f0f0f0f.mkv'

local function buttons()
	return mp.get_property_native('user-data/faststream-episodes/buttons') or {}
end

local function shown()
	return mp.get_property_native('user-data/faststream-episodes/shown')
end

-- 'shown' when all three buttons are pushed visible, 'hidden' when all three are
-- hidden, else what each one says
local function visibility()
	local b = buttons()
	local hides = {}
	for _, name in ipairs({ 'episode_prev', 'episode_next', 'autoplay' }) do
		local data = b[name]
		hides[#hides + 1] = data and tostring(data.hide) or 'missing'
	end
	local all = table.concat(hides, ',')
	if all == 'false,false,false' and shown() == true then
		return 'shown'
	elseif all == 'true,true,true' and shown() == false then
		return 'hidden'
	end
	return all .. ' shown=' .. tostring(shown())
end

local function autoplay_button()
	local data = buttons().autoplay or {}
	return tostring(data.active) .. ' / ' .. tostring(data.tooltip)
end

-- notify.lua's 'faststream' banner: title / detail / icon, or 'none'
local function fs_card()
	for _, c in ipairs((mp.get_property_native('user-data/notify') or {}).cards or {}) do
		if c.id == 'faststream' then
			return c.title .. ' / ' .. c.detail .. ' / ' .. tostring(c.icon)
		end
	end
	return 'none'
end

H.run(function()
	-- Ctrl+a is free: mpv's built-in bindings (listed even where input.conf
	-- overrides them) and every script's have none; only input.conf's.
	local ctrl_a = {}
	for _, b in ipairs(mp.get_property_native('input-bindings') or {}) do
		if b.key:lower() == 'ctrl+a' then
			ctrl_a[#ctrl_a + 1] = string.format('%s [%s%s] %s', b.key, b.section, b.is_weak and ', weak' or '', b.cmd)
		end
	end
	H.check(
		'Ctrl+a: input.conf binds it to script-message faststream-autoplay, nothing else uses it',
		#ctrl_a == 1 and ctrl_a[1] == 'Ctrl+a [default] script-message faststream-autoplay',
		table.concat(ctrl_a, ' | ')
	)

	-- a local file, FastStream not following: nothing
	H.expect('a local file, nothing connected: the buttons are hidden', visibility, 'hidden')
	H.expect('autoplay not set yet reads off', autoplay_button, 'false / Autoplay next episode: off')

	-- the keys with no helper following, on a local file: its folder's next / previous file
	-- (the playlist), and when there is none they say so, with the autoplay switch's icon
	-- as FastStream's own notices; autoplay is FastStream's alone
	local why = ' / only for videos FastStream sends to mpv / playlist_play'
	local last = 'Next episode / this is the last file of its folder / playlist_play'
	H.key('n')
	H.expect('n, a local file, the last of its folder: says so', fs_card, last)
	mp.commandv('script-message-to', 'notify', 'hide', 'faststream')
	H.key('N')
	H.expect('Shift+N: the same', fs_card, last)
	H.key('P')
	H.expect(
		'Shift+P, the first of its folder: says so',
		fs_card,
		'Previous episode / this is the first file of its folder / playlist_play'
	)
	H.key('Ctrl+a')
	H.expect('Ctrl+a: only for FastStream', fs_card, 'Autoplay' .. why)
	mp.commandv('script-message-to', 'notify', 'hide', 'faststream')
	H.expect('(banner taken down)', fs_card, 'none')
	-- with a next file (a series folder: autoload.lua queues it), the keys play it
	local position = function()
		return mp.get_property_number('playlist-pos')
	end
	mp.commandv('loadfile', H.media_path('second/clip2.mkv'), 'append')
	H.key('N')
	H.expect('Shift+N, a local file with a next one: plays it', position, 1)
	H.key('PREV')
	H.expect('the media key Previous: back to the first', position, 0)
	H.key('NEXT')
	H.expect('the media key Next: the next one again', position, 1)
	H.check('the first file again', H.load(H.media_path('plain/clip.mkv')))
	-- Space and a click on the video also send faststream-pause (the countdown's stop key,
	-- 2026-10-17); with no helper they only pause, no banner about FastStream
	local pause_keys = {}
	for _, b in ipairs(mp.get_property_native('input-bindings') or {}) do
		if (b.key == 'SPACE' or b.key == 'MBTN_LEFT') and b.section == 'default' and not b.is_weak then
			pause_keys[#pause_keys + 1] = b.key .. ': ' .. b.cmd
		end
	end
	table.sort(pause_keys)
	H.eq(
		'Space and a click on the video: pause, and faststream-pause',
		table.concat(pause_keys, ' | '),
		'MBTN_LEFT: cycle pause; script-message faststream-pause | SPACE: cycle pause; script-message faststream-pause'
	)
	local paused = mp.get_property_native('pause')
	H.key('SPACE')
	H.expect('Space, no FastStream following: pauses as ever', function()
		return mp.get_property_native('pause')
	end, not paused)
	H.sleep(0.3)
	H.eq('... and says nothing about FastStream', fs_card(), 'none')
	H.key('SPACE')
	H.expect('(Space again: back)', function()
		return mp.get_property_native('pause')
	end, paused)

	-- following this window, but the file is no FastStream stream
	mp.set_property_native('user-data/faststream/connected', true)
	H.sleep(0.3)
	H.eq('connected, a local file: still hidden', visibility(), 'hidden')

	-- a FastStream stream in a window FastStream follows: all three
	H.check('the FastStream clip loads', H.load(H.media_path(FS_MOVIE)))
	H.expect('connected, a FastStream stream: the three buttons show', visibility, 'shown')
	local b = buttons()
	H.eq('previous: icon', (b.episode_prev or {}).icon, 'skip_previous')
	H.eq('previous: tooltip', (b.episode_prev or {}).tooltip, 'Previous episode')
	H.eq('next: icon', (b.episode_next or {}).icon, 'skip_next')
	H.eq('next: tooltip', (b.episode_next or {}).tooltip, 'Next episode')
	H.eq('autoplay: icon', (b.autoplay or {}).icon, 'playlist_play')

	-- the switch follows FastStream's setting
	mp.set_property_native('user-data/faststream/autoplay', true)
	H.expect('autoplay on: the switch is active', autoplay_button, 'true / Autoplay next episode: on')
	mp.set_property_native('user-data/faststream/autoplay', false)
	H.expect('autoplay off: the switch is not', autoplay_button, 'false / Autoplay next episode: off')

	-- a click: uosc runs the button's command (execute_command: command_native on a
	-- table), and each one reaches the helper as its message
	local heard = {}
	for _, name in ipairs({ 'faststream-previous', 'faststream-next', 'faststream-autoplay', 'faststream-pause' }) do
		mp.register_script_message(name, function()
			heard[#heard + 1] = name:sub(12)
		end)
	end
	b = buttons()
	for _, name in ipairs({ 'episode_prev', 'episode_next', 'autoplay' }) do
		mp.command_native((b[name] or {}).command or { 'ignore' })
	end
	H.expect('the buttons send faststream-previous, -next and -autoplay', function()
		return table.concat(heard, ' ')
	end, 'previous next autoplay')

	-- the key
	heard = {}
	H.key('Ctrl+a')
	H.expect('Ctrl+a sends faststream-autoplay', function()
		return table.concat(heard, ' ')
	end, 'autoplay')
	H.sleep(0.3)
	H.eq('... and leaves the saying to FastStream, which follows', fs_card(), 'none')
	heard = {}
	paused = mp.get_property_native('pause')
	H.key('SPACE')
	H.expect('Space sends faststream-pause (the helper stops a countdown with it)', function()
		return table.concat(heard, ' ')
	end, 'pause')
	H.eq('... and pauses', mp.get_property_native('pause'), not paused)
	H.key('SPACE')
	H.expect('(Space again: back)', function()
		return mp.get_property_native('pause')
	end, paused)
	heard = {}

	-- FastStream stops following: gone; the property removed counts as false too
	mp.set_property_native('user-data/faststream/connected', false)
	H.expect('connected=false: hidden', visibility, 'hidden')
	mp.set_property_native('user-data/faststream/connected', true)
	H.expect('connected again: shown', visibility, 'shown')
	-- mpv tells no observer about a deleted user-data key: the script looks again
	-- once a second while it last heard true (3 s here)
	mp.del_property('user-data/faststream/connected')
	H.expect('connected deleted: hidden', visibility, 'hidden', nil, 3)
	mp.set_property_native('user-data/faststream/connected', true)
	H.expect('... and set true again after the delete: shown', visibility, 'shown', nil, 3)
	mp.set_property_native('user-data/faststream/connected', false)
	H.expect('connected=false once more: hidden', visibility, 'hidden')
	mp.set_property_native('user-data/faststream/connected', 'yes')
	H.expect('connected set as text ("yes"): shown', visibility, 'shown')

	-- host 10: a helper killed hard clears nothing, but its heartbeat stops (stale
	-- after 2 s here: the runner passes faststream_episodes-heartbeat_stale=2)
	mp.set_property_native('user-data/faststream/heartbeat', 1000)
	H.eq('a heartbeat: shown', visibility(), 'shown')
	H.sleep(1)
	H.eq('... still shown within its limit', visibility(), 'shown')
	H.expect('the heartbeat stood still past its limit: hidden', visibility, 'hidden', nil, 4)
	H.key('n')
	H.expect('n to a helper that stopped beating: says why', fs_card, 'Next episode' .. why)
	mp.commandv('script-message-to', 'notify', 'hide', 'faststream')
	mp.set_property_native('user-data/faststream/heartbeat', 2000)
	H.expect('a helper started anew beats (connected still true): shown', visibility, 'shown', nil, 2)
	-- a live helper for the rest of the test
	local beats = 0
	mp.add_periodic_timer(0.5, function()
		beats = beats + 1
		mp.set_property_native('user-data/faststream/heartbeat', 3000 + beats)
	end)

	-- other files while connected
	H.check('a local file loads', H.load(H.media_path('plain/clip.mkv')))
	H.expect('connected, a local file after the stream: hidden', visibility, 'hidden')
	H.check('the FastStream clip loads again', H.load(H.media_path(FS_MOVIE)))
	H.expect('... and the stream again: shown', visibility, 'shown')
	H.check(
		'a file with fs-content= only in its query loads',
		H.load(H.media_path('fs-forged-query/ep&x=fs-content=anime.mkv'))
	)
	H.expect('fs-content= in a query is no FastStream stream: hidden', visibility, 'hidden')
	H.check('the FastStream clip loads a third time', H.load(H.media_path(FS_MOVIE)))
	H.expect('... shown', visibility, 'shown')
	-- nothing loaded any more (mpv.conf idle=yes keeps the player open)
	mp.commandv('stop')
	H.expect('stopped, nothing loaded: hidden', visibility, 'hidden')
end)
