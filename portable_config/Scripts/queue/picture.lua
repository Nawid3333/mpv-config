-- queue/picture.lua - the Up next card's picture and tags for a local file: a short hidden mpv (probe.lua) opens it,
-- writes its tags as JSON and one frame as raw BGRA, scaled to the card's picture box - a third into a video, a song's
-- cover. One run at a time, the newest request first; a few results kept. Their files go when a result is dropped
-- and when mpv quits: a frame of what is watched stays nowhere (overlay-add reads the file into memory).

local mp = require('mp')
local utils = require('mp.utils')

local TIMEOUT_SECONDS = 20 -- a file that hangs the hidden mpv gets the icon
local KEEP = 3 -- results kept: the next file, and the one or two before it (back in the playlist, a moved queue)
local WINDOWS = package.config:sub(1, 1) == '\\'

---@class PictureResult
---@field state string 'loading', 'ready' (file, w, h) or 'none' (no picture: the icon)
---@field file string|nil raw BGRA, w * h * 4 bytes
---@field w integer|nil
---@field h integer|nil
---@field info table probe.lua's tags: title, artist, album, duration, audio, cover

---@param script_dir string
return function(script_dir)
	local temp = (WINDOWS and (os.getenv('TEMP') or os.getenv('TMP'))) or os.getenv('TMPDIR') or '/tmp'
	local prefix = utils.join_path(temp, 'mpv-queue-' .. (mp.get_property_number('pid') or 0) .. '-')
	local serial = 0
	local results = {} -- key -> PictureResult
	local order = {} -- keys, oldest first
	local running -- {key, id, timer, json, bgra}
	local wanted -- {key, path, w, h} the newest request, waiting for the run before it
	local on_change = function() end

	local function forget(key)
		local result = results[key]
		if result and result.file then
			os.remove(result.file)
		end
		results[key] = nil
		for i, k in ipairs(order) do
			if k == key then
				table.remove(order, i)
				break
			end
		end
	end

	local function keep(key, result)
		forget(key)
		results[key] = result
		order[#order + 1] = key
		while #order > KEEP do
			forget(order[1])
		end
	end

	local start -- (below)

	local function finish(run, ok)
		if running ~= run then
			return
		end
		running = nil
		run.timer:kill()
		local info = {}
		local file = io.open(run.json, 'r')
		if file then
			info = utils.parse_json(file:read('*a') or '') or {}
			file:close()
		end
		os.remove(run.json)
		local w, h = tonumber(info.w), tonumber(info.h)
		local stat = w and h and utils.file_info(run.bgra)
		if ok and stat and stat.size == w * h * 4 then
			keep(run.key, { state = 'ready', file = run.bgra, w = w, h = h, info = info })
		else
			os.remove(run.bgra)
			keep(run.key, { state = 'none', info = info })
		end
		on_change()
		if wanted then
			local next_run = wanted
			wanted = nil
			start(next_run)
		end
	end

	start = function(request)
		if results[request.key] and results[request.key].state ~= 'loading' then
			return
		end
		serial = serial + 1
		local run = {
			key = request.key,
			json = prefix .. serial .. '.json',
			bgra = prefix .. serial .. '.bgra',
		}
		results[request.key] = { state = 'loading', info = {} }
		local args = {
			'mpv',
			'--no-config',
			'--msg-level=all=no',
			'--no-terminal',
			'--load-scripts=no',
			'--osc=no',
			'--ytdl=no',
			'--load-stats-overlay=no',
			'--load-osd-console=no',
			'--load-auto-profiles=no',
			'--script=' .. utils.join_path(script_dir, 'probe.lua'),
			'--script-opts-append=queue_probe-json=' .. run.json,
			'--script-opts-append=queue_probe-w=' .. request.w,
			'--script-opts-append=queue_probe-h=' .. request.h,
			'--cover-art-auto=' .. (mp.get_property('cover-art-auto') or 'exact'),
			'--aid=no',
			'--sid=no',
			'--hwdec=no',
			'--vd-lavc-threads=2',
			'--hr-seek=no',
			'--frames=1',
			'--ovc=rawvideo',
			'--of=rawvideo',
			'--o=' .. run.bgra,
			'--',
			request.path,
		}
		if WINDOWS then
			-- the player plays on undisturbed
			table.insert(args, 2, '--priority=belownormal')
		end
		running = run
		run.id = mp.command_native_async({
			name = 'subprocess',
			args = args,
			playback_only = false,
			capture_stdout = true,
			capture_stderr = true,
		}, function(success, result)
			-- probe.lua's quit 3 (no picture) is no failure: the size check below tells
			finish(run, success and type(result) == 'table' and not result.killed_by_us)
		end)
		run.timer = mp.add_timeout(TIMEOUT_SECONDS, function()
			if running == run then
				mp.abort_async_command(run.id)
			end
		end)
	end

	local handle = {}

	--- The result for a file at a picture box's size, starting a run when there is none; nil until one ran.
	---@param path string
	---@param w integer
	---@param h integer
	---@return PictureResult
	function handle.get(path, w, h)
		local key = path .. '\0' .. w .. 'x' .. h
		local result = results[key]
		if result then
			return result
		end
		local request = { key = key, path = path, w = w, h = h }
		if running then
			-- a request that waited and is no longer the newest is not run: it is asked again when needed
			if wanted then
				results[wanted.key] = nil
			end
			wanted = request
			results[key] = { state = 'loading', info = {} }
		else
			start(request)
		end
		return results[key]
	end

	--- Called when a run ended, so the card can draw what came.
	function handle.on_change(fn)
		on_change = fn
	end

	mp.register_event('shutdown', function()
		if running then
			mp.abort_async_command(running.id)
			os.remove(running.json)
			os.remove(running.bgra)
		end
		local keys = {}
		for i, key in ipairs(order) do
			keys[i] = key
		end
		for _, key in ipairs(keys) do
			forget(key)
		end
	end)

	return handle
end
