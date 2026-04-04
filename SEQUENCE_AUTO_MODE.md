# Sequence Auto Mode

## Purpose

This is the canonical design and status document for sequence-driven Auto mode
in Ogol.

It replaces the earlier split findings, plan, and contract notes. This file is
meant to answer four questions in one place:

- what the conceptual cut is
- what the runtime contract is
- what is already implemented
- what is still incomplete

## Core Model

The right architectural split is:

- `machine` = local controller and capability boundary
- `sequence` = procedural owner of Auto mode
- `topology` = composed runtime, machine set, and hardware binding

That means:

- in `Manual`, operators invoke machine capabilities directly
- in `Auto`, one sequence run invokes those same capabilities automatically

The important boundary is that sequences own **procedure logic**, not all
control logic.

Machines should still own:

- local output/fact behavior
- interlocks
- feedback validation
- local timeout and fault behavior
- safe local reactions

Sequences should own:

- order of operations
- cross-machine coordination
- procedure-level waits
- operator-visible run progress
- explicit pause, resume, abort, and cycle behavior

Topology should own:

- which machines exist
- which hardware exists
- how bindings are realized
- which runtime tree is currently active

## Why This Model

This is a better fit for Ogol than treating sequences as generic workflows.

The system wants to model an industrial `Manual` / `Auto` split, not just “run
a workflow.” That means the runtime needs first-class semantics for:

- orchestration ownership
- run lifecycle
- trust in the realized world
- resumability from committed boundaries
- operator intent versus fulfilled state

## Canonical Runtime Contract

The runtime model should be treated as orthogonal axes, not one overloaded
status flag.

```elixir
%{
  control_mode: :manual | :auto,
  owner: :manual_operator | {:sequence_run, run_id},
  run: %{
    id: run_id | nil,
    state:
      :idle
      | :starting
      | :running
      | :paused
      | :held
      | :completed
      | :aborted
      | :faulted,
    policy: :once | :cycle,
    cycle_count: non_neg_integer(),
    resumable?: boolean(),
    resume_from_boundary: step_id | nil,
    resume_blockers: [term()],
    fault_source: :machine | :sequence_logic | :external_runtime | nil,
    fault_recoverability: :automatic | :operator_ack_required | :abort_required | nil,
    fault_scope: :step_local | :run_wide | :runtime_wide | nil
  },
  pending_intent: %{
    pause: %{
      requested?: boolean(),
      requested_by: term() | nil,
      requested_at: DateTime.t() | nil,
      admitted?: boolean(),
      admitted_at: DateTime.t() | nil,
      fulfilled?: boolean(),
      fulfilled_at: DateTime.t() | nil
    },
    abort: %{
      requested?: boolean(),
      requested_by: term() | nil,
      requested_at: DateTime.t() | nil,
      admitted?: boolean(),
      admitted_at: DateTime.t() | nil,
      fulfilled?: boolean(),
      fulfilled_at: DateTime.t() | nil
    }
  },
  runtime: %{
    topology_generation: term(),
    run_generation: term() | nil,
    trust_state: :trusted | :degraded | :invalidated,
    invalidation_reasons: [term()]
  }
}
```

### Axis Meanings

- `control_mode`
  Answers whether the cell is in Manual or Auto.
- `owner`
  Answers who currently owns orchestration rights.
- `run`
  Answers what the current sequence procedure is doing.
- `pending_intent`
  Answers which pause/abort requests were admitted but not yet fulfilled.
- `runtime`
  Answers which realized world the run belongs to and whether it is still
  trusted.

## Runtime Semantics

### Control Mode

- `:manual`
  Manual orchestration is enabled.
- `:auto`
  The cell is armed for sequence ownership.

`control_mode == :auto` does **not** imply an active sequence owner. Auto may
remain armed while `owner == :manual_operator`.

### Owner

- `:manual_operator`
  No active sequence currently owns orchestration rights.
- `{:sequence_run, run_id}`
  The identified run owns orchestration rights.

### Run State

- `:idle`
  No active run is executing.
- `:starting`
  A run was admitted and is being established against the active topology.
- `:running`
  The run is issuing or observing normal procedure progress.
- `:paused`
  An orderly operator-requested pause was fulfilled at a safe boundary.
- `:held`
  Trust was lost or operator intervention is required. The run may still be
  resumable.
- `:completed`
  The run terminated successfully.
- `:aborted`
  The run was intentionally terminated.
- `:faulted`
  The run ended in a terminal failure classification.

### Trust State

- `:trusted`
  The realized world matches the run’s assumptions.
- `:degraded`
  Reserved for a still-observable but policy-restricted world.
- `:invalidated`
  The run’s realized-world assumptions are no longer defensible.

### Generation Fields

- `topology_generation`
  Identity of the currently realized world.
- `run_generation`
  The realized-world generation that the run was admitted against.

### Pending Intent

`pending_intent` is request state, not outcome state.

- `requested?` means it was asked for
- `admitted?` means the controller accepted it
- `fulfilled?` means the runtime actually reached the safe boundary where it
  took effect

This is what keeps pause and abort from lying about timing.

## Ownership And Command Arbitration

Machine-affecting commands should be admitted by ownership, not by scattered
UI policy.

The effective command classes are:

- read-only / diagnostic
- normal operator command
- sequence-driven command
- acknowledge / clear-result
- emergency safe-stop

The default policy is:

- read-only / diagnostic is always allowed
- normal operator commands are allowed in Manual and denied while Auto owns the
  cell
- sequence-driven commands are only allowed for the active run owner
- acknowledge / clear-result is allowed by hold/fault/result policy
- emergency safe-stop remains distinct from run abort

## Pause, Hold, Abort, Resume

These meanings should stay asymmetric:

- `Pause`
  Operator-requested, orderly, trust-preserving, fulfilled only at a safe
  boundary
- `Hold`
  System-imposed because trust was lost or intervention is required
- `Abort`
  Explicit termination of the current run
- `Resume`
  Only valid from a committed boundary, and only when trust and blockers allow
  it

`Hold` is not just “Pause, but red.” It means the runtime no longer trusts the
world enough to keep progressing normally.

## Committed Boundaries And Resumability

Resume is only honest from committed boundaries.

A sequence step conceptually crosses:

- preconditions
- command issue
- observation / verification
- commit boundary

Commit boundaries depend on authoritative observation sources, such as:

- machine capability state
- topology-visible runtime state
- machine-emitted signals when they are the intended proof surface
- explicit operator acknowledgment when policy requires it

Sequence-local intent alone is not enough.

## Fault Classification

Faults should be classified by:

- source
  - `:machine`
  - `:sequence_logic`
  - `:external_runtime`
- recoverability
  - `:automatic`
  - `:operator_ack_required`
  - `:abort_required`
- scope
  - `:step_local`
  - `:run_wide`
  - `:runtime_wide`

The important semantic split is:

- `:held` = trust lost or intervention required, maybe resumable
- `:faulted` = terminal failure classification for this run
- `:aborted` = intentionally terminated

## One Active Run

The default rule remains:

- many authored sequences per workspace
- one active sequence run per active topology

That is the right default for a cell-level Auto owner.

## Cycle Policy

Looping belongs at the run-policy level, not as an implicit endless recursive
procedure.

The runtime policy is:

- `:once`
- `:cycle`

Cycle mode should restart only from a durable cycle boundary.

## Invariants

These should remain true:

- exactly one orchestration owner exists at a time
- `owner == {:sequence_run, run_id}` implies `control_mode == :auto`
- `owner == {:sequence_run, run_id}` implies `run.id == run_id`
- `control_mode == :manual` implies no new sequence run is admitted
- `run.state == :running` implies an active run id exists
- `control_mode == :auto` may coexist with `owner == :manual_operator`, but
  only when no sequence currently owns orchestration rights
- terminal run states release active sequence ownership by default
- `trust_state == :invalidated` blocks resume unless explicit revalidation
  restores defensibility
- `resume_from_boundary != nil` implies the run crossed at least one committed
  boundary
- terminal run states clear stale pause / abort intent

## Current Implementation State

The current implementation is already aligned with the model in important ways.

### Implemented

- explicit `Manual` / `Auto` control mode
- explicit sequence owner state
- one active sequence run per active topology
- session-owned run truth in `Ogol.Session.State`
- `Ogol.Session.AutoController` as the `:gen_statem` ownership boundary
- first-class `Ogol.Sequence.Runner`
- explicit run states:
  - `:idle`
  - `:starting`
  - `:running`
  - `:paused`
  - `:held`
  - `:completed`
  - `:aborted`
  - `:faulted`
- explicit pause and abort pending intent
- pause fulfilled at committed boundaries
- hold on runtime trust loss
- trust invalidation on workspace drift
- trust invalidation on runtime stop/failure
- realized-world generation tracking
- held-run resume only when trust and generation allow it
- `run_policy: :once | :cycle`
- fault classification on run truth
- explicit acknowledge / clear-result semantics for held and terminal runs
- sequence page support for:
  - arm/disarm Auto
  - run policy
  - run / pause / resume / abort
  - held resume
  - held acknowledge
  - terminal clear / acknowledge
  - runtime trust and fault classification display

### Important Current Behaviors

- Auto may remain armed after a run completes, aborts, faults, or is
  acknowledged away
- owner returns to `:manual_operator` after terminal states
- held runs can be acknowledged back to `:idle`
- faulted runs can be acknowledged back to `:idle`
- clearing a run preserves the selected run policy
- runtime-stop holds are intentionally non-resumable
- workspace-drift holds may be resumable after trust restoration
- topology generation changes invalidate held-run resume

## Current Gaps

The implementation is good enough to be considered a credible control-runtime
foundation, but it is not finished.

The main remaining gaps are:

- ownership/arbitration consistency outside the sequence page
- broader UI surfacing of control mode, owner, and trust
- deciding whether `:degraded` should become a real runtime state or be removed
- some policy is still distributed across reducer, controller, runner, and UI
- the full contract-wide regression sweep is not done yet

## Current Assessment

The current implementation is past the “interesting prototype” stage.

What is strong:

- the machine / sequence / topology split is correct
- the runtime contract is mostly honest
- pause, hold, resume, generation invalidation, and cycle policy are all real
- the code now reflects industrial `Manual` / `Auto` semantics better than a
  generic workflow engine would

What is still rough:

- not every UI surface fully enforces the same ownership contract yet
- `:degraded` exists in the model without full operational meaning
- some policy decisions still live in multiple layers

The right next work is consistency and completion, not a conceptual rewrite.

## Practical Next Steps

If work continues, the most useful next slices are:

1. finish ownership/arbitration consistency across the remaining UI and command
   surfaces
2. either implement real `:degraded` semantics or remove it
3. tighten policy placement so fault/trust handling is less distributed
4. run and stabilize the broader regression sweep

## Bottom Line

Ogol should treat sequences as Auto-mode procedure owners, not as generic
workflows and not as replacements for machine-local control behavior.

That direction is now both the intended design and the shape of the current
implementation.
