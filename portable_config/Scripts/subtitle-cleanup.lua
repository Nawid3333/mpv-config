-- subtitle-cleanup.lua - subtitles downloaded for a stream go after a week
--
-- uosc's "Download subtitles" saves a stream's subtitles in ~~/subtitles (uosc.conf's
-- subtitles_directory; a local file's go next to it and stay), and nothing deleted them.
-- mpv does not load them again by itself either: for a URL it looks only in ~~/sub
-- (--sub-file-paths in the manual). So each start deletes the subtitle files there older
-- than `days` (the owner: kept a week, then gone). Only files with an extension mpv
-- takes for subtitles (sub-auto-exts, any case); other files and folders stay. A file
-- that cannot be deleted (another mpv still reading it) stays for the next start.
--
-- State for tests: user-data/subtitle-cleanup = {sweeps, deleted, kept, failed}.

local mp = require('mp')
local msg = require('mp.msg')
local utils = require('mp.utils')
local options = require('mp.options')

local opts = {
	days = 7, -- a subtitle downloaded longer ago than this goes
}
options.read_options(opts, 'subtitle_cleanup')

-- uosc.conf's subtitles_directory (a static check keeps the two the same)
local DIR = '~~/subtitles'

local sweeps = 0

local function subtitle_extensions()
	local set = {}
	for _, ext in ipairs(mp.get_property_native('sub-auto-exts') or {}) do
		set[ext:lower()] = true
	end
	return set
end

local function sweep()
	local dir = mp.command_native({ 'expand-path', DIR })
	-- nil: no such folder (nothing was ever downloaded for a stream)
	local names = dir and utils.readdir(dir, 'files') or {}
	local extensions = subtitle_extensions()
	local cutoff = os.time() - opts.days * 86400
	local deleted, kept, failed = 0, 0, 0
	for _, name in ipairs(names) do
		local path = utils.join_path(dir, name)
		local ext = name:match('%.([^.]+)$')
		local info = utils.file_info(path)
		if ext and extensions[ext:lower()] and info and info.is_file and info.mtime < cutoff then
			local ok, err = os.remove(path)
			if ok then
				deleted = deleted + 1
			else
				failed = failed + 1
				msg.verbose('could not delete ' .. name .. ': ' .. tostring(err))
			end
		else
			kept = kept + 1
		end
	end
	sweeps = sweeps + 1
	mp.set_property_native('user-data/subtitle-cleanup', {
		sweeps = sweeps,
		deleted = deleted,
		kept = kept,
		failed = failed,
	})
end

sweep()
