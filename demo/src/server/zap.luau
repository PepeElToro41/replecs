--!native
--!optimize 2
--!nocheck
--!nolint
--#selene: allow(unused_variable, global_usage)
-- Server generated by Zap v0.6.25 (https://github.com/red-blox/zap)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local outgoing_buff: buffer
local outgoing_used: number
local outgoing_size: number
local outgoing_inst: { Instance }
local outgoing_apos: number
local outgoing_ids: { number }

local incoming_buff: buffer
local incoming_read: number
local incoming_inst: { Instance }
local incoming_ipos: number
local incoming_ids: { number }

-- thanks to https://dom.rojo.space/binary.html#cframe
local CFrameSpecialCases = {
	CFrame.Angles(0, 0, 0),
	CFrame.Angles(math.rad(90), 0, 0),
	CFrame.Angles(0, math.rad(180), math.rad(180)),
	CFrame.Angles(math.rad(-90), 0, 0),
	CFrame.Angles(0, math.rad(180), math.rad(90)),
	CFrame.Angles(0, math.rad(90), math.rad(90)),
	CFrame.Angles(0, 0, math.rad(90)),
	CFrame.Angles(0, math.rad(-90), math.rad(90)),
	CFrame.Angles(math.rad(-90), math.rad(-90), 0),
	CFrame.Angles(0, math.rad(-90), 0),
	CFrame.Angles(math.rad(90), math.rad(-90), 0),
	CFrame.Angles(0, math.rad(90), math.rad(180)),
	CFrame.Angles(0, math.rad(-90), math.rad(180)),
	CFrame.Angles(0, math.rad(180), math.rad(0)),
	CFrame.Angles(math.rad(-90), math.rad(-180), math.rad(0)),
	CFrame.Angles(0, math.rad(0), math.rad(180)),
	CFrame.Angles(math.rad(90), math.rad(180), math.rad(0)),
	CFrame.Angles(0, math.rad(0), math.rad(-90)),
	CFrame.Angles(0, math.rad(-90), math.rad(-90)),
	CFrame.Angles(0, math.rad(-180), math.rad(-90)),
	CFrame.Angles(0, math.rad(90), math.rad(-90)),
	CFrame.Angles(math.rad(90), math.rad(90), 0),
	CFrame.Angles(0, math.rad(90), 0),
	CFrame.Angles(math.rad(-90), math.rad(90), 0),
}

local function alloc(len: number)
	if outgoing_used + len > outgoing_size then
		while outgoing_used + len > outgoing_size do
			outgoing_size = outgoing_size * 2
		end

		local new_buff = buffer.create(outgoing_size)
		buffer.copy(new_buff, 0, outgoing_buff, 0, outgoing_used)

		outgoing_buff = new_buff
	end

	outgoing_apos = outgoing_used
	outgoing_used = outgoing_used + len

	return outgoing_apos
end

local function read(len: number)
	local pos = incoming_read
	incoming_read = incoming_read + len

	return pos
end

local function save()
	return {
		buff = outgoing_buff,
		used = outgoing_used,
		size = outgoing_size,
		inst = outgoing_inst,
		outgoing_ids = outgoing_ids,
		incoming_ids = incoming_ids,
	}
end

local function load(data: {
	buff: buffer,
	used: number,
	size: number,
	inst: { Instance },
	outgoing_ids: { number },
	incoming_ids: { number },
})
	outgoing_buff = data.buff
	outgoing_used = data.used
	outgoing_size = data.size
	outgoing_inst = data.inst
	outgoing_ids = data.outgoing_ids
	incoming_ids = data.incoming_ids
end

local function load_empty()
	outgoing_buff = buffer.create(64)
	outgoing_used = 0
	outgoing_size = 64
	outgoing_inst = {}
	outgoing_ids = {}
	incoming_ids = {}
end

load_empty()

local types = {}

local polling_queues_reliable = {}
local polling_queues_unreliable = {}
if not RunService:IsRunning() then
	local noop = function() end
	return table.freeze({
		SendEvents = noop,
		WaitForServer = table.freeze({
			SetCallback = noop
		}),
		OnUnreliableUpdates = table.freeze({
			Fire = noop,
			FireAll = noop,
			FireExcept = noop,
			FireList = noop,
			FireSet = noop
		}),
		OnReliableUpdates = table.freeze({
			Fire = noop,
			FireAll = noop,
			FireExcept = noop,
			FireList = noop,
			FireSet = noop
		}),
	}) :: Events
end
local Players = game:GetService("Players")

if RunService:IsClient() then
	error("Cannot use the server module on the client!")
end

local remotes = ReplicatedStorage:FindFirstChild("ZAP")
if remotes == nil then
	remotes = Instance.new("Folder")
	remotes.Name = "ZAP"
	remotes.Parent = ReplicatedStorage
end

local reliable = remotes:FindFirstChild("ZAP_RELIABLE")
if reliable == nil then
	reliable = Instance.new("RemoteEvent")
	reliable.Name = "ZAP_RELIABLE"
	reliable.Parent = remotes
end

local function getOrCreateUnreliableRemote(name: string): UnreliableRemoteEvent
	local remote = remotes:FindFirstChild(name)

	if remote == nil then
		remote = Instance.new("UnreliableRemoteEvent")
		remote.Name = name
		remote.Parent = remotes
	end

	return remote
end

local unreliable = { getOrCreateUnreliableRemote("ZAP_UNRELIABLE_0") }
assert(unreliable[1]:IsA("UnreliableRemoteEvent"), "Expected ZAP_UNRELIABLE_0 to be an UnreliableRemoteEvent")
local player_map = {}

local function load_player(player: Player)
	if player_map[player] then
		load(player_map[player])
	else
		load_empty()
	end
end

Players.PlayerRemoving:Connect(function(player)
	player_map[player] = nil
end)
export type Variants = ({ ({ ((unknown)) }) })

local function SendEvents()
	for player, outgoing in player_map do
		if outgoing.used > 0 then
			local buff = buffer.create(outgoing.used)
			buffer.copy(buff, 0, outgoing.buff, 0, outgoing.used)

			reliable:FireClient(player, buff, outgoing.inst)

			outgoing.buff = buffer.create(64)
			outgoing.used = 0
			outgoing.size = 64
			table.clear(outgoing.inst)
		end
	end
end

RunService.Heartbeat:Connect(SendEvents)

local reliable_events = table.create(1)
reliable.OnServerEvent:Connect(function(player, buff, inst)
	incoming_buff = buff
	incoming_inst = inst
	incoming_read = 0
	incoming_ipos = 0
	local len = buffer.len(buff)
	while incoming_read < len do
		local id = buffer.readu8(buff, read(1))
		if id == 0 then
			local call_id = buffer.readu8(buff, read(1))
			local value
			if reliable_events[0] then
				task.spawn(function(player_2, call_id_2, value_1)
					local ret_1, ret_2 = reliable_events[0](player_2, value_1)
					load_player(player_2)
					alloc(1)
					buffer.writeu8(outgoing_buff, outgoing_apos, 1)
					alloc(1)
					buffer.writeu8(outgoing_buff, outgoing_apos, call_id_2)
					local bool_1 = 0
					local bool_1_pos_1 = alloc(1)
					if ret_1 ~= nil then
						bool_1 = bit32.bor(bool_1, 0b0000000000000001)
						local len_1 = buffer.len(ret_1)
						alloc(2)
						buffer.writeu16(outgoing_buff, outgoing_apos, len_1)
						alloc(len_1)
						buffer.copy(outgoing_buff, outgoing_apos, ret_1, 0, len_1)
					end
					if ret_2 ~= nil then
						bool_1 = bit32.bor(bool_1, 0b0000000000000010)
						local len_2 = #ret_2
						alloc(2)
						buffer.writeu16(outgoing_buff, outgoing_apos, len_2)
						for i_1 = 1, len_2 do
							local val_1 = ret_2[i_1]
							local len_3 = #val_1
							alloc(2)
							buffer.writeu16(outgoing_buff, outgoing_apos, len_3)
							for i_2 = 1, len_3 do
								local bool_2 = 0
								local bool_2_pos_1 = alloc(1)
								local val_2 = val_1[i_2]
								if val_2 ~= nil then
									bool_2 = bit32.bor(bool_2, 0b0000000000000001)
									table.insert(outgoing_inst, val_2)
								end
								buffer.writeu8(outgoing_buff, bool_2_pos_1, bool_2)
							end
						end
					end
					buffer.writeu8(outgoing_buff, bool_1_pos_1, bool_1)
					player_map[player_2] = save()
				end, player, call_id, value)
			end
		else
			error("Unknown event id")
		end
	end
end)
table.freeze(polling_queues_reliable)
table.freeze(polling_queues_unreliable)

local returns = {
	SendEvents = SendEvents,
	WaitForServer = {
		SetCallback = function(Callback: (Player: Player) -> (((buffer)?), (({ ({ ((unknown)) }) })?))): () -> ()
			reliable_events[0] = Callback
			return function()
				reliable_events[0] = nil
			end
		end,
	},
	OnUnreliableUpdates = {
		Fire = function(Player: Player, buf: (buffer), variants: (({ ({ ((unknown)) }) })?))
			load_empty()
			local bool_3 = 0
			local bool_3_pos_1 = alloc(1)
			local len_4 = buffer.len(buf)
			alloc(2)
			buffer.writeu16(outgoing_buff, outgoing_apos, len_4)
			alloc(len_4)
			buffer.copy(outgoing_buff, outgoing_apos, buf, 0, len_4)
			if variants ~= nil then
				bool_3 = bit32.bor(bool_3, 0b0000000000000001)
				local len_5 = #variants
				alloc(2)
				buffer.writeu16(outgoing_buff, outgoing_apos, len_5)
				for i_3 = 1, len_5 do
					local val_3 = variants[i_3]
					local len_6 = #val_3
					alloc(2)
					buffer.writeu16(outgoing_buff, outgoing_apos, len_6)
					for i_4 = 1, len_6 do
						local bool_4 = 0
						local bool_4_pos_1 = alloc(1)
						local val_4 = val_3[i_4]
						if val_4 ~= nil then
							bool_4 = bit32.bor(bool_4, 0b0000000000000001)
							table.insert(outgoing_inst, val_4)
						end
						buffer.writeu8(outgoing_buff, bool_4_pos_1, bool_4)
					end
				end
			end
			buffer.writeu8(outgoing_buff, bool_3_pos_1, bool_3)
			local buff = buffer.create(outgoing_used)
			buffer.copy(buff, 0, outgoing_buff, 0, outgoing_used)
			unreliable[1]:FireClient(Player, buff, outgoing_inst)
		end,
		FireAll = function(buf: (buffer), variants: (({ ({ ((unknown)) }) })?))
			load_empty()
			local bool_5 = 0
			local bool_5_pos_1 = alloc(1)
			local len_7 = buffer.len(buf)
			alloc(2)
			buffer.writeu16(outgoing_buff, outgoing_apos, len_7)
			alloc(len_7)
			buffer.copy(outgoing_buff, outgoing_apos, buf, 0, len_7)
			if variants ~= nil then
				bool_5 = bit32.bor(bool_5, 0b0000000000000001)
				local len_8 = #variants
				alloc(2)
				buffer.writeu16(outgoing_buff, outgoing_apos, len_8)
				for i_5 = 1, len_8 do
					local val_5 = variants[i_5]
					local len_9 = #val_5
					alloc(2)
					buffer.writeu16(outgoing_buff, outgoing_apos, len_9)
					for i_6 = 1, len_9 do
						local bool_6 = 0
						local bool_6_pos_1 = alloc(1)
						local val_6 = val_5[i_6]
						if val_6 ~= nil then
							bool_6 = bit32.bor(bool_6, 0b0000000000000001)
							table.insert(outgoing_inst, val_6)
						end
						buffer.writeu8(outgoing_buff, bool_6_pos_1, bool_6)
					end
				end
			end
			buffer.writeu8(outgoing_buff, bool_5_pos_1, bool_5)
			local buff = buffer.create(outgoing_used)
			buffer.copy(buff, 0, outgoing_buff, 0, outgoing_used)
			unreliable[1]:FireAllClients(buff, outgoing_inst)
		end,
		FireExcept = function(Except: Player, buf: (buffer), variants: (({ ({ ((unknown)) }) })?))
			load_empty()
			local bool_7 = 0
			local bool_7_pos_1 = alloc(1)
			local len_10 = buffer.len(buf)
			alloc(2)
			buffer.writeu16(outgoing_buff, outgoing_apos, len_10)
			alloc(len_10)
			buffer.copy(outgoing_buff, outgoing_apos, buf, 0, len_10)
			if variants ~= nil then
				bool_7 = bit32.bor(bool_7, 0b0000000000000001)
				local len_11 = #variants
				alloc(2)
				buffer.writeu16(outgoing_buff, outgoing_apos, len_11)
				for i_7 = 1, len_11 do
					local val_7 = variants[i_7]
					local len_12 = #val_7
					alloc(2)
					buffer.writeu16(outgoing_buff, outgoing_apos, len_12)
					for i_8 = 1, len_12 do
						local bool_8 = 0
						local bool_8_pos_1 = alloc(1)
						local val_8 = val_7[i_8]
						if val_8 ~= nil then
							bool_8 = bit32.bor(bool_8, 0b0000000000000001)
							table.insert(outgoing_inst, val_8)
						end
						buffer.writeu8(outgoing_buff, bool_8_pos_1, bool_8)
					end
				end
			end
			buffer.writeu8(outgoing_buff, bool_7_pos_1, bool_7)
			local buff = buffer.create(outgoing_used)
			buffer.copy(buff, 0, outgoing_buff, 0, outgoing_used)
			for _, player in Players:GetPlayers() do
				if player ~= Except then
					unreliable[1]:FireClient(player, buff, outgoing_inst)
				end
			end
		end,
		FireList = function(List: { [unknown]: Player }, buf: (buffer), variants: (({ ({ ((unknown)) }) })?))
			load_empty()
			local bool_9 = 0
			local bool_9_pos_1 = alloc(1)
			local len_13 = buffer.len(buf)
			alloc(2)
			buffer.writeu16(outgoing_buff, outgoing_apos, len_13)
			alloc(len_13)
			buffer.copy(outgoing_buff, outgoing_apos, buf, 0, len_13)
			if variants ~= nil then
				bool_9 = bit32.bor(bool_9, 0b0000000000000001)
				local len_14 = #variants
				alloc(2)
				buffer.writeu16(outgoing_buff, outgoing_apos, len_14)
				for i_9 = 1, len_14 do
					local val_9 = variants[i_9]
					local len_15 = #val_9
					alloc(2)
					buffer.writeu16(outgoing_buff, outgoing_apos, len_15)
					for i_10 = 1, len_15 do
						local bool_10 = 0
						local bool_10_pos_1 = alloc(1)
						local val_10 = val_9[i_10]
						if val_10 ~= nil then
							bool_10 = bit32.bor(bool_10, 0b0000000000000001)
							table.insert(outgoing_inst, val_10)
						end
						buffer.writeu8(outgoing_buff, bool_10_pos_1, bool_10)
					end
				end
			end
			buffer.writeu8(outgoing_buff, bool_9_pos_1, bool_9)
			local buff = buffer.create(outgoing_used)
			buffer.copy(buff, 0, outgoing_buff, 0, outgoing_used)
			for _, player in List do
				unreliable[1]:FireClient(player, buff, outgoing_inst)
			end
		end,
		FireSet = function(Set: { [Player]: any }, buf: (buffer), variants: (({ ({ ((unknown)) }) })?))
			load_empty()
			local bool_11 = 0
			local bool_11_pos_1 = alloc(1)
			local len_16 = buffer.len(buf)
			alloc(2)
			buffer.writeu16(outgoing_buff, outgoing_apos, len_16)
			alloc(len_16)
			buffer.copy(outgoing_buff, outgoing_apos, buf, 0, len_16)
			if variants ~= nil then
				bool_11 = bit32.bor(bool_11, 0b0000000000000001)
				local len_17 = #variants
				alloc(2)
				buffer.writeu16(outgoing_buff, outgoing_apos, len_17)
				for i_11 = 1, len_17 do
					local val_11 = variants[i_11]
					local len_18 = #val_11
					alloc(2)
					buffer.writeu16(outgoing_buff, outgoing_apos, len_18)
					for i_12 = 1, len_18 do
						local bool_12 = 0
						local bool_12_pos_1 = alloc(1)
						local val_12 = val_11[i_12]
						if val_12 ~= nil then
							bool_12 = bit32.bor(bool_12, 0b0000000000000001)
							table.insert(outgoing_inst, val_12)
						end
						buffer.writeu8(outgoing_buff, bool_12_pos_1, bool_12)
					end
				end
			end
			buffer.writeu8(outgoing_buff, bool_11_pos_1, bool_11)
			local buff = buffer.create(outgoing_used)
			buffer.copy(buff, 0, outgoing_buff, 0, outgoing_used)
			for player in Set do
				unreliable[1]:FireClient(player, buff, outgoing_inst)
			end
		end,
	},
	OnReliableUpdates = {
		Fire = function(Player: Player, buf: (buffer), variants: (({ ({ ((unknown)) }) })?))
			load_player(Player)
			alloc(1)
			buffer.writeu8(outgoing_buff, outgoing_apos, 0)
			local bool_13 = 0
			local bool_13_pos_1 = alloc(1)
			local len_19 = buffer.len(buf)
			alloc(2)
			buffer.writeu16(outgoing_buff, outgoing_apos, len_19)
			alloc(len_19)
			buffer.copy(outgoing_buff, outgoing_apos, buf, 0, len_19)
			if variants ~= nil then
				bool_13 = bit32.bor(bool_13, 0b0000000000000001)
				local len_20 = #variants
				alloc(2)
				buffer.writeu16(outgoing_buff, outgoing_apos, len_20)
				for i_13 = 1, len_20 do
					local val_13 = variants[i_13]
					local len_21 = #val_13
					alloc(2)
					buffer.writeu16(outgoing_buff, outgoing_apos, len_21)
					for i_14 = 1, len_21 do
						local bool_14 = 0
						local bool_14_pos_1 = alloc(1)
						local val_14 = val_13[i_14]
						if val_14 ~= nil then
							bool_14 = bit32.bor(bool_14, 0b0000000000000001)
							table.insert(outgoing_inst, val_14)
						end
						buffer.writeu8(outgoing_buff, bool_14_pos_1, bool_14)
					end
				end
			end
			buffer.writeu8(outgoing_buff, bool_13_pos_1, bool_13)
			player_map[Player] = save()
		end,
		FireAll = function(buf: (buffer), variants: (({ ({ ((unknown)) }) })?))
			load_empty()
			alloc(1)
			buffer.writeu8(outgoing_buff, outgoing_apos, 0)
			local bool_15 = 0
			local bool_15_pos_1 = alloc(1)
			local len_22 = buffer.len(buf)
			alloc(2)
			buffer.writeu16(outgoing_buff, outgoing_apos, len_22)
			alloc(len_22)
			buffer.copy(outgoing_buff, outgoing_apos, buf, 0, len_22)
			if variants ~= nil then
				bool_15 = bit32.bor(bool_15, 0b0000000000000001)
				local len_23 = #variants
				alloc(2)
				buffer.writeu16(outgoing_buff, outgoing_apos, len_23)
				for i_15 = 1, len_23 do
					local val_15 = variants[i_15]
					local len_24 = #val_15
					alloc(2)
					buffer.writeu16(outgoing_buff, outgoing_apos, len_24)
					for i_16 = 1, len_24 do
						local bool_16 = 0
						local bool_16_pos_1 = alloc(1)
						local val_16 = val_15[i_16]
						if val_16 ~= nil then
							bool_16 = bit32.bor(bool_16, 0b0000000000000001)
							table.insert(outgoing_inst, val_16)
						end
						buffer.writeu8(outgoing_buff, bool_16_pos_1, bool_16)
					end
				end
			end
			buffer.writeu8(outgoing_buff, bool_15_pos_1, bool_15)
			local buff, used, inst = outgoing_buff, outgoing_used, outgoing_inst
			for _, player in Players:GetPlayers() do
				load_player(player)
				alloc(used)
				buffer.copy(outgoing_buff, outgoing_apos, buff, 0, used)
				table.move(inst, 1, #inst, #outgoing_inst + 1, outgoing_inst)
				player_map[player] = save()
			end
		end,
		FireExcept = function(Except: Player, buf: (buffer), variants: (({ ({ ((unknown)) }) })?))
			load_empty()
			alloc(1)
			buffer.writeu8(outgoing_buff, outgoing_apos, 0)
			local bool_17 = 0
			local bool_17_pos_1 = alloc(1)
			local len_25 = buffer.len(buf)
			alloc(2)
			buffer.writeu16(outgoing_buff, outgoing_apos, len_25)
			alloc(len_25)
			buffer.copy(outgoing_buff, outgoing_apos, buf, 0, len_25)
			if variants ~= nil then
				bool_17 = bit32.bor(bool_17, 0b0000000000000001)
				local len_26 = #variants
				alloc(2)
				buffer.writeu16(outgoing_buff, outgoing_apos, len_26)
				for i_17 = 1, len_26 do
					local val_17 = variants[i_17]
					local len_27 = #val_17
					alloc(2)
					buffer.writeu16(outgoing_buff, outgoing_apos, len_27)
					for i_18 = 1, len_27 do
						local bool_18 = 0
						local bool_18_pos_1 = alloc(1)
						local val_18 = val_17[i_18]
						if val_18 ~= nil then
							bool_18 = bit32.bor(bool_18, 0b0000000000000001)
							table.insert(outgoing_inst, val_18)
						end
						buffer.writeu8(outgoing_buff, bool_18_pos_1, bool_18)
					end
				end
			end
			buffer.writeu8(outgoing_buff, bool_17_pos_1, bool_17)
			local buff, used, inst = outgoing_buff, outgoing_used, outgoing_inst
			for _, player in Players:GetPlayers() do
				if player ~= Except then
					load_player(player)
					alloc(used)
					buffer.copy(outgoing_buff, outgoing_apos, buff, 0, used)
					table.move(inst, 1, #inst, #outgoing_inst + 1, outgoing_inst)
					player_map[player] = save()
				end
			end
		end,
		FireList = function(List: { [unknown]: Player }, buf: (buffer), variants: (({ ({ ((unknown)) }) })?))
			load_empty()
			alloc(1)
			buffer.writeu8(outgoing_buff, outgoing_apos, 0)
			local bool_19 = 0
			local bool_19_pos_1 = alloc(1)
			local len_28 = buffer.len(buf)
			alloc(2)
			buffer.writeu16(outgoing_buff, outgoing_apos, len_28)
			alloc(len_28)
			buffer.copy(outgoing_buff, outgoing_apos, buf, 0, len_28)
			if variants ~= nil then
				bool_19 = bit32.bor(bool_19, 0b0000000000000001)
				local len_29 = #variants
				alloc(2)
				buffer.writeu16(outgoing_buff, outgoing_apos, len_29)
				for i_19 = 1, len_29 do
					local val_19 = variants[i_19]
					local len_30 = #val_19
					alloc(2)
					buffer.writeu16(outgoing_buff, outgoing_apos, len_30)
					for i_20 = 1, len_30 do
						local bool_20 = 0
						local bool_20_pos_1 = alloc(1)
						local val_20 = val_19[i_20]
						if val_20 ~= nil then
							bool_20 = bit32.bor(bool_20, 0b0000000000000001)
							table.insert(outgoing_inst, val_20)
						end
						buffer.writeu8(outgoing_buff, bool_20_pos_1, bool_20)
					end
				end
			end
			buffer.writeu8(outgoing_buff, bool_19_pos_1, bool_19)
			local buff, used, inst = outgoing_buff, outgoing_used, outgoing_inst
			for _, player in List do
				load_player(player)
				alloc(used)
				buffer.copy(outgoing_buff, outgoing_apos, buff, 0, used)
				table.move(inst, 1, #inst, #outgoing_inst + 1, outgoing_inst)
				player_map[player] = save()
			end
		end,
		FireSet = function(Set: { [Player]: any }, buf: (buffer), variants: (({ ({ ((unknown)) }) })?))
			load_empty()
			alloc(1)
			buffer.writeu8(outgoing_buff, outgoing_apos, 0)
			local bool_21 = 0
			local bool_21_pos_1 = alloc(1)
			local len_31 = buffer.len(buf)
			alloc(2)
			buffer.writeu16(outgoing_buff, outgoing_apos, len_31)
			alloc(len_31)
			buffer.copy(outgoing_buff, outgoing_apos, buf, 0, len_31)
			if variants ~= nil then
				bool_21 = bit32.bor(bool_21, 0b0000000000000001)
				local len_32 = #variants
				alloc(2)
				buffer.writeu16(outgoing_buff, outgoing_apos, len_32)
				for i_21 = 1, len_32 do
					local val_21 = variants[i_21]
					local len_33 = #val_21
					alloc(2)
					buffer.writeu16(outgoing_buff, outgoing_apos, len_33)
					for i_22 = 1, len_33 do
						local bool_22 = 0
						local bool_22_pos_1 = alloc(1)
						local val_22 = val_21[i_22]
						if val_22 ~= nil then
							bool_22 = bit32.bor(bool_22, 0b0000000000000001)
							table.insert(outgoing_inst, val_22)
						end
						buffer.writeu8(outgoing_buff, bool_22_pos_1, bool_22)
					end
				end
			end
			buffer.writeu8(outgoing_buff, bool_21_pos_1, bool_21)
			local buff, used, inst = outgoing_buff, outgoing_used, outgoing_inst
			for player in Set do
				load_player(player)
				alloc(used)
				buffer.copy(outgoing_buff, outgoing_apos, buff, 0, used)
				table.move(inst, 1, #inst, #outgoing_inst + 1, outgoing_inst)
				player_map[player] = save()
			end
		end,
	},
}
type Events = typeof(returns)
return returns
