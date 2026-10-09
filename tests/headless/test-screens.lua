-- Scripts/settings.lua: the screens (2026-10-09, the user: "when I switch my
-- monitor - 4K, another refresh rate, other HDR - mpv should detect it"). Every
-- screen Windows reports is remembered with its own HDR brightness; the first
-- one keeps the value from before, a new one starts at Auto and is announced.
-- Headless has no display: `screen-seen W H Hz` stands in for what Windows
-- reports. Two processes (tests/run-tests.ps1, "screens"): "first", "again".
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')
local utils = require('mp.utils')

local PHASE = os.getenv('MPV_TEST_PHASE') or 'first'

local function peak()
	return mp.get_property('options/target-peak')
end

local function card()
	for _, c in ipairs((mp.get_property_native('user-data/notify') or {}).cards or {}) do
		if c.id == 'settings' then
			return c
		end
	end
	return nil
end

local function new_screen_banner()
	local c = card()
	return c and tostring(c.title):find('New screen', 1, true) ~= nil and c.title or nil
end

local function screen(w, h, hz)
	mp.commandv('script-message-to', 'settings', 'screen-seen', tostring(w), tostring(h), tostring(hz))
	H.sleep(0.3)
end

local function saved()
	local f = io.open(mp.command_native({ 'expand-path', '~~state/settings.json' }), 'r')
	if not f then
		return {}
	end
	local data = utils.parse_json(f:read('*a')) or {}
	f:close()
	return data
end

H.run(function()
	if PHASE == 'first' then
		H.load(H.media_path('hdr/pq.mkv'))
		mp.commandv('script-message-to', 'settings', 'set', 'hdr_peak', '350')
		H.expect('before any screen is known: HDR brightness 350 for the HDR clip', peak, '350')
		mp.commandv('script-message-to', 'notify', 'hide', 'settings')
		screen(2560, 1440, 144)
		H.eq('the first screen: no "new screen" banner', new_screen_banner(), nil)
		H.expect('... it keeps the value from before (350)', peak, '350')
		H.eq('... published', (mp.get_property_native('user-data/settings') or {}).screen, '2560x1440 @ 144 Hz')

		screen(3840, 2160, 120)
		H.check('a new screen: a banner names it', H.wait_until(new_screen_banner, 2), tostring(new_screen_banner()))
		H.eq('... "New screen: 3840x2160 @ 120 Hz"', new_screen_banner(), 'New screen: 3840x2160 @ 120 Hz')
		H.expect('... its HDR brightness starts at Auto', peak, 'auto')
		mp.commandv('script-message-to', 'settings', 'set', 'hdr_peak', '600')
		H.expect('HDR brightness 600 set for the new screen', peak, '600')

		mp.commandv('script-message-to', 'notify', 'hide', 'settings')
		screen(2560, 1440, 144)
		H.expect('back on the first screen: its own 350 again', peak, '350')
		H.eq('... no banner for a screen seen before', new_screen_banner(), nil)
		local s = saved().screens or {}
		H.check(
			'both screens are in settings.json with their own values',
			(s['2560x1440@144'] or {}).hdr_peak == 350 and (s['3840x2160@120'] or {}).hdr_peak == 600,
			utils.format_json(s)
		)
		-- the size before the refresh rate (review, 2026-10-09): the known screen of
		-- that size, no new one
		screen(3840, 2160, 0)
		H.eq('a size without a refresh rate is the known screen of that size', new_screen_banner(), nil)
		H.eq(
			'... (3840x2160 @ 120 Hz)',
			(mp.get_property_native('user-data/settings') or {}).screen,
			'3840x2160 @ 120 Hz'
		)
		H.expect('... with its 600 nits', peak, '600')
		screen(2560, 1440, 144)
		screen(0, 0, 0)
		H.eq(
			'a screen of 0x0 is ignored',
			(mp.get_property_native('user-data/settings') or {}).screen,
			'2560x1440 @ 144 Hz'
		)
	else
		H.load(H.media_path('hdr/pq.mkv'))
		screen(3840, 2160, 120)
		H.eq('a new process: the 4K screen is known, no banner', new_screen_banner(), nil)
		H.expect('... with its 600 nits', peak, '600')
	end
end)
