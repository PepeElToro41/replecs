--!optimize 2

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local Jecs = require(ReplicatedStorage.packages.jecs)
local Jabby = require(ReplicatedStorage.packages.jabby)

local world = require(ReplicatedStorage.code.world)

type Map<K, T> = { [K]: T }
type Set<T> = { [T]: true }
type Array<T> = { T }

local HIDDEN = world:entity()
local DEPENDS_ON = world:entity()
local PHASE = world:entity()

local SYSTEM = world:component() :: Jecs.Entity<{ name: string, callback: () -> (), group: string? }>
local EVENT = world:component()

local PRE_RENDER = world:entity()
local HEARBEAT = world:entity()
local PRE_ANIMATION = world:entity()
local PRE_SIMULATION = world:entity()
local POST_SIMULATION = world:entity()

type System = {
	callback: (...any) -> (),
	name: string,
	id: any?,
}
type Systems = Array<System>

world:add(PRE_RENDER, PHASE)
world:set(PRE_RENDER, EVENT, RunService.PreRender)

world:add(HEARBEAT, PHASE)
world:set(HEARBEAT, EVENT, RunService.Heartbeat)

world:add(PRE_ANIMATION, PHASE)
world:set(PRE_ANIMATION, EVENT, RunService.PreAnimation)

world:add(PRE_SIMULATION, PHASE)
world:set(PRE_SIMULATION, EVENT, RunService.PreSimulation)

world:add(POST_SIMULATION, PHASE)
world:set(POST_SIMULATION, EVENT, RunService.PostSimulation)

local StepPhases = {
	Hearbeat = HEARBEAT,
	PreRender = PRE_RENDER,
	PreAnimation = PRE_ANIMATION,
	PreSimulation = PRE_SIMULATION,
	PostSimulation = POST_SIMULATION,
}

local CurrentSystem = {} :: System

local SCHEDULER = Jabby.scheduler.create()

function Run(...)
	local id = CurrentSystem.id
	if id ~= nil then
		SCHEDULER:run(id, CurrentSystem.callback, ...)
	else
		CurrentSystem.callback(...)
	end
end

function ConnectEvent(event: any, callback: (...any) -> ()): any
	if typeof(event) == "RBXScriptSignal" then
		return event:Connect(callback)
	elseif event["Connect"] then
		return event:Connect(callback)
	elseif event["connect"] then
		return event:connect(callback)
	elseif event["subscribe"] then
		return event.subscribe(callback)
	else
		error "Event-like object does not have a supported connect method."
	end
end

local OTHER = "__other__"

type OrderedSystems = Array<string | ((...any) -> ())>

function Initialize(events: Map<any, Array<System>>, orderTable: OrderedSystems?)
	local connections: Map<any, any> = {}

	if orderTable then
		local old_events = events
		events = {}

		for event, systems in old_events do
			local ordered = table.clone(systems)
			table.sort(ordered, function(a, b)
				local a_order = table.find(orderTable, a.callback) or table.find(orderTable, OTHER) or 0
				local b_order = table.find(orderTable, b.callback) or table.find(orderTable, OTHER) or 0
				return a_order < b_order
			end)
			events[event] = ordered
		end
	end

	for event, systems in events do
		if not event then
			continue
		end

		local eventName = tostring(event)
		local connection = ConnectEvent(event, function(...)
			debug.profilebegin("JECS - " .. eventName)
			for _, system in systems do
				CurrentSystem = system

				debug.profilebegin("JECS - " .. system.name)
				Run(...)
				debug.profileend()
			end
			debug.profileend()
		end)
		connections[event] = connection
	end

	return function()
		for event, connection in connections do
			connection:disconnect()
		end
	end
end

function CollectSystemsUnderEventRecursive(systems: Systems, phase: Jecs.Entity)
	local depends = Jecs.pair(DEPENDS_ON, phase)
	local phaseHidden = world:has(phase, HIDDEN)

	for systemId, system in world:query(SYSTEM):with(depends):iter() do
		local systemEntry: System = {
			name = system.name,
			callback = system.callback,
		}

		local hidden = phaseHidden or world:has(systemId, HIDDEN)
		if not hidden then
			systemEntry.id = SCHEDULER:register_system {
				name = system.name,
				phase = system.group or "main",
			}
		end
		systems[#systems + 1] = systemEntry
	end

	for after in world:query(PHASE):with(depends):iter() do
		CollectSystemsUnderEventRecursive(systems, after)
	end
end

function CollectSystemsUnderEvent(event: Jecs.Entity)
	local systems: Systems = {}
	CollectSystemsUnderEventRecursive(systems, event)
	return systems
end

function CollectSystems()
	local events: { [any]: Array<System> } = {}
	for phase, event in world:query(EVENT):with(PHASE):iter() do
		events[event] = CollectSystemsUnderEvent(phase)
	end
	return events
end

function Phase(event: any?, after: Jecs.Entity, hidden: boolean?)
	local phase = world:entity()
	world:add(phase, PHASE)

	if after then
		local dependency = Jecs.pair(DEPENDS_ON, after)
		world:add(phase, dependency)
	end
	if event then
		world:set(phase, EVENT, event)
	end
	if hidden then
		world:add(phase, HIDDEN)
	end
end

function System(callback: (...any) -> (), phase: Jecs.Entity?, group: string?, hidden: boolean?)
	local system = world:entity()
	world:set(system, SYSTEM, {
		callback = callback,
		name = debug.info(callback, "n"),
		group = group,
	})

	phase = phase or HEARBEAT
	if hidden then
		world:add(system, HIDDEN)
	end

	world:add(system, Jecs.pair(DEPENDS_ON, phase :: any))
	return system
end

return {
	StepPhases = StepPhases,
	Initialize = Initialize,
	CollectSystems = CollectSystems,
	System = System,
	Phase = Phase,
	Phases = StepPhases,
	Scheduler = SCHEDULER,
}
