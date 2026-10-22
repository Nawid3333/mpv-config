-- subtitle-sync.lua: an audio read that failed (a stream's hiccup) is read again the next
-- time the panel opens. Kept as failed, its 30 s stayed empty for as long as the file
-- played. A stand-in for the analysing mpv fails its first run and hands every later one
-- to the real mpv.
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')

local function state()
	return mp.get_property_native('user-data/subtitle-sync') or {}
end

H.run(function()
	local tmp = os.getenv('TEMP') or os.getenv('TMP') or '.'
	local flag = tmp .. '\\subsync-analyser-failed-once'
	local cmd_path = tmp .. '\\subsync-analyser.cmd'
	os.remove(flag)
	local mpv = mp.command_native({ 'expand-path', '~~exe_dir/mpv.exe' })
	local cmd = assert(io.open(cmd_path, 'w'))
	cmd:write('@echo off\r\n')
	cmd:write('if not exist "' .. flag .. '" (\r\n  type nul > "' .. flag .. '"\r\n  exit /b 1\r\n)\r\n')
	cmd:write('"' .. mpv .. '" %*\r\n')
	cmd:close()
	mp.commandv('change-list', 'script-opts', 'append', 'subtitle_sync-analyser=' .. cmd_path)

	mp.set_property('sid', '1')
	mp.commandv('seek', '5', 'absolute+exact')
	H.sleep(0.3)
	H.key('t')
	H.expect('t opens the panel', function()
		return state().open
	end, true)
	H.expect('the first read fails (the stand-in)', function()
		local f = io.open(flag, 'r')
		if f then
			f:close()
		end
		return f ~= nil
	end, true, nil, 10)
	H.sleep(2)
	H.eq('... and nothing is read while the panel stays open', state().bins or 0, 0)
	H.key('t')
	H.expect('t closes the panel', function()
		return state().open
	end, false)
	H.key('t')
	H.expect('opened again, the failed part is read again', function()
		return (state().bins or 0) >= 900
	end, true, nil, 15)
	H.eq('... and the audio row finds the 5 beeps', #(state().onsets or {}), 5)
	H.key('t')
	os.remove(flag)
	os.remove(cmd_path)
end)
