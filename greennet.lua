local mountPoint = "front"
local endpoint = "https://greennet.chuie.io"

local oldPeripheral = {}
for k, v in pairs(peripheral) do
	oldPeripheral[k] = v
end

local virtualModem = {}
local userID
local sendQueue = {}
local channelEvent = false
local openChannels = {}

local b = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local enc = function(data)
    return ((data:gsub('.', function(x)
        local r,b='',x:byte()
        for i=8,1,-1 do r=r..(b%2^i-b%2^(i-1)>0 and '1' or '0') end
        return r;
    end)..'0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
        if (#x < 6) then return '' end
        local c=0
        for i=1,6 do c=c+(x:sub(i,i)=='1' and 2^(6-i) or 0) end
        return b:sub(c+1,c+1)
    end)..({ '', '==', '=' })[#data%3+1])
end

local dec = function(data)
    data = string.gsub(data, '[^'..b..'=]', '')
    return (data:gsub('.', function(x)
        if (x == '=') then return '' end
        local r,f='',(b:find(x)-1)
        for i=6,1,-1 do r=r..(f%2^i-f%2^(i-1)>0 and '1' or '0') end
        return r;
    end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
        if (#x ~= 8) then return '' end
        local c=0
        for i=1,8 do c=c+(x:sub(i,i)=='1' and 2^(8-i) or 0) end
        return string.char(c)
    end))
end

peripheral.isPresent = function(side)
	if side == mountPoint then return true end
	return oldPeripheral.isPresent(side)
end

peripheral.getType = function(side)
	if side == mountPoint then return "modem" end
	return oldPeripheral.getType(side)
end

peripheral.getMethods = function(side)
	if side == mountPoint then
		return {
			"open", "isOpen", "close", "closeAll", "transmit", "isWireless"
		}
	end
	return oldPeripheral.getMethods(side)
end

peripheral.call = function(side, method, a, b, c, d, e, f, g)
	if side == mountPoint then
		return virtualModem[method](a, b, c, d, e, f, g)
	end
	return oldPeripheral.call(side, method, a, b, c, d, e, f, g)
end

peripheral.wrap = function(side)
	if side == mountPoint then
		local returnModem = {}
		for k, v in pairs(virtualModem) do
			returnModem[k] = v
		end
		return returnModem
	end
	return oldPeripheral.wrap(side)
end

peripheral.find = function(pType, callback)
	if pType == "modem" then
		if not callback then
			return peripheral.wrap(mountPoint)
		end

		callback(mountPoint, peripheral.wrap(mountPoint))
		return nil
	end
	return oldPeripheral.find(pType, callback)
end

peripheral.getNames = function()
	local names = oldPeripheral.getNames()
	local found = false
	for k, v in pairs(names) do
		if v == mountPoint then found = true end
	end
	if not found then
		table.insert(names, mountPoint)
	end
	return names
end

virtualModem.open = function(channel)
	local found = false
	for k, v in pairs(openChannels) do
		if v == channel then found = true break end
	end
	if not found then
		table.insert(openChannels, channel)
		if not channelEvent then
			os.queueEvent("greennet_open")
			channelEvent = true
		end
	end
end

virtualModem.close = function(channel)
	local newChannels = {}
	for k, v in pairs(openChannels) do
		if v ~= channel then
			table.insert(newChannels, v)
		end
	end

	openChannels = newChannels
	if not channelEvent then
		os.queueEvent("greennet_open")
		channelEvent = true
	end
end

virtualModem.isWireless = function()
	return true
end

virtualModem.transmit = function(channel, replyChannel, message)
	if #sendQueue == 0 then
		os.queueEvent("greennet_transmit")
	end
	table.insert(sendQueue, {
		["channel"] = channel,
		["reply_channel"] = replyChannel,
		["message"] = enc(textutils.serialize(message)),
	})
end

virtualModem.closeAll = function()
	openChannels = {}
	if not channelEvent then
		os.queueEvent("greennet_open")
		channelEvent = true
	end
end

virtualModem.isOpen = function(channel)
	for _, v in pairs(openChannels) do
		if v == channel then
			return true
		end
	end
	return false
end

local postEncode = function(val)
	local str = ""
	for k, v in pairs(val) do
		str = str .. k .. "=" .. textutils.urlEncode(v) .. "&"
	end

	return str:sub(1, -1)
end

local reconnect

reconnect = function()
	local resp = http.get(endpoint .. "/register")
	if not resp then
		os.queueEvent("greennet_failure", "connection")
		sleep(5)
		return reconnect()
	end

	local registration = textutils.unserialize(resp.readAll())
	resp.close()

	if not registration or not registration.user then
		os.queueEvent("greennet_failure", "re-register")
		sleep(5)
		return reconnect()
	end

	userID = registration.user
	http.request(endpoint .. "/listen", postEncode({["user"] = userID}))
	http.request(endpoint .. "/open",
		postEncode({["user"] = userID, ["data"] = textutils.serializeJSON(openChannels)}))
end

local daemon = function()
	http.request(endpoint .. "/listen", postEncode({["user"] = userID}))
	while true do
		event, p1, p2, p3, p4, p5 = coroutine.yield()
		if event == "greennet_transmit" then
			if #sendQueue > 0 then
				http.request(endpoint .. "/transmit",
					postEncode({["user"] = userID, ["data"] = textutils.serializeJSON(sendQueue)}))
				sendQueue = {}
			end
		elseif event == "greennet_open" then
			http.request(endpoint .. "/open",
				postEncode({["user"] = userID, ["data"] = textutils.serializeJSON(openChannels)}))
			channelEvent = false
		elseif event == "http_success" then
			if p1 == endpoint .. "/listen" then
				http.request(endpoint .. "/listen", postEncode({["user"] = userID}))

				local messages = textutils.unserialize(p2.readAll())
				p2.close()
				if not messages then
					os.queueEvent("greennet_failure", "listen unserialize error")
					return
				end

				for k, msg in pairs(messages) do
					os.queueEvent("modem_message", mountPoint, msg.channel,
						msg.reply_channel, textutils.unserialize(dec(msg.message)), msg.distance)
				end
			end
		elseif event == "http_failure" then
			local start = p1:find(endpoint, 1, true)
			if start == 1 then
				os.queueEvent("greennet_failure", p1)

				reconnect()
			end
		end
	end
end

print("Connecting to network...")
local resp = http.get(endpoint .. "/register")
if not resp then
	print("Failed to connect to network!")
	return
end

local registration = textutils.unserialize(resp.readAll())
resp.close()

if not registration or not registration.user then
	print("Failed to register on network!")
	return
end

userID = registration.user

term.clear()
term.setCursorPos(1, 1)

parallel.waitForAny(daemon, function()
	print("Connected to network!")
	shell.run("/rom/programs/shell")
end)

print("Disconnected from network.")
