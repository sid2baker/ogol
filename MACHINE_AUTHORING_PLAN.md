# Machine Authoring Plan

This document is the canonical plan for machine authoring in Ogol.

It consolidates the previous split documents for:

- designer/runtime planning
- managed subset classification
- AST/intermediate-to-model lowering

It defines the first implementation target for the machine authoring surface
and the reusable authoring pattern that should later extend to:

- hardware configuration editors
- EtherCAT driver creation/editors

## 1. Purpose

The machine authoring system should produce and manage real Ogol DSL modules,
not a parallel proprietary persistence format.

The goal is to make machine authoring:

- visual when useful
- source-backed always
- runtime-loadable without an interpreter layer

This document defines:

- the authoring architecture
- the managed subset contract
- the lowering boundary into the machine intermediate model
- canonicalization and validation rules
- runtime activation expectations

## 2. Core Terms

### 2.1 Managed Authoring Kernel

The `Managed Authoring Kernel` is the shared authoring pattern used across
artifacts such as:

- machines
- hardware configurations
- future EtherCAT driver definitions

It provides the common contracts:

- parse
- classify
- lower into a structured intermediate model
- validate
- print canonical source
- support source/visual toggling

### 2.2 Artifact Adapter

The machine designer is an artifact-specific adapter on top of that kernel.

It provides:

- machine-specific AST lowering
- machine-specific structured intermediate model rules
- machine-specific validation
- machine-specific canonical printing
- machine-specific editor behavior

### 2.3 Structured Intermediate Model

The structured intermediate model is:

- artifact-specific
- non-persisted
- derived from canonical source or visual edits
- optimized for validation, printing, and UI manipulation

For machines, this is the editor-side machine model used during visual editing.

### 2.4 Partially Representable

A file is `:partially_representable` only if the system can inspect it and
classify unsupported regions without risking semantic ambiguity in the
represented portions.

In v1, partially representable files are inspectable but not saveable from the
visual editor.

## 3. Core Decisions

### 3.1 Persisted Artifact

The persisted artifact is canonical Ogol DSL source.

The visual editor does not persist a separate long-term editor-state document.

### 3.2 Source/Visual Toggle

The long-term authoring rule is:

- every managed artifact should have a visual representation
- every managed artifact should have a canonical source representation
- users should be able to toggle between them

For machines, the canonical source is Ogol DSL.

For hardware configuration and driver artifacts, the same pattern should apply
even if their source format later differs.

In v1 of the machine designer:

- source view is preview/inspection first
- direct source editing from the visual designer surface is not assumed
- source edits may arrive later only with explicit reclassification behavior

### 3.3 Editor State

The visual editor uses a transient structured machine model in memory while the
user edits.

That model exists to support:

- graph editing
- partial edits
- stable object identity during one editing session
- validation and code generation

It is not the persisted artifact.

### 3.4 Layout

No layout metadata is persisted in v1.

When a machine is reopened:

- the DSL is parsed back into the structured machine model
- the editor applies deterministic auto-layout

Auto-layout should be:

- deterministic for the same model
- reasonably stable under small edits
- independent of incidental parse ordering or map iteration order

### 3.5 Runtime Loading

Generated machines are compiled and loaded directly as Elixir modules.

The authoring system does not use a shared IEx evaluator as its runtime
mechanism.

### 3.6 Designer Compatibility Version

The machine authoring system should track a designer compatibility version.

This versions:

- the managed subset
- canonicalization behavior

It does not version machine semantics themselves.

## 4. Authoring Pipeline

The machine authoring pipeline is:

```text
Visual editor
-> transient structured machine model
-> canonical DSL source
-> formatter
-> saved file
-> compile/load
-> runtime activation
```

This is the machine-specific instance of a broader source/visual authoring
pattern that should also be reused for hardware config and driver editors.

## 5. Load Pipeline

The load path must be split into separate gates:

1. parse DSL into AST or a normalized intermediate representation
2. classify compatibility with the managed subset
3. lower supported constructs into the editor machine model
4. validate managed-subset semantics
5. render visual editor if compatible
6. compile/load only after successful validation

Parseability and compilability are separate concerns.

### 5.1 Parser Boundary

The parser boundary should be explicit:

- parse into AST or a normalized intermediate representation
- classify compatibility there
- only then lower into the editor machine model

This prevents the editor model from becoming an accidental universal parser for
all possible DSL constructs.

### 5.2 Compatibility Result

Compatibility classification results should live on the parsed artifact result
and must also be exposed in:

- validation responses
- loader responses
- UI status/banners

The lowering stage must not invent compatibility after the fact.

## 6. Compatibility Classification

Every loaded machine should receive one of these classifications:

- `:fully_editable`
- `:partially_representable`
- `:not_visually_editable`

### 6.1 Fully Editable

A machine is `:fully_editable` if:

- all parsed constructs fall inside the fully editable subset
- all state and transition actions are in the editable action set
- no unsupported escape hatches are required for managed semantics

### 6.2 Partially Representable

A machine is `:partially_representable` if:

- supported constructs can be lowered safely
- unsupported regions can be identified and classified
- represented portions remain semantically unambiguous

In v1:

- partial machines may be inspected visually
- partial machines may not be saved from the visual editor

### 6.3 Not Visually Editable

A machine is `:not_visually_editable` if:

- the parser cannot classify the structure safely
- lowering into the machine editor model would be semantically ambiguous
- unsupported constructs are too entangled with represented regions

### 6.4 Internal Partial Reasons

The user-facing classification may stay as `:partially_representable`, but the
implementation should track narrower internal reasons such as:

- partial due to unsupported-but-localized constructs
- partial due to deferred editing scope in v1

## 7. Save, Compile, and Activate

These are separate lifecycle stages in v1:

- `Save DSL`
- `Compile`
- `Activate`

The UI may offer a one-click happy path later, but the underlying lifecycle
should remain explicit.

### 7.1 Runtime Version States

The machine authoring lifecycle should at least distinguish:

- `saved`
- `validated`
- `compiled`
- `loaded`
- `activated`
- `retired`
- `failed`

### 7.2 Activation Failure Contract

On activation failure:

- the old active version remains active
- the new compiled version may remain loaded but inactive
- failure must not replace the active version

### 7.3 Module Lifecycle

Retired module purge/delete must be coordinated with runtime quiescence and
reference safety.

Module cleanup is not a trivial side effect.

## 8. Managed Subset Contract

Every DSL construct must be classified into one of these categories:

- fully editable
- preserved but read-only
- rejected as out of scope

This contract must be explicit before editor implementation.

### 8.1 Persistence and Save Rules

In v1:

- `:fully_editable` machines may be loaded, edited, and saved from the designer
- `:partially_representable` machines may be inspected visually, but not saved
- `:not_visually_editable` machines fall back to source-only inspection

The system must not silently drop or rewrite unsupported semantics.

## 9. Managed Subset Tables

### 9.1 Module-Level Structure

| Construct | Classification | Notes |
|---|---|---|
| `use Ogol.Machine` | fully editable | implied by generated source |
| one machine module per file | fully editable | v1 assumes one managed machine per file |
| unrelated extra modules in same file | rejected | out of scope for v1 |
| arbitrary file-level helper functions | rejected by default | only partial if the classifier can prove irrelevance to represented managed semantics |

### 9.2 `machine` Section

| Construct | Classification | Notes |
|---|---|---|
| `machine do ... end` | fully editable | managed section |
| `name(...)` | fully editable | canonical metadata |
| `meaning(...)` | fully editable | canonical metadata |
| `hardware_adapter(...)` | fully editable | canonical metadata |
| `hardware_opts(...)` | fully editable for a constrained literal subset | canonical metadata only when parser-normalized safely |
| additional simple scalar metadata fields | partially representable | only if parser can classify safely |
| arbitrary code inside `machine` | rejected | not part of managed subset |

Accepted simple scalar metadata values are limited to:

- `nil`
- booleans
- integers
- floats
- binaries
- atoms

In v1, `hardware_opts(...)` is fully editable only when it is a
parser-normalized literal keyword list whose values are composed of:

- accepted simple scalar values
- lists of accepted simple scalar values

If `hardware_opts(...)` contains executable expressions, opaque structs,
tuples, maps, or other non-literal values, it should classify as partial or be
rejected rather than being treated as editable.

For canonical printing in v1, editable `hardware_opts(...)` should be
normalized to a deterministic keyword order by key. Duplicate keys should not
be treated as part of the editable subset.

### 9.2.1 Descriptive Metadata

`meaning(...)` is optional descriptive metadata wherever the current DSL
supports it, including machine, boundary, memory, state, transition, safety,
and child declarations.

Canonical behavior in v1:

- when present, it is preserved and printed canonically
- when absent, it normalizes to `nil`
- it does not affect semantic equivalence beyond its presence/value as managed
  metadata

For testing purposes, `meaning(...)` participates in managed metadata equality
and canonicalization checks, not in runtime-behavior equivalence.

### 9.3 `boundary` Section

| Construct | Classification | Notes |
|---|---|---|
| `boundary do ... end` | fully editable | managed section |
| `fact(...)` | fully editable | core boundary declaration |
| `event(...)` | fully editable | core boundary declaration |
| `request(...)` | fully editable | core boundary declaration |
| `command(...)` | fully editable | core boundary declaration |
| `output(...)` | fully editable | core boundary declaration |
| `signal(...)` | fully editable | core boundary declaration |
| unknown/custom boundary declaration kinds | rejected | not safely representable in v1 |

### 9.4 `memory` Section

| Construct | Classification | Notes |
|---|---|---|
| `memory do ... end` | fully editable | managed section |
| `field(...)` | fully editable | core editable subset |
| unknown/custom memory declarations | rejected | not part of v1 |

### 9.5 `states` Section

| Construct | Classification | Notes |
|---|---|---|
| `states do ... end` | fully editable | managed section |
| `state :name do ... end` | fully editable | core graph node |
| initial state marker | fully editable | canonicalized into machine-level initial-state ownership |
| state-local first-class actions | partial or full depending on action kind | see action tables below |
| unsupported escape hatches in state body | partially representable | inspect-only in v1 |

### 9.6 `transitions` Section

| Construct | Classification | Notes |
|---|---|---|
| `transitions do ... end` | fully editable | managed section |
| `transition source, target do ... end` | fully editable | core graph edge |
| `on(...)` with managed trigger forms | fully editable | explicit trigger classification required |
| transition-local first-class actions | partial or full depending on action kind | see action tables below |
| unsupported escape hatches in transition body | partially representable | inspect-only in v1 |

### 9.7 `safety` Section

| Construct | Classification | Notes |
|---|---|---|
| `safety do ... end` | partially representable | section exists, but v1 editing may be narrower |
| `always(...)` with managed predicate form | partially representable initially | likely v1.1 or later for full editing |
| `while_in(...)` with managed predicate form | partially representable initially | likely v1.1 or later for full editing |
| safety callback references / opaque checks | partially representable | inspect-only in v1 |
| arbitrary code in safety rules | rejected | out of managed subset |

### 9.8 `children` Section

| Construct | Classification | Notes |
|---|---|---|
| `children do ... end` | partially representable | inspect first, edit later |
| `child(...)` declarations | partially representable initially | v1 may delay child editing |
| child bindings if purely declarative and well-formed | partially representable | inspect first, edit later |
| arbitrary child/runtime glue outside DSL declarations | rejected | not part of managed subset |

## 10. Action and Trigger Scope

### 10.1 Editable V1 Actions

| Action | Classification | Notes |
|---|---|---|
| `set_fact(...)` | fully editable | core editable |
| `set_field(...)` | fully editable | core editable |
| `set_output(...)` | fully editable | core editable |
| `signal(...)` | fully editable | core editable |
| `command(...)` | fully editable | core editable |
| `reply(...)` | fully editable | core editable |
| `send_event(...)` | fully editable | core editable |
| `state_timeout(...)` | fully editable | core editable |
| `cancel_timeout(...)` | fully editable | core editable |

### 10.2 Initially Inspect-Only Actions

| Action | Classification | Notes |
|---|---|---|
| `send_request(...)` | partially representable initially | more coupled to runtime flow |
| `internal(...)` | partially representable initially | continuation semantics need careful UI treatment |
| `stop(...)` | partially representable initially | valid but lower priority for first editor |
| `hibernate(...)` | partially representable initially | runtime-specific and lower priority |
| `monitor(...)` | partially representable initially | advanced OTP/runtime action |
| `demonitor(...)` | partially representable initially | advanced OTP/runtime action |
| `link(...)` | partially representable initially | advanced OTP/runtime action |
| `unlink(...)` | partially representable initially | advanced OTP/runtime action |

### 10.3 Escape Hatches

| Action | Classification | Notes |
|---|---|---|
| `callback(...)` | partially representable when localized and classifiable | otherwise rejected |
| `foreign(...)` | partially representable when localized and classifiable | otherwise rejected |
| opaque future action kinds | rejected or partially representable | must classify safely |

### 10.4 Trigger Classification

| Trigger Form | Classification | Notes |
|---|---|---|
| managed `request` trigger | fully editable | explicit trigger kind preferred |
| managed `event` trigger | fully editable | explicit trigger kind preferred |
| implicit/bare trigger requiring inference | partially representable or rejected | do not allow ambiguous inference in visual editing |
| unsupported runtime-family triggers | partially representable initially | inspect first |

Managed trigger ownership is explicit and conservative:

- `{:request, name}` -> managed request trigger
- `{:event, name}` -> managed event trigger
- bare `name` is accepted only if prior classification already established a
  safe canonical form
- runtime-family triggers such as `{:hardware, name}` or
  `{:state_timeout, name}` remain inspect-only unless made fully editable later

The lowering stage should never silently infer an ambiguous trigger kind.

## 11. Machine Intermediate Model

The machine intermediate model should align with the existing compiler model
where possible, but it needs more provenance and editor-facing structure than
`Ogol.Compiler.Model.Machine`.

Recommended shape:

```elixir
%MachineModel{
  module: module() | nil,
  metadata: %{
    name: atom(),
    meaning: String.t() | nil,
    hardware_adapter: module() | nil,
    hardware_opts: keyword()
  },
  boundary: %{
    facts: %{atom() => %BoundaryDecl{}},
    events: %{atom() => %BoundaryDecl{}},
    requests: %{atom() => %BoundaryDecl{}},
    commands: %{atom() => %BoundaryDecl{}},
    outputs: %{atom() => %BoundaryDecl{}},
    signals: %{atom() => %BoundaryDecl{}}
  },
  memory: %{
    fields: %{atom() => %FieldDecl{}}
  },
  states: %{
    nodes: %{atom() => %StateNode{}},
    initial_state: atom()
  },
  transitions: [%TransitionEdge{}],
  safety: [%SafetyNode{}],
  children: [%ChildNode{}],
  compatibility: %Compatibility{},
  provenance_index: %{term() => %Provenance{}}
}
```

Transient editor ids may exist inside nodes and edges, but they are not part of
semantic round-trip equivalence.

The implementation may also distinguish internally between:

- editable semantic nodes
- read-only represented nodes

That split is especially useful in v1 for sections such as `safety` and
`children`, where the editor may inspect represented semantics before it owns
full editing and printing for them.

### 11.1 Initial State Ownership

Canonical ownership of initial-state semantics belongs to the machine-level
relation:

- `model.states.initial_state`

State nodes may carry a derived `initial?` convenience flag in memory, but the
normalized source of truth is the machine-level `initial_state` field.

On source print:

- the printer derives `initial?: true` on the matching printed state
- non-initial states omit the marker unless required by canonical style

## 12. Lowering Boundary

The lowering input is not raw Elixir AST. It is a parsed artifact result with:

- normalized section entries
- compatibility classification
- partial-region diagnostics
- source-range provenance

The normalized entries should correspond to current DSL entities such as:

- `Ogol.Machine.Dsl.MachineOptions`
- `Ogol.Machine.Dsl.Fact`
- `Ogol.Machine.Dsl.State`
- `Ogol.Machine.Dsl.Transition`

or an equivalent parser-owned intermediate representation.

### 12.1 Provenance

Every lowered construct should carry provenance sufficient to:

- point validation errors back to source
- highlight represented source regions in the UI
- explain partial classification

At minimum, provenance should capture:

- source file
- section
- line/column range when available
- normalized construct kind
- classification reason when partial/rejected

When lowering from current Spark entities, `__spark_metadata__` should be used
where available.

### 12.2 Partial Handling

For `:partially_representable` files:

- supported constructs may still lower into the machine intermediate model
- unsupported localized constructs must remain attached as read-only region
  summaries on the parsed artifact result
- visual save remains disabled in v1

The machine model itself should not attempt to carry opaque source splices in
v1.

## 13. Lowering Tables

### 13.1 Module and File Structure

| Construct | Accepted AST/IR Form | Classification | Editor Model Mapping | Printer Ownership | Provenance Requirement |
|---|---|---|---|---|---|
| `use Ogol.Machine` | machine module marker or equivalent normalized file header | fully editable | file/module metadata only | canonical printer owns | module header range |
| one machine module per file | exactly one normalized machine module artifact | fully editable | `model.module` plus artifact root | canonical printer owns | module range |
| unrelated extra modules | additional normalized module nodes in same file | rejected | none | none | extra module range |
| helper functions proven irrelevant | localized function nodes not referenced by represented semantics | partially representable | none in model; attach read-only note to parsed artifact | none in v1 | function range and classification reason |
| helper functions not proven irrelevant | opaque helper nodes with unknown semantic impact | rejected | none | none | function range and rejection reason |

### 13.2 `machine`

| Construct | Accepted AST/IR Form | Classification | Editor Model Mapping | Printer Ownership | Provenance Requirement |
|---|---|---|---|---|---|
| `machine do ... end` | `%Dsl.MachineOptions{}` or equivalent section node | fully editable | `model.metadata` root | canonical printer owns | section range |
| `name(...)` | `name :: atom` | fully editable | `model.metadata.name` | canonical printer owns | option range |
| `meaning(...)` | `meaning :: String.t() \| nil` | fully editable | `model.metadata.meaning` | canonical printer owns | option range |
| `hardware_adapter(...)` | module alias or normalized module atom | fully editable | `model.metadata.hardware_adapter` | canonical printer owns | option range |
| `hardware_opts(...)` | parser-normalized literal keyword list within the constrained v1 literal subset | fully editable | `model.metadata.hardware_opts` | canonical printer owns | option range |
| additional scalar metadata | parser-normalized scalar option not owned by current machine schema | partially representable only if localized and unambiguous | do not lower into editable model; surface as read-only metadata note | none in v1 | option range and classification reason |
| arbitrary executable code in section | opaque AST in machine section | rejected | none | none | range and rejection reason |

### 13.3 `boundary`

| Construct | Accepted AST/IR Form | Classification | Editor Model Mapping | Printer Ownership | Provenance Requirement |
|---|---|---|---|---|---|
| `boundary do ... end` | section node containing boundary declarations | fully editable | `model.boundary` | canonical printer owns | section range |
| `fact(name, type, ...)` | `%Dsl.Fact{name, type, default, meaning}` | fully editable | `model.boundary.facts[name] = %BoundaryDecl{kind: :fact, ...}` | canonical printer owns | declaration range |
| `event(name, ...)` | `%Dsl.Event{name, meaning}` | fully editable | `model.boundary.events[name]` | canonical printer owns | declaration range |
| `request(name, ...)` | `%Dsl.Request{name, meaning}` | fully editable | `model.boundary.requests[name]` | canonical printer owns | declaration range |
| `command(name, ...)` | `%Dsl.Command{name, meaning}` | fully editable | `model.boundary.commands[name]` | canonical printer owns | declaration range |
| `output(name, type, ...)` | `%Dsl.Output{name, type, default, meaning}` | fully editable | `model.boundary.outputs[name]` | canonical printer owns | declaration range |
| `signal(name, ...)` | `%Dsl.Signal{name, meaning}` | fully editable | `model.boundary.signals[name]` | canonical printer owns | declaration range |
| unknown boundary declaration | normalized declaration kind outside known boundary set | rejected | none | none | declaration range and rejection reason |

### 13.4 `memory`

| Construct | Accepted AST/IR Form | Classification | Editor Model Mapping | Printer Ownership | Provenance Requirement |
|---|---|---|---|---|---|
| `memory do ... end` | section node containing field declarations | fully editable | `model.memory` | canonical printer owns | section range |
| `field(name, type, ...)` | `%Dsl.Field{name, type, default, meaning}` | fully editable | `model.memory.fields[name] = %FieldDecl{...}` | canonical printer owns | declaration range |
| unknown memory declaration | normalized declaration kind outside `field` | rejected | none | none | declaration range and rejection reason |

### 13.5 `states`

| Construct | Accepted AST/IR Form | Classification | Editor Model Mapping | Printer Ownership | Provenance Requirement |
|---|---|---|---|---|---|
| `states do ... end` | section node containing state declarations | fully editable | `model.states.nodes` | canonical printer owns | section range |
| `state :name do ... end` | `%Dsl.State{name, initial?, status, meaning, entries}` | fully editable | `model.states.nodes[name] = %StateNode{status, meaning, entries, editor_id}` | canonical printer owns | state range |
| `initial?: true` | state-local initial marker on exactly one state | fully editable | canonicalize into `model.states.initial_state = state.name`; derived node flag optional | canonical printer owns | marker range |
| duplicate or missing initial marker | invalid state-local initial markers | rejected by validation after lowering | lower node provenance for diagnostics, but no valid normalized state ownership | none until fixed | state range and validation provenance |
| editable entry action | normalized action in editable v1 set | fully editable | append lowered `%ActionNode{...}` to `StateNode.entries` | canonical printer owns | action range |
| partial entry action | normalized action classified inspect-only | partially representable | attach read-only action summary to state notes | none in v1 | action range and partial reason |
| rejected entry action | opaque or unsafe state entry form | rejected | none | none | action range and rejection reason |

### 13.6 `transitions`

| Construct | Accepted AST/IR Form | Classification | Editor Model Mapping | Printer Ownership | Provenance Requirement |
|---|---|---|---|---|---|
| `transitions do ... end` | section node containing transition declarations | fully editable | `model.transitions` | canonical printer owns | section range |
| `transition source, destination do ... end` | `%Dsl.Transition{source, destination, on, guard, priority, reenter?, meaning, actions}` | fully editable | `%TransitionEdge{source, destination, trigger, guard, priority, reenter?, meaning, actions, editor_id}` appended to `model.transitions` | canonical printer owns | transition range |
| managed trigger | normalized `{:event, name}` or `{:request, name}` | fully editable | `TransitionEdge.trigger` | canonical printer owns | trigger range |
| bare trigger proven canonical | parser/IR node already classified as unambiguous canonical trigger | fully editable after canonicalization | lower to explicit `{:event, name}` or `{:request, name}` | canonical printer owns explicit form | trigger range and canonicalization note |
| runtime-family trigger | normalized `{:hardware, name}`, `{:state_timeout, name}`, `{:monitor, name}`, `{:link, name}` | partially representable initially | attach read-only transition note | none in v1 | trigger range and partial reason |
| ambiguous bare trigger | atom requiring semantic inference | rejected or partial per classifier policy; default conservative | none in editable trigger model | none in v1 | trigger range and reason |
| editable transition action | normalized action in editable v1 set | fully editable | append lowered `%ActionNode{...}` to `TransitionEdge.actions` | canonical printer owns | action range |
| partial transition action | normalized action classified inspect-only | partially representable | attach read-only action summary to transition notes | none in v1 | action range and partial reason |
| rejected transition action | opaque or unsafe transition action form | rejected | none | none | action range and rejection reason |

### 13.7 `safety`

| Construct | Accepted AST/IR Form | Classification | Editor Model Mapping | Printer Ownership | Provenance Requirement |
|---|---|---|---|---|---|
| `safety do ... end` | section node containing safety rules | partially representable initially | `model.safety` may hold read-only nodes | none in v1 save path | section range |
| `always(check)` | `%Dsl.AlwaysSafety{check, meaning}` | partially representable initially | `%SafetyNode{scope: :always, check, meaning, editable?: false}` | none in v1 | rule range |
| `while_in(state, check)` | `%Dsl.WhileInSafety{state, check, meaning}` | partially representable initially | `%SafetyNode{scope: {:while_in, state}, check, meaning, editable?: false}` | none in v1 | rule range |
| localized callback predicate | parser can localize callback reference without ambiguity | partially representable | retain as read-only safety node | none in v1 | rule range and partial reason |
| arbitrary executable safety code | opaque AST beyond safe classification | rejected | none | none | rule range and rejection reason |

### 13.8 `children`

| Construct | Accepted AST/IR Form | Classification | Editor Model Mapping | Printer Ownership | Provenance Requirement |
|---|---|---|---|---|---|
| `children do ... end` | section node containing child declarations | partially representable initially | `model.children` may hold read-only nodes | none in v1 save path | section range |
| `child(...)` | `%Dsl.Child{name, machine, opts, restart, state_bindings, signal_bindings, down_binding, meaning}` | partially representable initially | `%ChildNode{..., editable?: false}` | none in v1 | child range |
| purely declarative bindings | normalized binding values without opaque code | partially representable | retained in read-only child node | none in v1 | binding range |
| runtime glue outside child declarations | opaque child/runtime behavior outside managed DSL | rejected | none | none | range and rejection reason |

## 14. Canonical Printing

Managed sections are semantically normalized by the designer.

For `:fully_editable` machines, canonical printing should:

- normalize section ordering
- normalize declaration ordering within sections
- print only the managed subset in canonical form
- produce formatter-stable source

The canonical section order in v1 should be:

1. `machine`
2. `boundary`
3. `memory`
4. `states`
5. `transitions`
6. `safety`
7. `children`

Optional sections may be omitted when absent or empty according to canonical
printer rules, but when present they should follow this order.

In v1, canonical printing should not be used to rewrite
`:partially_representable` machines from the visual editor.

Printer ownership in v1 covers only `:fully_editable` constructs:

- file/module header for managed machine modules
- `machine`
- `boundary`
- `memory`
- `states` with canonical initial-state rendering
- `transitions` with editable triggers/actions only

It does not own:

- partial `safety`
- partial `children`
- partial runtime-family triggers
- partial advanced actions
- preserved helper/source regions

## 15. Validation

Validation is separate from parsing.

Managed-subset validation should check at least:

- one-machine-per-file assumption for managed files
- presence and structure of required sections
- state graph integrity
- trigger compatibility with the managed subset
- action compatibility with the managed subset
- compatibility classification correctness

`State graph integrity` should include at least:

- every transition source exists
- every transition destination exists
- exactly one initial state exists after normalization
- state names are unique
- boundary declaration names are unique within each declaration kind
- memory field names are unique
- child names are unique
- editable references used by actions and triggers resolve against declared
  states, boundary declarations, memory fields, and other managed targets

### 15.1 Required Sections

For v1, validation should distinguish between:

- structurally required containers
- optional sections
- required declarations within a section

Recommended baseline:

- `machine` section: structurally required
- `states` section: structurally required
- `transitions` section: structurally required, though it may be empty
- `boundary` section: optional
- `memory` section: optional
- `safety` section: optional
- `children` section: optional

Within required sections, validation should separately define what declarations
are mandatory. For example, the machine should still require at least one state
and exactly one initial state even though `memory`, `safety`, and `children`
may be absent.

The `states` section is structurally required in v1. It may still parse if
empty, but validation must reject machine definitions with zero states.

## 16. Round-Trip Equivalence

For the managed subset, round-trip equivalence means:

- same machine semantics
- same declarations modulo canonical ordering
- same action semantics
- same managed-subset structure

Excluded from equivalence:

- transient editor ids
- formatting
- layout
- source trivia outside canonical ownership

Transition equivalence in the managed subset should compare transitions by a
canonical semantic tuple consisting of:

- source
- destination
- trigger
- priority
- guard
- reenter?
- actions
- managed metadata such as `meaning`

## 17. Golden Corpus Requirements

The initial golden corpus should include both:

- hand-authored source fixtures
- model-originated fixtures

It should cover:

- canonical happy-path machines
- ordering/canonicalization variants
- unsupported construct examples
- partial compatibility examples
- activation-failure fixtures

The first compact corpus lives under:

- [test/fixtures/machine_authoring/manifest.term](/home/n0gg1n/Development/Work/opencode/ogol/test/fixtures/machine_authoring/manifest.term)

## 18. User-Facing Runtime Scope

The first designer UI should make its runtime scope explicit:

- create a new machine
- edit a fully editable machine
- save DSL
- compile a new version
- activate that version

Rollback and richer replacement workflows may exist in the backend lifecycle,
but they do not need first-class UI exposure in the first editor surface.

## 19. Non-Goals For V1

These are explicitly out of scope for the first machine designer iteration:

- persisted node coordinates
- arbitrary handwritten DSL round-tripping beyond the managed subset
- freeform code editing with guaranteed visual round-trip
- shared IEx evaluation as the runtime compilation mechanism
- full collaborative editing semantics
- visual saving of partially representable machines

## 20. Success Criteria

The machine designer is successful when:

- it produces real Ogol DSL
- that DSL is the persisted artifact
- the managed subset round-trips safely
- generated modules load into the runtime under versioned names
- activation and retirement are explicit and observable
- the editor is a reliable authoring surface, not a second hidden runtime

## 21. Open Questions

The following questions remain intentionally open, but should not block the
first implementation:

- whether direct source editing enters v2 or later
- whether partial preservation ever moves beyond inspect-only
- whether `children` and richer `safety` editing land in v1.1 or v2
- whether rollback gets first-class UI exposure in the first designer surface

## 22. Immediate Next Deliverable

With the plan, subset, and lowering boundary now unified, the next concrete
implementation artifact should be the first golden round-trip and
canonicalization corpus.

That initial corpus now exists under:

- [test/fixtures/machine_authoring/manifest.term](/home/n0gg1n/Development/Work/opencode/ogol/test/fixtures/machine_authoring/manifest.term)
