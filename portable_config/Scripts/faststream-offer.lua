-- faststream-offer.lua - a stream FastStream sends while this window plays: banners ask "Play here", "Add to queue"
-- (when the extension offers it: queue/main.lua takes the stream) or "Play in a new window", and the click goes back to
-- the extension, which loads the stream itself. This script only shows and answers: what plays keeps playing.

local mp = require('mp')
local clicks = dofile(mp.command_native({ 'expand-path', '~~/script-modules/banner-click.lua' }))

local BANNERS = { here = 'faststream-here', queue = 'faststream-queue', window = 'faststream-window' }
-- top to bottom
local ORDER = { 'here', 'queue', 'window' }
-- the extension's texts come localized; these stand in only for one that did not come
local TITLES = { here = 'Play here', queue = 'Add to queue', window = 'Play in a new window' }
local DEFAULT_SECONDS = 15
local MAX_SECONDS = 60
local STATE = 'user-data/faststream/offer-state'

local offer -- {id, seconds, timer, choices = {here = true, ...}}
local banners -- (below) their clicks (banner-click.lua)
local on_ended -- (below) what plays came to its end while the banners ask

local function publish()
	mp.set_property_native(
		STATE,
		offer and { shown = true, id = offer.id, seconds = offer.seconds, queue = offer.choices.queue == true }
			or { shown = false }
	)
end

-- a broadcast: the helper's IPC client hears it as a client-message
local function answer(id, choice)
	mp.commandv('script-message', 'faststream-choice', id, choice)
end

local function close()
	if not offer then
		return
	end
	offer.timer:kill()
	offer = nil
	banners.stop()
	mp.unobserve_property(on_ended)
	for _, id in pairs(BANNERS) do
		mp.commandv('script-message-to', 'notify', 'hide', id)
	end
	publish()
end

local function choose(choice)
	local taken = offer
	if not taken or not taken.choices[choice] then
		return
	end
	answer(taken.id, choice)
	close()
end

---@param value string|nil
---@return integer
local function seconds_of(value)
	local n = type(value) == 'string' and value:match('^%d+$') and tonumber(value)
	return n and n >= 1 and n <= MAX_SECONDS and n or DEFAULT_SECONDS
end

local function show(choice, title, detail, seconds)
	mp.commandv(
		'script-message-to',
		'notify',
		'show',
		BANNERS[choice],
		(title and title ~= '') and title or TITLES[choice],
		detail or '',
		tostring(seconds)
	)
end

-- A new offer replaces the one up, which is answered none; the same id again only changes its texts and time. The
-- queue's texts come only from an extension that offers it, and only while queue/main.lua runs here.
local function on_offer(id, seconds, here_title, here_detail, window_title, window_detail, queue_title, queue_detail)
	if not id or id == '' then
		return
	end
	local choices = { here = true, window = true }
	choices.queue = queue_title ~= nil and mp.get_property_native('user-data/queue') ~= nil or nil
	local old = offer
	-- a banner more or less: all go, so the new set stands in its order
	if old and (old.choices.queue == true) ~= (choices.queue == true) then
		for _, name in ipairs(ORDER) do
			mp.commandv('script-message-to', 'notify', 'hide', BANNERS[name])
		end
	end
	if old then
		old.timer:kill()
		if old.id ~= id then
			answer(old.id, 'none')
			-- a click on its way was meant for the old one
			banners.hold()
		end
	end
	local current = { id = id, seconds = seconds_of(seconds), choices = choices }
	current.timer = mp.add_timeout(current.seconds, function()
		if offer == current then
			answer(current.id, 'none')
			close()
		end
	end)
	offer = current
	local texts = {
		here = { here_title, here_detail },
		queue = { queue_title, queue_detail },
		window = { window_title, window_detail },
	}
	for _, name in ipairs(ORDER) do
		if choices[name] then
			show(name, texts[name][1], texts[name][2], current.seconds)
		end
	end
	banners.watch()
	if not old then
		mp.observe_property('eof-reached', 'bool', on_ended)
		mp.observe_property('idle-active', 'bool', on_ended)
	end
	publish()
end

-- at its end (keep-open) or gone idle there is nothing to lose any more: the stream plays here
on_ended = function(_, value)
	if value and offer then
		choose('here')
	end
end

-- with an id, only that offer: a cancel that comes late leaves a newer one up
local function on_cancel(id)
	if offer and (not id or id == '' or id == offer.id) then
		close()
	end
end

banners = clicks.new('faststream-offer-click', BANNERS, choose)

mp.register_script_message('faststream-offer', on_offer)
mp.register_script_message('faststream-offer-cancel', on_cancel)

-- the extension reads it: without it, a new stream replaces what plays
mp.set_property_native('user-data/faststream/offer', 1)
publish()
