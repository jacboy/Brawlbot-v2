local gMaps = {}

local URL = require('socket.url')
local utilities = require('otouto.utilities')

gMaps.command = 'loc <Ort>'

function gMaps:init(config)
	gMaps.triggers = utilities.triggers(self.info.username, config.cmd_pat):t('loc', true).table
	gMaps.doc = [[*
]]..config.cmd_pat..[[loc* _<Ort>_: Sendet Ort via Google Maps]]
end

function gMaps:get_staticmap(area, lat, lon)
  local base_api = "https://maps.googleapis.com/maps/api"
  local url = base_api .. "/staticmap?size=600x300&zoom=12&center="..URL.escape(area).."&markers=color:red"..URL.escape("|"..area)

  local file = download_to_file(url)
  return file
end

function gMaps:action(msg, config)
	local input = utilities.input(msg.text)
	if not input then
		if msg.reply_to_message and msg.reply_to_message.text then
			input = msg.reply_to_message.text
		else
			utilities.send_message(self, msg.chat.id, gMaps.doc, true, msg.message_id, true)
			return
		end
	end
    utilities.send_typing(self, msg.chat.id, 'find_location')
	local coords = utilities.get_coords(input, config)
	if type(coords) == 'string' then
		utilities.send_reply(self, msg, coords)
		return
	end

  utilities.send_location(self, msg.chat.id, coords.lat, coords.lon, msg.message_id)
  utilities.send_photo(self, msg.chat.id, gMaps:get_staticmap(input, coords.lat, coords.lon), nil, msg.message_id)
end

return gMaps
