# Sequence Spark Schema Specification

## 1. Purpose

This document defines the intended Spark schema for authoring Sequence DSL
definitions in Ogol.

It complements:

- [SEQUENCE_DSL.md](SEQUENCE_DSL.md), which defines the source-layer semantics
- [CANONICAL_SEQUENCE_MODEL.md](CANONICAL_SEQUENCE_MODEL.md), which defines the
  validated model produced from source

Its purpose is to answer:

- what Spark sections and entities should exist?
- how should authored sequence structure map to the canonical sequence model?
- where should validation, transformation, and generated metadata live?

---

## 2. Architectural Position

The Spark schema is not the runtime and not the canonical model.

It is the declarative authoring layer that:

- captures sequence structure
- attaches source locations and metadata
- performs validation
- resolves references
- produces the canonical sequence model

The schema should be designed to mirror the canonical sequence model closely
enough that lowering is straightforward and diagnostics remain precise.

---

## 3. Core Principles

The schema should follow these rules:

1. Source remains declarative and structured.
2. Spark entities should correspond to meaningful sequence concepts, not parser
   trivia.
3. Validation should happen as early as possible.
4. Source locations should be preserved on every meaningful authored entity.
5. Generated canonical identities should remain traceable back to Spark
   entities.
6. The schema should privilege typed refs over opaque dotted strings.

---

## 4. Top-Level Module Shape

One likely authoring shape is:

```elixir
defmodule MyApp.Sequence.Auto do
  use Ogol.Sequence

  sequence :auto do
    invariant expr(not(ref(:system, :topology, :estop)))

    proc :startup do
      wait ref(:clamp, :status, :open), timeout: 2_000, else: fail("clamp not open")
    end

    run :startup
  end
end
```

The exact macro surface may evolve, but the schema should preserve the same
core authored structure:

- one `sequence` root
- nested reusable `proc` definitions
- ordered statements
- typed references
- explicit validation points

---

## 5. Section and Entity Model

The minimum Spark extension should model:

- one `sequence` entity
- nested `proc` entities
- invariant entities
- statement entities
- expression/reference helpers

Illustrative organization:

```text
sequence
  invariants
  procs
  body
```

The schema should avoid flattening everything into one generic “statement” map
too early. Spark entities should carry enough structure to support targeted
validation and accurate error reporting.

---

## 6. Root Sequence Entity

The root sequence entity represents one orchestration definition.

Illustrative fields:

```text
SequenceEntity {
  name
  invariants
  procs
  body
  __spark_metadata__
}
```

Expected responsibilities:

- define the sequence name
- own the root entry body
- collect reusable `proc` definitions
- provide the anchor for validation and lowering

There should be exactly one root `sequence` entity per sequence module.

---

## 7. Procedure Entity

`proc` is the reusable local block construct inside a sequence definition.

Illustrative fields:

```text
ProcEntity {
  name
  body
  __spark_metadata__
}
```

Validation responsibilities:

- procedure names must be unique within the sequence
- procedures referenced by `run` must exist
- recursive or cyclic `run` graphs should be validated by explicit policy

---

## 8. Statement Entities

The minimum statement entity set should include:

- `do_skill`
- `wait`
- `if`
- `run`
- `repeat`
- `fail`

Optional guard semantics such as `when` should be represented as statement
options or wrappers, not as an untyped afterthought.

### 8.1 `do_skill`

Illustrative fields:

```text
DoSkillEntity {
  machine
  skill
  when
  __spark_metadata__
}
```

### 8.2 `wait`

Illustrative fields:

```text
WaitEntity {
  condition
  timeout
  else_branch
  signal?
  __spark_metadata__
}
```

The schema must distinguish:

- durable waits over status/topology expressions
- explicit signal waits

It must not silently infer edge semantics from arbitrary expressions.

### 8.3 `if`

Illustrative fields:

```text
IfEntity {
  condition
  then_body
  else_body
  __spark_metadata__
}
```

### 8.4 `run`

Illustrative fields:

```text
RunEntity {
  procedure
  __spark_metadata__
}
```

`run` represents nested execution into a named procedure frame. Control returns
to the caller when the called procedure frame completes successfully.

### 8.5 `repeat`

Illustrative fields:

```text
RepeatEntity {
  body
  __spark_metadata__
}
```

### 8.6 `fail`

Illustrative fields:

```text
FailEntity {
  message
  __spark_metadata__
}
```

---

## 9. Typed Reference Helpers

The Spark schema should encourage typed references directly instead of treating
dotted strings as canonical semantics.

Minimum reference helpers:

- `ref(:machine, :status, :item)` -> `StatusRef`
- `ref(:machine, :signal, :item)` -> `SignalRef`
- `ref(:machine, :skill, :item)` -> `SkillRef`
- `ref(:system, :topology, :item)` -> `TopologyRef`

Shorter author-facing forms may exist, but Spark normalization should resolve
them into typed refs before canonical-model generation.

Unqualified global orchestration refs such as `estop` should normalize to
`TopologyRef(scope: :system, item: :estop)` or an equivalent explicit typed
representation.

---

## 10. Expression Representation

Expressions should be represented structurally inside Spark entities, not as raw
unparsed strings.

The minimum supported expression ingredients are:

- literals
- boolean operators
- comparison operators
- typed status/topology refs

Signal refs should only appear in signal-explicit constructs.

The schema does not need a general-purpose language. It needs enough structure
for:

- validation
- lowering
- HMI explanation
- diagnostics

---

## 11. Validation Responsibilities

The Spark schema and its verifiers should enforce at least:

1. referenced machines exist in the resolved topology
2. referenced skills exist and are public
3. referenced status items exist and are public
4. referenced signals exist and are public when signal waits are used
5. `wait` conditions are structurally valid for their wait kind
6. invariants are boolean expressions
7. `when` guards are boolean expressions
8. timeout values are valid durations
9. `run` targets exist
10. recovery/timeout branches are structurally valid
11. failure causes remain attributable to source sites
12. repeated bodies have at least one progress-bearing step or emit warning

Validation should fail at compile time whenever possible.

Every validation error should carry:

- module
- DSL path
- source location
- the specific entity or option that caused the error

---

## 12. Transformers and Lowering Pipeline

The Spark pipeline should follow this order:

1. parse source into Spark entities
2. attach default structure where appropriate
3. resolve typed references
4. validate topology and machine contracts
5. assign stable identities to sequence, procedure, and step entities
6. produce the canonical sequence model
7. persist canonical model metadata for generated runtime and tooling

Transformers should not depend on calling functions on the module being
compiled. They should work from DSL state, resolved topology metadata, and
persisted intermediate values.

---

## 13. Info Module Responsibilities

The Sequence DSL should expose Spark info accessors so tooling does not need to
reach into raw DSL state.

At minimum, info access should support:

- sequence definition lookup
- procedure listing
- invariant listing
- resolved reference listing
- canonical-model retrieval or access to persisted canonical metadata

This is important for:

- Studio inspection
- docs
- generated HMI
- diagnostics

---

## 14. Canonical Model Mapping

The schema should map cleanly into the canonical model defined in
[CANONICAL_SEQUENCE_MODEL.md](CANONICAL_SEQUENCE_MODEL.md).

Illustrative mapping:

- `sequence` entity -> `SequenceDefinition`
- `proc` entity -> `ProcedureDefinition`
- `do_skill` entity -> `DoSkill` step
- `wait` entity -> `WaitStatus` or `WaitSignal` step
- `if` entity -> `If` step
- `run` entity -> `RunProcedure` step
- `repeat` entity -> `Repeat` step
- `fail` entity -> `Fail` step
- `when` option -> step guard

This mapping should be close enough that canonical model generation is mostly a
structural transformation plus validation, not a second language design pass.

---

## 15. Generated Metadata

Beyond the canonical model itself, the schema should support generation of:

- stable step ids
- source-to-step mappings
- HMI projection labels or summaries
- trace metadata
- documentation metadata

This metadata should be derived from Spark entities with source locations
attached, so generated runtime diagnostics can point back to authored source
without ambiguity.

---

## 16. Example Schema Sketch

Illustrative pseudo-Spark organization:

```elixir
@sequence %Spark.Dsl.Entity{
  name: :sequence,
  target: Ogol.Sequence.Definition,
  args: [:name],
  entities: [
    invariants: [entities: [@invariant]],
    procs: [entities: [@proc]],
    body: [entities: [@do_skill, @wait, @if, @run, @repeat, @fail]]
  ]
}
```

And:

```elixir
@wait %Spark.Dsl.Entity{
  name: :wait,
  target: Ogol.Sequence.Dsl.Wait,
  args: [:condition],
  schema: [
    timeout: [type: :non_neg_integer],
    else: [type: :any],
    signal?: [type: :boolean, default: false]
  ]
}
```

This sketch is illustrative only. The important part is the structural
correspondence to the canonical model.

---

## 17. Conformance Summary

A Spark schema conforms to this specification if it:

- models Sequence DSL source as structured Spark entities
- resolves authored refs into typed references
- preserves source location and identity metadata
- validates machine/topology contracts at compile time where possible
- produces the canonical sequence model cleanly and deterministically
- supports generation of runtime, HMI, diagnostic, and documentation metadata

