# 05 Canonical Hardware Module Compiles And Reconciles Live

This scenario pins the new hardware contract after removing the old
config-first path.

## Scenario

Starting from the checked-in `pump_skid_commissioning_bench` example:

1. load the example through `Session.load_example/1`
2. rewrite the hardware draft to simulator-friendly `:udp` transport
3. assert that the hardware draft source is the canonical
   `Ogol.Generated.Hardware.EtherCAT` module and implements
   `@behaviour Ogol.Hardware` directly
4. compile the hardware artifact through `Session`
5. assert that session-owned hardware runtime status points at the canonical
   generated hardware module and the current source digest
6. boot the workspace simulator
7. reconcile desired runtime to `{:running, :live}`
8. assert that session runtime truth reaches running live with the example
   topology and `[:ethercat]` as the active adapters
9. assert that the hardware artifact runtime status still points at the same
   canonical hardware module after live reconcile

## API Note

better `Session` API suggested

A dedicated `Session.compile_artifact/2` helper would make this scenario more
direct than calling `Session.dispatch({:compile_artifact, ...})`, but the
current public surface is still sufficient.

## Expected Behavior

- workspace hardware source stays canonical as `Ogol.Generated.Hardware.EtherCAT`
- compiling `:hardware` through `Session` records
  `Session.runtime_status/2` and `Session.runtime_current/2` for that artifact
- live reconcile starts topology-owned EtherCAT hardware and reports it back through
  session-owned runtime truth
- `Session.runtime_state/0` exposes the active topology and active adapter list
  without reaching into runtime internals

## Fault Note

No fault is currently expected here. This is the baseline scenario that protects
the hardware refactor from drifting back toward config-first loading, old module
paths, or non-session-owned runtime assertions.

## Repair Plan

- keep the scenario test as the reproducer
- if it fails later, patch the smallest honest layer:
  - hardware source generation or parsing
  - hardware artifact compilation through session/runtime deployment
  - topology-owned hardware startup during live reconcile
  - runtime-owner feedback into session runtime truth
- rerun the targeted test first, then the session integration lane
