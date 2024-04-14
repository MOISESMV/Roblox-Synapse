-- better to handle this in its own module than try to weave it into Catwork
-- handles dispatching of Fragments

local Common = require(script.Parent.Common)
local ERROR = require(script.Parent.Error)

local Dispatcher = {}
local fragmentDispatchState = {}

local function safeAsyncHandler(err)
	ERROR.DISPATCHER_SPAWN_ERR(ERROR.traceback(err))
	return err
end

local function getFragmentState(f)
	local state = fragmentDispatchState[f]
	if not state then
		state = {
			Spawned = false,
			IsOK = false,
			ErrMsg = nil,
			Thread = nil,
			Ready = false,
			XPC = safeAsyncHandler,

			HeldThreads = {},
			Dispatchers = {}
		}

		fragmentDispatchState[f] = state
	end
	
	return state
end

local function runFragmentAction(
	f,
	spawnSignal,
	service,
	state
)
	state.Spawned = true
	state.Thread = coroutine.running()
	local ok, err = xpcall(spawnSignal, state.XPC, service, f)
	
	state.Ready = true
	state.IsOK = ok
	state.ErrMsg = err

	for _, v in state.Dispatchers do
		task.spawn(v, ok, err)
	end

	for _, v in state.HeldThreads do
		task.spawn(v, ok, err)
	end
	
	return ok, err
end

local function spawnFragment(self, state)
	local service = self.Service
	local spawnSignal = service.Spawning

	task.spawn(runFragmentAction, self, spawnSignal, service, state)
end

function Dispatcher.spawnFragment(f, asyncHandler)
	if not Common.Fragments[f.FullID] then
		-- the fragment does not exist, most likely because it was destroyed
		ERROR:DISPATCHER_DESTROYED_FRAGMENT(f)
	end
	
	local state = getFragmentState(f)
	
	-- basically new logic for Spawn
	if state.Spawned then
		ERROR:DISPATCHER_ALREADY_SPAWNED(f)
	end

	if asyncHandler then
		state.XPC = asyncHandler
	end

	return spawnFragment(f, state)
end

function Dispatcher.cleanFragmentState(f)
	fragmentDispatchState[f] = nil
end

function Dispatcher.slotAwait(f)
	local state = getFragmentState(f)

	if state.ErrMsg then
		return false, state.ErrMsg
	elseif state.IsOk then
		return true
	end

	table.insert(state.HeldThreads, coroutine.running())
	return coroutine.yield()
end

function Dispatcher.slotHandleAsync(f, asyncHandler)
	local state = getFragmentState(f)

	if state.ErrMsg then
		asyncHandler(false, state.ErrMsg)
	elseif state.IsOk then
		asyncHandler(true)
	else
		table.insert(state.Dispatchers, asyncHandler)
	end
end

function Dispatcher.isSelfAsyncCall(f)
	-- blocks self:Await calls while Init is running
	local state = getFragmentState(f)
	local co = coroutine.running()
	
	if state.Spawned and co == state.Thread then
		return not state.Ready
	end
	
	return false
end

return Dispatcher