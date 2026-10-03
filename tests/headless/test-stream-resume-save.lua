-- stream-resume.lua, process 1 of 2: watch a FastStream episode (its fs-id is
-- in the path, like the #fs-id= fragment the native host appends) to 0:40,
-- then quit. test-stream-resume-restore.lua checks a fresh process resumes it.
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')

H.run(function()
	H.check('episode starts at the beginning (no saved entry yet)', mp.get_property_number('time-pos', 99) < 2)
	local done = H.expect_event('playback-restart')
	mp.commandv('seek', '40', 'absolute', 'exact')
	done(5)
	H.sleep(0.5)
	H.eq('watched to 0:40', mp.get_property_number('time-pos'), 40, 1)
	-- quitting runs the on_unload hook, which saves the position
end)
