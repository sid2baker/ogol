# Hardware Programmer Workflows

This document defines the programmer-facing hardware workflows for Ogol.

It complements the runtime context model by focusing on artifact lifecycle,
release posture, and the tools programmers should get across draft, test, and
live runtime work.

The core rule is:

- live runtime can be observed
- live runtime can be captured
- live runtime can receive bounded operational actions
- live runtime must not be the direct target of semantic authoring

## 1. Artifact States

The hardware/programming lifecycle should be framed around three artifact
states:

- `Draft`
- `Candidate`
- `Armed Live`

Interpretation:

- `Draft`
  - editable source/configuration
- `Candidate`
  - compiled/tested release candidate
- `Armed Live`
  - currently active live system

## 2. Main Workflows

### 2.1 Capture / Baseline

Goal:

- read the current live hardware
- store it as a reusable `hardware_config`
- generate a simulator-ready baseline

Tools:

- `Scan Hardware`
- `Capture Live As hardware_config`
- `Generate Simulator Setup From Live Hardware`
- saved captured versions

This is not only a day-one workflow. It also matters for:

- replacement hardware
- changed fieldbus topology
- support snapshots
- refreshed simulator baselines

### 2.2 Testing

Testing is one workflow family with multiple execution contexts:

- laptop + simulator
- controller bench runtime
- offline authoring only

Goal:

- edit DSL/visuals safely
- iterate against simulator or no backend
- validate before deploy

Tools:

- `Save Draft`
- `Compile`
- `Start Simulator`
- `Reset Simulator`
- `Use Saved Config`
- `Diff Draft vs Live`
- `Open Visual`
- `Open DSL`

### 2.3 Deploy

Goal:

- move a tested draft toward the target controller/runtime

Tools:

- `Promote Draft To Candidate`
- `Compare Candidate vs Armed`
- `Deploy Candidate`
- deploy validation
- visible rollback target

Deploy must not automatically imply `Armed`.

### 2.4 Arm / Disarm

Goal:

- enter or leave the explicit live-hardware posture

Rules:

- `Armed` must be explicit
- `Armed` should be visually unmistakable
- `Armed` should only exist with live hardware

Tools:

- `Arm`
- `Disarm`
- pre-arm validation
- rollback target visibility

### 2.5 Live Diagnosis

Goal:

- understand the current live truth without disturbing runtime

Tools:

- live status header
- freshness and trust indicators
- fault scope
- expected-vs-actual comparison
- runtime logs / event timeline
- `Capture Runtime Snapshot`
- `Capture Support Snapshot`

Live diagnosis should be read-only by default.

### 2.6 Live Change

Live change must be split into two classes.

#### Operational Actions

Examples:

- restart
- rescan
- rebind
- acknowledge/reset/recover

These act on runtime state.

#### Operational Config Changes

Examples:

- thresholds
- selected mappings
- bounded hardware configuration changes

These change configuration and should still be versioned and auditable.

#### Semantic Changes

Examples:

- machine logic
- topology behavior
- HMI structure

These must not target the armed runtime directly.

Required flow:

- `Clone Live To Draft`
- edit draft
- test
- compare candidate vs armed
- deploy
- arm explicitly

## 3. Runtime Tooling Rules

The hardware page and Studio should provide strong bridges between runtime truth
and authored artifacts.

Recommended tools:

- `Scan Hardware`
- `Capture Live As Artifact`
- `Generate Simulator Setup From Live Hardware`
- `Clone Live To Draft`
- `Diff Draft vs Live`
- `Promote Draft To Candidate`
- `Compare Candidate vs Armed`
- `Deploy`
- `Arm / Disarm`
- `Rollback`
- `Rescan / Rebind / Restart`
- `Record Scenario`
- `Replay Scenario`
- `Open DSL`
- `Open Visual`
- `Jump Runtime Object -> Authored Source`
- `Capture Runtime Snapshot`
- `Capture Support Snapshot`

## 4. Mode Model

The underlying runtime model should stay simple:

- explicit mode:
  - `Testing`
  - `Armed`
- derived source:
  - `Live`
  - `Simulator`
  - `None`

Interpretation:

- `Testing + None`
  - config/simulator workspace
- `Testing + Simulator`
  - active development loop
- `Testing + Live`
  - inspect, compare, capture
- `Armed + Live`
  - confirmed live runtime changes

For user-facing labels, the hardware page may present:

- `Draft / Test`
- `Live Inspect`
- `Armed`

That is a display refinement, not a change in the underlying mode model.

## 5. Safety Rule

The strongest product rule is:

- live can be observed
- live can be captured
- live can receive bounded operational actions
- live cannot be the direct target for semantic authoring

That is the boundary that keeps the developer workflow strong without making the
live system ambiguous or unsafe.
