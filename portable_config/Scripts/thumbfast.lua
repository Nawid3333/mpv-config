-- thumbfast.lua
--
-- High-performance on-the-fly thumbnailer
--
-- Built for easy integration in third-party UIs.

--[[
This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at https://mozilla.org/MPL/2.0/.
]]

local options = {
	-- Socket path (leave empty for auto)
	socket = '',

	-- Thumbnail path (leave empty for auto)
	thumbnail = '',

	-- Maximum thumbnail generation size in pixels (scaled down to fit)
	-- Values are scaled when hidpi is enabled
	max_height = 200,
	max_width = 200,

	-- Scale factor for thumbnail display size (requires mpv 0.38+)
	-- Note that this is lower quality than increasing max_height and max_width
	scale_factor = 1,

	-- Apply tone-mapping, no to disable
	tone_mapping = 'auto',

	-- Overlay id
	overlay_id = 42,

	-- Spawn thumbnailer on file load for faster initial thumbnails
	spawn_first = false,

	-- Close thumbnailer process after an inactivity period in seconds, 0 to disable
	quit_after_inactivity = 0,

	-- Enable on network playback
	network = false,

	-- Enable on audio playback
	audio = false,

	-- Enable hardware decoding
	hwdec = false,

	-- Windows only: use native Windows API to write to pipe (requires LuaJIT)
	direct_io = false,

	-- Custom path to the mpv executable
	mpv_path = 'mpv',

	-- Local change (not upstream thumbfast), Windows only: a stream's buffered part from this mpv's own cache
	stream_cache = false,
}

mp.utils = require('mp.utils')
mp.options = require('mp.options')
mp.options.read_options(options, 'thumbfast')

-- Local change (not upstream thumbfast): FastStream's playlist-file streams (faststream-fragment.lua).
local fragment = dofile(mp.command_native({ 'expand-path', '~~/script-modules/faststream-fragment.lua' }))

local properties = {}
local pre_0_30_0 = mp.command_native_async == nil
local pre_0_33_0 = true
local support_media_control = mp.get_property_native('media-controls') ~= nil
local os_name

local function subprocess(args, async, callback)
	callback = callback or function() end

	if not pre_0_30_0 then
		-- FIXME: figure out which exact env var needs to be stripped. (PR: #144, Issue: #106 and #139)
		local env = os_name == 'darwin' and 'PATH=' .. os.getenv('PATH') or nil
		if async then
			return mp.command_native_async(
				{ name = 'subprocess', playback_only = true, args = args, env = env },
				callback
			)
		else
			return mp.command_native({
				name = 'subprocess',
				playback_only = false,
				capture_stdout = true,
				args = args,
				env = env,
			})
		end
	else
		if async then
			return mp.utils.subprocess_detached({ args = args }, callback)
		else
			return mp.utils.subprocess({ args = args })
		end
	end
end

local winapi = {}
if options.direct_io then
	local ffi_loaded, ffi = pcall(require, 'ffi')
	if ffi_loaded then
		winapi = {
			ffi = ffi,
			C = ffi.C,
			bit = require('bit'),
			socket_wc = '',

			-- WinAPI constants
			CP_UTF8 = 65001,
			GENERIC_WRITE = 0x40000000,
			OPEN_EXISTING = 3,
			FILE_FLAG_WRITE_THROUGH = 0x80000000,
			FILE_FLAG_NO_BUFFERING = 0x20000000,
			PIPE_NOWAIT = ffi.new('unsigned long[1]', 0x00000001),

			INVALID_HANDLE_VALUE = ffi.cast('void*', -1),

			-- don't care about how many bytes WriteFile wrote, so allocate something to store the result once
			_lpNumberOfBytesWritten = ffi.new('unsigned long[1]'),
		}
		-- cache flags used in run() to avoid bor() call
		winapi._createfile_pipe_flags = winapi.bit.bor(winapi.FILE_FLAG_WRITE_THROUGH, winapi.FILE_FLAG_NO_BUFFERING)

		ffi.cdef([[
            void* __stdcall CreateFileW(const wchar_t *lpFileName, unsigned long dwDesiredAccess, unsigned long dwShareMode, void *lpSecurityAttributes, unsigned long dwCreationDisposition, unsigned long dwFlagsAndAttributes, void *hTemplateFile);
            bool __stdcall WriteFile(void *hFile, const void *lpBuffer, unsigned long nNumberOfBytesToWrite, unsigned long *lpNumberOfBytesWritten, void *lpOverlapped);
            bool __stdcall CloseHandle(void *hObject);
            bool __stdcall SetNamedPipeHandleState(void *hNamedPipe, unsigned long *lpMode, unsigned long *lpMaxCollectionCount, unsigned long *lpCollectDataTimeout);
            int __stdcall MultiByteToWideChar(unsigned int CodePage, unsigned long dwFlags, const char *lpMultiByteStr, int cbMultiByte, wchar_t *lpWideCharStr, int cchWideChar);
        ]])

		winapi.MultiByteToWideChar = function(MultiByteStr)
			if MultiByteStr then
				local utf16_len = winapi.C.MultiByteToWideChar(winapi.CP_UTF8, 0, MultiByteStr, -1, nil, 0)
				if utf16_len > 0 then
					local utf16_str = winapi.ffi.new('wchar_t[?]', utf16_len)
					if winapi.C.MultiByteToWideChar(winapi.CP_UTF8, 0, MultiByteStr, -1, utf16_str, utf16_len) > 0 then
						return utf16_str
					end
				end
			end
			return ''
		end
	else
		options.direct_io = false
	end
end

local file
local file_bytes = 0
local spawned = false
local disabled = false
local force_disabled = false
local spawn_waiting = false
local spawn_working = false
local script_written = false

local dirty = false

local x, y
local last_x, last_y

local last_seek_time

local effective_w, effective_h = options.max_width, options.max_height
local real_w, real_h
local last_real_w, last_real_h

local script_name

local show_thumbnail = false

local filters_reset = { ['lavfi-crop'] = true, ['crop'] = true }
local filters_runtime = { ['hflip'] = true, ['vflip'] = true }
local filters_all = { ['hflip'] = true, ['vflip'] = true, ['lavfi-crop'] = true, ['crop'] = true }

local tone_mappings = {
	['none'] = true,
	['clip'] = true,
	['linear'] = true,
	['gamma'] = true,
	['reinhard'] = true,
	['hable'] = true,
	['mobius'] = true,
}
local last_tone_mapping

local last_vf_reset = ''
local last_vf_runtime = ''

local last_rotate = 0

local par = ''
local last_par = ''

local last_crop = nil

local last_has_vid = 0
local has_vid = 0

local file_timer
-- Local change: 2 ms, not 1/60 s, while a picture is due (file_timer): upstream's period added 8 ms to each picture on
-- average (doc/scripts.md).
local file_check_period = 0.002

local allow_fast_seek = true

-- Local change (not upstream thumbfast): the seek the thumbnailer is doing (time, exact, at, lost_after, motion; spawn
-- for its start, after for the place of a seek given up before it) and the one whose picture is the last (request_seek).
local seek_running, seek_shown = nil, nil
local duration = nil

local client_script = [=[
#!/usr/bin/env bash
MPV_IPC_FD=0; MPV_IPC_PATH="%s"
trap "kill 0" EXIT
while [[ $# -ne 0 ]]; do case $1 in --mpv-ipc-fd=*) MPV_IPC_FD=${1/--mpv-ipc-fd=/} ;; esac; shift; done
if echo "print-text thumbfast" >&"$MPV_IPC_FD"; then echo -n > "$MPV_IPC_PATH"; tail -f "$MPV_IPC_PATH" >&"$MPV_IPC_FD" & while read -r -u "$MPV_IPC_FD" 2>/dev/null; do :; done; fi
]=]

local function get_os()
	local raw_os_name = ''

	if jit and jit.os and jit.arch then
		raw_os_name = jit.os
	else
		if package.config:sub(1, 1) == '\\' then
			-- Windows
			local env_OS = os.getenv('OS')
			if env_OS then
				raw_os_name = env_OS
			end
		else
			raw_os_name = subprocess({ 'uname', '-s' }).stdout
		end
	end

	raw_os_name = (raw_os_name):lower()

	local os_patterns = {
		['windows'] = 'windows',
		['linux'] = 'linux',

		['osx'] = 'darwin',
		['mac'] = 'darwin',
		['darwin'] = 'darwin',

		['^mingw'] = 'windows',
		['^cygwin'] = 'windows',

		['bsd$'] = 'darwin',
		['sunos'] = 'darwin',
	}

	-- Default to linux
	local str_os_name = 'linux'

	for pattern, name in pairs(os_patterns) do
		if raw_os_name:match(pattern) then
			str_os_name = name
			break
		end
	end

	return str_os_name
end

os_name = mp.get_property('platform') or get_os()

local path_separator = os_name == 'windows' and '\\' or '/'

if options.socket == '' then
	if os_name == 'windows' then
		options.socket = 'thumbfast'
	else
		options.socket = '/tmp/thumbfast'
	end
end

if options.thumbnail == '' then
	if os_name == 'windows' then
		options.thumbnail = os.getenv('TEMP') .. '\\thumbfast.out'
	else
		options.thumbnail = '/tmp/thumbfast.out'
	end
end

local unique = mp.utils.getpid()

options.socket = options.socket .. unique
options.thumbnail = options.thumbnail .. unique

if options.direct_io then
	if os_name == 'windows' then
		winapi.socket_wc = winapi.MultiByteToWideChar('\\\\.\\pipe\\' .. options.socket)
	end

	if winapi.socket_wc == '' then
		options.direct_io = false
	end
end

options.scale_factor = math.floor(options.scale_factor)

local mpv_path = options.mpv_path
local frontend_path

if mpv_path == 'mpv' and os_name == 'windows' then
	frontend_path = mp.get_property_native('user-data/frontend/process-path')
	mpv_path = frontend_path or mpv_path
end

if mpv_path == 'mpv' and os_name == 'darwin' and unique then
	-- TODO: look into ~~osxbundle/
	mpv_path = string.gsub(subprocess({ 'ps', '-o', 'comm=', '-p', tostring(unique) }).stdout, '[\n\r]', '')
	if mpv_path ~= 'mpv' then
		mpv_path = string.gsub(mpv_path, '/mpv%-bundle$', '/mpv')
		local mpv_bin = mp.utils.file_info('/usr/local/mpv')
		if mpv_bin and mpv_bin.is_file then
			mpv_path = '/usr/local/mpv'
		else
			local mpv_app = mp.utils.file_info('/Applications/mpv.app/Contents/MacOS/mpv')
			if mpv_app and mpv_app.is_file then
				mp.msg.warn(
					'symlink mpv to fix Dock icons: `sudo ln -s /Applications/mpv.app/Contents/MacOS/mpv /usr/local/mpv`'
				)
			else
				mp.msg.warn(
					'drag to your Applications folder and symlink mpv to fix Dock icons: `sudo ln -s /Applications/mpv.app/Contents/MacOS/mpv /usr/local/mpv`'
				)
			end
		end
	end
end

local function vo_tone_mapping()
	local passes = mp.get_property_native('vo-passes')
	if passes and passes['fresh'] then
		for k, v in pairs(passes['fresh']) do
			for k2, v2 in pairs(v) do
				if k2 == 'desc' and v2 then
					local tone_mapping = string.match(v2, '([0-9a-z.-]+) tone map')
					if tone_mapping then
						return tone_mapping
					end
				end
			end
		end
	end
end

local function vf_string(filters, full)
	local vf = ''
	local vf_table = properties['vf']

	if (properties['video-crop'] or '') ~= '' then
		vf = 'lavfi-crop='
			.. string.gsub(properties['video-crop'], '(%d*)x?(%d*)%+(%d+)%+(%d+)', 'w=%1:h=%2:x=%3:y=%4')
			.. ','
		local width = properties['video-out-params'] and properties['video-out-params']['dw']
		local height = properties['video-out-params'] and properties['video-out-params']['dh']
		if width and height then
			vf = string.gsub(vf, 'w=:h=:', 'w=' .. width .. ':h=' .. height .. ':')
		end
	end

	if vf_table and #vf_table > 0 then
		for i = #vf_table, 1, -1 do
			if filters[vf_table[i].name] then
				local args = ''
				for key, value in pairs(vf_table[i].params) do
					if args ~= '' then
						args = args .. ':'
					end
					args = args .. key .. '=' .. value
				end
				vf = vf .. vf_table[i].name .. '=' .. args .. ','
			end
		end
	end

	if (full and options.tone_mapping ~= 'no') or options.tone_mapping == 'auto' then
		if properties['video-params'] and properties['video-params']['primaries'] == 'bt.2020' then
			local tone_mapping = options.tone_mapping
			if tone_mapping == 'auto' then
				tone_mapping = last_tone_mapping or properties['tone-mapping']
				if tone_mapping == 'auto' and properties['current-vo'] == 'gpu-next' then
					tone_mapping = vo_tone_mapping()
				end
			end
			if not tone_mappings[tone_mapping] then
				tone_mapping = 'hable'
			end
			last_tone_mapping = tone_mapping
			vf = vf .. 'zscale=transfer=linear,format=gbrpf32le,tonemap=' .. tone_mapping .. ',zscale=transfer=bt709,'
		end
	end

	if full then
		vf = vf
			.. 'scale=w='
			.. effective_w
			.. ':h='
			.. effective_h
			.. par
			.. ',pad=w='
			.. effective_w
			.. ':h='
			.. effective_h
			.. ':x=-1:y=-1,format=bgra'
	end

	return vf
end

local function calc_dimensions()
	local width = properties['video-out-params'] and properties['video-out-params']['dw']
	local height = properties['video-out-params'] and properties['video-out-params']['dh']
	if not width or not height then
		return
	end

	local scale = properties['display-hidpi-scale'] or 1

	if width / height > options.max_width / options.max_height then
		effective_w = math.floor(options.max_width * scale + 0.5)
		effective_h = math.floor(height / width * effective_w + 0.5)
	else
		effective_h = math.floor(options.max_height * scale + 0.5)
		effective_w = math.floor(width / height * effective_h + 0.5)
	end

	local v_par = properties['video-out-params'] and properties['video-out-params']['par'] or 1
	if v_par == 1 then
		par = ':force_original_aspect_ratio=decrease'
	else
		par = ''
	end
end

local info_timer = nil

local function info(w, h)
	local rotate = properties['video-params'] and properties['video-params']['rotate']
	local image = properties['current-tracks/video'] and properties['current-tracks/video']['image']
	local albumart = image and properties['current-tracks/video']['albumart']

	disabled = (w or 0) == 0
		or (h or 0) == 0
		or has_vid == 0
		or (properties['demuxer-via-network'] and not options.network)
		-- Local change: a stream played from FastStream's playlist files is a network stream too. A thumbnail
		-- would fetch it again, without the page's headers (doc/scripts.md).
		or (fragment.target(properties['path']) and not options.network)
		-- Local change: none for a private window's stream, which leaves no files behind (faststream-private.lua);
		-- the frames go through a file in TEMP.
		or fragment.value(properties['path'], 'fs-private=') == '1'
		or (albumart and not options.audio)
		or (image and not albumart)
		or force_disabled

	if info_timer then
		info_timer:kill()
		info_timer = nil
	elseif has_vid == 0 or (rotate == nil and not disabled) then
		info_timer = mp.add_timeout(0.05, function()
			info(w, h)
		end)
	end

	local json, err = mp.utils.format_json({
		width = w * options.scale_factor,
		height = h * options.scale_factor,
		scale_factor = options.scale_factor,
		disabled = disabled,
		available = true,
		socket = options.socket,
		thumbnail = options.thumbnail,
		overlay_id = options.overlay_id,
	})
	if pre_0_30_0 then
		mp.command_native({ 'script-message', 'thumbfast-info', json })
	else
		mp.command_native_async({ 'script-message', 'thumbfast-info', json }, function() end)
	end
end

local function remove_thumbnail_files()
	if file then
		file:close()
		file = nil
		file_bytes = 0
	end
	os.remove(options.thumbnail)
	os.remove(options.thumbnail .. '.bgra')
end

local activity_timer

-- Local change (not upstream thumbfast): a stream's thumbnails. The thumbnailer opens the stream as this mpv does:
-- with the page's headers (a CDN may refuse it without its Referer or Cookie), the demuxer options that let ffmpeg
-- read FastStream's playlist files, and the lowest HLS bitrate (a thumbnail is 200 px). The stream and its options
-- go over the thumbnailer's pipe (send_when_open), never on its command line, which any program can read: a cookie,
-- an address with a token. Nil for a local file, whose path stays on the command line as upstream has it.
local send_when_open
-- The running thumbnailer's pipe. A stream's gets a name of its own: a thumbnailer that quits (the video's size
-- changed) may hold its pipe a while, and the load must reach the new one.
local pipe_name = options.socket
local stream_spawns = 0
-- An HLS stream's qualities are its video tracks, and --vid names this mpv's: the thumbnailer picks its own, the
-- lowest (vid=auto, hls-bitrate=min), and this mpv's track changes are not passed on (sync_changes).
local own_variant = false

local function stream_load(path, time)
	own_variant = false
	if os_name ~= 'windows' or not (properties['demuxer-via-network'] or fragment.target(properties['path'])) then
		return nil
	end
	local opts = { start = tostring(time) }
	if mp.get_property('file-format') == 'hls' then
		own_variant = true
		opts['hls-bitrate'] = 'min'
		opts.vid = 'auto'
	end
	local fields = {}
	for _, field in ipairs(mp.get_property_native('http-header-fields') or {}) do
		-- As FastStream's helper writes them: a comma escaped; one ending in a backslash would swallow the next.
		if not field:match('\\$') then
			fields[#fields + 1] = (field:gsub(',', '\\,'))
		end
	end
	if #fields > 0 then
		opts['http-header-fields'] = table.concat(fields, ',')
	end
	-- Only one set for this file or in mpv.conf: the thumbnailer has the defaults (--no-config).
	for _, name in ipairs({ 'user-agent', 'referrer', 'demuxer' }) do
		local value = mp.get_property(name)
		if value and value ~= mp.get_property('option-info/' .. name .. '/default-value') then
			opts[name] = value
		end
	end
	local lavf = {}
	for key, value in pairs(mp.get_property_native('demuxer-lavf-o') or {}) do
		lavf[#lavf + 1] = key .. '=[' .. value .. ']'
	end
	if #lavf > 0 then
		table.sort(lavf)
		opts['demuxer-lavf-o'] = table.concat(lavf, ',')
	end
	-- For the tests: which options went, never their values.
	local names = {}
	for name in pairs(opts) do
		names[#names + 1] = name
	end
	table.sort(names)
	mp.set_property_native('user-data/thumbfast/stream-options', names)
	return { command = { 'loadfile', path, 'replace', -1, opts } }
end

-- Local change (not upstream thumbfast): a stream's buffered part comes from this mpv's own cache, not from the network
-- a second time (stream_cache). As the cache grows it is written out in chunks of whole GOPs with `dump-cache`, which
-- holds this mpv's demuxer while it writes (about 0.4 ms a MB, so at most CHUNK_BYTES at a time); the thumbnailer loads
-- the chunk that holds the time hovered and seeks in it as in a local file. dump-cache begins at the keyframe before
-- the time it is given and makes the chunk's own times start at 0, so a chunk begins only where that keyframe's time is
-- known: a cached range's start (seekable-ranges; mpv takes it from the audio where that starts before or after the
-- video, so the frame is off by as much), or the last keyframe of the chunk before it, read from that chunk's cues. A
-- chunk goes once this mpv's cache no longer holds its part, and all of them at the file's end; the lock file, open
-- while this mpv runs, tells a later mpv that the chunks it finds of this one are left over (doc/scripts.md).
local CHUNK_BYTES = 16 * 1024 * 1024
local chunks = {}
local chunk_count = 0
local chunk_secs = 30
local chunk_min = 4
local chunk_failures = 0
local chunk_lock = nil
local leftovers = {}
local swept = false
local dumping = false
local cache_timer = nil
local file_serial = 0
-- What the thumbnailer has loaded: a chunk, or false for the stream itself; nil for a local file.
local source = nil
local net_load = nil

-- A Matroska file's keyframe times (its cues), in seconds as mpv plays it (from its first cluster); nil if it has none.
local function mkv_keyframes(path)
	local f = io.open(path, 'rb')
	if not f then
		return nil
	end
	-- The EBML element at p of s: its id, where its data starts and its size (nil: unknown).
	local function element(s, p)
		local function vint(q, keep_marker)
			local b = s:byte(q)
			if not b then
				return nil
			end
			local len, mask = 1, 128
			while len <= 8 and b < mask do
				len, mask = len + 1, mask / 2
			end
			if len > 8 or q + len - 1 > #s then
				return nil
			end
			local v = keep_marker and b or b - mask
			local all_ones = v == mask - 1
			for i = q + 1, q + len - 1 do
				local c = s:byte(i)
				v = v * 256 + c
				all_ones = all_ones and c == 255
			end
			return v, len, all_ones
		end
		local id, id_len = vint(p, true)
		if not id then
			return nil
		end
		local size, size_len, unknown = vint(p + id_len)
		if not size then
			return nil
		end
		return id, p + id_len + size_len, (not unknown) and size or nil
	end
	local function uint(s, p, n)
		local v = 0
		for i = p, p + n - 1 do
			v = v * 256 + s:byte(i)
		end
		return v
	end
	local head = f:read(65536) or ''
	local id, data, size = element(head, 1)
	if id ~= 0x1A45DFA3 or not size then
		f:close()
		return nil
	end
	id, data = element(head, data + size)
	if id ~= 0x18538067 then
		f:close()
		return nil
	end
	-- The segment's head: TimestampScale in Info, the cues' place in SeekHead; it ends at the first cluster, whose
	-- timestamp mpv takes for the file's start (its time 0).
	local segment = data
	local scale, cues_at, start = 1000000, nil, nil
	local p = segment
	while p < #head do
		local eid, edata, esize = element(head, p)
		if eid == 0x1F43B675 then
			local q = edata
			for _ = 1, 4 do
				local tid, tdata, tsize = element(head, q)
				if not tid or not tsize or tdata + tsize > #head + 1 then
					break
				end
				if tid == 0xE7 then
					start = uint(head, tdata, tsize)
					break
				end
				q = tdata + tsize
			end
			break
		end
		if not eid or not esize then
			break
		end
		local q = edata
		while q < math.min(edata + esize, #head + 1) do
			local cid, cdata, csize = element(head, q)
			if not cid or not csize then
				break
			end
			if eid == 0x1549A966 and cid == 0x2AD7B1 then
				scale = uint(head, cdata, csize)
			elseif eid == 0x114D9B74 and cid == 0x4DBB then
				local seek_id, seek_pos
				local r = cdata
				while r < cdata + csize do
					local gid, gdata, gsize = element(head, r)
					if not gid or not gsize then
						break
					end
					if gid == 0x53AB then
						seek_id = uint(head, gdata, gsize)
					elseif gid == 0x53AC then
						seek_pos = uint(head, gdata, gsize)
					end
					r = gdata + gsize
				end
				if seek_id == 0x1C53BB6B and seek_pos then
					cues_at = segment - 1 + seek_pos
				end
			end
			q = cdata + csize
		end
		p = edata + esize
	end
	if not cues_at or not start then
		f:close()
		return nil
	end
	f:seek('set', cues_at)
	local cues = f:read(16) or ''
	local cid, cdata, csize = element(cues, 1)
	if cid ~= 0x1C53BB6B or not csize or csize > 16777216 then
		f:close()
		return nil
	end
	f:seek('set', cues_at + cdata - 1)
	cues = f:read(csize) or ''
	f:close()
	local times = {}
	local q = 1
	while q < #cues do
		local pid, pdata, psize = element(cues, q)
		if not pid or not psize then
			break
		end
		if pid == 0xBB then
			local r = pdata
			while r < pdata + psize do
				local tid, tdata, tsize = element(cues, r)
				if not tid or not tsize then
					break
				end
				if tid == 0xB3 then
					times[#times + 1] = (uint(cues, tdata, tsize) - start) * scale / 1e9
				end
				r = tdata + tsize
			end
		end
		q = pdata + psize
	end
	table.sort(times)
	return #times > 0 and times or nil
end

-- The chunk that holds a time: the thumbnailer's own if it does (no load), else the first one.
local function chunk_at(time)
	if source and source.from <= time and time < source.to then
		return source
	end
	for _, c in ipairs(chunks) do
		if c.from <= time and time < c.to then
			return c
		end
	end
	return nil
end

-- The thumbnailer's load for a time: the chunk that holds it, else the stream. A chunk is decoded without the GPU (its
-- decoder starts again with each chunk, which took 40 ms more with d3d11va-copy) and without a look for subtitles
-- beside it (the 4000 files a TEMP folder may hold took 15 ms more).
local function source_load(time, exact)
	local c = chunk_at(time)
	source = c or false
	-- For the tests: where the thumbnailer's pictures come from.
	mp.set_property('user-data/thumbfast/source', c and 'cache' or 'stream')
	if c then
		return {
			command = {
				'loadfile',
				c.path,
				'replace',
				-1,
				{
					start = tostring(time - c.from + c.offset),
					['hr-seek'] = exact and 'yes' or 'no',
					vid = '1',
					edition = 'auto',
					['autoload-files'] = 'no',
					['vd-lavc-threads'] = '0',
					hwdec = 'no',
				},
			},
		}
	end
	local per_file = net_load and net_load.command[5]
	if per_file then
		per_file.start = tostring(time)
		per_file['hr-seek'] = exact and 'yes' or 'no'
	end
	return net_load
end

local function remove_file(path)
	if not os.remove(path) and mp.utils.file_info(path) then
		leftovers[#leftovers + 1] = path
	end
end

local function remove_leftovers()
	local left = leftovers
	leftovers = {}
	for _, path in ipairs(left) do
		remove_file(path)
	end
end

-- The lock: a file Windows deletes once this mpv's handle on it closes, also when mpv crashes
-- (FILE_FLAG_DELETE_ON_CLOSE). Returns its release, or nil off Windows or without LuaJIT's ffi (then no chunks).
local function take_lock()
	local ok, ffi = pcall(require, 'ffi')
	if not ok or os_name ~= 'windows' then
		return nil
	end
	pcall(
		ffi.cdef,
		[[
		void* __stdcall CreateFileW(const wchar_t *lpFileName, unsigned long dwDesiredAccess,
			unsigned long dwShareMode, void *lpSecurityAttributes, unsigned long dwCreationDisposition,
			unsigned long dwFlagsAndAttributes, void *hTemplateFile);
		bool __stdcall CloseHandle(void *hObject);
		int __stdcall MultiByteToWideChar(unsigned int CodePage, unsigned long dwFlags, const char *lpMultiByteStr,
			int cbMultiByte, wchar_t *lpWideCharStr, int cchWideChar);
	]]
	)
	local path = options.thumbnail .. '.lock'
	local len = ffi.C.MultiByteToWideChar(65001, 0, path, -1, nil, 0)
	if len <= 0 then
		return nil
	end
	local wide = ffi.new('wchar_t[?]', len)
	ffi.C.MultiByteToWideChar(65001, 0, path, -1, wide, len)
	-- GENERIC_WRITE, shared for reading only, CREATE_ALWAYS, FILE_FLAG_DELETE_ON_CLOSE
	local handle = ffi.C.CreateFileW(wide, 0x40000000, 1, nil, 2, 0x04000000, nil)
	if handle == ffi.cast('void*', -1) then
		return nil
	end
	return function()
		ffi.C.CloseHandle(handle)
	end
end

-- Chunks another mpv left behind: its lock is gone, so it runs no more (this mpv's own before its first chunk: an mpv
-- with the same PID before it).
local function sweep()
	swept = true
	local dir, own = options.thumbnail:match('^(.*)[/\\]([^/\\]+)$')
	if not dir then
		return
	end
	local prefix = own:gsub('%d+$', '')
	local running = {}
	for _, name in ipairs(mp.utils.readdir(dir, 'files') or {}) do
		local pid = name:sub(1, #prefix) == prefix and name:sub(#prefix + 1):match('^(%d+)%-c%d+%.mkv$')
		if pid then
			if running[pid] == nil then
				running[pid] = mp.utils.file_info(dir .. path_separator .. prefix .. pid .. '.lock') ~= nil
			end
			if not running[pid] then
				os.remove(dir .. path_separator .. name)
			end
		end
	end
end

local function remove_chunks()
	for _, c in ipairs(chunks) do
		remove_file(c.path)
	end
	chunks = {}
	source = nil
end

-- A chunk's times are whole ms, so a chain of chunks would add up their rounding: on a video of one frame rate the next
-- chunk's start goes on its frame grid, counted from the range's first keyframe (anchor).
local function on_grid(time, anchor)
	local fps = mp.get_property_number('container-fps', 0)
	if fps <= 0 or fps > 1000 then
		return time
	end
	local grid = anchor + math.floor((time - anchor) * fps + 0.5) / fps
	return math.abs(grid - time) <= 0.002 and grid or time
end

local function dump(from, anchor, stop, tail, final)
	if not swept then
		sweep()
	end
	if not chunk_lock then
		chunk_lock = take_lock()
		if not chunk_lock then
			chunk_failures = math.huge
			return
		end
	end
	chunk_count = chunk_count + 1
	local path = options.thumbnail .. '-c' .. chunk_count .. '.mkv'
	local serial = file_serial
	dumping = true
	-- 50 ms past the keyframe: dump-cache takes the keyframe before the time it gets.
	mp.command_native_async({ 'dump-cache', from + 0.05, stop, path }, function(success)
		dumping = false
		if serial ~= file_serial then
			remove_file(path)
			return
		end
		local keyframes = success and mkv_keyframes(path)
		local finfo = mp.utils.file_info(path)
		if not keyframes or not finfo then
			remove_file(path)
			chunk_failures = chunk_failures + 1
			return
		end
		if not tail and #keyframes < 2 then
			-- One GOP longer than the chunk: no keyframe to go on from, so longer chunks.
			remove_file(path)
			chunk_min = chunk_min * 2
			return
		end
		local c = { path = path, from = from, anchor = anchor, offset = keyframes[1], bytes = finfo.size }
		c.next = final and math.huge or on_grid(from + keyframes[#keyframes] - keyframes[1], anchor)
		c.to = final and math.huge or tail and stop or c.next
		chunks[#chunks + 1] = c
	end)
end

local function cache_tick()
	remove_leftovers()
	if not net_load then
		return
	end
	local state = mp.get_property_native('demuxer-cache-state')
	local ranges = state and state['seekable-ranges'] or {}
	if #ranges == 0 then
		return
	end
	table.sort(ranges, function(a, b)
		return a.start < b.start
	end)
	-- A chunk goes once the cache holds none of its part, or a later one holds all of it (a tail grown since).
	for i = #chunks, 1, -1 do
		local c = chunks[i]
		local held = false
		for _, r in ipairs(ranges) do
			held = held or (c.from < r['end'] and c.to > r.start)
		end
		for j = i + 1, #chunks do
			held = held and not (chunks[j].from == c.from and chunks[j].to >= c.to)
		end
		if not held and c ~= source then
			remove_file(c.path)
			table.remove(chunks, i)
		end
	end
	if dumping or not spawned or disabled or chunk_failures >= 3 then
		return
	end
	local secs = 0
	for _, r in ipairs(ranges) do
		secs = secs + r['end'] - r.start
	end
	local bytes = state['total-bytes'] or 0
	if secs > 1 and bytes > 0 then
		chunk_secs = math.max(math.min(CHUNK_BYTES * secs / bytes, 120), chunk_min)
	end
	for i, r in ipairs(ranges) do
		-- From the range's start on, past the chunks that hold it, to the next keyframe none holds.
		local from, anchor = r.start, r.start
		local moved = true
		while moved do
			moved = false
			for _, c in ipairs(chunks) do
				if c.from <= from + 0.01 and from < c.next then
					from, anchor, moved = c.next, c.anchor, true
				end
			end
		end
		local final = i == #ranges and state['eof-cached']
		local left = r['end'] - from
		if left > 0.1 then
			if left >= chunk_secs then
				dump(from, anchor, from + chunk_secs, false, false)
				return
			end
			-- The rest of a range that grows no more (the end of the file, or this mpv's cache is full).
			local held = false
			for _, c in ipairs(chunks) do
				held = held or (c.from <= from + 0.01 and c.to >= r['end'] - 0.01)
			end
			if (final or state.idle) and not held then
				dump(from, anchor, r['end'], true, final)
				return
			end
		end
	end
end

local function spawn(time)
	if disabled then
		return
	end

	local path = properties['path']
	if path == nil then
		return
	end
	local stream = properties['demuxer-via-network'] or fragment.target(path) ~= nil

	if options.quit_after_inactivity > 0 then
		if show_thumbnail or activity_timer:is_enabled() then
			activity_timer:kill()
		end
		activity_timer:resume()
	end

	local open_filename = properties['stream-open-filename']
	local ytdl = open_filename and properties['demuxer-via-network'] and path ~= open_filename
	if ytdl then
		path = open_filename
	end

	remove_thumbnail_files()

	local vid = properties['vid']
	has_vid = vid or 0

	local args = {
		mpv_path,
		'--no-config',
		'--msg-level=all=no',
		'--idle',
		'--pause',
		'--keep-open=always',
		'--really-quiet',
		'--no-terminal',
		'--load-scripts=no',
		'--osc=no',
		'--ytdl=no',
		'--load-stats-overlay=no',
		'--load-osd-console=no',
		'--load-auto-profiles=no',
		'--edition=' .. (properties['edition'] or 'auto'),
		'--vid=' .. (vid or 'auto'),
		'--no-sub',
		'--no-audio',
		'--start=' .. time,
		allow_fast_seek and '--hr-seek=no' or '--hr-seek=yes',
		'--ytdl-format=worst',
		'--demuxer-readahead-secs=0',
		'--demuxer-max-bytes=128KiB',
		'--vd-lavc-skiploopfilter=all',
		'--vd-lavc-software-fallback=1',
		'--vd-lavc-fast',
		-- Local change: for a file every CPU thread, and with hwdec=yes this mpv's own hwdec list (mpv.conf's, never one
		-- it does not use), not 2 threads and auto: the exact frame of a long-GOP file comes in half the time. A stream
		-- keeps upstream's 2 threads without the GPU: with it, each of its pictures came 100-200 ms later (doc/scripts.md).
		'--vd-lavc-threads=' .. (stream and '2' or '0'),
		'--hwdec=' .. ((options.hwdec and not stream) and mp.get_property('hwdec', 'no') or 'no'),
		'--vf=' .. vf_string(filters_all, true),
		'--sws-scaler=fast-bilinear',
		'--video-rotate=' .. last_rotate,
		'--ovc=rawvideo',
		'--of=image2',
		'--ofopts=update=1',
		'--o=' .. options.thumbnail,
	}

	if not pre_0_30_0 then
		table.insert(args, '--sws-allow-zimg=no')
	end

	if support_media_control then
		table.insert(args, '--media-controls=no')
	end

	if os_name == 'darwin' and properties['macos-app-activation-policy'] then
		table.insert(args, '--macos-app-activation-policy=accessory')
	end

	-- Local change: a stream goes over the pipe once the thumbnailer is up (stream_load); it starts idle.
	local load = stream_load(path, time)
	pipe_name = options.socket
	if load then
		stream_spawns = stream_spawns + 1
		pipe_name = options.socket .. '-' .. stream_spawns
	end
	if options.direct_io and os_name == 'windows' then
		winapi.socket_wc = winapi.MultiByteToWideChar('\\\\.\\pipe\\' .. pipe_name)
	end

	if os_name == 'windows' or pre_0_33_0 then
		table.insert(args, '--input-ipc-server=' .. pipe_name)
	elseif not script_written then
		local client_script_path = options.socket .. '.run'
		local script = io.open(client_script_path, 'w+')
		if script == nil then
			mp.msg.error('client script write failed')
			return
		else
			script_written = true
			script:write(string.format(client_script, options.socket))
			script:close()
			subprocess({ 'chmod', '+x', client_script_path }, true)
			table.insert(args, '--scripts=' .. client_script_path)
		end
	else
		local client_script_path = options.socket .. '.run'
		table.insert(args, '--scripts=' .. client_script_path)
	end

	if not load then
		table.insert(args, '--')
		table.insert(args, path)
	end

	spawned = true
	spawn_waiting = true
	-- Local change: the first picture is the start's (a keyframe unless allow_fast_seek is off); it is waited for, the
	-- pipe opens only then.
	seek_running = { time = time, exact = not allow_fast_seek, at = mp.get_time(), lost_after = 10, spawn = true }
	seek_shown = nil
	-- Local change: the stream's load is kept for when the thumbnailer goes back to it from a chunk (source_load).
	net_load = load
	source = nil
	if load then
		if options.stream_cache and not cache_timer then
			cache_timer = mp.add_periodic_timer(0.5, cache_tick)
		end
		send_when_open(time)
	end

	subprocess(args, true, function(success, result)
		if spawn_waiting and (success == false or (result.status ~= 0 and result.status ~= -2)) then
			spawned = false
			spawn_waiting = false
			options.tone_mapping = 'no'
			mp.msg.error('mpv subprocess create failed')
			if not spawn_working then -- notify users of required configuration
				if options.mpv_path == 'mpv' then
					if properties['current-vo'] == 'libmpv' then
						if options.mpv_path == mpv_path then -- attempt to locate ImPlay
							mpv_path = 'ImPlay'
							spawn(time)
						else -- ImPlay not in path
							if os_name ~= 'darwin' then
								force_disabled = true
								info(real_w or effective_w, real_h or effective_h)
							end
							mp.commandv('show-text', 'thumbfast: ERROR! cannot create mpv subprocess', 5000)
							mp.commandv(
								'script-message-to',
								'implay',
								'show-message',
								'thumbfast initial setup',
								'Set mpv_path=PATH_TO_ImPlay in thumbfast config:\n'
									.. string.gsub(
										mp.command_native({ 'expand-path', '~~/script-opts/thumbfast.conf' }),
										'[/\\]',
										path_separator
									)
									.. '\nand restart ImPlay'
							)
						end
					else
						mp.commandv('show-text', 'thumbfast: ERROR! cannot create mpv subprocess', 5000)
						if os_name == 'windows' and frontend_path == nil then
							mp.commandv(
								'script-message-to',
								'mpvnet',
								'show-text',
								'thumbfast: ERROR! install standalone mpv, see README',
								5000,
								20
							)
							mp.commandv(
								'script-message',
								'mpv.net',
								'show-text',
								'thumbfast: ERROR! install standalone mpv, see README',
								5000,
								20
							)
						end
					end
				else
					mp.commandv('show-text', 'thumbfast: ERROR! cannot create mpv subprocess', 5000)
					-- found ImPlay but not defined in config
					mp.commandv(
						'script-message-to',
						'implay',
						'show-message',
						'thumbfast',
						'Set mpv_path=PATH_TO_ImPlay in thumbfast config:\n'
							.. string.gsub(
								mp.command_native({ 'expand-path', '~~/script-opts/thumbfast.conf' }),
								'[/\\]',
								path_separator
							)
							.. '\nand restart ImPlay'
					)
				end
			end
		elseif success == true and (result.status == 0 or result.status == -2) then
			if not spawn_working and properties['current-vo'] == 'libmpv' and options.mpv_path ~= mpv_path then
				mp.commandv(
					'script-message-to',
					'implay',
					'show-message',
					'thumbfast initial setup',
					'Set mpv_path=ImPlay in thumbfast config:\n'
						.. string.gsub(
							mp.command_native({ 'expand-path', '~~/script-opts/thumbfast.conf' }),
							'[/\\]',
							path_separator
						)
						.. '\nand restart ImPlay'
				)
			end
			spawn_working = true
			spawn_waiting = false
		end
	end)
end

-- Local change (not upstream thumbfast): a pipe opened to the thumbnailer asks it for no events. Its mpv wrote an
-- event line after every seek, which nothing here reads: once the pipe's 4 KB were full (about 90 seeks) it read no
-- more commands until the pipe was opened again, and the seeks meanwhile got no picture (doc/scripts.md).
local function open_pipe()
	local pipe = io.open('\\\\.\\pipe\\' .. pipe_name, 'r+b')
	if pipe then
		pipe:write('{"command":["disable_event","all"]}\n')
		pipe:flush()
	end
	return pipe
end

local function run(command)
	if not spawned then
		return
	end

	if options.direct_io then
		local hPipe = winapi.C.CreateFileW(
			winapi.socket_wc,
			winapi.GENERIC_WRITE,
			0,
			nil,
			winapi.OPEN_EXISTING,
			winapi._createfile_pipe_flags,
			nil
		)
		if hPipe ~= winapi.INVALID_HANDLE_VALUE then
			local buf = command .. '\n'
			winapi.C.SetNamedPipeHandleState(hPipe, winapi.PIPE_NOWAIT, nil, nil)
			winapi.C.WriteFile(hPipe, buf, #buf + 1, winapi._lpNumberOfBytesWritten, nil)
			winapi.C.CloseHandle(hPipe)
		end

		return
	end

	local command_n = command .. '\n'

	if os_name == 'windows' then
		if file and file_bytes + #command_n >= 4096 then
			file:close()
			file = nil
			file_bytes = 0
		end
		if not file then
			-- Local change: pipe_name (spawn), not options.socket; no events (open_pipe).
			file = open_pipe()
		end
	elseif pre_0_33_0 then
		subprocess({ '/usr/bin/env', 'sh', '-c', "echo '" .. command .. "' | socat - " .. options.socket })
		return
	elseif not file then
		file = io.open(options.socket, 'r+')
	end
	if file then
		file_bytes = file:seek('end')
		file:write(command_n)
		file:flush()
	end
end

-- Local change: waits up to 10 s for the thumbnailer's pipe, then loads the stream (or the chunk of this mpv's cache
-- that holds it, source_load) at the time the pointer is on now.
local load_timer
send_when_open = function(time)
	if load_timer then
		load_timer:kill()
	end
	local tries = 0
	load_timer = mp.add_periodic_timer(0.05, function()
		tries = tries + 1
		if not spawned or tries > 200 then
			load_timer:kill()
			return
		end
		if not file then
			local pipe = open_pipe()
			if not pipe then
				return
			end
			if options.direct_io then
				pipe:close()
			else
				file, file_bytes = pipe, 0
			end
		end
		load_timer:kill()
		if last_seek_time then
			time = last_seek_time
			if seek_running and seek_running.spawn then
				seek_running.time = last_seek_time
			end
		end
		if seek_running and seek_running.spawn then
			seek_running.at = mp.get_time()
		end
		run(mp.utils.format_json(source_load(time, not allow_fast_seek)))
	end)
end

local function draw(w, h, script)
	if not w or not show_thumbnail then
		return
	end
	if x ~= nil then
		local scale_w, scale_h =
			options.scale_factor ~= 1 and (w * options.scale_factor) or nil,
			options.scale_factor ~= 1 and (h * options.scale_factor) or nil
		if pre_0_30_0 then
			mp.command_native({
				'overlay-add',
				options.overlay_id,
				x,
				y,
				options.thumbnail .. '.bgra',
				0,
				'bgra',
				w,
				h,
				(4 * w),
				scale_w,
				scale_h,
			})
		else
			mp.command_native_async({
				'overlay-add',
				options.overlay_id,
				x,
				y,
				options.thumbnail .. '.bgra',
				0,
				'bgra',
				w,
				h,
				(4 * w),
				scale_w,
				scale_h,
			}, function() end)
		end
	elseif script then
		local json, err = mp.utils.format_json({
			width = w,
			height = h,
			scale_factor = options.scale_factor,
			x = x,
			y = y,
			socket = options.socket,
			thumbnail = options.thumbnail,
			overlay_id = options.overlay_id,
		})
		mp.commandv('script-message-to', script, 'thumbfast-render', json)
	end
end

local function real_res(req_w, req_h, filesize)
	local count = filesize / 4
	local diff = (req_w * req_h) - count

	if (properties['video-params'] and properties['video-params']['rotate'] or 0) % 180 == 90 then
		req_w, req_h = req_h, req_w
	end

	if diff == 0 then
		return req_w, req_h
	else
		local threshold = 5 -- throw out results that change too much
		local long_side, short_side = req_w, req_h
		if req_h > req_w then
			long_side, short_side = req_h, req_w
		end
		for a = short_side, short_side - threshold, -1 do
			if count % a == 0 then
				local b = count / a
				if long_side - b < threshold then
					if req_h < req_w then
						return b, a
					else
						return a, b
					end
				end
			end
		end
		return nil
	end
end

local function move_file(from, to)
	if os_name == 'windows' then
		os.remove(to)
	end
	-- move the file because it can get overwritten while overlay-add is reading it, and crash the player
	os.rename(from, to)
end

local function check_new_thumb()
	-- the slave might start writing to the file after checking existance and
	-- validity but before actually moving the file, so move to a temporary
	-- location before validity check to make sure everything stays consistant
	-- and valid thumbnails don't get overwritten by invalid ones
	-- Local change: one look while nothing is there, not a remove, a rename and a look (it looks every 2 ms).
	if not mp.utils.file_info(options.thumbnail) then
		return false
	end
	local tmp = options.thumbnail .. '.tmp'
	move_file(options.thumbnail, tmp)
	local finfo = mp.utils.file_info(tmp)
	if not finfo then
		return false
	end
	spawn_waiting = false
	local w, h = real_res(effective_w, effective_h, finfo.size)
	if w then -- only accept valid thumbnails
		move_file(tmp, options.thumbnail .. '.bgra')

		real_w, real_h = w, h
		if real_w and (real_w ~= last_real_w or real_h ~= last_real_h) then
			last_real_w, last_real_h = real_w, real_h
			info(real_w, real_h)
		end
		if not show_thumbnail then
			file_timer:kill()
		end
		return true
	end

	return false
end

-- Local change (not upstream thumbfast): one seek at a time, each picture known by the seek that made it.
-- Upstream sent a keyframe seek and the exact one on a 50 ms timer, whatever the thumbnailer was doing, and drew each
-- picture that came at the pointer: after a quick move from one place to another it showed the old place's picture
-- there, and the exact frame came late (doc/scripts.md). Here the next seek goes out when the last one's picture came:
-- the pointer's keyframe, then its exact frame. A new place stops an exact seek still running elsewhere (mpv ends a
-- keyframe seek it began anyway); a picture is drawn only at its own place, near it, or while the pointer still moves
-- on from it without a jump, else the thumbnail is empty.
local near_px = 30
-- One pointer movement: a step farther than near_px starts the next one (thumb).
local motion = 0

-- How far apart two times are on the timeline, in pixels (the window's width stands for the timeline's).
local function px_apart(a, b)
	if not duration or duration <= 0 then
		return math.huge
	end
	local width = mp.get_property_number('osd-width', 0)
	return math.abs(a - b) / duration * (width > 0 and width or 1280)
end

local function seek(time, exact)
	seek_running = {
		time = time,
		exact = exact,
		at = mp.get_time(),
		lost_after = (properties['demuxer-via-network'] or fragment.target(properties['path'])) and 10 or 2,
		motion = motion,
	}
	if not file_timer:is_enabled() then
		file_timer:resume()
	end
	-- Local change: a stream's time from the chunk of this mpv's cache that holds it, else from the stream
	-- (source_load).
	local at = time
	if options.stream_cache and net_load then
		local c = chunk_at(time) or false
		if c then
			seek_running.lost_after = 2
		end
		if c ~= source then
			run(mp.utils.format_json(source_load(time, exact)))
			return
		end
		if c then
			at = time - c.from + c.offset
		end
	end
	run('async seek ' .. at .. (exact and ' absolute+exact' or ' absolute+keyframes'))
end

local function next_seek()
	if seek_running or not last_seek_time or not spawned then
		return
	end
	if seek_shown and seek_shown.time == last_seek_time then
		-- The keyframe's picture is here: its exact frame next.
		if not seek_shown.exact then
			seek(last_seek_time, true)
		end
		return
	end
	seek(last_seek_time, not allow_fast_seek)
end

-- A sweep's pictures come a little behind the pointer; after a jump the last place's are of another place.
local function fits(time)
	-- No time: no pointer on the timeline (the start's picture before the first hover).
	return seek_shown ~= nil
		and time ~= nil
		and (seek_shown.time == time or px_apart(seek_shown.time, time) <= near_px or seek_shown.motion == motion)
end

local function hide()
	if pre_0_30_0 then
		mp.command_native({ 'overlay-remove', options.overlay_id })
	else
		mp.command_native_async({ 'overlay-remove', options.overlay_id }, function() end)
	end
end

-- A script that draws the thumbnail itself (thumbfast-render) gets every picture, as upstream.
local function show_or_hide(time, script)
	-- No hover: clear() took the thumbnail off.
	if not show_thumbnail then
		return
	end
	if script or fits(time) then
		draw(real_w, real_h, script)
	else
		hide()
	end
end

local function got_picture()
	local given_up = nil
	if seek_running then
		given_up = seek_running.after
		seek_shown = { time = seek_running.time, exact = seek_running.exact, motion = seek_running.motion }
		seek_running = nil
	end
	-- The first picture after a seek given up may be that seek's: not drawn if that place is far from the pointer.
	if given_up and show_thumbnail and not script_name and last_seek_time
		and given_up ~= last_seek_time and px_apart(given_up, last_seek_time) > near_px then
		hide()
	else
		show_or_hide(last_seek_time, script_name)
	end
	next_seek()
end

local function request_seek(time)
	local running = seek_running
	if running and running.exact and not running.spawn and running.time ~= time then
		-- A picture already written is the running seek's; any later one is the new seek's.
		if check_new_thumb() then
			got_picture()
		elseif seek_running == running then
			seek_running = nil
		end
	end
	next_seek()
end

file_timer = mp.add_periodic_timer(file_check_period, function()
	if check_new_thumb() then
		got_picture()
	elseif seek_running and mp.get_time() - seek_running.at > seek_running.lost_after then
		-- Given up (a command the thumbnailer never got, or a very slow line): the pointer's place again.
		local given_up = seek_running.time
		seek_running = nil
		next_seek()
		if seek_running then
			seek_running.after = given_up
		end
	end
	-- Local change: it looks only while a picture is due (seek).
	if not seek_running then
		file_timer:kill()
	end
end)
file_timer:kill()

local function clear()
	file_timer:kill()
	if options.quit_after_inactivity > 0 then
		if show_thumbnail or activity_timer:is_enabled() then
			activity_timer:kill()
		end
		activity_timer:resume()
	end
	last_seek_time = nil
	show_thumbnail = false
	last_x = nil
	last_y = nil
	if script_name then
		return
	end
	if pre_0_30_0 then
		mp.command_native({ 'overlay-remove', options.overlay_id })
	else
		mp.command_native_async({ 'overlay-remove', options.overlay_id }, function() end)
	end
end

local function quit()
	activity_timer:kill()
	if show_thumbnail then
		activity_timer:resume()
		return
	end
	run('quit')
	spawned = false
	real_w, real_h = nil, nil
	clear()
end

activity_timer = mp.add_timeout(options.quit_after_inactivity, quit)
activity_timer:kill()

local function thumb(time, r_x, r_y, script)
	if disabled then
		return
	end

	time = tonumber(time)
	if time == nil then
		return
	end

	if r_x == '' or r_y == '' then
		x, y = nil, nil
	else
		x, y = math.floor(r_x + 0.5), math.floor(r_y + 0.5)
	end

	script_name = script
	-- Local change: a jump starts a new movement (fits).
	if time ~= last_seek_time and (not last_seek_time or px_apart(last_seek_time, time) > near_px) then
		motion = motion + 1
	end
	if last_x ~= x or last_y ~= y or not show_thumbnail then
		show_thumbnail = true
		last_x, last_y = x, y
		-- Local change: the last picture only where it belongs (request_seek).
		show_or_hide(time, script)
	end

	if options.quit_after_inactivity > 0 then
		if show_thumbnail or activity_timer:is_enabled() then
			activity_timer:kill()
		end
		activity_timer:resume()
	end

	if time == last_seek_time then
		return
	end
	last_seek_time = time
	if not spawned then
		spawn(time)
	end
	request_seek(time)
	if not file_timer:is_enabled() then
		file_timer:resume()
	end
end

local function watch_changes()
	if not dirty or not properties['video-out-params'] then
		return
	end
	dirty = false

	local old_w = effective_w
	local old_h = effective_h

	calc_dimensions()

	local vf_reset = vf_string(filters_reset)
	local rotate = properties['video-rotate'] or 0

	local resized = old_w ~= effective_w
		or old_h ~= effective_h
		or last_vf_reset ~= vf_reset
		or (last_rotate % 180) ~= (rotate % 180)
		or par ~= last_par
		or last_crop ~= properties['video-crop']

	if resized then
		last_rotate = rotate
		info(effective_w, effective_h)
	elseif last_has_vid ~= has_vid and has_vid ~= 0 then
		info(effective_w, effective_h)
	end

	if spawned then
		if resized then
			-- mpv doesn't allow us to change output size
			local seek_time = last_seek_time
			run('quit')
			clear()
			spawned = false
			spawn(seek_time or mp.get_property_number('time-pos', 0))
			file_timer:resume()
		else
			if rotate ~= last_rotate then
				run('set video-rotate ' .. rotate)
			end
			local vf_runtime = vf_string(filters_runtime)
			if vf_runtime ~= last_vf_runtime then
				run('vf set ' .. vf_string(filters_all, true))
				last_vf_runtime = vf_runtime
			end
		end
	else
		last_vf_runtime = vf_string(filters_runtime)
	end

	last_vf_reset = vf_reset
	last_rotate = rotate
	last_par = par
	last_crop = properties['video-crop']
	last_has_vid = has_vid

	if not spawned and not disabled and options.spawn_first and resized then
		spawn(mp.get_property_number('time-pos', 0))
		file_timer:resume()
	end
end

local function update_property(name, value)
	properties[name] = value
end

local function update_property_dirty(name, value)
	properties[name] = value
	dirty = true
	if name == 'tone-mapping' then
		last_tone_mapping = nil
	end
end

local function update_tracklist(name, value)
	-- current-tracks shim
	for _, track in ipairs(value) do
		if track.type == 'video' and track.selected then
			properties['current-tracks/video'] = track
			return
		end
	end
end

local function sync_changes(prop, val)
	update_property(prop, val)
	if val == nil then
		return
	end

	if type(val) == 'boolean' then
		if prop == 'vid' then
			has_vid = 0
			last_has_vid = 0
			info(effective_w, effective_h)
			clear()
			return
		end
		val = val and 'yes' or 'no'
	end

	if prop == 'vid' then
		has_vid = 1
	end

	-- Local change: own_variant (stream_load); a chunk of this mpv's cache has only the track it plays (source_load).
	if not spawned or (prop == 'vid' and own_variant) or source then
		return
	end

	run('set ' .. prop .. ' ' .. val)
	dirty = true
end

-- Local change: a file's chunks go with it (stream_cache); the thumbnailer, which had one open, ended with the file.
local function end_chunks()
	file_serial = file_serial + 1
	if cache_timer then
		cache_timer:kill()
		cache_timer = nil
	end
	remove_chunks()
	remove_leftovers()
	net_load = nil
	chunk_secs, chunk_min, chunk_failures = 30, 4, 0
end

local function file_load()
	clear()
	spawned = false
	real_w, real_h = nil, nil
	last_real_w, last_real_h = nil, nil
	last_tone_mapping = nil
	last_seek_time = nil
	seek_running, seek_shown = nil, nil
	if info_timer then
		info_timer:kill()
		info_timer = nil
	end
	end_chunks()

	calc_dimensions()
	info(effective_w, effective_h)
end

local function shutdown()
	run('quit')
	remove_thumbnail_files()
	-- Local change: what the thumbnailer still holds open stays for the next mpv's sweep (stream_cache).
	end_chunks()
	if chunk_lock then
		chunk_lock()
	end
	if os_name ~= 'windows' then
		os.remove(options.socket)
		os.remove(options.socket .. '.run')
	end
end

local function on_duration(prop, val)
	duration = val
	allow_fast_seek = (val or 30) >= 30
end

mp.observe_property('current-tracks/video', 'native', function(name, value)
	if pre_0_33_0 then
		mp.unobserve_property(update_tracklist)
		pre_0_33_0 = false
	end
	update_property(name, value)
end)

mp.observe_property('track-list', 'native', update_tracklist)
mp.observe_property('display-hidpi-scale', 'native', update_property_dirty)
mp.observe_property('video-out-params', 'native', update_property_dirty)
mp.observe_property('video-params', 'native', update_property_dirty)
mp.observe_property('vf', 'native', update_property_dirty)
mp.observe_property('tone-mapping', 'native', update_property_dirty)
mp.observe_property('demuxer-via-network', 'native', update_property)
mp.observe_property('stream-open-filename', 'native', update_property)
mp.observe_property('macos-app-activation-policy', 'native', update_property)
mp.observe_property('current-vo', 'native', update_property)
mp.observe_property('video-rotate', 'native', update_property)
mp.observe_property('video-crop', 'native', update_property)
mp.observe_property('path', 'native', update_property)
mp.observe_property('vid', 'native', sync_changes)
mp.observe_property('edition', 'native', sync_changes)
mp.observe_property('duration', 'native', on_duration)

mp.register_script_message('thumb', thumb)
mp.register_script_message('clear', clear)

mp.register_event('file-loaded', file_load)
mp.register_event('end-file', end_chunks)
mp.register_event('shutdown', shutdown)

mp.register_idle(watch_changes)
