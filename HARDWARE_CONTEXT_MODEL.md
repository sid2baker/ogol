# Hardware Context Model

This document defines the runtime control model for the Ogol hardware area.

The core rule remains:

> expected no hardware, simulated hardware, and unexpectedly missing hardware
> are different truths.

The hardware page should not behave like a generic app page. It should behave
like a programmer-facing operational instrument that answers, in order:

- what hardware truth is currently available
- whether that truth is live, simulated, or absent
- what is still trustworthy
- what actions are legal now

## 1. Simplified Runtime Model

The hardware UI should use one explicit user-facing mode and one derived source.

### 1.1 Explicit Mode

The visible mode is:

- `:testing`
- `:armed`

`Testing` is the default draft-first posture.

`Armed` is the explicit live-hardware posture for confirmed runtime changes.

If live hardware is not present, the system must fail closed back to
`Testing`.

The internal mode model should stay this small even if the UI chooses clearer
display labels such as:

- `Draft / Test`
- `Live Inspect`
- `Armed`

### 1.2 Derived Source

The source of hardware truth is observed, not selected.

Suggested shape:

```elixir
%{
  source: :live | :simulator | :none,
  truth_source: :local_runtime | :remote_runtime | :snapshot | :simulator,
  host_kind: :controller | :laptop | :remote,
  coupling: :attached | :detached | :partial,
  hardware_expectation: :required | :optional | :none,
  topology_match: :match | :missing | :extra | :swapped | :multiple | :unknown,
  last_update_at: DateTime.t() | nil,
  staleness_ms: non_neg_integer() | nil,
  freshness: :live | :stale | :unknown,
  runtime_health: :healthy | :degraded | :disconnected | :unknown,
  fault_scope:
    :none
    | :local_device
    | :fieldbus_segment
    | :runtime_coupling
    | :remote_link
    | :multiple
    | :unknown
}
```

Key interpretation:

- `source == :none`
  - no live hardware backend is currently active
  - no simulator is currently running
  - the UI should pivot into config/simulator workflow
- `source == :simulator`
  - the page is rendering simulated truth
- `source == :live`
  - the page is rendering connected live hardware truth

## 2. Derived Control Policy

The page should derive visible authority instead of exposing many knobs.

Suggested shape:

```elixir
%{
  kind: :testing | :armed,
  armable?: boolean(),
  write_policy: :blocked | :restricted | :confirmed | :enabled,
  authority_scope:
    :observe_only
    | :draft_and_simulation
    | :capture_and_compare
    | :live_runtime_changes
}
```

Interpretation:

- `:draft_and_simulation`
  - save configs
  - edit simulator setup
  - start simulator
- `:capture_and_compare`
  - observe live hardware
  - capture live hardware as a reusable config
  - compare live vs expected
  - no live runtime mutation
- `:live_runtime_changes`
  - confirmed live runtime controls
  - confirmed provisioning changes

`write_policy` is a derived visible result of:

- observed source/truth
- selected mode
- permissions
- deployment policy

## 3. Summary State

The page should still synthesize a short operator/programmer-facing summary.

Suggested values:

- `:live_healthy`
- `:live_degraded`
- `:simulated`
- `:expected_none`
- `:disconnected_fault`
- `:remote_stale`

This is presentation shorthand only.

The UI must not drive behavior from summary state alone.

## 4. Behavior By Source And Mode

### 4.1 Testing + None

This is the default no-hardware workspace.

The page should:

- show saved hardware configs first
- show simulator authoring first
- allow config editing and simulator start
- avoid presenting absent hardware as a production fault

### 4.2 Testing + Simulator

This is the normal development loop.

The page should:

- show simulator-backed runtime truth
- keep simulator/config tools prominent
- allow iteration without armed-runtime semantics

### 4.3 Testing + Live

This is the safe live-inspection and capture workflow.

The page should:

- show connected live hardware first
- keep runtime/provisioning mutations blocked
- allow “Capture live as hardware_config”
- emphasize expected-vs-actual comparison and trust/freshness

This is the important boundary:

> live can be observed and captured in testing, but not semantically edited in
> place.

### 4.4 Armed + Live

This is the explicit live-change posture.

The page should:

- make the whole window visually unmistakable
- enable bounded, confirmed live runtime actions
- enable confirmed provisioning changes
- keep capture available because it is observational

`Armed` should never silently exist for `:none` or `:simulator`.

## 5. Mandatory Header

The header must answer the situation first.

Minimum fields:

- `Summary`
- `Mode`
- `Source`
- `Truth Source`
- `Coupling`
- `Expectation`
- `Match`
- `Freshness`
- `Runtime Health`
- `Write Policy`
- `Authority`
- `Fault Scope`

Freshness should keep both:

- a badge-level summary
- real timing data such as `staleness_ms`

## 6. Section Priority

Section order should be shaped by source and mode.

Recommended first-pass rules:

- `Testing + None`
  - `Simulation`
  - `Status`
  - `Diagnostics`
- `Testing + Simulator`
  - `Status`
  - `Commissioning` when expected config exists
  - `Simulation`
  - `Devices`
  - `Diagnostics`
  - `Provisioning`
- `Testing + Live`
  - `Status`
  - `Capture / Baseline`
  - `Commissioning` when expected config exists
  - `Devices`
  - `Diagnostics`
- `Armed + Live`
  - `Status`
  - `Capture / Baseline`
  - `Commissioning` when expected config exists
  - `Devices`
  - `Diagnostics`
  - `Provisioning`

The hardware page should not be one static page with hidden widgets.

## 7. Guiding Rule

When hardware truth is ambiguous, the UI must prefer explicit context and
reduced authority over optimistic assumptions.
