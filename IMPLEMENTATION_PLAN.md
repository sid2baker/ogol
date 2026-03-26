# Ogol Implementation Plan

This plan translates [SPEC.md](/home/n0gg1n/Development/Work/opencode/ogol/SPEC.md)
into a concrete build order and file layout for a scratch-built implementation.

The guiding constraint is:

```text
do not rebuild the old interpreter under a new name
```

The new project should generate real `:gen_statem` machine brains directly.
Any compile-time normalization exists only to support code generation and
validation.

## 1. Scope Layers

The implementation should distinguish three scopes from day one.

### 1.1 `v1` Language Surface

These concepts belong to the target `v1` language even if they are not all in
the first executable slice:

- `machine`
- `boundary`
- `memory`
- `states`
- `transitions`
- `safety`
- `children`

and:

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

and the `v1` action set:

- `set_fact`
- `set_field`
- `set_output`
- `signal`
- `command`
- `reply`
- `internal`
- `state_timeout`
- `cancel_timeout`
- `send_event`
- `send_request`

### 1.2 Milestone 1

Milestone 1 proves atomic machine semantics only.

It MUST include:

- direct `:gen_statem` generation for atomic machines
- request normalization
- event normalization
- eligible fact patch merge timing
- guard evaluation after eligible fact patch merge
- staged output / signal / command behavior
- reply cardinality
- named timeout replacement
- safety checks and crash behavior
- hardware adapter boundary for atomic machines

It MUST NOT require:

- children
- topology modules
- supervision trees for composites
- routed child metadata
- cross-machine `send_request`

### 1.3 Post-Core Additions

These come only after the atomic machine brain is correct:

- generated topology modules
- child routing and metadata
- `send_event` target resolution beyond local helper tests
- strict `send_request` between machines
- composite examples
- ergonomics and editor-facing polish

## 2. Design Constraints

The implementation should follow these rules.

1. `SPEC.md` is the source of truth.
2. `../ogol_old` is a reference shelf, not a migration target.
3. The first vertical slice proves semantics, not syntax breadth.
4. Runtime helpers may exist, but they must not become a generic interpreter.
5. Child orchestration belongs in topology, not in machine callback data.
6. Hardware feedback must re-enter only as delivered events.
7. Tests should read like executable spec examples.

## 3. Dependency Strategy

Milestone 1 SHOULD use Spark as the DSL foundation from day one.

Recommended default:

- `spark` for section/entity definition, compile-time validation, and info access
- `usage_rules` in development
- no HMI/editor dependencies
- no fieldbus dependency yet

Reason:

- the public language is already large enough to benefit from a deliberate DSL
  framework
- Spark gives a clean entity/section/extension pipeline, verifiers, and info
  modules without forcing runtime interpreter semantics
- Spark can hold the compile-time normalized form while the runtime still
  targets generated `:gen_statem` code directly

Constraint:

- Spark MUST be used only for authoring, normalization, validation, and code
  generation support
- Spark MUST NOT become a generic runtime or second semantics layer above the
  generated machine

## 4. Proposed File Layout

This is the intended layout for milestone 1.

### 4.1 Public Entry Surface

`lib/ogol.ex`

Responsibility:

- minimal public helpers
- optional wrapper functions for request/event delivery
- public documentation pointing to `SPEC.md`

Likely functions:

- `request(server, name, data \\ %{}, meta \\ %{}, timeout \\ 5_000)`
- `event(server, name, data \\ %{}, meta \\ %{})`

The generated machine modules will still have their own `start_link/1`.

### 4.2 Machine DSL Entry

`lib/ogol/machine.ex`

Responsibility:

- `use Ogol.Machine`
- `use Spark.Dsl`
- install the Ogol Spark extension
- expose the public authoring entrypoint
- trigger final code generation in `__before_compile__`

This module is the public authoring entry point.

### 4.3 Spark Extension

`lib/ogol/machine/dsl.ex`

Responsibility:

- define Spark entities and sections:
  - `machine`
  - `boundary`
  - `memory`
  - `states`
  - `transitions`
  - `safety`
- define milestone 1 entities:
  - `fact`, `event`, `request`, `command`, `output`, `signal`
  - `field`
  - `state`
  - `transition`
  - `always`, `while_in`
- define nested transition/state action entities for milestone 1:
  - `set_fact`, `set_field`, `set_output`
  - `reply`, `internal`, `state_timeout`, `cancel_timeout`
  - `command`, `signal`
  - guard helpers such as `callback(...)`

Spark should own the public authoring surface.
The runtime should still remain plain generated OTP code.

### 4.4 Compile-Time Normalization

`lib/ogol/compiler/normalize.ex`

Responsibility:

- read validated Spark DSL state
- build a tiny normalized semantic form
- enforce declaration ordering invariants that are semantic rather than purely
  schema-driven

This is not a public IR and not a runtime artifact.
It exists only during compilation.

### 4.5 Compile-Time Validation

`lib/ogol/machine/verifiers/validate_spec.ex`

Responsibility:

- ensure exactly one initial state
- ensure declared boundary names are unique within their kind
- ensure transitions refer to declared states
- ensure action targets refer to declared facts/fields/outputs
- ensure `request`-only reply semantics are structurally valid where checkable
- ensure safety rules refer to declared states where needed

These checks should be implemented as Spark verifiers where possible.

### 4.6 Info Access

`lib/ogol/machine/info.ex`

Responsibility:

- expose read-only accessors over the Spark DSL state
- give the compiler and tests a stable introspection surface

This module should be generated with `Spark.InfoGenerator`.

### 4.7 Code Generation

`lib/ogol/compiler/generate.ex`

Responsibility:

- take normalized semantic form
- inject the generated `:gen_statem` functions into the authored module

Generated functions for milestone 1:

- `@behaviour :gen_statem`
- `start_link/1`
- `start/1`
- `child_spec/1`
- `callback_mode/0`
- `init/1`
- one callback function per authored state
- `terminate/3`
- `code_change/4`

This module is where the milestone 1 architecture succeeds or fails.

## 5. Compile-Time Semantic Form

Milestone 1 should normalize the DSL into a very small set of structs.

Recommended files:

- `lib/ogol/compiler/model/machine.ex`
- `lib/ogol/compiler/model/boundary_item.ex`
- `lib/ogol/compiler/model/state.ex`
- `lib/ogol/compiler/model/transition.ex`
- `lib/ogol/compiler/model/action.ex`
- `lib/ogol/compiler/model/safety_rule.ex`

Suggested shapes:

### 5.1 `Machine`

- machine module
- optional machine metadata
- boundary items
- fields
- states
- transitions
- safety rules

### 5.2 `BoundaryItem`

- `name`
- `kind`
  - `:fact`
  - `:event`
  - `:request`
  - `:command`
  - `:output`
  - `:signal`
- optional type
- default

### 5.3 `State`

- `name`
- `initial?`
- entry actions

### 5.4 `Transition`

- `source`
- `destination`
- trigger family
- trigger name
- optional guard
- priority
- ordered actions
- optional explicit re-entry flag

### 5.5 `Action`

- `kind`
- normalized arguments

### 5.6 `SafetyRule`

- `scope`
  - `:always`
  - `{:while_in, state}`
- check form
  - callback reference for milestone 1

Spark is responsible for validating the authored DSL. The normalized semantic
form exists to feed code generation, not to create a public intermediate
language.

## 6. Spark Pipeline

Milestone 1 should follow this compile-time flow:

```text
Spark DSL -> Spark validation/verifiers -> normalized semantic form -> codegen
```

Recommended components:

- Spark extension in `Ogol.Machine.Dsl`
- Spark verifier(s) in `lib/ogol/machine/verifiers/`
- Spark info module in `lib/ogol/machine/info.ex`
- normalization step in `lib/ogol/compiler/normalize.ex`
- code generation in `lib/ogol/compiler/generate.ex`

Suggested rule of thumb:

- schema and structural validation belong in Spark entities/verifiers
- semantic lowering belongs in normalization
- emitted runtime callback code belongs in code generation

## 7. Runtime Helper Boundary

Milestone 1 may use helper modules, but they MUST stay helper-sized.

Recommended files:

- `lib/ogol/runtime/data.ex`
- `lib/ogol/runtime/delivered_event.ex`
- `lib/ogol/runtime/staging.ex`
- `lib/ogol/runtime/safety.ex`
- `lib/ogol/runtime/normalize.ex`

These helpers should do only what generated code needs:

- define callback-data shape
- normalize delivered call/cast/info/state_timeout inputs
- merge eligible fact patches
- accumulate staged outward effects and staged OTP actions
- enforce reply cardinality
- run safety checks

They must not decide transitions generically.
Transition selection belongs in generated state callbacks.

## 8. Callback Data Shape

Milestone 1 runtime data should follow the spec directly.

Recommended file:

`lib/ogol/runtime/data.ex`

Suggested struct:

```elixir
defmodule Ogol.Runtime.Data do
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

No child process bookkeeping belongs here.

## 9. Hardware Boundary

Recommended files:

- `lib/ogol/hardware_adapter.ex`
- `lib/ogol/hardware/noop_adapter.ex`

Responsibilities:

- define behavior for command dispatch
- define how hardware feedback is reintroduced as delivered events
- provide a test adapter for milestone 1

Milestone 1 goal:

- prove the semantic boundary
- not real EtherCAT transport yet

The adapter tests should prove:

- commands go out
- hardware feedback re-enters only as delivered events
- adapter code does not mutate callback data directly
- command dispatch is not treated as proof of effect

## 10. Milestone 1 Test Layout

The test suite should mirror the spec.

### 9.1 Test Support Fixtures

Recommended directory:

`test/support/machines/`

Recommended fixture modules:

- `reply_machine.ex`
- `missing_reply_machine.ex`
- `duplicate_reply_machine.ex`
- `fact_patch_machine.ex`
- `safety_machine.ex`
- `timeout_machine.ex`
- `hardware_machine.ex`

### 9.2 Test Files

Recommended files:

- `test/atomic_machine_test.exs`
- `test/reply_semantics_test.exs`
- `test/fact_patch_test.exs`
- `test/timeout_semantics_test.exs`
- `test/hardware_adapter_test.exs`

Mandatory milestone 1 cases:

- matched request with reply
- matched request without reply -> `{:error, :missing_reply}`
- duplicate reply -> crash
- eligible fact patch merged before guard
- ineligible families do not patch facts implicitly
- unmatched event still counts as handled event for safety timing
- staged command/signal dropped if safety fails
- timeout replacement by name
- command dispatch not treated as success proof

In addition to runtime tests, milestone 1 should include compile-time DSL tests:

- duplicate boundary names are rejected
- missing initial state is rejected
- unknown transition state references are rejected
- invalid action targets are rejected

## 11. Milestone 2 Layout

Only after milestone 1 is green:

- add `lib/ogol/topology.ex`
- add generated companion topology modules
- add `children` DSL handling
- add child routing metadata
- add `send_event` target resolution through topology

At this point, new support files likely appear:

- `lib/ogol/topology/router.ex`
- `lib/ogol/topology/supervisor.ex`
- `lib/ogol/topology/child_binding.ex`

None of those are needed in milestone 1.

## 12. `send_request` Policy

`send_request` belongs to `v1`, but not milestone 1.

When it is implemented, it should be exactly the spec version:

- synchronous
- success/failure oriented
- no typed inline reply binding
- no hidden continuation sublanguage

If richer request composition is ever added later, it should be a deliberate
language extension, not an accidental side effect of the first runtime.

## 13. How To Use `../ogol_old`

`../ogol_old` may be mined only after milestone 1 exists and is green.

Allowed uses:

- compare test cases
- copy tiny utility ideas
- reuse example scenarios after rewriting them to fit the new architecture

Disallowed uses:

- importing the old generic runtime architecture
- reviving reactor-driven orchestration
- reviving `effect/3` as the primary behavior model
- carrying over compatibility aliases

## 14. First Concrete Build Order

The first actual code steps should be:

1. replace placeholder `Ogol` module with minimal public API
2. add `Ogol.Machine`
3. add `Ogol.Machine.Dsl` as a Spark extension
4. add Spark entity target structs
5. add `Ogol.Machine.Info`
6. add Spark verifiers
7. add compile-time model structs
8. add normalization + code generation
9. add runtime data / delivered event / staging / safety helpers
10. generate one atomic machine as real `:gen_statem`
11. write compile-time and runtime semantic tests
12. get milestone 1 green
13. only then design topology and children

## 15. Success Criteria

Milestone 1 is successful when:

- one authored machine compiles into a working `:gen_statem`
- the DSL is defined through Spark sections/entities/verifiers rather than ad
  hoc macros
- the runtime behavior matches the ordering and failure semantics in
  [SPEC.md](/home/n0gg1n/Development/Work/opencode/ogol/SPEC.md)
- the tests read like executable spec clauses
- no generic interpreter exists in the runtime path

If that works, the new project has the right center of gravity.
