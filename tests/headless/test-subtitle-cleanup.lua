-- Scripts/subtitle-cleanup.lua: at each start, the subtitles uosc downloaded for a stream
-- into ~~/subtitles that are older than a week are deleted. Two processes
-- (tests/run-tests.ps1, "subtitle-cleanup"):
--   none  - no such folder: the start sweeps it quietly. The runner then makes the folder
--           with old.srt and "Old Film.ASS" 8 days old, new.srt of now, old.jpg 8 days old
--           and a folder.
--   start - the next start deletes the two old subtitles and keeps the rest; the runner
--           removes the folder after it.
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')
local utils = require('mp.utils')

local PHASE = os.getenv('MPV_TEST_PHASE') or 'none'

local function state()
	return mp.get_property_native('user-data/subtitle-cleanup') or {}
end

local function exists(name)
	local dir = mp.command_native({ 'expand-path', '~~/subtitles' })
	return utils.file_info(utils.join_path(dir, name)) ~= nil
end

H.run(function()
	H.expect('the start swept the folder once', function()
		return state().sweeps
	end, 1)
	if PHASE == 'none' then
		H.eq('no folder: nothing deleted', state().deleted, 0)
		H.eq('... nothing failed', state().failed, 0)
		return
	end
	H.eq('two old subtitles deleted', state().deleted, 2)
	H.eq('... none failed', state().failed, 0)
	H.eq('an 8-day-old .srt is gone', exists('old.srt'), false)
	H.eq('an 8-day-old .ASS is gone (any case)', exists('Old Film.ASS'), false)
	H.eq('a .srt of now stays', exists('new.srt'), true)
	H.eq('an old file of another kind stays', exists('old.jpg'), true)
	H.eq('a folder stays', exists('folder'), true)
end)
