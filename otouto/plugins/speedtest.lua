local speedtest = {}

local utilities = require('otouto.utilities')

speedtest.triggers = {
  "speedtest.net/my%-result/(%d+)",
  "speedtest.net/my%-result/i/(%d+)"
}

function speedtest:action(msg, config, matches)
  local url = 'http://www.speedtest.net/result/'..matches[1]..'.png'
  utilities.send_typing(self, msg.chat.id, 'upload_photo')
  local file = download_to_file(url)
  utilities.send_photo(self, msg.chat.id, file, nil, msg.message_id)
end

return speedtest