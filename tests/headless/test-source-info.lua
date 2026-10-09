-- source-info.lua: the "source" button really pushes its button JSON to uosc,
-- the menu it opens is a real uosc menu (callback mode), and the copy action
-- goes through mpv's clipboard/text and reports a notify.lua banner (id
-- "source-copy", replaced in place on a repeat copy). The badge for
-- FastStream content comes from the fragment markers in `path` - the
-- runner's clip FILE NAME carries them, exactly as the stream-resume and
-- upscale tests stand in for the URL fragment. Button/menu rendering itself
-- is uosc's; the wiring is asserted here and by the static checks.
local H = dofile(debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$') .. 'lib/harness.lua')
local utils = require('mp.utils')

local function menu_type()
	return mp.get_property_native('user-data/uosc/menu/type')
end

local function notify_cards()
	return (mp.get_property_native('user-data/notify') or {}).cards or {}
end

local function card(id)
	for _, c in ipairs(notify_cards()) do
		if c.id == id then
			return c
		end
	end
end

local function count_cards(id)
	local n = 0
	for _, c in ipairs(notify_cards()) do
		if c.id == id then
			n = n + 1
		end
	end
	return n
end

local function clipboard()
	return mp.get_property('clipboard/text')
end

local function close_menu()
	mp.commandv('script-message-to', 'uosc', 'close-menu')
	H.wait_until(function()
		return menu_type() == nil
	end, 3)
	H.eq('the menu closed again', menu_type(), nil)
end

local function open_menu(name)
	mp.commandv('script-message-to', 'source_info', 'open-menu')
	H.wait_until(function()
		return menu_type() ~= nil
	end, 3)
	H.eq(name, menu_type(), 'source-menu')
	close_menu()
end

-- One event, exactly what uosc's callback mode produces for this menu:
-- "script-message-to source_info menu-callback <event json>" (the callback
-- array's entries become the script-message-to arguments, the event JSON is
-- appended last). format_json, not a hand-built string: a value with a quote
-- or a backslash made invalid JSON, which the script drops - the refusal of
-- 'https://site.example/a"&calc' below was never really tested (2026-10-05).
local function activate(value)
	mp.commandv(
		'script-message-to',
		'source_info',
		'menu-callback',
		utils.format_json({ type = 'activate', value = value })
	)
end

local function expect_clipboard(name, want)
	H.wait_until(function()
		return clipboard() == want
	end, 3)
	H.eq(name, clipboard(), want)
end

H.run(function()
	-- A local file: the button pushed its set-button JSON at file-loaded (its
	-- effect is asserted by the config-load/static wiring checks), and the
	-- menu opens and closes without a JSON uosc would reject.
	open_menu('the source button opens its menu on a local file')

	-- Copy: the value grammar copy:<payload>, the same value a row and its
	-- Copy sub-item carry. The banner replaces in place, the clipboard is mpv's.
	activate('copy:regression-url-probe')
	H.wait_until(function()
		return card('source-copy') ~= nil
	end, 3)
	H.check('copy announces a notify.lua banner', card('source-copy') ~= nil)
	expect_clipboard('copy puts the value on the clipboard (clipboard/text)', 'regression-url-probe')
	activate('copy:regression-url-probe-2')
	expect_clipboard('a second copy replaces the clipboard', 'regression-url-probe-2')
	H.eq('the copy banner is replaced, not stacked', count_cards('source-copy'), 1)

	-- The payload is everything after the FIRST colon: URLs keep theirs.
	activate('copy:https://example.com/watch?v=1&x=2')
	expect_clipboard('a URL payload keeps its colons', 'https://example.com/watch?v=1&x=2')

	-- Unknown verbs do nothing (no banner, no crash).
	local before = count_cards('source-copy')
	activate('nonsense:whatever')
	H.sleep(0.2)
	H.eq('an unknown action is ignored', count_cards('source-copy'), before)

	-- FastStream content: the fragment in `path` makes it FastStream, and the
	-- fs-page= fragment decodes to the Site page link. Load the
	-- stream-resume-shaped clip again (its position was never saved here:
	-- stream-resume.lua writes only for streams with fs-id and this is the
	-- same media the stream-resume tests used in an earlier process).
	H.load(H.media_path('fs-anime/ep1#fs-content=anime&fs-id=a1b2c3d4e5f60718.mkv'))
	H.wait_until(function()
		return (mp.get_property('path') or ''):find('fs%-content=anime', 1, false) ~= nil
	end, 5)
	open_menu('the FastStream file also opens its menu')
	local function badge()
		return mp.get_property_native('user-data/source-info/badge')
	end
	H.expect('... its button reads Fast', badge, 'Fast')
	-- "fs-content=" only in a query is no FastStream tag (review, 2026-10-09)
	H.load(H.media_path('fs-forged-query/ep&x=fs-content=anime.mkv'))
	H.expect('a query holding fs-content= reads File, not Fast', badge, 'File')
	H.load(H.media_path('fs-anime/ep1#fs-content=anime&fs-id=a1b2c3d4e5f60718.mkv'))

	-- The site-page copy: the fs-page= fragment, percent-encoded, decodes
	-- back to the page URL. Driven the same way the menu event would arrive.
	activate('copy:https://example.com/ep1')
	expect_clipboard('a copied site page lands on the clipboard verbatim', 'https://example.com/ep1')

	-- Open in browser (the runner sets source_info-launch=no: what would be
	-- launched is recorded, nothing starts). Never through cmd: an '&' in the
	-- address stays part of it (2026-10-02: `cmd /c start` ran what followed
	-- it as a command).
	local function launched()
		return mp.get_property_native('user-data/source-info/launched')
	end
	local page = 'https://site.example/watch?ep=1&lang=en&calc'
	activate('browse:' .. page)
	H.wait_until(function()
		return launched() ~= nil
	end, 3)
	local args = launched() or {}
	H.eq('the browser is started without cmd', args[1], 'rundll32.exe')
	H.eq('through the URL protocol handler', args[2], 'url.dll,FileProtocolHandler')
	H.eq('the whole address, & included, as one argument', args[3], page)
	H.eq('and nothing else', #args, 3)

	-- Not a plain web address: refused, with a banner, and nothing launched.
	-- Each one on its own: a copy first puts another title on the banner, so
	-- 'Not opened' can only come from this refusal.
	for i, bad in ipairs({
		'https://site.example/a"&calc',
		'file:///C:/Windows/System32/calc.exe',
		'https://site.example/a b',
	}) do
		mp.set_property_native('user-data/source-info/launched', {})
		activate('copy:before-refusal-' .. i)
		expect_clipboard('(a copy before refusal ' .. i .. ')', 'before-refusal-' .. i)
		activate('browse:' .. bad)
		H.wait_until(function()
			return (card('source-copy') or {}).title == 'Not opened'
		end, 3)
		H.eq('refused, and says so: ' .. bad, (card('source-copy') or {}).title, 'Not opened')
		H.eq('... and nothing launched: ' .. bad, #(launched() or {}), 0)
	end

	-- The Site page link is the host's own last fs-page= item only: a stream
	-- URL's own "xfs-page=" (kept by the host, which drops only fs-* items)
	-- must not pass for it.
	H.load(
		H.media_path(
			'fs-page/ep1#xfs-page=https%3A%2F%2Fevil.example%2F&fs-content=anime&fs-page=https%3A%2F%2Fsite.example%2Fwatch%3Fep%3D1%26lang%3Den.mkv'
		)
	)
	H.wait_until(function()
		return (mp.get_property('path') or ''):find('xfs-page=', 1, true) ~= nil
	end, 5)
	open_menu('the forged-tag file opens its menu')
	local links = mp.get_property_native('user-data/source-info/links') or {}
	H.eq('the Site page is the host tag, decoded', links.page, 'https://site.example/watch?ep=1&lang=en.mkv')

	-- The Stream URL a copy gives: what was requested, not decoded (%2B and %26 inside
	-- a proxied address are part of it) and without the host's fs-* tags. links-for
	-- reaches the same code without a server to load a stream from.
	local function links_for(path)
		mp.set_property_native('user-data/source-info/links-for', {})
		mp.commandv('script-message-to', 'source_info', 'links-for', path)
		H.wait_until(function()
			return (mp.get_property_native('user-data/source-info/links-for') or {}).stream ~= nil
		end, 3)
		return mp.get_property_native('user-data/source-info/links-for') or {}
	end
	local proxied = 'https://proxy.example/p?url=https%3A%2F%2Fcdn.example%2Fa.m3u8%3Ft%3Dab%2Bc%26e%3D2'
	local got =
		links_for(proxied .. '#t=5&fs-content=anime&fs-id=1234567890abcdef&fs-page=https%3A%2F%2Fsite.example%2Fep1')
	H.eq('a copied stream URL is the one requested, without the fs tags', got.stream, proxied .. '#t=5')
	H.eq('its Site page is still the decoded host tag', got.page, 'https://site.example/ep1')
	H.eq(
		'a fragment of fs tags only goes entirely',
		links_for('https://cdn.example/a.m3u8#fs-content=anime').stream,
		'https://cdn.example/a.m3u8'
	)

	-- A link pasted into mpv that yt-dlp resolves (YouTube: FastStream hands mpv no
	-- YouTube, those links are pasted into mpv directly): for separate audio and video
	-- formats ytdl_hook gives mpv an edl:// - no address anyone can copy or open
	-- elsewhere, thousands of characters of googlevideo links. The Stream URL is the
	-- pasted link then, and "Open in mpv" runs yt-dlp on it again. A stand-in for
	-- ytdl_hook (priority 9: before it, and before source-info's capture at 11)
	-- rewrites this one made-up address to an EDL of the local clip, as yt-dlp would.
	local page_link = 'http://127.0.0.1:9/watch?v=regression-edl'
	local clip = H.media_path('plain/clip.mkv')
	mp.add_hook('on_load', 9, function()
		if mp.get_property('stream-open-filename') == page_link then
			mp.set_property('stream-open-filename', 'edl://%' .. #clip .. '%' .. clip)
		end
	end)
	H.load(page_link)
	open_menu('a link yt-dlp resolved to an EDL opens its menu')
	local resolved = mp.get_property_native('user-data/source-info/links') or {}
	H.eq("its Stream URL is the pasted link, not yt-dlp's EDL", resolved.stream, page_link)
	H.eq('and no Original URL entry repeats it', resolved.origin, nil)

	-- "Open in mpv" gives the stream its headers and title again. The FastStream host
	-- hands them over as per-file options of the one file (here loadfile's options, as
	-- its reuse path sends them); a plain `loadfile <url> replace` dropped them, and a
	-- CDN that checks the Referer refused the stream opened again. A comma inside a
	-- header value survives the round trip (mpv's '\,' list escape).
	local function headers_now()
		return table.concat(mp.get_property_native('http-header-fields') or {}, ' | ')
	end
	local want_headers = 'Referer: https://site.example/watch?a=1,2 | User-Agent: Regression/1.0'
	local fs_clip = H.media_path('fs-anime/ep1#fs-content=anime&fs-id=a1b2c3d4e5f60718.mkv')
	local loaded = H.expect_event('playback-restart')
	mp.command_native({
		name = 'loadfile',
		url = fs_clip,
		flags = 'replace',
		index = -1,
		options = {
			['http-header-fields'] = 'Referer: https://site.example/watch?a=1\\,2,User-Agent: Regression/1.0',
			['force-media-title'] = 'Episode 1',
		},
	})
	H.check('a FastStream file loads with its headers and title', loaded(15))
	H.eq('... its headers are in effect', headers_now(), want_headers)
	H.eq('... and its title', mp.get_property('media-title'), 'Episode 1')
	local reopened = H.expect_event('file-loaded')
	activate('open:' .. fs_clip) -- the clip's path holds backslashes on Windows
	H.check('Open in mpv loads the stream again', reopened(15))
	H.wait_until(function()
		return headers_now() == want_headers
	end, 3)
	H.eq('the stream opened again keeps its headers', headers_now(), want_headers)
	H.eq('... and its title', mp.get_property('media-title'), 'Episode 1')
	-- the same file, its separators aside: a local path comes back with Windows' backslashes
	-- (a FastStream stream is an http URL, which keeps its slashes)
	local function slashes(p)
		return ((p or ''):gsub('\\', '/'))
	end
	H.eq('... and is the same stream, FastStream tags included', slashes(mp.get_property('path')), slashes(fs_clip))

	-- A FastStream stream that does not open (a refused link; port 9 refuses at once)
	-- says so in a banner, instead of an empty window.
	-- (The first end-file is the clip before it ending, so the banner itself is waited
	-- for; ytdl_hook may try the URL too before mpv gives up.)
	mp.commandv('loadfile', 'http://127.0.0.1:9/a.m3u8#fs-content=anime&fs-id=1234567890abcdef', 'replace')
	H.wait_until(function()
		return card('stream-error') ~= nil
	end, 30)
	H.eq(
		'a FastStream stream that fails to open says so',
		(card('stream-error') or {}).title,
		'The stream could not be opened'
	)
	H.eq("... with the source button's icon", (card('stream-error') or {}).icon, 'language')
end)
