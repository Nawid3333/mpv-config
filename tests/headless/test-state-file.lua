-- script-modules/state-file.lua (#96): how the scripts replace their state files.
-- write() replaces a file whole (MoveFileExW on Windows, which os.rename cannot do)
-- and leaves no temp file; a write that cannot happen leaves the old file as it was;
-- read_json() keeps a damaged file beside it and reads nothing from it.
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')
local utils = require('mp.utils')

local statefile = dofile(mp.command_native({ 'expand-path', '~~/script-modules/state-file.lua' }))

local function read(path)
	local f = io.open(path, 'rb')
	if not f then
		return nil
	end
	local text = f:read('*a')
	f:close()
	return text
end

local function leftovers(dir, prefix)
	local found = {}
	for _, name in ipairs(utils.readdir(dir, 'all') or {}) do
		if name:sub(1, #prefix) == prefix and name ~= prefix then
			found[#found + 1] = name
		end
	end
	return found
end

H.run(function()
	local dir = mp.command_native({ 'expand-path', '~~state/' })
	local name = 'state-file-test.json'
	local path = utils.join_path(dir, name)
	os.remove(path)

	H.check('a new file is written', (statefile.write(path, '{"a":1}')))
	H.eq('... with the text', read(path), '{"a":1}')
	H.check('an existing file is replaced', (statefile.write(path, '{"a":2}')))
	H.eq('... with the new text', read(path), '{"a":2}')
	H.eq('... and no temp file is left', #leftovers(dir, name), 0)

	-- the temp file cannot be written (a folder holds its name): the old file stays
	local tmp = path .. '.' .. utils.getpid() .. '.tmp'
	H.check("a folder takes the temp file's name", mp.command_native({
		name = 'subprocess',
		args = { 'cmd', '/d', '/c', 'mkdir', (tmp:gsub('/', '\\')) },
		playback_only = false,
	}).status == 0)
	local ok, err = statefile.write(path, '{"a":3}')
	H.eq('a write that cannot happen says so', ok, false)
	H.info(tostring(err))
	H.eq('... and leaves the old file as it was', read(path), '{"a":2}')
	mp.command_native({
		name = 'subprocess',
		args = { 'cmd', '/d', '/c', 'rmdir', (tmp:gsub('/', '\\')) },
		playback_only = false,
	})

	-- a damaged file: kept beside, nothing read from it
	local f = assert(io.open(path, 'wb'))
	f:write('{"a":')
	f:close()
	local data, stuck = statefile.read_json(path, name)
	H.eq('a damaged file reads as nothing', data, nil)
	H.eq('... it was moved', stuck, nil)
	H.eq('... out of the way', read(path), nil)
	local aside = leftovers(dir, name .. '.corrupt-')
	H.eq('... kept beside it', #aside, 1)
	for _, kept in ipairs(aside) do
		os.remove(utils.join_path(dir, kept))
	end
	H.eq('a missing file reads as nothing', (statefile.read_json(path, name)), nil)
end)
