# 02 Compile Updates Artifact Runtime Through Session Only

This scenario pins the contract for artifact-runtime status when source changes
inside the workspace.

## Scenario

Starting from the loaded packaging-line workspace:

1. edit one machine through the public `Session.save_machine_source/5` path
2. assert that artifact-runtime state is still empty for that machine
3. compile the machine through `Session`
4. assert that session-backed artifact-runtime status now reflects the edited source
5. edit the same source again without compiling
6. assert that session-backed artifact-runtime status stays on the old compiled digest
7. compile again and assert that session truth advances to the new digest

## API Note

better `Session` API suggested

A dedicated `Session.compile_artifact/2` helper would make this flow more
honest than calling `Session.dispatch({:compile_artifact, ...})` directly, but
the current public surface is still sufficient for this scenario.

## Expected Behavior

- saving source alone does not change artifact-runtime status
- compiling through `Session` updates session-owned artifact-runtime status
- `Session.runtime_current/2` and `Session.runtime_status/2` stay aligned
- a second source edit leaves the runtime artifact stale until the next compile

## Fault Note

No fault is currently expected here. This is the baseline scenario that keeps
artifact-runtime truth session-owned instead of tied to direct runtime queries
or source-save side effects.

## Repair Plan

- keep the scenario test as the reproducer
- if it fails later, patch the smallest honest layer:
  - session action handling for compile
  - artifact-runtime feedback replacement
  - public session artifact-runtime helpers
- rerun the targeted test first, then the session integration lane
