# Studio Cells

This document defines the broader Studio Cell concept for Ogol Studio.

The idea should stay simple:

> A Studio Cell is the UI for one bounded, source-backed artifact.

Source is authoritative. The user has intent. The outside world has observed
reality. The UI should show the most honest projection it can.

`StudioCell` started as a reusable UI shell. The longer-term concept is
broader: a shared authoring model for source-backed things across Studio.

## 1. Core Idea

A Studio Cell exists to let a user work on one source-backed thing.

Everything else follows from that.

For any cell, the important questions are:

1. What is the thing?
   The source-backed artifact.
2. What is the truth?
   The source.
3. What does the user want?
   The intended or desired state.
4. What is the world doing?
   The observed state.
5. What can the UI honestly show right now?
   A visual projection, source, or a degraded fallback.

If the model stays centered on those questions, it stays understandable.

## 2. What A Cell Is

A Studio Cell is:

- bounded
  - it solves one clear problem for one artifact
- source-backed
  - the source is the durable truth
- stateful
  - actions and external events change what the cell can honestly show and do
- two-way
  - visual edits update source
  - source edits update the visual projection when supported

Use this distinction:

- `cell`
  - the UI interaction surface
- `artifact`
  - the source-backed thing the cell is about

Examples:

- Driver Studio Cell -> edits one driver artifact
- Machine Studio Cell -> edits one machine artifact
- Topology Studio Cell -> edits one topology artifact
- EtherCAT Master Studio Cell -> edits one master configuration artifact
- HMI Studio Cell -> edits one HMI surface artifact

## 3. Fundamental Facts

The cell should stay centered on a small set of core facts.

## 3.1 Source

`source` is the exact authored text for the artifact.

This is the only durable authority.

## 3.2 Model

`model` is a parsed or recovered form of the source, when possible.

It exists to support visual editing and round-tripping.

Typical outcomes are:

- `{:ok, model}`
- `{:partial, model, diagnostics}`
- `:unsupported`

The model is derived from source. It is not a second truth.

## 3.3 Desired State

`desired_state` describes what the user or artifact intends.

Examples:

- `:stopped`
- `:running`
- `:applied`
- `:deployed`
- `:assigned`

Desired state changes only when a requested transition is accepted.

If a transition is rejected:

- desired state does not change

This keeps the UI from faking progress.

## 3.4 Observed State

`observed_state` describes what the external world reports now.

Examples:

- `:idle`
- `:starting`
- `:running`
- `:stopping`
- `:faulted`
- `:disconnected`

Observed state comes from runtime facts, not from author intent.

The key split is:

- desired state = what the user or source intends
- observed state = what the world is actually doing

Examples:

- desired `:running`, observed `:starting`
- desired `:applied`, observed `:disconnected`
- desired `:stopped`, observed `:faulted`

## 3.5 Issues

`issues` are explicit facts that explain mismatch, failure, or degraded
capability.

Examples:

- `:visual_unavailable`
- `:partial_recovery`
- `:build_failed`
- `:apply_blocked`
- `:master_not_running`
- `:runtime_disconnected`

Issues may also carry detail.

Examples:

- `{:master_not_running, "Start the EtherCAT master before starting this topology."}`
- `{:apply_blocked, %{lingering_pids: [...]}}`

Issues are facts. They are not UI labels.

## 4. Derived UI

The UI should mostly be derived from the core facts rather than stored as
parallel truth.

Derived UI includes:

- available actions
- the current top-priority notice
- available representations
- the selected representation
- disabled reasons
- the current visual presentation

This keeps the authority model simple:

- source, model, desired state, observed state, and issues are the facts
- the UI is a projection of those facts

## 5. Core Rules

These rules should hold for every Studio Cell.

## 5.1 Source Is Authoritative

The source is the only durable truth.

Visual mode must never become a second authority.

## 5.2 Visual Is A Projection

Visual editing is a projection of source.

It may be:

- available
- partial
- unavailable

If the source cannot be represented visually:

- do not fake a synced visual state
- do not silently coerce the source into a different meaning
- keep source fully editable
- explain the degraded state honestly

## 5.3 Intent Is Not Reality

User actions express intent by requesting transitions.

Observed state comes from the outside world.

The UI must keep this distinction explicit.

## 5.4 Desired State Changes Only On Accepted Transition

This is the key operational rule.

If the user clicks `Start`, `Apply`, or `Deploy`, the cell should:

1. validate the action
2. check preconditions
3. accept or reject the transition

Only if the transition is accepted should desired state change.

If it is rejected:

- desired state stays where it was
- the cell derives an issue
- the UI explains the reason

## 5.5 The UI Must Be Honest

The UI should show the most honest projection it can.

That may be:

- visual
- partial visual
- source
- source with a clear explanation

## 5.6 The UI Is Derived

Actions, notices, and presentation should come from the core facts, not from
ad hoc LiveView booleans that become the real model by accident.

## 6. Views And Representation

Do not think of representation as a promise that both `Visual` and `Source`
always exist.

Instead, think of it as two simpler questions:

- what views are available right now?
- which one is selected?

At minimum, every cell must support:

- source

Some cells also support:

- visual
- partial visual

So the right side of the header is not always a true toggle.
It is a selector among available views.

## 7. Header And Body

The shared UI contract should stay simple.

## 7.1 Header

The header answers three questions:

- What can I do now?
- What do I most need to know?
- How can I view this right now?

So the header is:

- left: available actions
- middle: the most important current notice
- right: available views

The header should not become a dashboard for passive detail.

## 7.2 Body

The body shows the current view:

- visual
- partial visual
- source

Different states may produce different visual presentations, but they are still
presentations of the same source-backed artifact.

## 8. Actions And Events

Two kinds of things change a cell:

- user actions
- external events

### User actions

Examples:

- `Build`
- `Apply`
- `Start`
- `Stop`
- `Scan`
- `Deploy`
- `Assign`
- source edit
- visual edit

### External events

Examples:

- runtime started
- runtime stopped
- bus disconnected
- simulator crashed
- HMI assignment changed elsewhere
- active topology changed

The shared model should make room for both without confusing intent with
reality.

## 9. Framework Boundary

The shared Studio Cell concept should define:

- source is authoritative
- model is derived from source
- desired and observed are distinct
- issues are explicit facts
- UI is derived
- the header/body contract

Each cell type should define:

- which desired states it supports
- which observed states matter
- which issues can arise
- which actions exist
- which views are possible

This keeps the framework small and avoids a giant universal enum taxonomy too
early.

## 10. Secondary Concepts

Some cells may need additional summaries such as:

- validity
- build/apply state
- deployment state
- draftness

These can be useful, but they should be treated as secondary or derived
concepts unless they prove essential across all cell types.

For example, a shared lifecycle enum may be useful in practice, but it is not
the first-principles foundation of the model.

## 11. Examples

## 11.1 Driver Cell

Core facts:

- source = generated driver module source
- desired state = typically `:applied`
- observed state = host/runtime apply reality
- issues = build failure, apply blocked, visual unavailable

Derived UI:

- actions = `Build`, `Apply`
- views = `Visual`, `Source`, or `Source` only

## 11.2 EtherCAT Master Cell

Core facts:

- source = authored master configuration
- desired state = `:running` or `:stopped`
- observed state = idle, starting, running, faulted, disconnected
- issues = runtime disconnected, scan rejected, master fault

Derived UI:

- actions = `Scan`, `Start`, `Stop`
- notice = top-priority master/runtime condition

## 11.3 Simulator Cell

Core facts:

- source = authored simulator ring configuration
- desired state = `:running` or `:stopped`
- observed state = idle, starting, running, faulted
- issues = runtime fault, source/visual mismatch

Derived UI:

- actions = `Start`, `Stop`

Important rule:

- simulator running does not imply EtherCAT master running

## 11.4 Topology Cell

Core facts:

- source = authored topology source
- desired state = `:running` or `:stopped`
- observed state = topology runtime condition
- issues = master not running, dependency mismatch, observation contract errors

Derived UI:

- actions = `Start`, `Stop`
- notice = highest-priority reason the topology can or cannot run

## 11.5 HMI Cell

Core facts:

- source = authored HMI surface source
- desired state = `:deployed` or `:assigned`
- observed state = deployed, assigned, disconnected, missing
- issues = deployment missing, assignment missing, runtime disconnected

Derived UI:

- actions = `Build`, `Deploy`, `Assign`

## 12. Summary

A Studio Cell is the UI for one bounded, source-backed artifact.

The core facts are:

- source
- model
- desired state
- observed state
- issues

From those facts, the UI derives:

- actions
- notices
- available views
- selected view
- current presentation

The core doctrine is:

- source is truth
- visual is a projection
- intent is not reality
- issues are facts
- the UI must be honest
- the UI is derived

The shortest version is:

> A Studio Cell is the UI for one source-backed thing. Source is truth. The
> user has intent. The world has reality. The UI shows the most honest
> projection it can.
