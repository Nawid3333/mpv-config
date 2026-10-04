-- tests/lib/warmup-slow-killed.lua - stands in for warmup.lua in the "two
-- warm-ups in one session" phase: runs 6 s, then exits with code 1, as a
-- warm-up killed from outside does ("interrupted": nothing recorded as failed).
mp.add_timeout(6, function()
	mp.command('quit 1')
end)
