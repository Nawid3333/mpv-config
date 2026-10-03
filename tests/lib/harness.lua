-- tests/lib/harness.lua - the in-player half of the regression suite.
--
-- Every runtime test is an ordinary mpv Lua script (tests/headless/*.lua,
-- tests/gpu/*.lua) that loads this file with dofile() and hands its body to
-- H.run(). The body runs as a coroutine, so a test reads top to bottom:
-- H.sleep(), H.wait_until() and an H.expect_event() waiter suspend it until a
-- timer or an mpv event resumes it.
--
-- Results go to stdout as lines the runner (tests/run-tests.ps1) parses (each
-- after a blank line, see out()):
--   RESULT PASS <check>
--   RESULT FAIL <check> :: <detail>
--   RESULT INFO <text>
-- and mpv exits with 0 (all checks passed) or 1 (any failed). A watchdog
-- fails the test and quits if it runs past its time limit, so a hung wait can
-- never leave an mpv process behind.
--
-- The input used by tests is mpv's OWN command set (keypress, keydown/keyup,
-- mouse, script-message ...), which enters mpv's input layer exactly where a
-- real key or click would, never OS-level input. Do not add OS input
-- injection here (keybd_event/SendInput) - see AGENTS.md.

local msg = require('mp.msg')

local H = { passed = 0, failed = 0 }

local function out(line)
	-- io.write goes straight to mpv's stdout, independent of --msg-level. The
	-- newline in FRONT as well: a terminal-graphics VO (test-notify-render's
	-- --vo=sixel) writes its frames to the same stdout without a line end, and
	-- a result appended to one would no longer start a line. One write call,
	-- so the C library's stream lock keeps the line whole.
	io.stdout:write('\n' .. line .. '\n')
	io.stdout:flush()
end

local function fmt(v)
	if type(v) == 'number' then
		return string.format('%.4g', v)
	elseif type(v) == 'table' then
		local ok, json = pcall(require('mp.utils').format_json, v)
		return ok and json or tostring(v)
	end
	return tostring(v)
end

function H.pass(name)
	H.passed = H.passed + 1
	out('RESULT PASS ' .. name)
end

function H.fail(name, detail)
	H.failed = H.failed + 1
	out('RESULT FAIL ' .. name .. ' :: ' .. tostring(detail or ''))
	msg.error('FAIL ' .. name .. ': ' .. tostring(detail or ''))
end

function H.info(text)
	out('RESULT INFO ' .. text)
end

-- Records one check; returns cond so a test can stop early on a broken premise.
function H.check(name, cond, detail)
	if cond then
		H.pass(name)
	else
		H.fail(name, detail)
	end
	return cond
end

-- Equality with an optional numeric tolerance.
function H.eq(name, got, want, tol)
	local ok
	if tol and type(got) == 'number' and type(want) == 'number' then
		ok = math.abs(got - want) <= tol
	else
		ok = got == want
	end
	return H.check(name, ok, 'got ' .. fmt(got) .. ', want ' .. fmt(want) .. (tol and (' +-' .. tol) or ''))
end

-- ---- coroutine plumbing ----------------------------------------------------

local co = nil
local finished = false

function H.finish()
	if finished then
		return
	end
	finished = true
	if H.passed + H.failed == 0 then
		H.fail('harness', 'test body recorded no checks')
	end
	out(string.format('RESULT DONE passed=%d failed=%d', H.passed, H.failed))
	mp.command('quit ' .. (H.failed == 0 and 0 or 1))
end

local function resume(...)
	if finished or not co then
		return
	end
	local ok, err = coroutine.resume(co, ...)
	if not ok then
		H.fail('uncaught error', debug.traceback(co, err))
		H.finish()
	elseif coroutine.status(co) == 'dead' then
		H.finish()
	end
end

function H.sleep(seconds)
	mp.add_timeout(seconds, function()
		resume()
	end)
	coroutine.yield()
end

-- Polls pred (every 50 ms, or `interval`); true once it holds, false after timeout.
function H.wait_until(pred, timeout, interval)
	local deadline = mp.get_time() + (timeout or 5)
	while not pred() do
		if mp.get_time() > deadline then
			return false
		end
		H.sleep(interval or 0.05)
	end
	return true
end

-- For a value an action should CHANGE: waits (up to `timeout`, default 2 s)
-- for get() to reach `want`, then records the check. Scripts react
-- asynchronously and a CI runner is slower than a desktop, so a fixed delay
-- would flake. A check that expects NO change must sleep first instead -
-- waiting would pass at once.
function H.expect(name, get, want, tol, timeout)
	local function matches()
		local v = get()
		if tol and type(v) == 'number' and type(want) == 'number' then
			return math.abs(v - want) <= tol
		end
		return v == want
	end
	H.wait_until(matches, timeout or 2)
	return H.eq(name, get(), want, tol)
end

-- Registers for an mpv event NOW and returns a waiter, so the event cannot
-- slip past between the command that causes it and the wait:
--   local loaded = H.expect_event('file-loaded')
--   mp.commandv('loadfile', path, 'replace')
--   H.check('file loads', loaded(10))
function H.expect_event(name)
	local fired = false
	local function handler()
		fired = true
	end
	mp.register_event(name, handler)
	return function(timeout)
		local ok = H.wait_until(function()
			return fired
		end, timeout)
		mp.unregister_event(handler)
		return ok
	end
end

-- Loads a file and waits until it is playing (file-loaded + playback-restart).
function H.load(path, timeout)
	local restarted = H.expect_event('playback-restart')
	mp.commandv('loadfile', path, 'replace')
	return restarted(timeout or 15)
end

-- A left click on the video through mpv's own input path: move there, press,
-- optionally move `jitter` px while held, release (the MBTN_LEFT binding fires
-- on release). The 0.35 s pause after it keeps the next click outside
-- --input-doubleclick-time (300 ms), so clicks never pair into a double-click.
function H.click(x, y, jitter)
	mp.commandv('mouse', tostring(x), tostring(y))
	mp.commandv('keydown', 'MBTN_LEFT')
	if jitter and jitter > 0 then
		mp.commandv('mouse', tostring(x + jitter), tostring(y))
	end
	mp.commandv('keyup', 'MBTN_LEFT')
	H.sleep(0.35)
end

-- Press + release of a key bound in input.conf (keypress = one combined
-- event, like a quick tap).
function H.key(name, settle)
	mp.commandv('keypress', name)
	H.sleep(settle or 0.15)
end

-- Test environment passed by the runner.
H.media = os.getenv('MPV_TEST_MEDIA') or ''
H.root = os.getenv('MPV_TEST_ROOT') or ''

function H.media_path(rel)
	return H.media .. '/' .. rel
end

-- Starts `body` once the player is up. Waits for the first file-loaded when
-- one was given on the command line (opts.wait_file ~= false), otherwise
-- starts right away (idle tests).
function H.run(body, opts)
	opts = opts or {}
	local limit = opts.timeout or tonumber(os.getenv('MPV_TEST_TIMEOUT') or '') or 90
	mp.add_timeout(limit, function()
		if not finished then
			H.fail('watchdog', 'test still running after ' .. limit .. ' s')
			H.finish()
		end
	end)
	co = coroutine.create(body)
	if opts.wait_file == false then
		mp.add_timeout(0.3, function()
			resume()
		end)
	else
		local started = false
		mp.register_event('file-loaded', function()
			if not started then
				started = true
				-- let every other script's own file-loaded handler run first
				mp.add_timeout(0.3, function()
					resume()
				end)
			end
		end)
	end
end

return H
