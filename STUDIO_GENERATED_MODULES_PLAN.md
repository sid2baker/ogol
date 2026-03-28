# Studio Generated Modules Plan

This document defines the implementation plan for Studio-authored artifacts that
generate plain `defmodule` source and are activated through a shared OTP host.

The immediate reference slice is `/studio/drivers`.

## 1. Decision

Adopt one shared generated-module pipeline across Studio artifact families:

- simulator definitions
- master definitions
- driver definitions
- later, other constrained generated artifacts where plain modules are the
  right runtime boundary

The core rule is:

- Studio edits a structured model
- the structured model generates plain Elixir source
- the source builds into a BEAM artifact without loading
- a single host owns apply/switch/retire behavior

## 2. Design Goals

- Keep DSL/source authoritative.
- Keep generated output plain Elixir.
- Keep runtime lifecycle outside generated modules.
- Make `build` non-loading and explicit.
- Make `apply` safe-by-default under BEAM code loading rules.
- Make blocked apply a normal, inspectable UI state.
- Prove the architecture first on `/studio/drivers`.

## 3. Non-Goals

This plan does not try to provide:

- arbitrary trusted-code execution UX
- guaranteed full round-trip for arbitrary handwritten Elixir
- live semantic hot-swap of every artifact family in v1
- per-generated-module lifecycle callbacks like `load/preview/dispose`

## 4. Shared Architecture

### 4.1 Core Namespace

Put the shared kernel outside `Ogol.HMI` so it is reusable by simulator,
master, driver, and later Studio artifacts.

Recommended namespace:

- `Ogol.Studio.Definition`
- `Ogol.Studio.Build`
- `Ogol.Studio.Build.Artifact`
- `Ogol.Studio.Modules`
- `Ogol.Studio.ModuleStatusStore`

Keep the LiveView shell under `Ogol.HMIWeb`, but move the generated-module
runtime/build logic into `Ogol.Studio`.

### 4.2 Definition Behaviour

Create:

```elixir
defmodule Ogol.Studio.Definition do
  @callback schema() :: map()
  @callback cast_model(map()) :: {:ok, map()} | {:error, term()}
  @callback to_source(module(), map()) :: String.t()
  @callback from_source(String.t()) ::
              {:ok, map()} | {:partial, map(), [term()]} | :unsupported
end
```

Responsibilities:

- `schema/0`
  machine-readable editor contract
- `cast_model/1`
  validates and normalizes UI input
- `to_source/2`
  generates canonical `defmodule` source
- `from_source/1`
  best-effort recovery from recognized source subset

### 4.3 Build API

Create:

```elixir
defmodule Ogol.Studio.Build do
  @spec build(term(), module(), String.t()) ::
          {:ok, Ogol.Studio.Build.Artifact.t()}
          | {:error, %{diagnostics: [term()]}}
end
```

Also create:

```elixir
defmodule Ogol.Studio.Build.Artifact do
  @enforce_keys [:id, :module, :beam, :source_digest]
  defstruct [:id, :module, :beam, :source_digest, :beam_path, diagnostics: []]
end
```

Important:

- `build/3` must not load code
- `build/3` should produce a typed BEAM artifact and diagnostics only

Implementation direction:

- write source to a temporary build path
- compile to path, not to loaded memory
- read back the produced `.beam`
- return the binary artifact and diagnostics
- delete temp files after extraction unless retention helps debugging

Do not use `Code.compile_*` helpers that implicitly load modules for the real
build step.

The artifact record exists so `apply/2` does not need to trust a bare binary.
It should always know:

- which logical id the artifact belongs to
- which module the BEAM targets
- which source digest produced it
- which diagnostics were emitted at build time

### 4.4 Runtime Host API

Create:

```elixir
defmodule Ogol.Studio.Modules do
  @spec apply(term(), Ogol.Studio.Build.Artifact.t()) ::
          {:ok, %{id: term(), module: module(), status: :applied}}
          | {:blocked, %{reason: :old_code_in_use, module: module(), pids: [pid()]}}
          | {:error, term()}

  @spec current(term()) :: {:ok, module()} | {:error, :not_found}

  @spec status(term()) ::
          {:ok,
           %{
             module: module() | nil,
             apply_state: :draft | :built | :applied | :blocked,
             source_digest: binary() | nil,
             old_code: boolean(),
             blocked_reason: term() | nil,
             lingering_pids: [pid()],
             last_build_at: DateTime.t() | nil,
             last_apply_at: DateTime.t() | nil
           }}
          | {:error, :not_found}
end
```

Responsibilities:

- serialize apply per logical id
- load/switch only when safe
- detect old-code drain state
- expose the current module and blocked apply status to Studio
- act as the single source of truth for UI-facing build/apply state

### 4.5 Latest-Only Apply Policy

Use same module name per logical artifact id by default.

Example:

- logical id: `:el2809_packaging_outputs`
- module: `Ogol.Generated.Drivers.El2809PackagingOutputs`

Apply policy:

1. host receives `{id, module, artifact}`
2. host checks whether the module has old code
3. if no old code exists, load the new artifact
4. if old code exists, try soft purge
5. if soft purge succeeds, load the new artifact
6. if soft purge fails, collect lingering PIDs and return `{:blocked, ...}`

The host must never blindly trigger a dangerous third load of the same module.

Make the runtime transport explicit:

- `build/3` produces the `.beam` artifact without loading
- `apply/2` loads the artifact only after the safety gate passes

Recommended `apply/2` algorithm:

1. serialize apply per logical id
2. compare artifact module with the logical id registry entry
3. check whether the target module currently has old code
4. if old code exists, try `:code.soft_purge(module)`
5. if `soft_purge/1` returns `false`, scan local processes with
   `:erlang.check_process_code/2` or `/3`, collect lingering PIDs, and return
   `{:blocked, ...}`
6. only then load the artifact via `:code.load_binary/3` or prepared-loading
   equivalent

Blocked apply is a normal outcome, not an exceptional one.

### 4.6 Registry / Status Storage

Create a small host-owned registry/status store, likely ETS-backed plus a
`GenServer`, containing:

- logical id
- module
- apply state
- source digest
- apply status
- blocked reason
- lingering PIDs
- last built timestamp
- last applied timestamp

This should be independent of the draft/source store.

## 5. Studio Sync Model

Studio must keep source authoritative while still allowing visual editing for
recognized subsets.

### 5.1 Sync States

Every generated-module Studio surface should expose exactly these sync states:

- `:synced`
- `:partial`
- `:unsupported`

Meaning:

- `:synced`
  source fully translates back into the visual model
- `:partial`
  source partially translates and Studio has diagnostics
- `:unsupported`
  source can no longer be represented visually

### 5.2 Source-First Behavior

Rules:

- source stays editable and authoritative at all times
- Studio must not block source editing when visual recovery fails
- Studio must not present stale visuals as if they reflect current source

Recommended browser behavior:

- while source editor has focus, keep source responsive and do only lightweight
  background parsing/classification
- on source-editor blur, or after a short idle debounce, run `from_source/1`
- if `{:ok, model}`, update visuals and clear warnings
- if `{:partial, model, diagnostics}`, update the recovered subset and show a
  warning
- if `:unsupported`, keep source primary and disable or freeze visual editing
  with an immediate explanation

Start with the safest unsupported-state UX:

- keep the `Source` mode fully usable
- mark `Visual` as unavailable or read-only
- show a visible sync badge and warning

Do not keep showing stale visuals as if they are current.

## 6. Shared Studio Flow

The intended Studio flow for generated modules is:

1. Visual or source edits update model/source
2. `cast_model/1`
3. `to_source/2`
4. `build/3`
5. display diagnostics and generated source
6. user clicks `Apply`
7. `apply/2`
8. UI reads `current/1` and `status/1`

This yields four real states:

- draft changed, not built
- built, not applied
- applied
- blocked waiting on old-code drain

## 7. Reference Slice: `/studio/drivers`

### 7.1 Why Start Here

`/studio/drivers` is currently a placeholder and is a good first reference
slice because:

- it does not yet have competing implementation baggage
- it exercises source generation, build, apply, and status
- it proves the shared kernel before simulator/master are moved onto it

### 7.2 V1 Scope For Drivers

Do not start with arbitrary driver logic authoring.

Start with a constrained driver family that generates thin declarative modules
over shared runtime helpers.

Recommended V1:

- one EtherCAT digital I/O driver family
- generated module shape is metadata-heavy and logic-thin
- generated module delegates behavior to shared runtime/helper modules

Example model fields:

- `id`
- `module_name`
- `label`
- `device_kind` (`:digital_input` or `:digital_output`)
- `channel_count`
- per-channel names
- optional inversion/defaults

This is enough to prove:

- model -> source
- source -> BEAM artifact
- apply -> current module resolution
- source subset round-trip

without making the first slice depend on arbitrary generated callback code.

### 7.3 Driver Runtime Boundary

Generated driver modules should be plain modules, but thin ones.

Prefer:

- generated metadata
- generated declarative config
- delegation to shared runtime helpers

Avoid in v1:

- full arbitrary callback body generation
- long-lived logic hidden inside generated code

This keeps the first slice auditable and easier to apply safely.

### 7.4 Driver Studio UX

Replace the placeholder route with:

- `Ogol.HMIWeb.DriverStudioLive`

Recommended first UI:

- artifact picker / id field
- Visual / Source toggle, always visible in-browser, without navigation away
  from the artifact
- generated source viewer
- sync status badge:
  - `synced`
  - `partial`
  - `unsupported`
- diagnostics panel
- `Save Draft`
- `Build`
- `Apply`
- `Current Module`
- `Apply Status`
- blocked/draining warning with lingering PID list

The first slice does not need a full inspector-heavy shell. It needs a clear
end-to-end generated-module flow.

### 7.5 Driver Studio Stores

Create:

- `Ogol.Studio.DriverDraftStore`
- `Ogol.Studio.DriverDefinition`

The draft store should keep:

- draft source
- normalized model if available
- last successful build artifact
- build diagnostics
- current applied status snapshot

This store is not the authoritative source of runtime apply state. It caches
authoring-side snapshots only. `Ogol.Studio.Modules.status/1` remains the
runtime-authoritative status API.

Follow the `SurfaceDraftStore` pattern, but keep the build/apply kernel shared
under `Ogol.Studio`.

## 8. Concrete Module Plan

### Phase 1: Shared Kernel

Implement:

- `lib/ogol/studio/definition.ex`
- `lib/ogol/studio/build.ex`
- `lib/ogol/studio/modules.ex`
- `lib/ogol/studio/module_status_store.ex`

Add the host to `Ogol.Application`.

Acceptance:

- build returns BEAM binary without loading
- build returns typed artifacts, not bare binaries
- apply loads only when safe
- blocked apply returns lingering PID diagnostics
- current/status queries work

### Phase 2: Driver Definition Family

Implement:

- `lib/ogol/studio/driver_definition.ex`
- `lib/ogol/studio/driver_printer.ex`
- `lib/ogol/studio/driver_parser.ex`
- `lib/ogol/studio/driver_draft_store.ex`

Acceptance:

- driver model validates
- source is generated canonically
- recognized generated source round-trips
- edited unsupported source falls back honestly

### Phase 3: Driver Studio Route

Replace:

- `/studio/drivers` -> `StudioPlaceholderLive`

with:

- `/studio/drivers` -> `DriverStudioLive`

Acceptance:

- Studio can edit a driver visually
- Studio can show source
- Studio can show `synced / partial / unsupported`
- Studio can build
- Studio can apply
- Studio can show blocked apply status

### Phase 4: Runtime Resolution Integration

Add a small reference consumer path that resolves a driver by logical id through
`Ogol.Studio.Modules.current/1`.

This should be a future-use or test-runtime integration first, not immediate
live hot replacement of real hardware sessions.

Acceptance:

- new work resolves current module via host
- applied module becomes visible through resolution API
- no forced live hot-swap is required for v1

### Phase 5: Expand To Simulator / Master

After `/studio/drivers` is stable, implement:

- `SimulatorDefinition`
- `MasterDefinition`

using the same build/apply host and the same Studio contract.

At that point, the hardware page should become a launcher/bridge rather than
the long-term home of simulator/master authoring.

## 9. BEAM Safety Rules

These rules should be implementation invariants:

- build must not load code
- apply must be serialized per logical id/module
- apply may return `{:blocked, ...}` as a normal outcome
- Studio must show blocked apply state explicitly
- the host must prefer soft purge over force purge
- force purge must not be part of the normal Studio path
- generated modules must not use `@on_load`

## 10. Test Plan

### 10.1 Shared Kernel

- build does not load module into current code
- apply loads module when no old code exists
- apply rejects an artifact whose module does not match the logical id registry entry
- apply blocks when old code is still in use
- status reports old-code drain correctly
- status is the only UI source of truth for build/apply state
- status exposes the applied `source_digest`

### 10.2 Driver Definition

- `cast_model/1` validates good/bad input
- `to_source/2` generates canonical source
- `from_source/1` returns:
  - `{:ok, model}`
  - `{:partial, model, diagnostics}`
  - `:unsupported`

### 10.3 Driver Studio LiveView

- visual edit updates source
- source edit reclassifies correctly
- source blur updates visuals only when classification succeeds
- build shows diagnostics without applying
- apply updates current module when safe
- blocked apply shows PID diagnostics
- stale visuals are never presented as current

### 10.4 Integration

- a reference consumer resolves `current/1`
- applying a new driver changes future resolution
- blocked apply leaves current module unchanged

## 11. Acceptance Criteria

This plan is done for the reference slice when:

- `/studio/drivers` is a real Studio artifact, not a placeholder
- generated driver source is canonical and inspectable
- build is explicitly non-loading
- build returns a typed artifact record
- apply is safe under latest-only module semantics
- blocked apply is visible and understandable in the UI
- runtime resolution uses `current/1`
- the same shared kernel is ready to be reused for simulator/master definitions

## 12. Guiding Rule

Generated modules should stay plain, thin, and replaceable.

Studio owns model and source.
The build step owns artifact generation.
The host owns switching.
Runtime state stays in OTP processes, not in generated-module lifecycle logic.
