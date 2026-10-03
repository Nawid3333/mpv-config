-- auto-start.lua: a newly loaded file always starts playing, even when the
-- previous file was paused (pause is a global option and carries over through
-- `loadfile replace`, which is how FastStream and mpv-single hand the next
-- episode to a running player). A pause during playback is respected.
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')

H.run(function()
	H.eq('first file plays', mp.get_property_native('pause'), false)

	mp.set_property_native('pause', true)
	H.load(H.media_path('second/clip2.mkv'))
	H.eq('paused file 1 -> loadfile replace -> file 2 plays', mp.get_property_native('pause'), false)

	mp.set_property_native('pause', true)
	H.sleep(1)
	H.eq('a pause during playback is respected', mp.get_property_native('pause'), true)

	-- keep-open=yes pauses at the end of a file; the next file must still play.
	mp.set_property_native('pause', false)
	local duration = mp.get_property_number('duration')
	mp.commandv('seek', tostring(duration - 0.5), 'absolute', 'exact')
	H.check(
		'file plays out to its end',
		H.wait_until(function()
			return mp.get_property_native('eof-reached') == true
		end, 10)
	)
	H.eq('keep-open paused at EOF', mp.get_property_native('pause'), true)
	H.load(H.media_path('plain/clip.mkv'))
	H.eq('after EOF -> loadfile replace -> next file plays', mp.get_property_native('pause'), false)

	-- A delay belongs to its file: kept while it plays, 0 again for the next one.
	mp.set_property_number('sub-delay', 1.5)
	mp.set_property_number('audio-delay', 0.3)
	H.sleep(0.5)
	H.eq('a delay stays while its file plays', mp.get_property_number('sub-delay'), 1.5, 0.001)
	H.load(H.media_path('second/clip2.mkv'))
	H.eq('the next file starts without the subtitle delay', mp.get_property_number('sub-delay'), 0, 0.001)
	H.eq('and without the audio delay', mp.get_property_number('audio-delay'), 0, 0.001)
end)
