local bot = {}

-- Requires are moved to init to allow for reloads.
local bindings -- Load Telegram bindings.
local utilities -- Load miscellaneous and cross-plugin functions.
local redis = (loadfile "./otouto/redis.lua")()

bot.version = '2.0'

function bot:init(config) -- The function run when the bot is started or reloaded.

	bindings = require('otouto.bindings')
	utilities = require('otouto.utilities')
	redis = (loadfile "./otouto/redis.lua")()
	cred_data = load_cred()

	assert(
		config.bot_api_key and config.bot_api_key ~= '',
    'You did not set your bot token in the config!'
	)
	self.BASE_URL = 'https://api.telegram.org/bot' .. config.bot_api_key .. '/'

	-- Fetch bot information. Try until it succeeds.
	repeat
		print('Fetching bot information...')
		self.info = bindings.getMe(self)
	until self.info
	self.info = self.info.result

	-- Load the "database"! ;)
	if not self.database then
		self.database = utilities.load_data(self.info.username..'.db')
	end

	self.database.users = self.database.users or {} -- Table to cache userdata.
	self.database.users[tostring(self.info.id)] = self.info

	self.plugins = {} -- Load plugins.
	enabled_plugins = load_plugins()
	for k,v in pairs(enabled_plugins) do
		local p = require('otouto.plugins.'..v)
		-- print('loading plugin',v)
		table.insert(self.plugins, p)
	    self.plugins[k].name = v
		if p.init then p.init(self, config) end
	end
	
	print('Bot started successfully as:\n@' .. self.info.username .. ', AKA ' .. self.info.first_name ..' ('..self.info.id..')')

	self.last_update = self.last_update or 0 -- Set loop variables: Update offset,
	self.last_cron = self.last_cron or os.date('%M') -- the time of the last cron job,
	self.is_started = true -- and whether or not the bot should be running.

end

function bot:on_msg_receive(msg, config) -- The fn run whenever a message is received.
	-- remove comment to enable debugging
	-- vardump(msg)
	-- Cache user info for those involved.
	utilities.create_user_entry(self, msg.from)
	if msg.forward_from and msg.forward_from.id ~= msg.from.id then
		utilities.create_user_entry(self, msg.forward_from)
	elseif msg.reply_to_message and msg.reply_to_message.from.id ~= msg.from.id then
		utilities.create_user_entry(self, msg.reply_to_message.from)
	end

	if msg.date < os.time() - 5 then return end -- Do not process old messages.

	msg = utilities.enrich_message(msg)
	

	if msg.text:match('^'..config.cmd_pat..'start .+') then
		msg.text = config.cmd_pat .. utilities.input(msg.text)
		msg.text_lower = msg.text:lower()
	end

	-- gsub out user name if multiple bots are in the same group
	msg.text = string.gsub(msg.text, '@'..self.info.username, "")
	msg.text_lower = string.gsub(msg.text, '@'..string.lower(self.info.username), "")

	msg = pre_process_msg(self, msg, config)
	
	for _, plugin in ipairs(self.plugins) do
	  match_plugins(self, msg, config, plugin)
	end
end

function bot:run(config)
	bot.init(self, config) -- Actually start the script.

	while self.is_started do -- Start a loop while the bot should be running.

		local res = bindings.getUpdates(self, { timeout=20, offset = self.last_update+1 } )
		if res then
			for _,v in ipairs(res.result) do -- Go through every new message.
				self.last_update = v.update_id
				if v.callback_query then
				    print('callback_query wird noch nicht unterstützt! Erhaltener Wert: '..v.callback_query.data)
				elseif v.message then
					bot.on_msg_receive(self, v.message, config)
				end
			end
		else
			print('Connection error while fetching updates.')
		end

		if self.last_cron ~= os.date('%M') then -- Run cron jobs every minute.
			self.last_cron = os.date('%M')
			utilities.save_data(self.info.username..'.db', self.database) -- Save the database.
			for i,v in ipairs(self.plugins) do
				if v.cron then -- Call each plugin's cron function, if it has one.
					local result, err = pcall(function() v.cron(self, config) end)
					if not result then
						utilities.handle_exception(self, err, 'CRON: ' .. i, config)
					end
				end
			end
		end

	end

	-- Save the database before exiting.
	utilities.save_data(self.info.username..'.db', self.database)
	print('Halted.')
end

-- Apply plugin.pre_process function
function pre_process_msg(self, msg, config)
  for _,plugin in ipairs(self.plugins) do
    if plugin.pre_process and msg then
	  -- print('Preprocess '..plugin.name) -- remove comment to restore old behaviour
	  new_msg = plugin:pre_process(msg, self, config)
    end
  end
  return new_msg
end

function match_plugins(self, msg, config, plugin)
  for _, trigger in pairs(plugin.triggers) do
    if string.match(msg.text_lower, trigger) then
	-- Check if Plugin is disabled
	if is_plugin_disabled_on_chat(plugin.name, msg) then return end
	local success, result = pcall(function()
	  -- trying to port matches to otouto
	  for k, pattern in pairs(plugin.triggers) do
	    matches = match_pattern(pattern, msg.text)
		if matches then
		  break;
		end
	  end
	  print(plugin.name..' triggered')
	  return plugin.action(self, msg, config, matches)
	end)
	if not success then
	-- If the plugin has an error message, send it. If it does
	-- not, use the generic one specified in config. If it's set
	-- to false, do nothing.
	if plugin.error then
	  utilities.send_reply(self, msg, plugin.error)
	elseif plugin.error == nil then
	  utilities.send_reply(self, msg, config.errors.generic, true)
	end
	  utilities.handle_exception(self, result, msg.from.id .. ': ' .. msg.text, config)
	  return
	end
	-- If the action returns a table, make that table the new msg.
	if type(result) == 'table' then
	  msg = result
	  -- If the action returns true, continue.
	  elseif result ~= true then
	    return
	  end
	end
  end
end

function is_plugin_disabled_on_chat(plugin_name, msg)
  local hash = get_redis_hash(msg, 'disabled_plugins')
  local disabled = redis:hget(hash, plugin_name)
  
  -- Plugin is disabled
  if disabled == 'true' then
    print('Plugin '..plugin_name..' ist in diesem Chat deaktiviert')
	return true
  else
    return false
  end
end

function load_plugins()
  enabled_plugins = redis:smembers('telegram:enabled_plugins')
  if not enabled_plugins[1] then
    create_plugin_set()
  end
  return enabled_plugins
end

-- create plugin set if it doesn't exist
function create_plugin_set()
  enabled_plugins = {
    'control',
    'about',
    'id',
    'echo',
    'imgblacklist',
    'gImages',
    'gSearch',
    'wikipedia',
    'hackernews',
    'imdb',
    'calc',
    'urbandictionary',
    'time',
    'reddit',
	'reddit_post',
    'xkcd',
    'currency',
    'set',
    'get',
    'patterns',
    '9gag',
    'shell',
    'adfly',
    'twitter',
    'rss',
    'remind',
    'youtube',
    'youtube_search',
    'youtube_channel',
    'youtube_playlist',
    'tagesschau_eil',
    'twitter_send',
    'respond',
    'roll',
    'quotes',
    'pasteee',
    'images',
    'media',
    'location_manager',
    'creds',
    'weather',
    'forecast',
    'expand',
    'facebook',
    'github',
    'bitly',
    'app_store',
    'bitly_create',
    'br',
    'heise',
    'tagesschau',
    'wiimmfi',
    'wikia',
    'afk',
    'stats',
    'btc',
    'cats',
    'cleverbot',
    'imgur',
    'banhammer',
    'channels',
	'plugins',
    'help',
    'greetings'
  }
  print ('enabling a few plugins - saving to redis set telegram:enabled_plugins')
  for _,plugin in pairs(enabled_plugins) do
    redis:sadd("telegram:enabled_plugins", plugin)
  end
end

function load_cred()
  if redis:exists("telegram:credentials") == false then
  -- If credentials hash doesnt exists
    print ("Created new credentials hash: telegram:credentials")
    create_cred()
  end
  return redis:hgetall("telegram:credentials")
end

-- create credentials hash with redis
function create_cred()
  cred = {
  bitly_access_token = "",
  cloudinary_apikey = "",
  cloudinary_api_secret = "",
  cloudinary_public_id = "",
  derpibooru_apikey = "",
  fb_access_token = "",
  flickr_apikey = "",
  ftp_site = "",
  ftp_username = "",
  ftp_password = "",
  gender_apikey = "",
  golem_apikey = "",
  google_apikey = "",
  google_cse_id = "",
  gitlab_private_token = "",
  gitlab_project_id = "",
  instagram_access_token = "",
  lyricsnmusic_apikey = "",
  mal_username = "",
  mal_pw = "",
  neutrino_userid = "",
  neutrino_apikey = "",
  owm_apikey = "",
  page2images_restkey = "",
  soundcloud_client_id = "",
  tw_consumer_key = "",
  tw_consumer_secret = "",
  tw_access_token = "",
  tw_access_token_secret = "",
  x_mashape_key = "",
  yandex_translate_apikey = "",
  yandex_rich_content_apikey = "",
  yourls_site_url = "",
  yourls_signature_token = ""
  }
  redis:hmset("telegram:credentials", cred)
  print ('saved credentials into reds hash telegram:credentials')
end

return bot
