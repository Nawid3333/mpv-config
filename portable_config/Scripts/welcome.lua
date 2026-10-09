-- welcome.lua - the first start, and F1 (2026-10-09, for the one-click install:
-- a new user should see every setting and every feature, and decide the
-- settings in the onboarding).
--
-- The Welcome menu itself is built by Scripts/settings.lua (`open-welcome`):
-- the settings on top, recommended values marked, then every feature with its
-- key. Nothing blocks and nothing is forced over a video (the user removed a
-- full-screen warm-up screen for that, 2026-09-26):
--   * the first start shows one banner for 10 s - "Welcome to mpv", F1 to set
--     up and see what it can do; opened with no file (the Start menu shortcut)
--     the Welcome menu opens as well, there is nothing to cover yet;
--   * F1 (and right-click menu > Help) opens it any time.
-- ~~state/welcome.json remembers that the welcome was shown (once per PC).
local mp = require('mp')
local msg = require('mp.msg')
local options = require('mp.options')
local utils = require('mp.utils')

local opts = {
	auto = true, -- the welcome at the first start (the tests switch it off)
	delay = 1.5, -- seconds after the start, so the window and uosc are there
}
options.read_options(opts, 'welcome')

local FILE = utils.join_path(mp.command_native({ 'expand-path', '~~state/' }), 'welcome.json')

local function open_welcome()
	mp.commandv('script-message-to', 'settings', 'open-welcome')
end

mp.add_key_binding(nil, 'tour', open_welcome)
mp.register_script_message('tour', open_welcome)

local function seen()
	return utils.file_info(FILE) ~= nil
end

local function remember()
	local f = io.open(FILE, 'w')
	if f then
		f:write(utils.format_json({ shown = os.date('%Y-%m-%d') }) or '{}')
		f:close()
	else
		msg.warn('cannot write ' .. FILE)
	end
end

if opts.auto and not seen() then
	mp.add_timeout(opts.delay, function()
		mp.commandv(
			'script-message-to',
			'notify',
			'show',
			'welcome',
			'Welcome to mpv',
			'F1: set it up and see what it can do · right-click: menu',
			'10'
		)
		if mp.get_property_native('idle-active') then
			open_welcome()
		end
		remember()
		mp.set_property_native('user-data/welcome', { shown = true })
	end)
end
