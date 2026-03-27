# HMI Roadmap

This is the canonical HMI and Studio roadmap for the remaining Ogol UI work.

It replaces the earlier HMI planning split with one document that keeps only:

- the governing invariants that still matter
- the runtime HMI artifact model
- the unfinished work

## 1. Governing Rules

- DSL is the system of record.
- Visual editors are constrained projections over DSL.
- Runtime HMIs are explicit artifacts, not ad hoc application pages.
- Runtime must render compiled surface definitions, not improvise layout.
- Unsupported or non-preservable DSL must fail closed into DSL-first editing.
- `Save`, `Compile`, `Deploy`, and `Assign` are distinct lifecycle steps.

## 2. Current Baseline

The following is implemented:

- `Operations` and `Studio` are split into distinct shells.
- `/ops` renders an assigned runtime surface instead of a generic dashboard page.
- `/ops/hmis` exists as a supervisor/fallback launcher.
- `/studio/hmis` is a real HMI Studio workspace with:
  - canonical DSL editing
  - visual / DSL / split modes
  - diagnostics
  - save draft
  - compile
  - deploy
  - assign panel
- HMI surfaces are first-class artifacts with:
  - exact-match device profiles
  - screen variants
  - grid layout
  - zone placement
  - one primary node per zone
  - constrained widget groups
- Published surface versions can be assigned to panels explicitly.
- Current authored surfaces include:
  - `operations_overview`
  - `operations_alarm_focus`
  - `operations_station`

## 3. Stable Architecture

### 3.1 Studio

Studio remains DSL-first:

- load = parse -> classify -> determine visual availability -> lower where supported
- visual edits lower back to DSL
- DSL edits re-parse and refresh diagnostics
- only DSL is saved

Editor states remain:

- `Visual`
- `Partial`
- `DSL-only`
- `Invalid`

### 3.2 Runtime HMI

Runtime may only:

- resolve deployment
- resolve effective device profile
- select an exact compiled variant
- bind projected data
- render the compiled node tree
- manage narrow ephemeral player state

Runtime must not:

- compute layout
- invent responsive rearrangements
- mutate authored structure

### 3.3 Surface Model

The surface model remains:

- `SurfaceDefinition`
- `SurfaceVersion`
- `Panel`
- `AssignedSurface`
- `DefaultScreen`
- `DeviceProfile`

Templates remain constrained and industrial:

- no scrolling for core tasks
- no generic dashboard-builder escape hatches
- no arbitrary nested layout system in v1

## 4. Remaining Work

### 4.1 HMI Surface Runtime

- Add `alarm_console` as a first-class role/template.
- Add a `maintenance` surface role with tighter permission handling.
- Rename the current generic runtime renderer away from `OverviewSurface` to reflect that it now renders more than overview templates.
- Split template-specific rendering concerns more cleanly if the surface set grows further.

### 4.2 HMI Surface Deployment

- Make panel assignment management fully panel-aware in Studio instead of default-panel-first.
- Decide whether direct runtime routes should become panel-specific when multiple panels are active.
- Expose assigned version history and rollback more explicitly in Studio.
- Decide whether `Deploy` and `Assign` should gain a separate publish-history view.

### 4.3 HMI Studio Editing

- Extend visual editing beyond metadata and simple zone-node mutation.
- Add visual editing for:
  - groups
  - bindings
  - navigation
  - multiple screens per surface
  - role/template-specific constraints
- Make unsupported visual constructs fail into `Partial` instead of current mostly all-or-nothing managed editing.
- Add a better artifact library and creation flow for new HMI surfaces.

### 4.4 Shared Studio Shell

- Move hardware authoring onto the same shared Studio shell contract used by HMI Studio.
- Build topology Studio on the shared shell.
- Build machine Studio on the shared shell.
- Build driver Studio on the shared shell.

The intended order remains:

1. hardware
2. topology
3. machines
4. drivers

### 4.5 Permissions And Operations Boundaries

- Add explicit permission boundaries between:
  - operator runtime actions
  - engineering authoring
  - deploy
  - assign
- Tighten which skills are allowed on operator surfaces by role.
- Add explicit supervisor-only handling around launcher and assignment surfaces.

### 4.6 UX And Industrial Hardening

- Continue tightening contrast and readability for real panel usage.
- Add clearer deployment/status visibility in Studio.
- Validate touch-target sizing and density more aggressively.
- Expand fixed viewport/profile coverage beyond the current profiles if real hardware requires it.

## 5. Known Current Limitations

- Studio panel assignment is still effectively centered on the default runtime panel.
- Direct `/ops/hmis/:surface_id/:screen` routing is surface-centric, not truly panel-centric.
- HMI Studio currently edits one constrained node per zone, but not the full surface DSL visually.
- Non-HMI Studio artifacts do not yet share the same authoring shell.

## 6. Guiding Principle

When the visual editor cannot preserve semantics with confidence, Ogol must
prefer truthful DSL access over misleading visual affordances.
