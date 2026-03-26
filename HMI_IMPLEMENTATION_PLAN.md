# Ogol HMI Implementation Plan

This plan defines the first HMI for Ogol.

The HMI is a **projection and control surface** around the real runtime
processes. It is not a second runtime, not a simulator, and not a hidden state
manager that competes with the machine brains.

The key boundary is:

```text
machine runtime owns truth
HMI owns projection and operator interaction
```

The implementation target is:

- Phoenix
- Phoenix LiveView
- Tailwind CSS

## 1. Goals

The first HMI should provide:

- machine overview
- machine detail inspection
- operator request/event controls
- topology visibility
- EtherCAT visibility
- crash/restart visibility
- append-only event log

It should do this without:

- bypassing machine request/event semantics
- reading random process internals ad hoc from LiveView
- pushing browser-specific state into the machine runtime

## 2. Non-Goals

The first HMI should not try to provide:

- a visual machine editor
- a PLC ladder-style screen designer
- historian/long-term analytics
- production auth/SSO on day one
- full RBAC on day one
- chart-heavy BI dashboards

Those may come later, but they are not required for the first useful HMI.

## 3. Core Principles

1. `:gen_statem` machine brains remain the source of truth.
2. LiveView pages render read models, not raw machine callback data.
3. All operator writes go through a dedicated command gateway.
4. Runtime notifications are explicit and typed.
5. Event history and current snapshot state are separate concerns.
6. Tailwind is the styling layer; no component framework is required for v1.

## 4. Stack

Recommended stack:

- `phoenix`
- `phoenix_live_view`
- `phoenix_html`
- `phoenix_live_reload` in development
- built-in Tailwind integration from the Phoenix installer

Tailwind is the styling layer for:

- layout
- typography
- spacing
- color/state semantics
- responsive tables and panels

Do not add a second UI framework first.
The first HMI should stay close to standard Phoenix + LiveView + Tailwind.

## 5. Runtime Notification Contract

Before building pages, define a stable runtime notification shape.

This contract should be treated as a stable runtime integration boundary, not
as an ad hoc HMI convenience type.

Preferred layering:

```text
machine/topology/adapter runtime
-> runtime notification contract
-> HMI projector
-> snapshots / bus / event log
```

Rules:

- machine runtime SHOULD emit stable runtime notifications directly
- topology SHOULD emit stable runtime notifications directly
- adapters SHOULD emit stable runtime notifications directly
- if lower-level runtime tuples still exist temporarily, a thin translation
  layer MAY adapt them into the runtime notification contract
- LiveView MUST NOT parse arbitrary runtime tuples directly

Suggested envelope:

```elixir
defmodule Ogol.HMI.Notification do
  @enforce_keys [:type, :occurred_at]
  defstruct [
    :type,
    :machine_id,
    :topology_id,
    :source,
    :occurred_at,
    payload: %{},
    meta: %{}
  ]
end
```

Initial notification types:

- `:machine_started`
- `:machine_stopped`
- `:machine_down`
- `:state_entered`
- `:signal_emitted`
- `:command_dispatched`
- `:command_failed`
- `:safety_violation`
- `:child_state_entered`
- `:child_signal_emitted`
- `:child_down`
- `:adapter_feedback`
- `:adapter_status_changed`
- `:topology_ready`

Rule:

- machine runtime emits typed notifications
- topology emits typed notifications
- adapter boundary emits typed notifications
- projector consumes only these notifications

LiveView MUST NOT subscribe to arbitrary runtime tuples directly.

## 6. Canonical Snapshot Shape

Define the engineering snapshot first.

Suggested shape:

```elixir
defmodule Ogol.HMI.MachineSnapshot do
  @enforce_keys [:machine_id, :module, :current_state, :health]
  defstruct [
    :machine_id,
    :module,
    :current_state,
    :health,
    :last_signal,
    :last_transition_at,
    :restart_count,
    :connected?,
    facts: %{},
    fields: %{},
    outputs: %{},
    alarms: [],
    faults: [],
    children: [],
    adapter_status: %{},
    meta: %{}
  ]
end
```

Then derive an operator-facing projection as needed.

Important:

- `fields` belong in engineering/debug views by default
- `fields` MAY exist in engineering snapshots
- operator-facing pages SHOULD render only explicitly whitelisted machine data

### 6.1 Topology Snapshot

Define a sibling topology snapshot now, even if small.

Suggested shape:

```elixir
defmodule Ogol.HMI.TopologySnapshot do
  @enforce_keys [:topology_id, :parent_machine_id, :health]
  defstruct [
    :topology_id,
    :parent_machine_id,
    :health,
    :connected?,
    children: [],
    restart_summary: %{},
    connectivity: %{},
    meta: %{}
  ]
end
```

Suggested child summary entries:

- child name
- machine id
- current state
- health
- connected/running flag
- last update time

### 6.2 Hardware Snapshot

Define a small hardware snapshot type now for EtherCAT and future adapters.

Suggested shape:

```elixir
defmodule Ogol.HMI.HardwareSnapshot do
  @enforce_keys [:bus, :endpoint_id, :connected?]
  defstruct [
    :bus,
    :endpoint_id,
    :connected?,
    :last_feedback_at,
    observed_signals: %{},
    driven_outputs: %{},
    status: %{},
    faults: [],
    meta: %{}
  ]
end
```

For EtherCAT, `endpoint_id` is typically the slave name.

This snapshot should be the canonical read model for the EtherCAT page, rather
than letting the page invent its own data shape.

### 6.3 Snapshot Authority

The snapshot store contains projected HMI state only.

Rules:

- `SnapshotStore` MUST NOT be treated as machine authority
- `SnapshotStore` MUST NOT be written directly by LiveView
- `SnapshotStore` MUST only be updated by projector/index style runtime
  consumers
- operators act on the runtime through `CommandGateway`, not through snapshot
  mutation

### 6.4 Health States

Freeze a first canonical health vocabulary now.

Initial set:

- `:healthy`
- `:running`
- `:waiting`
- `:stopped`
- `:faulted`
- `:crashed`
- `:recovering`
- `:stale`
- `:disconnected`

Shared UI components SHOULD treat these as the initial canonical health states.

## 7. Runtime Index

Add a dedicated runtime index for presence and expected-vs-actual state.

Suggested responsibility:

- expected machines
- expected topologies
- running machine pids
- running topology pids
- known hardware endpoints
- stale/disconnected/missing markers

Suggested module:

```text
Ogol.HMI.RuntimeIndex
```

This may use ETS internally.

## 8. Projection Architecture

The HMI projection path should be:

```text
runtime notification
-> projector
-> snapshot store update
-> bus publish
-> LiveView render
```

Projection rule:

- the projector SHOULD be able to apply the same notification more than once
  without corrupting the resulting snapshot

Projection should therefore be idempotent wherever practical.

### 8.1 Modules

#### `Ogol.HMI.Projector`

Responsibility:

- consume notifications
- translate them into projection operations
- no storage policy inside the projector

v1 recommendation:

- use one central projector consumer process first
- scale into partitioned projector workers only if runtime volume requires it

#### `Ogol.HMI.SnapshotStore`

Responsibility:

- ETS-backed latest snapshots
- machine snapshots
- topology snapshots
- hardware snapshots

Retention rule for v1:

- snapshots keep latest state only
- historical timelines are not stored in snapshot tables

#### `Ogol.HMI.Bus`

Responsibility:

- Phoenix PubSub transport only
- publish typed snapshot update events

Do not let topic naming become the domain model.

#### `Ogol.HMI.EventLog`

Responsibility:

- append-only audit trail
- operator actions
- machine notifications
- crash and restart history

This is separate from the snapshot store.

Retention rule for v1:

- keep bounded append-only history in memory
- persistence MAY come later
- default retention SHOULD be count-based, for example the last `N` events per
  system or process group

#### `Ogol.HMI.CommandGateway`

Responsibility:

- validated UI write path
- sends `Ogol.request/5` and `Ogol.event/4`
- logs operator actions
- optional policy checks later

## 9. Web Module Layout

Suggested structure:

```text
lib/ogol_hmi/application.ex
lib/ogol_hmi/runtime_index.ex
lib/ogol_hmi/notification.ex
lib/ogol_hmi/projector.ex
lib/ogol_hmi/snapshot_store.ex
lib/ogol_hmi/event_log.ex
lib/ogol_hmi/bus.ex
lib/ogol_hmi/command_gateway.ex

lib/ogol_hmi_web/endpoint.ex
lib/ogol_hmi_web/router.ex
lib/ogol_hmi_web/telemetry.ex

lib/ogol_hmi_web/live/overview_live.ex
lib/ogol_hmi_web/live/machine_live.ex
lib/ogol_hmi_web/live/topology_live.ex
lib/ogol_hmi_web/live/ethercat_live.ex
lib/ogol_hmi_web/live/event_log_live.ex

lib/ogol_hmi_web/components/layouts.ex
lib/ogol_hmi_web/components/status_badge.ex
lib/ogol_hmi_web/components/machine_card.ex
lib/ogol_hmi_web/components/detail_table.ex
lib/ogol_hmi_web/components/timeline.ex

assets/css/app.css
assets/js/app.js
```

Whether these live under the same OTP app or a dedicated `ogol_hmi` app is a
packaging decision. For the first cut, a single app is acceptable.

## 10. Tailwind Styling Plan

Tailwind should be used deliberately, not as ad hoc utility sprawl.

### 10.1 UI Direction

The HMI should look like an engineering console:

- dense but readable
- calm color palette
- strong status colors
- fast visual scanning
- responsive without becoming mobile-first fluff

### 10.2 Tailwind Rules

1. Define semantic color tokens in CSS variables.
2. Wrap repeated patterns in LiveView components instead of duplicating long
   utility strings everywhere.
3. Use status-driven variants consistently:
   - healthy
   - running
   - waiting
   - stopped
   - faulted
   - stale
4. Prefer tables/cards/panels over flashy layouts.
5. Use transitions sparingly and only when they communicate state changes.

### 10.3 Initial Design Tokens

Suggested token groups:

- surface
- text
- border
- accent
- success
- warning
- danger
- info

Example usage:

- machine state badges
- alarm banners
- command buttons
- topology link status
- EtherCAT signal tables

### 10.4 First Shared Components

- `StatusBadge`
- `Panel`
- `SectionHeader`
- `MachineCard`
- `DetailTable`
- `EventRow`

Build these first so styling stays coherent.

## 11. First Pages

### 11.1 Overview

Shows:

- all known machines
- current state
- health
- last signal
- restart/crash indicator
- connectivity status

### 11.2 Machine Detail

Shows:

- machine identity
- current state
- facts
- selected fields
- outputs
- recent signals
- alarms/faults
- available operator actions

### 11.3 Topology

Shows:

- parent machine
- child machines
- child states
- child health
- restart/down history summary

### 11.4 EtherCAT

Shows:

- known slaves/endpoints
- observed signals
- driven outputs
- recent adapter feedback
- stale/disconnected indicators

### 11.5 Event Log

Shows:

- append-only timeline
- operator actions
- machine signals
- crashes
- safety violations
- command dispatch failures

## 12. Write Path

All LiveView writes should go through:

```text
LiveView -> CommandGateway -> Ogol.request / Ogol.event -> runtime notifications -> projector
```

Rules:

- no direct machine mutation from LiveView
- no direct ETS writes from UI
- no UI-only semantic shortcuts

Examples of operator actions:

- `start_cycle`
- `stop_cycle`
- `reset_fault`
- `ack_alarm`
- `enter_maintenance`

## 13. Crash and Restart Handling

The HMI should treat crash semantics honestly.

When a machine crashes:

- OTP restarts it according to topology policy
- runtime notifications record the crash and restart
- snapshot health becomes `:crashed` then `:recovering` then `:healthy` or
  `:faulted`
- event log records the sequence

The HMI must not pretend the crash did not happen.

## 14. Milestones

### Milestone A: Web Shell

Deliver:

- Phoenix + LiveView app
- Tailwind integrated
- root layout
- placeholder pages

### Milestone B: Runtime Contracts

Deliver:

- `Notification`
- `MachineSnapshot`
- `RuntimeIndex`
- `SnapshotStore`
- `Bus`

### Milestone C: Projection Pipeline

Deliver:

- projector consumes notifications
- ETS snapshots update
- PubSub broadcasts update LiveViews

### Milestone D: Overview + Machine Detail

Deliver:

- overview page
- machine detail page
- first operator actions through `CommandGateway`

### Milestone E: Topology + EtherCAT

Deliver:

- topology page
- EtherCAT page
- child health and hardware status projection

### Milestone F: Event Log + Policy

Deliver:

- append-only event log page
- operator action logging
- first policy/auth hooks

## 15. Implementation Order

The recommended build order is:

1. Phoenix + LiveView shell
2. runtime notification contract
3. snapshot store + bus
4. projector
5. overview page
6. machine detail page
7. command gateway
8. topology page
9. EtherCAT page
10. event log + auth/policy

This order keeps the UI downstream of the runtime semantics instead of letting
pages invent their own data model.

## 16. Initial Acceptance Criteria

The first HMI iteration is acceptable when:

1. A running machine appears on the overview page with correct state and health.
2. A machine detail page updates live on state changes and signals.
3. An operator can send a request through the HMI and see the resulting state
   change.
4. A machine crash is visible in the overview and event log.
5. A child state/signal change appears in the topology view.
6. EtherCAT feedback appears in the HMI through the adapter boundary, not by
   direct UI polling of machine internals.
7. Tailwind styling is coherent across overview, detail, and event log pages.

## 17. Recommended First Commit Scope

Do not build the full HMI in one jump.

The first HMI commit should contain only:

- Phoenix + LiveView scaffold
- Tailwind setup
- `Notification`
- `SnapshotStore`
- `Bus`
- one fake or real projector feed
- one overview page
- one status badge component

That is enough to validate the HMI architecture before adding command handling,
topology, or EtherCAT screens.
