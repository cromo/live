local state_machine = {}
local sm = state_machine

local EventQueue = {data = {}}
sm.EventQueue = EventQueue
function EventQueue.add(event)
  EventQueue.data[#EventQueue.data + 1] = event
end

function EventQueue.pop()
  return table.remove(EventQueue.data, 1)
end

function EventQueue.is_empty()
  return #EventQueue.data == 0
end

function EventQueue.pump(stateful_objects)
  local event = EventQueue.pop()
  while event do
    for _, stateful_object in ipairs(stateful_objects) do
      sm.process(stateful_object, event)
    end
    event = EventQueue.pop()
  end
end

local Event = {}
sm.Event = Event
function Event.new(kind, payload)
  local event = {}
  setmetatable(event, {__index = sm.Event})
  event.kind = kind
  event.payload = payload
  return event
end

local Emitter = {}
sm.Emitter = Emitter
function Emitter.new(kind)
  local emitter = {}
  setmetatable(emitter, {__index = sm.Emitter})
  emitter.kind = kind
  return emitter
end

function Emitter:emit(payload)
  local event = Event.new(self.kind, payload)
  EventQueue.add(event)
end

local Edge = {}
sm.Edge = Edge
function Edge.new(trigger, guard, effect, to)
  local edge = {}
  setmetatable(edge, {__index = sm.Edge})
  edge.trigger = trigger
  edge.guard = guard
  edge.effect = effect
  edge.to = to
  return edge
end

function Edge:matches(event)
  if self.trigger and event then
    return self.trigger == event.kind
  end
  return true
end

function Edge:passes_guard(stateful_object, event)
  if self.guard then
    return self.guard(stateful_object, event)
  end
  return true
end

function Edge:execute(stateful_object, payload, event)
  if self.effect then
    self.effect(stateful_object, payload, event)
  end
  return self.to
end

local initial = 'initial'
local final = 'final'
local regular = 'regular'
local choice = 'choice'
local State = {}
sm.State = State
function State.new(name, transitions)
  local state = {}
  setmetatable(state, {__index = sm.State})
  state.kind = regular
  state.name = name
  state.transitions = transitions
  return state
end

function State.new_choice(name, transitions)
  local state = {}
  setmetatable(state, {__index = sm.State})
  state.kind = choice
  state.name = name
  state.transitions = transitions
  return state
end

function State.new_initial(transition)
  local state = {}
  setmetatable(state, {__index = sm.State})
  state.kind = initial
  state.name = initial
  state.transitions = {transition}
  return state
end

function State.new_final()
  local state = {}
  setmetatable(state, {__index = sm.State})
  state.kind = final
  state.name = final
  state.transitions = {}
  return state
end

local StateMachine = {}
sm.StateMachine = StateMachine
function StateMachine.new(states)
  local machine = {}
  setmetatable(machine, {__index = sm.StateMachine})
  -- TODO: add validation
  local state_lookup = {}
  for _, state in ipairs(states) do
    state_lookup[state.name] = state
  end
  state_lookup.final = State.new_final()
  machine.states = state_lookup
  return machine
end

local function lazy_any(fs)
  return function(...)
    if #fs == 0 then
      return false
    end
    for _, f in ipairs(fs) do
      if not f(...) then
	return false
      end
    end
    return true
  end
end

local function lazy_each(fs)
  return function(...)
    for _, f in ipairs(fs) do
      f(...)
    end
  end
end

function StateMachine.new_from_table(raw_states)
  -- {effect, to}
  -- {'name', {trigger, guard, effect, to}, [kind = blah]}
  assert(1 <= #raw_states, "No states provided in table")
  local initial_transition = raw_states[1]
  states = {State.new_initial(sm.Edge.new(nil, nil, initial_transition[1], initial_transition[2]))}
  if #raw_states == 1 then
    return StateMachine.new(states)
  end
  local kinds = {regular = State.new, choice = State.new_choice}
  for i = 2, #raw_states do
    local raw_state = raw_states[i]
    local name = raw_state[1]
    local kind = regular
    if raw_state.kind then
      kind = raw_state.kind
    end
    kind = kinds[kind]
    edges = {}
    for _, raw_transition in ipairs(raw_state[2]) do
      local trigger = raw_transition[1]
      local guard = raw_transition[2]
      if type(guard) == 'table' then
	guard = lazy_any(guard)
      end
      local effect = raw_transition[3]
      if type(effect) == 'table' then
	effect = lazy_each(effect)
      end
      local to = raw_transition[4] or name
      edges[#edges + 1] = Edge.new(trigger, guard, effect, to)
    end
    local state = kind(name, edges)
    states[#states + 1] = state
  end
  return StateMachine.new(states)
end

function StateMachine:initialize_state(stateful_object)
  stateful_object.state = {
    name = initial,
    machine = self,
  }
  self:process_event(stateful_object, sm.Event.new(nil, nil))
end

function StateMachine:process_event(stateful_object, event)
  local current_state_name = stateful_object.state.name
  assert(self.states[current_state_name], "Current object state not a state in state machine")
  local transition_was_taken = false
  repeat
    transition_was_taken = false
    local state = self.states[current_state_name]
    for i, transition in ipairs(state.transitions) do
      if transition:matches(event) and
          transition:passes_guard(stateful_object, event.payload) then
	current_state_name = transition:execute(stateful_object, event.payload, event)
	assert(self.states[current_state_name], "State transitioned to does not exist in the state table: " .. current_state_name)
	transition_was_taken = true
	break
      end
    end
  until self.states[current_state_name].kind == regular or self.states[current_state_name].kind == final or not transition_was_taken
  stateful_object.state.name = current_state_name
end

function state_machine.process(stateful_object, event)
  stateful_object.state.machine:process_event(stateful_object, event)
end

return state_machine
