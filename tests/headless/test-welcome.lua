-- Scripts/welcome.lua (2026-10-09): the first start says hello once, as a
-- banner (never a blocking screen); F1 opens the feature tour. Two processes
-- (tests/run-tests.ps1, "welcome", with welcome-auto=yes): "first" sees the
-- banner and welcome.json gets written, "again" (same state) sees none, "idle"
-- (no file, welcome.json removed) sees the banner and the tour.
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')

local PHASE = os.getenv('MPV_TEST_PHASE') or 'first'

local function welcome_card()
	for _, card in ipairs((mp.get_property_native('user-data/notify') or {}).cards or {}) do
		if card.id == 'welcome' then
			return card
		end
	end
	return nil
end

local function remembered()
	local f = io.open(mp.command_native({ 'expand-path', '~~state/welcome.json' }), 'r')
	if f then
		f:close()
	end
	return f ~= nil
end

-- the "idle" phase starts with no file: no first file-loaded to wait for
H.run(function()
	if PHASE == 'first' then
		H.check('the first start shows the welcome banner', H.wait_until(welcome_card, 5))
		local card = welcome_card() or {}
		H.eq('... titled "Welcome to mpv"', card.title, 'Welcome to mpv')
		H.check('... and it names F1', tostring(card.detail):find('F1', 1, true) ~= nil, tostring(card.detail))
		H.check('... and remembers it was shown', H.wait_until(remembered, 2))
		-- opened with a file, the tour waits for F1 (a menu would cover the video)
		H.eq('a start with a video: no tour menu over it', mp.get_property_native('user-data/uosc/menu/type'), nil)
	elseif PHASE == 'again' then
		H.sleep(3)
		H.check('a later start shows no welcome banner', welcome_card() == nil)
	else
		-- "idle": a first start with no file (the Start menu shortcut, the runner removed
		-- welcome.json): nothing to cover yet, so the tour opens as well
		H.check('a first start with no file shows the banner', H.wait_until(welcome_card, 5))
		H.expect('... and opens the tour', function()
			return mp.get_property_native('user-data/uosc/menu/type')
		end, 'welcome-tour', nil, 3)
	end
end, { wait_file = PHASE ~= 'idle' })
