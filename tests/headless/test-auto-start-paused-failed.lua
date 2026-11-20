-- auto-start.lua with start_paused, when the first file never loads (it fails;
-- no file-loaded): the wait ends with it, and the file opened next plays.
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')

H.run(function()
	H.check(
		'the first file did not load',
		H.wait_until(function()
			return mp.get_property_native('idle-active') == true
		end, 10)
	)
	H.load(H.media_path('plain/clip.mkv'))
	H.expect('the next file plays', function()
		return mp.get_property_native('pause')
	end, false)
end, { wait_file = false })
