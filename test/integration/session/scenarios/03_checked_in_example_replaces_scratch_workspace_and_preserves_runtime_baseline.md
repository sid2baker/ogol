# 03 Checked-In Example Replaces Scratch Workspace And Preserves Runtime Baseline

This scenario pins the contract for loading the canonical checked-in example
from `priv/examples` into a populated workspace that is not currently tied to a
loaded revision.

## Scenario

Starting from the default packaging-line workspace with `loaded_revision == nil`:

1. load the checked-in commissioning example through `Session.load_example/2`
2. assert that `Session` treats the current workspace as scratch and replaces it
3. assert that the workspace now contains the example artifacts from
   `priv/examples`
4. assert that loaded-revision metadata now points at the checked-in example
5. assert that default HMI surfaces are seeded for the example topology
6. assert that runtime truth is still stopped, realized, and clean

## API Note

no API change needed

## Expected Behavior

- `Session.load_example/2` uses the checked-in example under `priv/examples`
- when `loaded_revision` is `nil`, the current workspace is treated as scratch
  and the example replaces it directly
- example load replaces machines, topology, hardware config, simulator config,
  and sequence drafts with the example workspace
- example load seeds default HMI surfaces when the checked-in revision does not
  contain explicit surface artifacts
- runtime state and artifact-runtime state stay untouched by example loading

## Fault Note

No fault is currently expected here. This is the baseline scenario that keeps
checked-in example loading tied to explicit session truth instead of web-only
coverage.

## Repair Plan

- keep the scenario test as the reproducer
- if it fails later, patch the smallest honest layer:
  - example source lookup under `priv/examples`
  - revision-file scratch-workspace load behavior
  - workspace replacement
  - loaded-revision metadata
  - default HMI surface seeding
- rerun the targeted test first, then the session integration lane
