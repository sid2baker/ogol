# 00 Workspace Load Populates Canonical Session State

This scenario pins the baseline contract for loading a revision into the
current session workspace.

## Scenario

Starting from an empty session workspace:

1. load the internal packaging-line revision fixture through the normal revision loader
2. assert that the workspace entries now reflect the revision inventory
3. assert that loaded-revision metadata is recorded in session truth
4. assert that runtime truth is still untouched and stopped

## API Note

no API change needed

## Expected Behavior

- `Session` exposes the loaded machines, topology, and hardware config
- kinds not present in the revision stay empty
- `Session.loaded_revision/0` reflects the imported revision identity and inventory
- `Session.runtime_state/0` remains the default stopped state
- session runtime stays realized and not dirty because nothing is running

## Fault Note

No fault is currently expected here. This is the baseline scenario that keeps
future workspace-load regressions tied to one explicit session contract.

## Repair Plan

- keep the scenario test as the baseline reproducer
- if it fails later, patch the smallest honest layer:
  - revision import
  - workspace replacement
  - loaded-revision metadata
  - runtime-state reset semantics
- rerun the targeted test first, then the session integration lane
