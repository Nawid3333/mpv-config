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

	-- the keys with no helper following: they say why instead of nothing (2026-10-12),
	-- with the autoplay switch's icon, as FastStream's own notices
	local why = ' / only for videos FastStream sends to mpv / playlist_play'
	H.key('n')
	H.expect('n, no FastStream following: says why', fs_card, 'Next episode' .. why)
	H.key('N')
	H.expect('N: the same', fs_card, 'Previous episode' .. why)
	H.key('Ctrl+a')
	H.expect('Ctrl+a: the same', fs_card, 'Autoplay' .. why)
	mp.commandv('script-message-to', 'notify', 'hide', 'faststream')
	H.expect('(banner taken down)', fs_card, 'none')

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
	for _, name in ipairs({ 'faststream-previous', 'faststream-next', 'faststream-autoplay' }) do
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
