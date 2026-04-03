# 01 Source Edit Marks Runtime Unrealized Without Changing Observed Runtime

This scenario pins the contract for editing workspace source while a live
runtime is still active.

## Scenario

Starting from the loaded packaging-line workspace:

1. boot the EtherCAT simulator and realize the workspace as live runtime
2. assert that session truth says the runtime is running and realized
3. edit one machine through the public `Session.save_machine_source/5` path
4. assert that the observed runtime stays live, but the workspace is now dirty
   relative to the realized runtime

## API Note

no API change needed

## Expected Behavior

- `Session.runtime_state/0` keeps `observed == {:running, :live}` after the edit
- the active deployment id stays the same until reconciliation happens
- `Session.runtime_realized?/0` flips to `false`
- `Session.runtime_dirty?/0` flips to `true`
- the active topology keeps running until the caller explicitly reconciles

## Fault Note

No fault is currently expected here. This is the baseline contract that keeps
"editing while live" separate from runtime realization state.

## Repair Plan

- keep the scenario test as the reproducer
- if it fails later, patch the smallest honest layer:
  - workspace hashing
  - session reducer behavior around source saves
  - runtime-state derived truth
- rerun the targeted test first, then the session integration lane
