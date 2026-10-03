-- title-bar.lua - the native Windows title bar and window border in OLED black.
--
-- 2026-09-26, at the user's request ("make it OLED black"). mpv.conf's
-- border=yes gives mpv the native title bar (for Windows 11 snapping, see
-- there), and mpv colours it by the Windows dark/light setting: dark grey in
-- dark mode. mpv has no option for that colour on Windows (--macos-title-bar-
-- color is macOS only), but Windows 11 (build 22000+) takes a caption, border
-- and caption-text colour per window through DwmSetWindowAttribute. mpv's Lua
-- is LuaJIT, so its FFI calls that in-process: no helper process, and the bar
-- is black from the moment the window exists. On Windows 10 the call fails
-- (E_INVALIDARG) and the bar keeps mpv's own colours - logged, nothing else.
--
-- Dark mode is set too, so the minimize/maximize/close glyphs are light on the
-- black bar even with Windows in light mode (mpv sets it from the Windows
-- setting at start; switching the Windows theme while mpv runs makes mpv
-- re-apply the theme's value, which this does not follow).
--
-- State for tests and curious users: user-data/title-bar = { applied, hresult }.

local mp = require('mp')
local msg = require('mp.msg')

local ok, ffi = pcall(require, 'ffi')
if not ok or ffi.os ~= 'Windows' then
	return
end

ffi.cdef([[
long __stdcall DwmSetWindowAttribute(void *hwnd, unsigned long attribute, const void *value, unsigned long size);
]])
local loaded, dwmapi = pcall(ffi.load, 'dwmapi')
if not loaded then
	msg.warn('dwmapi.dll not available: ' .. tostring(dwmapi))
	return
end

local DWMWA_USE_IMMERSIVE_DARK_MODE = 20
local DWMWA_BORDER_COLOR = 34
local DWMWA_CAPTION_COLOR = 35
local DWMWA_TEXT_COLOR = 36

-- COLORREF = 0x00BBGGRR
local CAPTION = 0x000000 -- OLED black
local BORDER = 0x000000 -- the 1 px window outline Windows 11 draws
local TEXT = 0xFFFFFF -- the title, white like uosc's text

local value = ffi.new('unsigned long[1]')

---@param hwnd ffi.cdata*
---@param attribute integer
---@param v integer
---@return integer hresult
local function set(hwnd, attribute, v)
	value[0] = v
	return tonumber(dwmapi.DwmSetWindowAttribute(hwnd, attribute, value, 4)) --[[@as integer]]
end

local function apply()
	local id = mp.get_property_number('window-id')
	if not id then
		return -- no window (yet), or --vo=null
	end
	local hwnd = ffi.cast('void *', id)
	set(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, 1)
	local hr = set(hwnd, DWMWA_CAPTION_COLOR, CAPTION)
	if hr == 0 then
		set(hwnd, DWMWA_BORDER_COLOR, BORDER)
		set(hwnd, DWMWA_TEXT_COLOR, TEXT)
	else
		msg.verbose(string.format('title bar colour not supported here (HRESULT 0x%08X)', hr % 0x100000000))
	end
	mp.set_property_native('user-data/title-bar', { applied = hr == 0, hresult = hr })
end

-- The window appears with window-id; the others can bring the frame back after
-- fullscreen, so the colour is set again (a few µs, nothing is redrawn by mpv).
for _, name in ipairs({ 'window-id', 'fullscreen', 'border', 'title-bar', 'window-maximized' }) do
	mp.observe_property(name, 'native', apply)
end
