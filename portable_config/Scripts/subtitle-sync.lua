-- subtitle-sync.lua
-- Subtitle & audio sync on a zoomed timeline (key t, the uosc sync button, or
-- the Subtitles / Audio menus). A port of FastStream's resync tool
-- (github.com/Andrews54757/FastStream, chrome/player/ui/subtitles/
-- SubtitleSyncer.mjs + FineTimeControls.mjs): a strip of the timeline around
-- the playhead, 30 s wide by default, with
--   - a time row (ticks, the playhead's time),
--   - an AUDIO row: the sound's loudness over time, so speech shows as blobs,
--   - a SUBTITLE row: every line as a block from its start to its end,
-- so the blocks can be lined up with the speech by eye, like FastStream's.
--
-- Mouse (inside the panel only - outside it mpv and uosc work as usual):
--   drag the subtitle row   shift the subtitles (sub-delay), the blocks follow
--   drag the audio row      shift the sound (audio-delay)
--   drag the time row       scrub (pauses while dragging)
--   click                   jump there; on a subtitle block: to its start
--   wheel                   +-0.05 s on the row under the pointer; zoom on the time row
-- Keys while open: Left/Right subtitles -+0.05 s, Shift+Left/Right audio -+0.05 s,
-- Enter (or t) keeps both, Esc puts both back to what they were when it opened.
--
-- Where the data comes from (all measured 2026-09-27, see AGENTS.md):
--   - Audio: a second mpv (mpv.exe itself, --no-config, no window, no sound)
--     decodes 30 s of the selected audio track around the view and prints its
--     loudness every 20 ms (lavfi astats -> ametadata). It uses the same
--     demuxer and timeline as the player, so a beep at 3.00 s in the file is
--     drawn at 3.00 s - also for mkv/mp4 whose audio starts later than the
--     video and MPEG-TS with a non-zero start (checked: identical to a
--     playing mpv with the video on). Speech band only (200 Hz - 4 kHz),
--     and on 5.1 the centre channel, where films put the dialogue. ~0.2 s per
--     30 s of a local film; a stream is fetched again for it (same headers).
--   - Subtitles: mpv's `sub-lines` (the lines in memory, times without
--     sub-delay). For an external file (.srt/.ass/.vtt..., also a URL) that is
--     every line, parsed by mpv itself. For a track INSIDE the video it is only
--     what has been read so far (a seek drops the rest), so an embedded text
--     track is extracted in full with ffmpeg (next to mpv.exe or on PATH).
--     Without ffmpeg (not shipped: the row says where to put one), and for
--     tracks inside a stream, the row collects the lines as playback reads
--     them (a few seconds ahead); picture subtitles
--     (PGS/DVD) have no text list, so their lines appear as they are shown
--     (sub-start/sub-end).
-- FastStream's extras that are not ported: its voice-activity model (an ONNX
-- network in the browser) - the speech band is the stand-in - and its
-- per-line editor (subEditMode).

local utils = require('mp.utils')
local msg = require('mp.msg')
local options = require('mp.options')
local assdraw = require('mp.assdraw')

local opts = {
	-- ffmpeg for embedded subtitles: empty = ffmpeg.exe next to mpv.exe, else PATH
	ffmpeg = '',
	-- seconds the timeline shows (the wheel on the time row zooms 5-180 s)
	view_seconds = 30,
}
local ffmpeg_exe = nil -- nil = not looked for yet, false = none
local view -- seconds shown, set below
options.read_options(opts, 'subtitle_sync', function(changed)
	if changed.ffmpeg then
		ffmpeg_exe = nil -- look again
	end
	if changed.view_seconds then
		view = math.min(math.max(tonumber(opts.view_seconds) or 30, 5), 180)
	end
end)

local HARD_LIMIT = 300 -- clamp for both delays
local NUDGE = 0.05
local ENV_RATE = 50 -- loudness values per second (20 ms each)
local CHUNK = 30 -- seconds of audio per analyser run
local MIN_VIEW, MAX_VIEW = 5, 180
local SECTION = 'subtitle_sync_panel'

-- notify.lua's design: black box, white title, grey detail, sky-blue accent.
-- Colours are &HBBGGRR&. Sizes are in 720-line units, scaled with the window.
local BOX = '000000'
local WHITE, GREY, DIM = 'FFFFFF', 'B4B4B4', '6E6E6E'
local ACCENT = 'FFC24C' -- RGB(76,194,255), a row while it is dragged
local LANE = '141414' -- row backgrounds
local WAVE = 'D29B5A' -- RGB(90,155,210)
local CUE, CUE_NOW = '363636', '5A5A5A' -- subtitle blocks; the one on screen now
local IMAGE_CODECS = { hdmv_pgs_subtitle = true, dvd_subtitle = true, dvb_subtitle = true, xsub = true }

local active = false
local overlay = nil
local timer = nil
view = math.min(math.max(tonumber(opts.view_seconds) or 30, MIN_VIEW), MAX_VIEW)
local start_sub, start_audio = 0, 0
local drag = nil -- { row, x, value | time/target/was_paused, moved }
local geom = nil -- the last layout
local bottom_ui, bottom_key = nil, '' -- user-data/uosc/bottom-ui (uosc's controls row, to sit above it)
local last_key, last_area, last_published = nil, nil, nil

local function clamp(v, lo, hi)
	return v < lo and lo or (v > hi and hi or v)
end

local function trim(s)
	return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

local function get_delay(prop)
	return mp.get_property_number(prop, 0) or 0
end

local function set_delay(prop, v)
	mp.set_property_number(prop, math.floor(clamp(v, -HARD_LIMIT, HARD_LIMIT) * 1000 + 0.5) / 1000)
end

local function exe_dir()
	return mp.command_native({ 'expand-path', '~~exe_dir/' }) or ''
end

local function is_local(path)
	return path and not path:find('://', 1, true)
end

-- ---- subtitles: the lines of the selected track -----------------------------------

-- Text into an ASS event: a backslash gets a zero-width no-break space after
-- it (as mpv's osc.lua does), braces are escaped.
local function ass_escape(s)
	return (s:gsub('\\', '\\\239\187\191'):gsub('{', '\\{'):gsub('}', '\\}'):gsub('[\r\n]+', ' '))
end

local function clean_text(s)
	s = s:gsub('{[^}]*}', ''):gsub('\\[Nn]', ' '):gsub('\\h', ' ')
	return trim((s:gsub('%s+', ' ')))
end

-- An ASS drawing (a typesetting shape) left as text once its tags are gone:
-- "m 0 0 l 100 0 ..." is not a line anyone reads.
local function is_drawing(s)
	return s:match('^m%s+%-?%d') and not s:find('[^mnlbspc%d%s%.%-]')
end

-- h:mm:ss.cc
local function parse_time(str)
	local h, m, s = str:match('^%s*(%d+):(%d+):([%d%.]+)%s*$')
	s = h and tonumber(s) -- nil for "01..2": a Lua error here would end the whole tool
	if not s then
		return nil
	end
	return tonumber(h) * 3600 + tonumber(m) * 60 + s
end

local ASS_FIELDS = { 'layer', 'start', 'end', 'style', 'name', 'marginl', 'marginr', 'marginv', 'effect', 'text' }

-- ffmpeg's ASS output: the Dialogue lines of [Events], in the order its Format
-- line gives. Drawings (\p1 typesetting shapes) are skipped.
local function parse_ass(content)
	local cues, fields, in_events = {}, ASS_FIELDS, false
	for line in (content .. '\n'):gmatch('([^\n]*)\n') do
		line = line:gsub('\r$', '')
		local section = line:match('^%s*%[(.-)%]%s*$')
		if section then
			in_events = section:lower() == 'events'
		elseif in_events then
			local kind, rest = line:match('^(%a+):%s*(.*)$')
			if kind == 'Format' then
				fields = {}
				for f in rest:gmatch('[^,]+') do
					fields[#fields + 1] = trim(f):lower()
				end
			elseif kind == 'Dialogue' then
				local values, pos = {}, 1
				for i = 1, #fields - 1 do
					local comma = rest:find(',', pos, true)
					if not comma then
						break
					end
					values[i] = rest:sub(pos, comma - 1)
					pos = comma + 1
				end
				values[#fields] = rest:sub(pos)
				local rec = {}
				for i, f in ipairs(fields) do
					rec[f] = values[i]
				end
				local raw = rec.text or ''
				if not raw:find('{[^}]*\\p[1-9]') then
					cues[#cues + 1] = {
						s = parse_time(rec.start or ''),
						e = parse_time(rec['end'] or ''),
						text = clean_text(raw),
					}
				end
			end
		end
	end
	return cues
end

-- Sorted by start, empty, broken and duplicate lines dropped; `longest` bounds
-- the binary search for the lines in view.
local function finish_cues(list)
	local cues, longest, have = {}, 0, {}
	for _, cue in ipairs(list) do
		local id = cue.s and string.format('%.3f|%s', cue.s, cue.text)
		if cue.s and cue.e and cue.e > cue.s and cue.text ~= '' and not is_drawing(cue.text) and not have[id] then
			have[id] = true
			cues[#cues + 1] = cue
			longest = math.max(longest, cue.e - cue.s)
		end
	end
	table.sort(cues, function(a, b)
		return a.s < b.s
	end)
	cues.longest = longest
	return cues
end

-- mpv's sub-lines: the lines of the selected track in memory, times without
-- sub-delay; nil for picture subtitles. A line without an end gets 2 s.
local function mpv_lines()
	local lines = mp.get_property_native('sub-lines')
	if type(lines) ~= 'table' then
		return nil
	end
	local list = {}
	for _, line in ipairs(lines) do
		if type(line.start) == 'number' then
			list[#list + 1] = { s = line.start, e = line['end'] or line.start + 2, text = clean_text(line.text or '') }
		end
	end
	return list
end

local function find_ffmpeg()
	if ffmpeg_exe == nil then
		ffmpeg_exe = false
		local candidates = opts.ffmpeg ~= '' and { opts.ffmpeg }
			or { utils.join_path(exe_dir(), 'ffmpeg.exe'), 'ffmpeg' }
		for _, exe in ipairs(candidates) do
			local r = mp.command_native({
				name = 'subprocess',
				args = { exe, '-hide_banner', '-version' },
				capture_stdout = true,
				capture_stderr = true,
				playback_only = false,
			})
			if r and r.status == 0 then
				ffmpeg_exe = exe
				break
			end
		end
	end
	return ffmpeg_exe or nil
end

-- subs.status: 'none' (no track) | 'loading' | 'ready' (every line known) |
-- 'live' (lines collected as playback reads them; subs.note says why)
local subs = { status = 'none', cues = { longest = 0 }, version = 0 }
local sub_cache = {} -- track key -> cues, for the current file
local seen = {} -- track key -> { [start ms .. text] = line } collected in 'live' mode
local sub_job = nil
local last_collect = 0

local function sub_track()
	local track = mp.get_property_native('current-tracks/sub')
	if type(track) ~= 'table' then
		return nil
	end
	local key = table.concat({
		mp.get_property('path', ''),
		tostring(track.id),
		track['external-filename'] or '',
		track.codec or '',
	}, '|')
	return track, key
end

local function subs_set(key, status, cues, note)
	if subs.key ~= key then
		return
	end
	subs.status, subs.cues, subs.note = status, cues, note
	subs.version = subs.version + 1
	if status == 'ready' then
		sub_cache[key] = cues
	end
end

-- 'live': merges what mpv holds now into what was collected before (a seek
-- drops mpv's older lines, the tool keeps them)
local function collect(key, list)
	local store = seen[key] or {}
	seen[key] = store
	local added = false
	for _, line in ipairs(list or {}) do
		local id = string.format('%.3f|%s', line.s, line.text)
		if not store[id] then
			store[id] = line
			added = true
		end
	end
	if added or subs.status ~= 'live' then
		local all = {}
		for _, line in pairs(store) do
			all[#all + 1] = line
		end
		return finish_cues(all)
	end
	return nil
end

local function go_live(key, note)
	subs_set(key, 'live', collect(key, mpv_lines()) or subs.cues, note)
end

local function load_subs()
	local track, key = sub_track()
	if not track then
		subs = { status = 'none', cues = { longest = 0 }, version = subs.version + 1 }
		return
	end
	if subs.key == key then
		return
	end
	if sub_job then
		mp.abort_async_command(sub_job)
		sub_job = nil
	end
	subs = { key = key, status = 'loading', cues = { longest = 0 }, version = subs.version + 1 }
	if sub_cache[key] then
		subs_set(key, 'ready', sub_cache[key])
		return
	end

	local path = mp.get_property('path')
	if track.external then
		-- mpv read the whole file when it added the track
		local list = mpv_lines()
		if list then
			subs_set(key, 'ready', finish_cues(list))
		else
			go_live(key, 'picture subtitles: lines appear as they are shown')
		end
		return
	elseif IMAGE_CODECS[track.codec or ''] then
		go_live(key, 'picture subtitles: lines appear as they are shown')
		return
	elseif not is_local(path) or not track['ff-index'] then
		go_live(key, 'a track inside a stream: lines appear as they are read')
		return
	end
	local ffmpeg = find_ffmpeg()
	if not ffmpeg then
		-- the hint: ffmpeg is not shipped (his decision, 2026-10-10); one put there is found
		go_live(key, 'no ffmpeg: lines appear as they are read · put ffmpeg.exe next to mpv.exe to read them all')
		return
	end
	sub_job = mp.command_native_async({
		name = 'subprocess',
		args = {
			ffmpeg,
			'-nostdin',
			'-hide_banner',
			'-v',
			'error',
			'-i',
			path,
			'-map',
			'0:' .. track['ff-index'],
			'-c:s',
			'ass',
			'-f',
			'ass',
			'-',
		},
		capture_stdout = true,
		capture_stderr = true,
	}, function(ok, res)
		sub_job = nil
		local cues = ok and res and res.status == 0 and finish_cues(parse_ass(res.stdout or '')) or nil
		if cues and #cues > 0 then
			subs_set(key, 'ready', cues)
		else
			msg.warn('reading the subtitle lines with ffmpeg failed: ' .. tostring(res and (res.stderr or res.error)))
			go_live(key, 'lines appear as they are read')
		end
	end)
end

-- 'live' mode, every half second while the tool is open
local function collect_live()
	if subs.status ~= 'live' or mp.get_time() - last_collect < 0.5 then
		return
	end
	last_collect = mp.get_time()
	local cues = collect(subs.key, mpv_lines())
	if cues then
		subs.cues = cues
		subs.version = subs.version + 1
	end
end

-- Picture subtitles have no sub-lines: each line is remembered as it is shown
-- (sub-start/sub-end are without sub-delay, like sub-lines).
mp.observe_property('sub-start', 'number', function(_, start)
	local stop = mp.get_property_number('sub-end')
	if not start or not stop or subs.status ~= 'live' or mp.get_property_native('sub-lines') then
		return
	end
	local cues = collect(subs.key, { { s = start, e = stop, text = '(picture)' } })
	if cues then
		subs.cues = cues
		subs.version = subs.version + 1
	end
end)

-- The lines overlapping [lo, hi] (times without sub-delay).
local function cues_between(lo, hi)
	local cues, out = subs.cues, {}
	local a, b = 1, #cues + 1
	local from = lo - (cues.longest or 0)
	while a < b do
		local mid = math.floor((a + b) / 2)
		if cues[mid].s < from then
			a = mid + 1
		else
			b = mid
		end
	end
	for i = a, #cues do
		local cue = cues[i]
		if cue.s > hi then
			break
		end
		if cue.e >= lo then
			out[#out + 1] = cue
		end
	end
	return out
end

-- ---- audio: loudness of the selected track -------------------------------------

-- audio.bins[n] = loudness (dB) of the 20 ms from n/50 s on, in the player's
-- timeline (without audio-delay). audio.chunks[i] = 'pending'|'done'|'failed'
-- for [i*30, i*30+30).
local audio = { bins = {}, chunks = {}, count = 0, version = 0, gen = 0, low = -55, high = -15, failures = 0 }

local function audio_source()
	local track = mp.get_property_native('current-tracks/audio')
	if type(track) ~= 'table' then
		return nil
	end
	local file, aid = mp.get_property('stream-open-filename'), track.id
	if not file or file == '' then
		file = mp.get_property('path')
	end
	if track.external and track['external-filename'] then
		file, aid = track['external-filename'], 1
	end
	if not file then
		return nil
	end
	return { file = file, aid = aid, channels = track['demux-channel-count'] or 2, key = file .. '|' .. tostring(aid) }
end

local function reset_audio(key)
	if audio.running then
		mp.abort_async_command(audio.running)
	end
	audio = {
		key = key,
		bins = {},
		chunks = {},
		count = 0,
		version = audio.version + 1,
		gen = audio.gen + 1,
		low = -55,
		high = -15,
		failures = 0,
		no_centre = audio.key == key and audio.no_centre or nil,
	}
end

-- The loudness range drawn: from the 10th to the 99.5th percentile of what was
-- measured (digital silence left out), at least 24 dB - so a quiet anime mix
-- and a loud film both fill the row, and a clip of beeps in digital silence
-- (the tests) still shows its beeps.
local function renormalize()
	local values = {}
	for _, v in pairs(audio.bins) do
		if v > -100 then
			values[#values + 1] = v
		end
	end
	if #values < 50 then
		return
	end
	table.sort(values)
	local low = values[math.max(1, math.floor(#values * 0.10))]
	local high = values[math.max(1, math.floor(#values * 0.995))]
	audio.low, audio.high = math.max(math.min(low, high - 24), -90), high
end

local function add_bins(out)
	local n = 0
	for pts, value in out:gmatch('pts_time:(%S+)%s+lavfi%.astats%.Overall%.RMS_level=(%S+)') do
		local t, v = tonumber(pts), tonumber(value)
		if t then
			if not v or v ~= v or v < -120 then
				v = -120 -- "-inf": digital silence
			end
			local bin = math.floor(t * ENV_RATE + 0.5)
			if not audio.bins[bin] then
				audio.count = audio.count + 1
			end
			audio.bins[bin] = v
			n = n + 1
		end
	end
	return n
end

local function analyser_args(src, t0, t1)
	local channel = (src.channels >= 5 and not audio.no_centre) and 'pan=mono|c0=FC' or 'aformat=channel_layouts=mono'
	local graph = table.concat({
		channel,
		'highpass=f=200',
		'aresample=8000',
		'asetnsamples=n=160:p=0',
		'astats=metadata=1:reset=1:measure_perchannel=none:measure_overall=RMS_level',
		'ametadata=mode=print:key=lavfi.astats.Overall.RMS_level:file=-',
	}, ',')
	local args = {
		utils.join_path(exe_dir(), 'mpv.exe'),
		'--no-config',
		'--load-scripts=no',
		'--ytdl=no',
		'--osc=no',
		'--really-quiet',
		'--idle=no',
		'--keep-open=no',
		'--force-window=no',
		'--vo=null',
		'--ao=null',
		'--ao-null-untimed=yes',
		'--untimed',
		'--vid=no',
		'--sid=no',
		'--audio-display=no',
		'--audio-file-auto=no',
		'--aid=' .. tostring(src.aid),
		string.format('--start=%.3f', t0),
		string.format('--end=%.3f', t1),
		'--af=lavfi=[' .. graph .. ']',
	}
	-- a stream: the same headers the player used (the FastStream host and
	-- ytdl_hook set them)
	for _, field in ipairs(mp.get_property_native('http-header-fields') or {}) do
		args[#args + 1] = '--http-header-fields-append=' .. field
	end
	for _, name in ipairs({ 'user-agent', 'referrer', 'cookies-file' }) do
		local value = mp.get_property(name)
		if value and value ~= '' then
			args[#args + 1] = '--' .. name .. '=' .. value
		end
	end
	if mp.get_property_native('cookies') then
		args[#args + 1] = '--cookies=yes'
	end
	args[#args + 1] = '--'
	args[#args + 1] = src.file
	return args
end

local function center()
	if drag and drag.row == 'time' and drag.moved then
		return drag.target
	end
	return mp.get_property_number('time-pos') or 0
end

-- Starts the analyser on the missing chunk nearest the middle of the view
-- (one screen of margin each side), one run at a time.
local function want_chunks()
	if not active or audio.running or audio.error then
		return
	end
	local src = audio_source()
	if not src then
		return
	end
	if src.key ~= audio.key then
		reset_audio(src.key)
	end
	local c = center() - get_delay('audio-delay')
	local lo, hi = math.max(0, c - view), c + view
	local duration = mp.get_property_number('duration')
	if duration then
		hi = math.min(hi, duration)
	end
	local best, best_d = nil, nil
	for i = math.floor(lo / CHUNK), math.floor(hi / CHUNK) do
		if not audio.chunks[i] then
			local d = math.abs((i + 0.5) * CHUNK - c)
			if not best_d or d < best_d then
				best, best_d = i, d
			end
		end
	end
	if not best then
		return
	end
	local gen, i = audio.gen, best
	audio.chunks[i] = 'pending'
	audio.running = mp.command_native_async({
		name = 'subprocess',
		args = analyser_args(src, i * CHUNK, (i + 1) * CHUNK + 0.1),
		capture_stdout = true,
		capture_stderr = true,
	}, function(ok, res)
		if gen ~= audio.gen then
			return -- aborted, or the file/track changed meanwhile
		end
		audio.running = nil
		if ok and res and add_bins(res.stdout or '') > 0 then
			audio.chunks[i] = 'done'
			renormalize()
		else
			audio.chunks[i] = 'failed'
			audio.failures = audio.failures + 1
			msg.warn(
				string.format(
					'audio analysis of %d-%d s failed: %s',
					i * CHUNK,
					(i + 1) * CHUNK,
					tostring(res and res.stderr)
				)
			)
			if src.channels >= 5 and not audio.no_centre then
				-- a layout without a centre channel: downmix instead, try again
				audio.no_centre = true
				audio.chunks = {}
			elseif audio.count == 0 and audio.failures >= 3 then
				audio.error = 'audio preview unavailable'
			end
		end
		audio.version = audio.version + 1
		want_chunks()
	end)
end

-- 0..1 for the drawing, nil where nothing is measured yet
local function level(bin)
	local v = audio.bins[bin]
	if not v then
		return nil
	end
	return clamp((v - audio.low) / (audio.high - audio.low), 0, 1)
end

-- For tests and debugging: where the sound gets loud (half of the drawn range),
-- in the player's timeline. Worked out again only when new audio arrived.
local onsets_cache = { version = -1, list = {} }
local function onsets()
	if onsets_cache.version == audio.version then
		return onsets_cache.list
	end
	local list, bins = {}, {}
	for bin in pairs(audio.bins) do
		bins[#bins + 1] = bin
	end
	table.sort(bins)
	local was = true
	for _, bin in ipairs(bins) do
		local loud = (level(bin) or 0) >= 0.5
		if loud and not was and #list < 40 then
			list[#list + 1] = bin / ENV_RATE
		end
		was = loud
	end
	onsets_cache = { version = audio.version, list = list }
	return list
end

-- ---- drawing ----------------------------------------------------------------------

local function layout()
	local w, h = mp.get_osd_size()
	if not w or not h or w <= 0 or h <= 0 then
		w, h = 1280, 720
	end
	-- The panel sizes with uosc's interface scale (its user-data hook, falling
	-- back to the window height like notify.lua does before uosc reports) - the
	-- panel matches uosc's own elements instead of shrinking with the window.
	local k = mp.get_property_number('user-data/uosc/ui-scale', h / 720)
	local function px(v)
		return math.floor(v * k + 0.5)
	end
	-- right above uosc's controls (their layout position, shown or not, so the
	-- panel never jumps when uosc fades)
	local bottom = h - px(100)
	if bottom_ui and bottom_ui.height == h and bottom_ui.controls_top then
		bottom = bottom_ui.controls_top
	end
	local g = { w = w, h = h, k = k, px = px, pad = px(10) }
	g.x0, g.x1 = px(14), w - px(14)
	g.y1 = bottom - px(8)
	g.subs = { y1 = g.y1 - g.pad }
	g.subs.y0 = g.subs.y1 - px(38)
	g.audio = { y1 = g.subs.y0 - px(4) }
	g.audio.y0 = g.audio.y1 - px(38)
	g.time = { y1 = g.audio.y0 - px(2) }
	g.time.y0 = g.time.y1 - px(18)
	g.header = { y1 = g.time.y0 - px(6) }
	g.header.y0 = g.header.y1 - px(16)
	g.y0 = g.header.y0 - g.pad
	-- clear of uosc's volume slider where it reaches down to the panel: it is
	-- drawn over the panel and takes the clicks there
	local volume = bottom_ui and bottom_ui.height == h and bottom_ui.volume
	if type(volume) == 'table' and volume.by and volume.by > g.y0 then
		if volume.ax > w / 2 then
			g.x1 = math.min(g.x1, volume.ax - px(8))
		else
			g.x0 = math.max(g.x0, volume.bx + px(8))
		end
	end
	g.tx0 = g.x0 + g.pad + px(84) -- the timeline, right of the row labels
	g.tx1 = g.x1 - g.pad
	g.cx = math.floor((g.tx0 + g.tx1) / 2)
	g.pps = (g.tx1 - g.tx0) / view
	return g
end

-- one filled rectangle; \rDefault first, as uosc and notify.lua do: mpv.conf's
-- osd-box style would box it otherwise
local function rect(x0, y0, x1, y1, color, clip)
	return string.format(
		'{\\rDefault\\an7\\pos(0,0)\\blur0\\bord0\\shad0\\1c&H%s&%s\\p1}m %d %d l %d %d %d %d %d %d{\\p0}',
		color,
		clip or '',
		x0,
		y0,
		x1,
		y0,
		x1,
		y1,
		x0,
		y1
	)
end

-- the panel itself: rounded like uosc's menus and notify.lua's banners
-- (uosc.conf border_radius 6), with the banners' hairline edge (2026-10-02)
local RADIUS = 6
local function panel_box(x0, y0, x1, y1, radius)
	local path = assdraw.ass_new()
	path:round_rect_cw(0, 0, x1 - x0, y1 - y0, radius)
	return string.format(
		'{\\rDefault\\an7\\pos(%d,%d)\\blur0\\bord1\\shad0\\1c&H%s&\\3c&HFFFFFF&\\3a&HE6&\\p%d}%s{\\p0}',
		x0,
		y0,
		BOX,
		path.scale,
		path.text
	)
end

-- Text sizes are multiplied by this: mpv.conf's osd-font (Segoe UI) has a
-- 1.19x taller line box than the Arial the sizes were designed with, and
-- libass sizes text by that box (uosc.conf font_scale, notify.lua: same value).
local FONT_SCALE = 1.19

local function text(x, y, align, size, color, str, clip)
	return string.format(
		'{\\rDefault\\an%d\\pos(%d,%d)\\q2\\blur0\\bord0\\shad0\\fs%d\\1c&H%s&%s}%s',
		align,
		x,
		y,
		math.floor(size * FONT_SCALE + 0.5),
		color,
		clip or '',
		str
	)
end

local function clip(x0, y0, x1, y1)
	return string.format('\\clip(%d,%d,%d,%d)', x0, y0, x1, y1)
end

local function clock(t, decimals)
	local sign = t < 0 and '-' or ''
	-- rounded to what is shown before it is split up: 59.96 s read 0:60.0
	t = decimals and math.floor(math.abs(t) * 10 ^ decimals + 0.5) / 10 ^ decimals or math.abs(t)
	local h, m = math.floor(t / 3600), math.floor(t / 60) % 60
	local s = t - math.floor(t / 60) * 60
	local sec = decimals and string.format('%0' .. (3 + decimals) .. '.' .. decimals .. 'f', s)
		or string.format('%02d', math.floor(s))
	if h > 0 then
		return string.format('%s%d:%02d:%s', sign, h, m, sec)
	end
	return string.format('%s%d:%s', sign, m, sec)
end

-- label step and minor tick step for the zoom level
local STEPS =
	{ { 1, 0.2 }, { 2, 0.5 }, { 5, 1 }, { 10, 2 }, { 15, 5 }, { 30, 5 }, { 60, 10 }, { 120, 30 }, { 300, 60 } }

local function draw_time_row(g, c, ev)
	local px, row = g.px, g.time
	local label_step, minor = 600, 120
	for _, s in ipairs(STEPS) do
		if s[1] * g.pps >= px(70) then
			label_step, minor = s[1], s[2]
			break
		end
	end
	if minor * g.pps < px(6) then
		minor = label_step
	end
	local t_lo = c - (g.cx - g.tx0) / g.pps
	local t_hi = c + (g.tx1 - g.cx) / g.pps
	local path = {}
	for n = math.ceil(math.max(t_lo, 0) / minor), math.floor(t_hi / minor) do
		local t = n * minor
		local x = math.floor(g.cx + (t - c) * g.pps + 0.5)
		local major = math.abs(t / label_step - math.floor(t / label_step + 0.5)) < 1e-6
		local top = row.y1 - (major and px(7) or px(4))
		path[#path + 1] = string.format('m %d %d l %d %d %d %d %d %d', x, top, x + 1, top, x + 1, row.y1, x, row.y1)
		if major and math.abs(x - g.cx) > px(44) then
			ev[#ev + 1] = text(x, row.y0, 8, px(10), GREY, clock(t), clip(g.tx0, row.y0, g.tx1, row.y1))
		end
	end
	if #path > 0 then
		ev[#ev + 1] = string.format(
			'{\\rDefault\\an7\\pos(0,0)\\blur0\\bord0\\shad0\\1c&H%s&%s\\p1}%s{\\p0}',
			DIM,
			clip(g.tx0, row.y0, g.tx1, row.y1),
			table.concat(path, ' ')
		)
	end
end

local function draw_wave(g, c, ev)
	local px, row = g.px, g.audio
	local cy = math.floor((row.y0 + row.y1) / 2)
	local half = (row.y1 - row.y0) / 2 - px(3)
	local delay = get_delay('audio-delay')
	-- columns on a fixed grid of the audio's own time (2 px wide), so the
	-- shape stays put while the view scrolls instead of shimmering
	local dt = 2 / g.pps
	local t_lo = c - delay - (g.cx - g.tx0) / g.pps
	local t_hi = c - delay + (g.tx1 - g.cx) / g.pps
	local contours, top, bottom = {}, {}, {}
	local function flush()
		if #top > 0 then
			local pts = {}
			for i = 1, #top do
				pts[#pts + 1] = top[i]
			end
			for i = #bottom, 1, -1 do
				pts[#pts + 1] = bottom[i]
			end
			contours[#contours + 1] = 'm ' .. pts[1] .. ' l ' .. table.concat(pts, ' ', 2)
		end
		top, bottom = {}, {}
	end
	for n = math.floor(t_lo / dt), math.ceil(t_hi / dt) do
		local b0 = math.floor(n * dt * ENV_RATE)
		local b1 = math.max(b0, math.floor((n + 1) * dt * ENV_RATE) - 1)
		local a = nil
		for b = b0, b1 do
			local v = level(b)
			if v and (not a or v > a) then
				a = v
			end
		end
		if a then
			local x = math.floor(g.cx + ((n + 0.5) * dt + delay - c) * g.pps + 0.5)
			local y = math.max(1, math.floor(a * half + 0.5))
			top[#top + 1] = x .. ' ' .. (cy - y)
			bottom[#bottom + 1] = x .. ' ' .. (cy + y)
		else
			flush()
		end
	end
	flush()
	if #contours > 0 then
		ev[#ev + 1] = string.format(
			'{\\rDefault\\an7\\pos(0,0)\\blur0\\bord0\\shad0\\1c&H%s&%s\\p1}%s{\\p0}',
			WAVE,
			clip(g.tx0, row.y0, g.tx1, row.y1),
			table.concat(contours, ' ')
		)
	end
end

local function draw_cues(g, c, ev)
	local px, row = g.px, g.subs
	local delay = get_delay('sub-delay')
	local now = mp.get_property_number('time-pos') or 0
	local list = cues_between(c - delay - (g.cx - g.tx0) / g.pps, c - delay + (g.tx1 - g.cx) / g.pps)
	-- overlapping lines (signs, two speakers) go on a second lane
	local lane_end, lanes = { -math.huge, -math.huge }, 1
	for _, cue in ipairs(list) do
		if cue.s >= lane_end[1] - 0.001 then
			cue.lane = 1
		elseif cue.s >= lane_end[2] - 0.001 then
			cue.lane = 2
		else
			cue.lane = lane_end[1] <= lane_end[2] and 1 or 2
		end
		lane_end[cue.lane] = math.max(lane_end[cue.lane], cue.e)
		lanes = math.max(lanes, cue.lane)
	end
	local lane_h = (row.y1 - row.y0 - px(4)) / lanes
	local size = lanes > 1 and px(10) or px(11)
	for _, cue in ipairs(list) do
		local x0 = math.floor(g.cx + (cue.s + delay - c) * g.pps + 0.5)
		local x1 = math.max(x0 + 2, math.floor(g.cx + (cue.e + delay - c) * g.pps + 0.5))
		local y0 = math.floor(row.y0 + px(2) + (cue.lane - 1) * lane_h + 0.5)
		local y1 = math.floor(y0 + lane_h - px(2) + 0.5)
		local on_screen = now >= cue.s + delay and now < cue.e + delay
		ev[#ev + 1] = rect(x0, y0, x1 - 1, y1, on_screen and CUE_NOW or CUE, clip(g.tx0, row.y0, g.tx1, row.y1))
		local cx0, cx1 = math.max(x0, g.tx0), math.min(x1 - px(3), g.tx1)
		if cx1 - cx0 > px(8) then
			ev[#ev + 1] = text(
				math.max(x0, g.tx0) + px(4),
				math.floor((y0 + y1) / 2),
				4,
				size,
				WHITE,
				ass_escape(cue.text),
				clip(cx0, y0, cx1, y1)
			)
		end
	end
end

local function row_label(g, row, name, value, dragged, ev)
	local px = g.px
	local color = dragged and ACCENT or (math.abs(value) >= 0.0005 and WHITE or GREY)
	ev[#ev + 1] = text(g.x0 + g.pad, row.y0 + px(3), 7, px(12), WHITE, name)
	ev[#ev + 1] = text(g.x0 + g.pad, row.y0 + px(19), 7, px(12), color, string.format('%+.2f s', value))
end

local function status_text(g, row, str, ev)
	ev[#ev + 1] = text(g.tx1 - g.px(4), math.floor((row.y0 + row.y1) / 2), 6, g.px(10), GREY, ass_escape(str))
end

local function audio_status()
	if audio.error then
		return audio.error
	end
	if not audio_source() then
		return 'no audio track'
	end
	local c = center() - get_delay('audio-delay')
	local state = audio.chunks[math.floor(math.max(c, 0) / CHUNK)]
	if state == nil or state == 'pending' then
		return 'reading the audio…'
	end
	return nil
end

local function subs_status()
	if subs.status == 'none' then
		return 'no subtitles selected'
	elseif subs.status == 'loading' then
		return 'reading the subtitles…'
	elseif subs.status == 'live' then
		return subs.note
	end
	return nil
end

local function render()
	if not overlay then
		return
	end
	local g = layout()
	geom = g
	local px = g.px
	local c = center()
	local sub_delay, audio_delay = get_delay('sub-delay'), get_delay('audio-delay')
	local ev = {}

	ev[#ev + 1] = panel_box(g.x0, g.y0, g.x1, g.y1, px(RADIUS))
	local header_y = math.floor((g.header.y0 + g.header.y1) / 2)
	ev[#ev + 1] = text(g.x0 + g.pad, header_y, 4, px(14), WHITE, 'Subtitle & audio sync')
	ev[#ev + 1] = text(
		g.x1 - g.pad,
		header_y,
		6,
		px(11),
		GREY,
		'drag a row to shift it · click: jump there · wheel: ±0.05 s, zoom on the time row · Enter keep · Esc undo',
		clip(g.x0 + g.pad + px(170), g.header.y0 - px(4), g.x1, g.header.y1 + px(4))
	)

	ev[#ev + 1] = text(g.x0 + g.pad, g.time.y0 + px(3), 7, px(10), GREY, string.format('view %d s', view))
	draw_time_row(g, c, ev)

	ev[#ev + 1] = rect(g.tx0, g.audio.y0, g.tx1, g.audio.y1, LANE)
	row_label(g, g.audio, 'Audio', audio_delay, drag and drag.row == 'audio' and drag.moved, ev)
	draw_wave(g, c, ev)
	local a_status = audio_status()
	if a_status then
		status_text(g, g.audio, a_status, ev)
	end

	ev[#ev + 1] = rect(g.tx0, g.subs.y0, g.tx1, g.subs.y1, LANE)
	row_label(g, g.subs, 'Subtitles', sub_delay, drag and drag.row == 'subs' and drag.moved, ev)
	draw_cues(g, c, ev)
	local s_status = subs_status()
	if s_status then
		status_text(g, g.subs, s_status, ev)
	end

	-- the playhead and its time
	ev[#ev + 1] = rect(g.cx - 1, g.time.y0 + px(14), g.cx + 1, g.subs.y1, WHITE)
	ev[#ev + 1] = rect(g.cx - px(30), g.time.y0, g.cx + px(30), g.time.y0 + px(14), BOX)
	ev[#ev + 1] = text(g.cx, g.time.y0, 8, px(11), WHITE, clock(c, 1))

	overlay.res_x, overlay.res_y = g.w, g.h
	overlay.data = table.concat(ev, '\n')
	overlay:update()

	-- clicks and the wheel are ours only inside the panel
	local area = string.format('%d %d %d %d', g.x0, g.y0, g.x1, g.y1)
	if area ~= last_area then
		last_area = area
		mp.set_mouse_area(g.x0, g.y0, g.x1, g.y1, SECTION)
	end
end

-- user-data/subtitle-sync: the state, for tests and other scripts
local function publish()
	local g = geom
	local state = {
		open = active,
		sub_delay = get_delay('sub-delay'),
		audio_delay = get_delay('audio-delay'),
		view = view,
		subs = subs.status,
		subs_note = subs.note,
		cues = #subs.cues,
		first_cue = subs.cues[1] and subs.cues[1].s or nil,
		audio = audio.error and 'error' or (audio.count > 0 and 'ready' or (audio_source() and 'reading' or 'none')),
		bins = audio.count,
		onsets = active and onsets() or {},
		ffmpeg = ffmpeg_exe and true or false,
	}
	if active and g then
		state.pps = g.pps
		state.cx = g.cx
		state.rows = {}
		for _, name in ipairs({ 'time', 'audio', 'subs' }) do
			state.rows[name] = { x0 = g.tx0, x1 = g.tx1, y0 = g[name].y0, y1 = g[name].y1 }
		end
		state.panel = { x0 = g.x0, y0 = g.y0, x1 = g.x1, y1 = g.y1 }
	end
	local json = utils.format_json(state)
	if json ~= last_published then
		last_published = json
		mp.set_property_native('user-data/subtitle-sync', state)
	end
end

local function tick()
	want_chunks()
	collect_live()
	local w, h = mp.get_osd_size()
	local key = table.concat({
		string.format('%.3f', center()),
		get_delay('sub-delay'),
		get_delay('audio-delay'),
		view,
		audio.version,
		subs.version,
		subs.status,
		tostring(w) .. 'x' .. tostring(h),
		bottom_key,
		drag and (drag.row .. tostring(drag.moved)) or '',
	}, '|')
	if key ~= last_key then
		last_key = key
		render()
		publish()
	end
end

-- ---- input ------------------------------------------------------------------------

local function mouse()
	local pos = mp.get_property_native('mouse-pos') or {}
	return pos.x or 0, pos.y or 0
end

local function row_at(x, y)
	local g = geom
	if not g or x < g.x0 or x > g.x1 then
		return nil
	end
	for _, name in ipairs({ 'time', 'audio', 'subs' }) do
		local row = g[name]
		if y >= row.y0 - g.px(2) and y <= row.y1 + g.px(2) then
			return name
		end
	end
	return nil
end

local function seek(t, exact)
	mp.commandv('seek', string.format('%.3f', math.max(t, 0)), exact and 'absolute+exact' or 'absolute+keyframes')
end

local function on_press()
	local x, y = mouse()
	local row = row_at(x, y)
	if not row then
		return
	end
	drag = { row = row, x = x, moved = false }
	if row == 'subs' then
		drag.value = get_delay('sub-delay')
	elseif row == 'audio' then
		drag.value = get_delay('audio-delay')
	else
		drag.time = center()
		drag.target = drag.time
	end
end

local function on_move()
	local d, g = drag, geom
	if not d or not g then
		return
	end
	local x = mouse()
	local dx = x - d.x
	if not d.moved then
		if math.abs(dx) < g.px(4) then
			return
		end
		d.moved = true
		if d.row == 'time' then
			d.was_paused = mp.get_property_native('pause')
			mp.set_property_native('pause', true)
		end
	end
	local dt = dx / g.pps
	if d.row == 'subs' then
		set_delay('sub-delay', d.value + dt)
	elseif d.row == 'audio' then
		set_delay('audio-delay', d.value + dt)
	else
		-- the strip follows the pointer: dragging left moves forward in time
		d.target = math.max(0, d.time - dt)
		local duration = mp.get_property_number('duration')
		if duration then
			d.target = math.min(d.target, duration)
		end
		seek(d.target, true)
	end
	-- drawn by the next tick: a fast mouse sends hundreds of moves a second
end

local function on_release()
	on_move() -- the pointer's last position, in case its change is still queued
	local d, g = drag, geom
	drag = nil
	if not d or not g then
		return
	end
	if d.moved then
		if d.row == 'time' then
			seek(d.target, true)
			if not d.was_paused then
				mp.set_property_native('pause', false)
			end
		end
	else
		-- a click: jump there, on a subtitle block to its start
		local x = mouse()
		local t = center() + (x - g.cx) / g.pps
		if d.row == 'subs' then
			local delay = get_delay('sub-delay')
			for _, cue in ipairs(cues_between(t - delay, t - delay)) do
				t = cue.s + delay
				break
			end
		end
		seek(t, true)
	end
	tick()
end

local function on_wheel(dir)
	local row = row_at(mouse())
	if row == 'subs' then
		set_delay('sub-delay', get_delay('sub-delay') + dir * NUDGE)
	elseif row == 'audio' then
		set_delay('audio-delay', get_delay('audio-delay') + dir * NUDGE)
	elseif row == 'time' then
		view = clamp(dir > 0 and view / 1.25 or view * 1.25, MIN_VIEW, MAX_VIEW)
	end
	tick()
end

mp.set_key_bindings({
	{
		'mbtn_left',
		function() -- one combined press (no separate down/up)
			on_press()
			on_release()
		end,
		on_press,
		on_release,
	},
	{ 'mbtn_left_dbl', function() end }, -- not fullscreen (input.conf) inside the panel
	{
		'wheel_up',
		function()
			on_wheel(1)
		end,
	},
	{
		'wheel_down',
		function()
			on_wheel(-1)
		end,
	},
}, SECTION, 'force')

-- ---- open / close -----------------------------------------------------------------

-- uosc toolbar button (button:subtitle_sync in uosc.conf's controls list)
local function update_button()
	local json = utils.format_json({
		icon = 'sync',
		active = active,
		tooltip = 'Subtitle & audio sync (t)',
		command = { 'script-message-to', 'subtitle_sync', 'toggle' },
	})
	if json then
		mp.commandv('script-message-to', 'uosc', 'set-button', 'subtitle_sync', json)
	end
end

local KEYS = {
	{ 'left', -NUDGE, 'sub-delay' },
	{ 'right', NUDGE, 'sub-delay' },
	{ 'Shift+left', -NUDGE, 'audio-delay' },
	{ 'Shift+right', NUDGE, 'audio-delay' },
}

-- quiet: no banner (the file ended: auto-start.lua has set both delays back to 0 by then,
-- and "Sync kept, +0.00 s" came after every file the panel was open on)
local function close(revert, quiet)
	if not active then
		return
	end
	active = false
	-- a drag of the time row paused playback, and only the button coming up played on:
	-- closed before that (Esc, Enter, t, the file's end), mpv stayed paused
	if drag and drag.moved and drag.row == 'time' and not drag.was_paused then
		mp.set_property_native('pause', false)
	end
	drag = nil
	if timer then
		timer:kill()
		timer = nil
	end
	mp.unobserve_property(on_move)
	mp.disable_key_bindings(SECTION)
	for _, key in ipairs(KEYS) do
		mp.remove_key_binding('subtitle_sync_' .. key[1])
	end
	for _, name in ipairs({ 'enter', 'kp_enter', 'esc' }) do
		mp.remove_key_binding('subtitle_sync_' .. name)
	end
	if audio.running then
		-- stop the analyser; what it had not finished is read again next time
		mp.abort_async_command(audio.running)
		audio.running = nil
		audio.gen = audio.gen + 1
		for i, state in pairs(audio.chunks) do
			if state == 'pending' then
				audio.chunks[i] = nil
			end
		end
	end
	if revert then
		set_delay('sub-delay', start_sub)
		set_delay('audio-delay', start_audio)
	end
	-- a banner top right (Scripts/notify.lua draws every message)
	if not quiet then
		mp.commandv(
			'script-message-to',
			'notify',
			'show',
			'subtitle-sync',
			revert and 'Sync undone' or 'Sync kept',
			string.format('subtitles %+.2f s · audio %+.2f s', get_delay('sub-delay'), get_delay('audio-delay'))
		)
	end
	if overlay then
		overlay:remove()
		overlay = nil
	end
	last_key, last_area = nil, nil
	publish()
	update_button()
end

local function open()
	if active then
		return
	end
	active = true
	start_sub, start_audio = get_delay('sub-delay'), get_delay('audio-delay')
	overlay = mp.create_osd_overlay('ass-events')
	overlay.z = 1500 -- over music-info's panel, under uosc's menus
	for _, key in ipairs(KEYS) do
		mp.add_forced_key_binding(key[1], 'subtitle_sync_' .. key[1], function()
			set_delay(key[3], get_delay(key[3]) + key[2])
			tick()
		end, { repeatable = true })
	end
	for _, name in ipairs({ 'enter', 'kp_enter' }) do
		mp.add_forced_key_binding(name, 'subtitle_sync_' .. name, function()
			close(false)
		end)
	end
	mp.add_forced_key_binding('esc', 'subtitle_sync_esc', function()
		close(true)
	end)
	mp.enable_key_bindings(SECTION)
	mp.observe_property('mouse-pos', 'native', on_move)
	load_subs()
	timer = mp.add_periodic_timer(1 / 60, tick)
	tick()
	update_button()
end

local function toggle()
	if active then
		close(false)
	else
		open()
	end
end

-- key=nil: the key lives in input.conf (script-binding subtitle_sync/toggle),
-- same convention as gpu-toggles.lua/subtitle-toggle.lua.
mp.add_key_binding(nil, 'toggle', toggle)
mp.register_script_message('toggle', toggle)

mp.observe_property('current-tracks/sub', 'native', function()
	if active then
		load_subs()
	end
end)
-- a display change, a fullscreen switch or uosc's HiDPI scale re-lays it out
mp.observe_property('user-data/uosc/ui-scale', 'number', function()
	if active then
		last_key = nil -- force tick() to redraw at the new size
		tick()
	end
end)
mp.observe_property('user-data/uosc/bottom-ui', 'native', function(_, value)
	bottom_ui = type(value) == 'table' and value or nil
	bottom_key = utils.format_json(value) or ''
end)
mp.register_event('end-file', function()
	close(false, true)
	reset_audio(nil)
	subs = { status = 'none', cues = { longest = 0 }, version = subs.version + 1 }
	seen, sub_cache = {}, {}
end)

update_button()
mp.add_timeout(0.5, update_button) -- in case uosc loads after this script
