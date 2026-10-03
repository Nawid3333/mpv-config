-- shader-cache (7/11): the same fingerprint as the failed attempt - no new
-- warm-up at this start, and the video starts right away. The first start after
-- the failure says so on screen, once (it was only in a log a normal start does
-- not write).
local base = debug.getinfo(1, 'S').source:match('^@(.*[/\\])[^/\\]+[/\\][^/\\]+$')
local H = dofile(base .. 'lib/harness.lua')
local R = dofile(base .. 'lib/shader-cache.lua')

local told = nil
mp.observe_property('user-data/notify', 'native', function(_, v)
	for _, c in ipairs((v or {}).cards or {}) do
		if c.id == 'shader-cache' then
			told = c.title
		end
	end
end)

H.run(function()
	R.wait_playing(H)
	H.eq('failed before with this fingerprint: not retried', R.info.state, 'failed-before')
	H.check('no warm-up started (' .. R.seq() .. ')', not R.saw('warming'))
	H.check('the video starts right away', R.until_playing() < 2, R.until_playing())
	H.eq('the failure is said once on screen', told, 'Shaders not compiled')
	local f = io.open(R.path('shader-warmup.failed'), 'r')
	local text = f and f:read('*a') or ''
	if f then
		f:close()
	end
	H.check('and marked as said, so the next start stays quiet', text:find('told=yes', 1, true) ~= nil, text)
end)
