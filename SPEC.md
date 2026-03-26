# Ogol Runtime Process Specification

## 1. Scope

This document defines the target Ogol language and runtime architecture.

The target is not a pure interpreter, not a digital twin, and not a generic
workflow engine. The target is a BEAM-native language for authoring machine
brains that compile directly to real OTP runtime processes.

The central commitment is:

```text
one machine instance = one primary :gen_statem brain process
```

Each machine instance is a real process with:

- a mailbox
- a callback state
- callback data
- OTP lifecycle and failure semantics
- a real hardware or software boundary

The generated process is the controller that thinks on behalf of the hardware.

EtherCAT is the primary hardware integration path. Other adapters, such as
Modbus or Profinet, may implement the same hardware boundary contract later.

## 2. Non-Goals

This specification does not try to:

- preserve the current generic `Ogol.Runtime` interpreter as the normative
  execution model
- model raw Erlang selective receive semantics
- hide OTP supervision, timers, monitors, or links behind a fake monolithic
  abstraction
- define a second behavior model above generated OTP code
- keep host-side reactor orchestration as a first-class language concept
- keep `effect/3` as the primary authoring mechanism

Some compile-time normalization still exists, but it is an implementation
detail. The public semantics are the semantics of the generated OTP runtime.

## 3. Core Commitments

The target system commits to these rules:

1. Every machine module compiles to a `:gen_statem` callback module.
2. Every authored state becomes a real OTP callback state.
3. The default callback mode is `[:state_functions, :state_enter]`.
4. A machine reacts only to delivered OTP events.
5. Commands are outbound instructions to an external executor, not proof of
   effect.
6. Child machines are other machine processes, not embedded fake submachines.
7. Parent-child communication reuses the same machine-boundary semantics as all
   other communication.
8. Topology and supervision are generated around machine processes, not mixed
   into local state callback semantics.
9. “Let it crash” applies to the machine brain, but the hardware boundary must
   still guarantee a safe physical envelope.

## 4. Design Principle

A term is classified by its meaning at the machine boundary, not by source or
transport.

Source does not define type.
Transport does not define type.
Direction is primary, followed by shape, then interaction, then role.

### 4.1 Normative Language

The keywords `MUST`, `MUST NOT`, `SHOULD`, `SHOULD NOT`, and `MAY` in this
document are normative.

- `MUST` / `MUST NOT` mean required behavior for a conforming implementation
- `SHOULD` / `SHOULD NOT` mean recommended behavior with a justified reason
  required to deviate
- `MAY` means optional behavior that does not change core conformance

## 5. Semantic Basis

### 5.1 Axes

| Axis | Values | Meaning |
|---|---|---|
| Direction | `in`, `out` | crosses into the machine vs leaves the machine |
| Shape | `level`, `pulse` | persistent value vs discrete occurrence |
| Interaction | `passive`, `async`, `sync` | current value, fire-and-forget occurrence, or blocking request/reply |
| Role | `observation`, `control`, `actuation`, `coordination`, `presentation` | why this thing exists |

### 5.2 Canonical DSL Terms

| Term | Direction | Shape | Interaction | Role | Definition |
|---|---|---|---|---|---|
| `fact` | `in` | `level` | `passive` | `observation` | a remembered value representing an observed condition of the world or environment |
| `event` | `in` | `pulse` | `async` | `observation` | an incoming occurrence telling the machine that something happened |
| `request` | `in` | `pulse` | `sync` | `control` | an incoming ask for the machine to make a decision or perform behavior and return a result |
| `command` | `out` | `pulse` | `async` | `actuation` | an outgoing instruction telling an external executor to do something |
| `output` | `out` | `level` | `passive` | `actuation` | an outbound persistent value actively driven by the machine toward an external interface, device, or observer |
| `signal` | `out` | `pulse` | `async` | `coordination` | an outgoing occurrence announcing that something happened or changed |

### 5.3 Tightened Definitions

#### `fact`

A fact is a stored value whose semantic origin is observation.

It is not merely “data in state.”
It is not a computed internal variable.
It is not a desired target.

Examples:

- measured temperature
- door position sensed from hardware
- remote system online status last observed
- operator mode switch position as read

Not fact:

- retry counter
- current state node
- desired temperature setpoint
- derived alarm state unless explicitly treated as observed from elsewhere

#### `event`

An event is an incoming asynchronous occurrence.

It says: something happened.
It does not block for a reply.
It may trigger behavior, but it is not itself a synchronous ask.

Examples:

- coin inserted
- timeout elapsed
- sensor edge detected
- upstream machine says batch finished

#### `request`

A request is an inbound control occurrence addressed to the machine as
decision-maker, with reply or back-pressure semantics. In runtime terms this is
typically synchronous.

Examples:

- open session
- calculate route
- authorize dispense
- transition to maintenance mode and report result

#### `command`

A command is an outgoing actuating occurrence.

It says: external world, executor, or adapter, do this.
A command leaves the machine after the machine has already decided.

Examples:

- energize valve
- write register
- move axis to position
- persist record to external store

#### `output`

An output is an outbound persistent value actively driven by the machine
toward an external interface, device, or observer.

Examples:

- motor enable line
- lamp state
- EtherCAT process image bit
- published current status value

#### `signal`

A signal is an outgoing coordination occurrence.

It says: this happened; others may react.
It informs or synchronizes observers, parents, or peer machines.
It does not directly instruct an executor.

Examples:

- `cycle_completed`
- `state_changed`
- `alarm_raised`
- `item_rejected`

### 5.4 Guardrails

1. Source does not define type.

   A `request` from an operator, parent machine, test harness, or service is
   still `request` if it is an inbound control ask with reply semantics.

2. Direction outranks origin.

   First decide whether the thing enters or leaves the machine. Only then
   decide its role.

3. Structure alone is not enough.

   - `event` and `request` are both inbound pulses
   - `command` and `signal` are both outbound pulses
   - `fact` and `output` are both persistent values

   They differ by semantics, not only by shape.

4. A fact is not any stored field.

   A field is a fact only if it stands for something observed from outside the
   machine.

5. A request is pre-decision; a command is post-decision.

   A request asks the machine to decide or act.
   A command is what the machine emits after deciding.

6. A signal announces; a command directs.

   `open_door` is a command.
   `door_opened` is a signal.

### 5.5 Decision Procedure

Use this classification rule for anything crossing the machine boundary:

1. Does it cross the boundary at all?
   - If no, it is internal state or implementation detail.
2. Which direction?
   - entering -> `in`
   - leaving -> `out`
3. Is it a persistent value or a discrete occurrence?
   - persistent/current value -> `level`
   - one-time happening -> `pulse`
4. If inbound:
   - inbound + observed level -> `fact`
   - inbound + async occurrence -> `event`
   - inbound + control ask with reply/back-pressure semantics -> `request`
5. If outbound:
   - outbound + driven level -> `output`
   - outbound + actuation occurrence -> `command`
   - outbound + coordination occurrence -> `signal`

## 6. Public DSL

The target public DSL has these top-level sections:

- `machine`
- `boundary`
- `memory`
- `states`
- `transitions`
- `safety`
- `children`

The public entities are:

- `fact`
- `event`
- `request`
- `command`
- `output`
- `signal`
- `field`
- `always`
- `while_in`
- `child`

There is no compatibility layer in this target. Legacy names such as
`interface`, `input`, `intent`, `value`, `invariants`, and `in_state` are not
part of the new specification.

## 7. Section Semantics

### 7.1 `machine`

`machine` defines machine-level identity and code-generation options.

Required semantics:

- machine identity
- human meaning
- optional hardware adapter defaults
- optional topology-generation defaults

What does **not** belong here as local machine semantics:

- supervision behavior of the local callback state machine
- host-side reactor logic
- arbitrary runtime orchestration code

Supervision settings, if exposed here at all, are generation inputs for the
companion topology module, not local state-machine rules.

### 7.2 `boundary`

`boundary` defines the machine interface.

This is the contract for:

- human operators
- other machines
- hardware adapters
- parent topologies
- tests
- HMIs

It is the machine’s true public surface.

### 7.3 `memory`

`memory` defines machine-owned state that is not merely the latest observed
external value.

Examples:

- retry counters
- correlation ids
- recipe selections
- expectation state
- protocol phase bookkeeping

### 7.4 `states`

`states` declares the real OTP callback states of the machine.

Required semantics:

- exactly one initial state
- zero or more state-entry actions
- optional operator-facing metadata such as `status` and `meaning`

Every authored state becomes a generated `StateName/3` callback.

### 7.5 `transitions`

`transitions` declare event-handling rules.

Each transition defines:

- `source`
- `destination`
- `on`
- optional guard
- optional priority
- ordered actions

Transitions compile into ordered branches inside the source state callback.

### 7.6 `safety`

`safety` declares generated process-local safety checks.

Supported forms:

- `always`
- `while_in`

Safety is not merely documentation. It MUST compile to runtime checks.

### 7.7 `children`

`children` declares runtime child machine processes.

Each child declaration supplies:

- logical child name
- child machine module
- child restart policy
- parent-routing rules
- optional child startup options

Children are not embedded local structs. They are runtime processes deployed
and supervised by generated topology.

## 8. Runtime Reading

| Term | Runtime reading |
|---|---|
| `fact` | stored machine data updated from incoming observation |
| `event` | asynchronously delivered incoming occurrence, often `cast` or `info` |
| `request` | synchronously delivered incoming occurrence, often `call` |
| `command` | outbound dispatch to adapter, device, service, or world |
| `output` | persistent outward-driven value in machine state, process image, or published interface |
| `signal` | outbound emitted occurrence for parent, observer, peer, or bus |

Orthogonal attributes such as timestamp, source identity, units, quality,
freshness, confidence, provenance, and expiry are not top-level term kinds.
They belong in payload or metadata.

## 9. Generated Runtime Shape

For a machine module `MyApp.SorterMachine`, `use Ogol.Machine` generates or
injects these runtime functions into that same module:

- `@behaviour :gen_statem`
- `start_link/1`
- `start/1`
- `child_spec/1`
- `callback_mode/0`
- `init/1`
- one state callback per authored state, arity 3
- `terminate/3`
- `code_change/4`

Required v1 callback mode:

```elixir
callback_mode() do
  [:state_functions, :state_enter]
end
```

Generated state names are the authored state atoms.

## 10. Generated Topology Shape

If a machine declares children, the compiler also generates a companion module,
for example:

```text
MyApp.SorterMachine
MyApp.SorterMachine.Topology
```

Responsibilities:

- `MyApp.SorterMachine`
  - the primary brain process
  - local state transitions
  - local safety checks
  - hardware command emission

- `MyApp.SorterMachine.Topology`
  - starts the brain and children
  - supervises them with real OTP supervision
  - routes child signals, declared child state entries, and child downs to the
    parent as events
  - resolves child targets for parent actions like `send_request`

Deployment rule:

- atomic machine -> start the machine module directly
- composite machine -> start the topology module directly

The machine module is always the semantic brain. The topology module is the
generated deployment shell around it.

## 11. Machine Data Model

Each machine module generates an internal callback-data struct. The exact
representation may vary, but it MUST preserve these semantic partitions:

```elixir
defmodule Machine.Data do
  defstruct [
    :machine_id,
    :hardware_adapter,
    :hardware_ref,
    facts: %{},
    fields: %{},
    outputs: %{},
    meta: %{}
  ]
end
```

Required partitions:

- `facts`: remembered observed values
- `fields`: machine-owned memory
- `outputs`: persistent driven values
- `meta`: runtime metadata such as correlation ids, adapter refs, and event
  metadata

Child supervisor state and restart bookkeeping do not belong here. They belong
in generated topology code.

## 12. Delivered Event Model

The machine never observes the world directly. It reacts only to delivered OTP
events.

The generated module handles these delivered classes:

- `{:call, from}` with `{:request, name, data, meta}`
- `:cast` with `{:event, name, data, meta}`
- `:info` with adapter, monitor, link, or topology-routed tuples
- `:internal` with compiler-generated continuation events
- state enter calls
- state timeout calls

Normalized event families:

- `request`
- `event`
- `internal`
- `hardware`
- `child`
- `monitor`
- `link`
- `state_timeout`

This normalization is a generated helper inside the machine module, not a
shared interpreter.

`event` is both a public DSL boundary term and one normalized runtime family.
The other normalized families are generated runtime delivery classes and do not
introduce additional public DSL term kinds.

### 12.1 Fact Patch Eligibility

Implicit fact patch merge is reserved for delivered observation families.

- normalized `event` and `hardware` deliveries MAY carry an implicit fact patch
- `request`, `internal`, `child`, `monitor`, `link`, and `state_timeout`
  deliveries MUST NOT mutate `data.facts` implicitly

If topology or another machine needs to contribute an observation, it MUST
either:

- deliver an observation-bearing `event`
- deliver a `hardware` event through the adapter boundary
- or rely on authored logic that calls `set_fact`

### 12.2 Handled Event

A delivered event is considered handled once normalization, any eligible
implicit fact patch merge, and default matched or unmatched behavior have
completed.

Safety timing and observability rules in this document apply to handled events
in that sense.

## 13. Initialization

`init/1` performs these steps:

1. build callback data from declared defaults and runtime options
2. install the configured hardware adapter reference
3. choose the single authored initial state
4. run generated state-entry actions for the initial state
5. run generated safety checks
6. return `{ok, initial_state, data, actions}`

If safety fails during initialization, the machine start fails.

## 14. Transition Compilation

For each authored state, the compiler generates one `StateName/3` callback
function.

All transitions leaving that state are compiled into that function in this
order:

1. higher `priority` first
2. declaration order as tiebreaker

A transition matches when:

- the current callback function corresponds to the transition source state
- the delivered event family and name match `on`
- the guard, if present, evaluates to `true`

Before any guard is evaluated, any eligible fact patch carried by a normalized
`event` or `hardware` delivery MUST be merged into `data.facts`.

If no transition matches:

- unmatched `request` MUST reply with `{:error, :unhandled_request}`
- unmatched `event` and `info` MUST keep state and data
- unmatched internal events MUST keep state unless explicitly marked strict

A delivered event that updates facts but matches no transition still counts as a
handled event for later safety evaluation.

The generated module MUST NOT introduce ad hoc `receive` loops.

## 15. State Entry Semantics

State entry actions compile to `state_enter` handling in the generated state
callbacks.

Entry actions run:

- during initialization of the initial state
- after every state change into that state

Entry actions run after transition actions and after the destination state has
been chosen, but before final safety validation and before any staged outward
machine-boundary effect or staged OTP action is committed.

Self-transition behavior MUST be explicit in the DSL:

- default self-transition -> `keep_state`, no re-entry
- explicit re-enter self-transition -> leave and re-enter the same authored
  state, rerunning state-entry actions

The DSL MUST therefore provide a way to mark re-entry explicitly. This is part
of the target design, not optional prose.

## 16. Guard Semantics

Guards SHOULD compile to plain Elixir predicates where possible.

Preferred target:

- simple declarative guard expressions
- optional typed callback escape hatches

Escape hatch form:

```elixir
guard callback(:can_start?)
```

Generated call shape:

```elixir
__MODULE__.can_start?(normalized_event, data)
```

Guard callbacks MUST be pure and side-effect free.

## 17. Action Language

The target backend does not use `effect/3` as the primary behavior language.
It uses first-class generated actions.

### 17.1 Action Ordering

Actions in one transition or state-entry block execute in authored order against
working callback data.

Normative handling order for a matching transition is:

1. merge any eligible implicit fact patch
2. evaluate the guard
3. execute transition actions in authored order
4. commit any state change chosen by the transition
5. execute destination state-entry actions if the destination state is entered
6. validate reply cardinality and assemble staged OTP actions
7. run safety checks against the resulting machine state
8. emit or return staged OTP continuation and reply actions in the required OTP
   form, preserving authored order where order is semantically observable

If any action fails:

- the machine stops with an abnormal exit unless the action explicitly defines a
  recoverable failure mode
- no later actions in the same ordered block are executed
- staged outward effects that have not yet been committed MUST be discarded

Action staging rules:

- local mutations (`set_fact`, `set_field`, `set_output`) take effect
  immediately in working callback data
- outward machine-boundary effects (`signal`, `command`, `send_event`) are
  staged in authored order and committed only after safety succeeds
- `send_request` is executed when encountered because it carries synchronous
  control and back-pressure semantics
- OTP continuation actions (`reply`, `internal`, `state_timeout`,
  `cancel_timeout`, `hibernate`, `stop`) are staged and returned only after
  reply validation and safety succeed

This yields three semantic buckets:

- working local mutations
- staged outward machine-boundary effects
- staged OTP continuation and reply actions

### 17.2 Core Action Set

The minimum target action vocabulary is:

- `set_fact`
- `set_field`
- `set_output`
- `signal`
- `command`
- `reply`
- `internal`
- `send_request`
- `send_event`
- `state_timeout`
- `cancel_timeout`
- `monitor`
- `demonitor`
- `link`
- `unlink`
- `stop`
- `hibernate`
- `callback`
- `foreign`

`callback` and `foreign` are escape hatches. Everything else SHOULD compile to
generated code directly.

### 17.3 Reply Cardinality

Reply cardinality is part of the action semantics.

- while handling a `request`, the machine MAY stage zero or one `reply/1`
- more than one staged reply is illegal and MUST crash the machine with
  `{:invalid_reply_cardinality, count}`
- if a `request` is unmatched, the generated module MUST reply with
  `{:error, :unhandled_request}`
- if a matched `request` completes normally without an explicit reply, the
  generated module MUST reply with `{:error, :missing_reply}`
- if the machine stops or crashes before replying, normal OTP exit and timeout
  semantics apply; the implementation MUST NOT invent a synthetic reply

### 17.4 Action Meanings

#### `set_fact(name, value)`

Update a remembered observed value.

`set_fact` is for integrating an observation into remembered state, not for
general local mutation.

`set_fact` MUST NOT be used for:

- counters
- desired targets
- derived control bookkeeping
- arbitrary internal variables

Use `set_field` for machine-owned memory.

#### `set_field(name, value)`

Update machine-owned memory.

#### `set_output(name, value)`

Update a persistent driven outward value.

#### `signal(name, data \\ %{}, meta \\ %{})`

Emit an outbound coordination occurrence.

#### `command(name, data \\ %{}, meta \\ %{})`

Emit an outbound actuation occurrence to the hardware boundary.

#### `reply(value)`

Stage a reply to the current inbound request. Valid only while handling a
`request`.

#### `internal(name, data \\ %{}, meta \\ %{})`

Insert an internal continuation event.

`internal` compiles to a generated `next_event`-style continuation and MUST be
processed before later external mailbox traffic is handled.

`internal` does not by itself change machine state. It preserves the current
state unless the surrounding transition changes state.

Because recursive internal continuations can starve ordinary mailbox traffic,
authors SHOULD avoid unbounded internal chains and implementations SHOULD warn
about obviously unbounded patterns.

#### `send_request(target, name, data \\ %{}, meta \\ %{}, timeout \\ default)`

Send an inbound control ask with reply/back-pressure semantics to another
machine. `target` may address a child or another topology-visible machine.

In the first target cut, `send_request` is synchronous and status-oriented:

- the action succeeds only if the target replies once before timeout
- a timeout, exit, or unavailable target is action failure
- the first-class action language does not bind the reply payload into local
  data; if the author needs reply-dependent local logic in the same step, they
  SHOULD use an explicit escape hatch until a typed binding form exists

In v1, `send_request` is a synchronization primitive, not a general
request/reply dataflow construct.

#### `send_event(target, name, data \\ %{}, meta \\ %{})`

Send an inbound asynchronous occurrence to another machine.

#### `state_timeout(name, delay_ms, data \\ %{}, meta \\ %{})`

Set a named DSL-managed timeout that later arrives as a delivered timeout event.

Timeout namespace rules:

- multiple named timeouts MAY coexist
- scheduling a timeout with the same `name` MUST replace the previous timeout of
  that name
- later delivery MUST arrive as a normalized `state_timeout` event carrying the
  timeout name in metadata
- implementations MAY use `:gen_statem` helper actions, timer refs, or other OTP
  mechanisms internally, but they MUST preserve the named coexistence semantics
  above

#### `cancel_timeout(name)`

Cancel a previously scheduled DSL-managed timeout of the same name.

`cancel_timeout(name)` MUST be idempotent.

#### `monitor(target, name)`

Install a monitor and route later `:DOWN` into a delivered event.

Monitor names are machine-local identifiers within the generated runtime
instance.

#### `demonitor(name)`

Remove a previously installed monitor.

#### `link(target)`

Link to a target process where appropriate.

#### `unlink(target)`

Remove a previously installed link where appropriate.

#### `stop(reason)`

Stop the machine process intentionally.

#### `hibernate`

Request hibernation after transition handling.

### 17.5 Why `send_request` / `send_event`

The language does not introduce a separate parent-child communication interface.
It reuses the same machine boundary semantics everywhere.

Examples:

- operator -> machine: `request`
- parent -> child: `send_request`
- timer -> machine: `event`
- child -> parent: routed `signal` or bound state/down event

Source does not define type.
Direction and role define type first.

## 18. Child Communication

### 18.1 Parent to Child

The parent communicates with a child using the same semantic interface it would
use with any other machine:

- `send_request(target, ...)`
- `send_event(target, ...)`

`target` is resolved by topology, not by local machine state.

`send_request` semantics:

- synchronous by default
- applies back-pressure
- if the child is unavailable, the action fails and the parent crashes unless
  the generated code or action form explicitly handles the failure

`send_event` semantics:

- asynchronous
- the default behavior for an unavailable target MUST be action failure
- topology MAY convert an unavailable target into a routed local event such as
  `child_unavailable` only if that policy is explicitly declared
- silent dropping MUST NOT occur

### 18.2 Child to Parent

Children do not mutate parent state.

Instead, topology routes child behavior back into the parent boundary using
declared bindings:

- child signal -> parent event
- child state entry -> parent event
- child down -> parent event

This preserves actor-style isolation.

Every child-originated routed event MUST include:

- `meta.origin = :child`
- `meta.child = <logical_child_name>`

It SHOULD also include `meta.child_pid` and original child payload or exit
reason when available.

## 19. Hardware Semantics

The hardware boundary is first-class and EtherCAT-first.

Every machine instance receives a hardware adapter configuration at startup.
Default expectation:

- adapter module implements the Ogol hardware adapter behaviour
- default adapter family is EtherCAT
- adapter calls are bounded and non-blocking from the machine’s point of view

Command rule:

```text
command :lift_up
```

means:

- validate `:lift_up` against declared commands at compile time
- at runtime dispatch it through the configured hardware adapter
- treat later hardware feedback as a future delivered event

Hardware feedback enters the machine only as delivered events through the
adapter boundary. Adapters MUST NOT mutate machine callback data directly.

The generated machine MUST NOT assume a command succeeded merely because it was
dispatched.

## 20. Safety

Safety checks MUST run:

- after initialization
- after every handled event
- after state entry actions complete

Supported forms:

- `always check`
- `while_in state, check`

The semantic meaning of a safety violation is:

- the machine state is invalid for continued autonomous execution

Default generated policy:

- the machine MUST stop with `{:safety_violation, check_name, state_name}`

If the author wants recovery behavior, they SHOULD model it explicitly with:

- fault states
- requests
- transitions
- or generated topology policy

## 21. Crash Semantics and “Let It Crash”

### 21.1 Principle

Ogol adopts “let it crash” for the machine brain.

That means:

- software bugs MUST NOT be hidden by defensive spaghetti code
- invalid generated action execution MUST NOT be silently swallowed
- violated safety checks MUST terminate the machine process by default
- child machine crashes SHOULD be handled by topology and supervision, not by
  shared mutable state recovery

### 21.2 Crash Classes

The spec distinguishes:

1. **Expected stop**
   - `:normal`
   - `:shutdown`
   - `{:shutdown, term}`

2. **Domain fault handled inside the machine**
   - transition to explicit fault state
   - emit fault signal
   - remain alive

3. **Machine crash**
   - exception in callback
   - invalid generated action execution
   - unhandled fatal adapter failure
   - safety violation under default policy
   - explicit `stop(reason)` with abnormal reason

### 21.3 Recovery Rule

Expected domain faults SHOULD be modeled explicitly in the machine.

Bugs and invalid states SHOULD crash the machine and be handled by topology via
OTP supervision.

### 21.4 Automation-Specific Safety Rule

“Let it crash” is not by itself a physical safety strategy.

Therefore the hardware boundary MUST guarantee a safe envelope independently of
the machine brain:

- safe defaults on controller loss
- watchdog or failsafe behavior in adapters or devices
- safe torque off, relays, interlocks, or other external safety mechanisms for
  hazardous motion

The machine process may crash.
The plant must still land in a safe state.

### 21.5 Restart Rule

After restart, a machine MUST NOT assume the external world still matches its
old internal state.

Therefore restarted machines SHOULD:

- start from declared initial state
- resynchronize by consuming facts/events from hardware and other machines
- avoid issuing hazardous commands until synchronized

The DSL may eventually support an explicit `recovering` state pattern, but the
base rule is already normative.

## 22. Supervision

Supervision is real OTP supervision generated as topology around machine
processes.

Supported strategy in the first target cut:

- `:one_for_one`

Supported restart values:

- `:permanent`
- `:transient`
- `:temporary`

Supported restart intensity settings:

- `max_restarts`
- `max_seconds`

Child crashes are ordinary OTP failures. Restart and escalation behavior follow
OTP rules first. The parent observes consequences only through routed events,
not through shared state mutation.

Supervision does not perfectly coincide with the local machine concept. It is a
deployment and lifecycle concern generated alongside the machine.

## 23. Escape Hatches

Escape hatches are necessary, but they MUST stay typed and explicit.

Allowed forms:

- `callback(:name)`
- `foreign(:kind, opts)`

Not allowed:

- arbitrary inline `receive`
- arbitrary inline process orchestration inside state callbacks
- blocking fieldbus logic written directly in authored transition bodies

The generated `:gen_statem` is the controller, but it SHOULD still use OTP
structure and adapter processes instead of ad hoc mailbox programming.

## 24. Explicit Exclusions

The following are intentionally excluded from the target core:

- host-side `reactor` as a first-class orchestration language
- opaque generic `effect/3` as the primary authoring model

Both may exist temporarily during implementation work, but they are not part of
the target language.

## 25. Non-Normative Implementation Order

1. freeze the public DSL vocabulary
2. implement the semantic matrix and classification rules in the spec and
   validators
3. implement first-class action constructors
4. generate `:gen_statem` modules with state callbacks and state-enter logic
5. implement `send_request` and `send_event`
6. implement generated topology/supervisor modules for children
7. implement crash classification and safe hardware boundary behavior
8. remove host-side reactor orchestration from the core design
9. demote `effect/3` to explicit escape hatch
10. delete the generic interpreter path

## 26. Summary

The target architecture is:

```text
author DSL -> generate real :gen_statem brain -> run real hardware process
```

The point is not to simulate a machine above OTP.

The point is to let the DSL generate the OTP machine that actually controls the
hardware, while using OTP supervision and crash semantics honestly and safely.

## 27. Worked Example

This appendix is informative, but it follows the normative rules above.

### 27.1 Example Machine

```elixir
defmodule ClampCell do
  use Ogol.Machine

  boundary do
    fact :guard_closed?, :boolean

    request :start_cycle
    event :clamp_ready
    event :guard_changed

    command :start_motor
    signal :cycle_started
  end

  states do
    state :idle, initial?: true
    state :clamping
    state :running
  end

  safety do
    while_in :running, callback(:guard_must_stay_closed?)
  end

  children do
    child :clamp, ClampMachine
    # topology routes child signal :ready to parent event :clamp_ready
  end

  transitions do
    transition :idle, :clamping do
      on request(:start_cycle)
      do
        signal(:cycle_started)
        send_event(:clamp, :close_requested)
        reply(:ok)
      end
    end

    transition :clamping, :running do
      on event(:clamp_ready)
      do
        command(:start_motor)
      end
    end
  end
end
```

### 27.2 Example Flow

1. A caller sends `request :start_cycle`.
2. The machine handles a `request`, so exactly one reply is allowed.
3. The transition from `:idle` to `:clamping` stages `signal(:cycle_started)`,
   `send_event(:clamp, :close_requested)`, and `reply(:ok)`.
4. Safety passes, so the reply is returned, the signal is emitted, and the
   child event is delivered.
5. The child later emits signal `:ready`. Topology routes that into the parent
   as event `:clamp_ready` with metadata including `origin: :child` and
   `child: :clamp`.
6. The parent transitions to `:running` and stages `command(:start_motor)`.
7. Later, hardware delivers event `:guard_changed` with an implicit fact patch
   `%{guard_closed?: false}`. The fact patch is merged before guard evaluation
   because this is an observation-bearing event.
8. Even if no transition matches `:guard_changed`, safety still runs because
   the event was handled.
9. `while_in :running, guard_must_stay_closed?` fails, so the machine exits with
   `{:safety_violation, :guard_must_stay_closed?, :running}`.
10. Topology and OTP supervision restart the machine, while the independent
    hardware safety envelope keeps the plant in a safe state.

### 27.3 Mini Rules

- A matched `request` that stages no reply MUST yield `{:error, :missing_reply}`.
- A transition that stages two replies MUST crash with
  `{:invalid_reply_cardinality, 2}`.
- Scheduling `state_timeout(:watchdog, 1_000, ...)` twice replaces the earlier
  `:watchdog` timeout rather than creating a duplicate with the same name.
