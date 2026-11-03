--[[

This is the main API for dispatching CISI. It should be here for quick overview of the code, but you should get CISI from the .rbxm file.

]]

local API = {}

const Config = require(script.Config)
const InspectorsConfig = require(script.InspectorsConfig)
const util2 = require(game.ReplicatedStorage.UtilFunc.UtilFuncSet2)

const inspectors = script.Inspectors
const telemetryEvent = game.ReplicatedStorage.Events.CISITelemetry

const reportWaiters: {[Player]: thread} = {}
const sidePings: {[Player]: {RBXScriptConnection}} = {}
const changesConnects: {[Player]: {RBXScriptConnection}} = {}

const eventsCache: {RemoteEvent} = {}

if Config.UseCustomEventsList then
	for _, event in pairs(require(script.CustomEventsList)()) do
		if not event:IsA("RemoteEvent") then continue end
		table.insert(eventsCache, event)
	end
else
	for _, v in pairs(Config.EventsFolders) do
		for _, event in pairs(v:GetChildren()) do
			if not event:IsA("RemoteEvent") then continue end
			table.insert(eventsCache, event)
		end
	end
end

local function getRandomName(length: number?): string
	length = length or 16
	local name = ""
	for i = 1, length do
		name ..= string.char(math.random(97, 122))
	end

	return name
end

local function getSettingsFromInstance(dispatch: LocalScript)
	local classNameSize = #dispatch.Name - 1
	while true do
		if InspectorsConfig[dispatch.Name:sub(1, classNameSize)] then
			return InspectorsConfig[dispatch.Name:sub(1, classNameSize)].Variants[tonumber(dispatch.Name:sub(classNameSize + 1, -1))]
		end
		classNameSize -= 1
	end
end

const getInitialPointer = util2[3]

local function disconnectChangeConnects(player)
	local connects = changesConnects[player]
	if not connects then return end
	for _, v in pairs(connects) do
		v:Disconnect()
	end
	table.clear(changesConnects[player])
end

local function disconnectPingEvents(player: Player)
	local connections = sidePings[player]
	if not connections then return end

	for _, v in pairs(connections) do
		v:Disconnect()
	end

	sidePings[player] = nil
end

API.CancelReport = function(player: Player)
	if reportWaiters[player] then
		if coroutine.running() ~= reportWaiters[player] then
			task.cancel(reportWaiters[player])
		end
		reportWaiters[player] = nil
	end
	disconnectPingEvents(player)
	disconnectChangeConnects(player)
end

API.DispatchSpecific = function(player: Player, dispatch: LocalScript)
	assert(player, "Pass a player when dispatching an inspector.")
	assert(dispatch, "Pass an inspector script when dispatching an inspector.")
	local candidateLocations = player.PlayerGui:GetDescendants()
	local dispatchLocation
	while not dispatchLocation or dispatchLocation:IsA("LocalScript") or dispatchLocation:IsA("RemoteEvent") do
		dispatchLocation = candidateLocations[math.random(#candidateLocations)]
	end
	
	local otherPings = 0
	API.CancelReport(player)
	reportWaiters[player] = task.delay(Config.ReportTime, function() -- Handles missing reports from client
		API.CancelReport(player)
		if otherPings <= Config.SidePingCountReq then return end
		API.OnTamperDetected(player)
	end)
	
	local variantSettings = getSettingsFromInstance(dispatch)
	
	dispatch = dispatch:Clone()
	local dispatchEvent = Instance.new("RemoteEvent")
	dispatchEvent.Parent = dispatch
	dispatch.Name = getRandomName()
	dispatchEvent.Name = getRandomName()
	
	sidePings[player] = {}
	for _, v in pairs(eventsCache) do
		local connection
		connection = v.OnServerEvent:Connect(function(_player)
			if _player ~= player then return end
			otherPings += 1
			connection:Disconnect()
		end)
		
		table.insert(sidePings[player], connection)
	end
	
	local validResponses = {}
	changesConnects[player] = changesConnects[player] or {}
	
	local function addHash()
		table.insert(validResponses, variantSettings.Output(player, dispatch))
	end
	addHash()
	
	local usingCharacterAdded = false
	for path: string, property: string in pairs(variantSettings.DependantValues or {}) do
		local parts = path:split("/")
		local pointer
		for i = 1, #parts do
			if parts[i] == "" then continue end
			if not pointer then
				pointer = getInitialPointer(parts[i], player)
			else
				pointer = pointer:FindFirstChild(parts[i])
			end
		end
		
		if not usingCharacterAdded and string.match(path, "character") then
			table.insert(changesConnects[player], player.CharacterAdded:Connect(addHash))
			usingCharacterAdded = true
		end
		
		table.insert(changesConnects[player], pointer:GetPropertyChangedSignal(property):Connect(addHash))
	end
	
	local existingCode
	dispatchEvent.OnServerEvent:Connect(function(_player, code)
		if _player ~= player then
			-- This can only happen if a bad actor targets another player to attempt to get them banned.
			API.OnTamperDetected(_player)
			return
		end
		if existingCode then
			-- Inspectors should never send more than one code.
			API.OnTamperDetected(player)
			return
		end
		
		existingCode = code
		
		API.CancelReport(player)

		if not table.find(validResponses, code) then
			task.delay(Config.LeaveWindow, function()
				if table.find(validResponses, code) then
					-- Here to prevent any weird edge cases due to network latency.
					return
				end
				if player and player.Parent then
					API.OnCheatingDetected(player)
				end
			end)
		else
			--print("All good!")
		end
	end)

	for i = 1, Config.NoiseAttribs do
		dispatch:SetAttribute("a" .. tostring(i), getRandomName())
	end

	dispatch.Parent = dispatchLocation
	game.Debris:AddItem(dispatch, Config.ReportTime + Config.LeaveWindow)
end

API.Dispatch = function(player: Player)
	if not(player and player.Parent) then return end

	local currentClass
	local rng = math.random(1, 1000) / 10
	for i, v in pairs(InspectorsConfig) do
		if rng <= (v.Chance or 0) then
			currentClass = i
			break
		else
			rng -= v.Chance or 0
		end
	end
	
	if not currentClass then
		return
	end

	local variantsPool = {}
	for i = 1, #InspectorsConfig[currentClass].Variants do
		table.insert(variantsPool, i)
	end

	for i = #variantsPool, 1, -1 do
		if Config.EnablePlayerGrouping then
			local mod = i % Config.PlayerGroups + 1
			if mod ~= util2[1](Config.PlayerGroups, tostring(player.UserId)) then
				table.remove(variantsPool, i)
				continue
			end
		end
		if Config.EnableSessionGrouping then
			local mod = i % Config.SessionGroups + 1
			if mod ~= util2[1](Config.SessionGroups, game.JobId) then
				table.remove(variantsPool, i)
				continue
			end
		end
	end
	
	assert(#variantsPool > 0, "Failed to dispatch an inspector: Too few variants. Make sure you have enough variants, or decrease PlayerGroups or SessionGroups.")
	
	local variantID = math.random(#variantsPool)
	local variantSettings = InspectorsConfig[currentClass].Variants[variantID]
	local dispatch = inspectors:FindFirstChild(currentClass .. tostring(variantID))
	assert(dispatch, `Mismatch between Inspectors folder and InspectorsConfig: {currentClass .. tostring(variantID)} not found.`)
	
	API.DispatchSpecific(player, dispatch)
end

API.WaitForInspectionEnd = function(player)
	local dt = 0
	while reportWaiters[player] do
		dt += task.wait()
	end
	return dt
end

API.OnCheatingDetected = function(player: Player)
	-- Up to developer implementation
end

API.OnTamperDetected = function(player: Player)
	-- Up to developer implementation
end

game.Players.PlayerRemoving:Connect(function(player)
	API.CancelReport(player)
end)

return API
