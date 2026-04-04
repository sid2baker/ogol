## Simulator Integration Loop

Scenario `12` covers held resume after workspace trust is restored.
If an active sequence is held because the workspace drifted away from the
realized runtime, restoring the exact authored source should return runtime
trust to `:trusted` and allow the operator to resume the held run from its
last committed boundary.

Failure classification:
- auto-controller held resume / workspace trust revalidation bug

API note:
- no API change needed

Repair plan:
- run the checked-in commissioning example on the simulator-backed topology
- drift the checked-in sequence source mid-run and assert the sequence moves to
  `:held`
- restore the exact source and wait until runtime trust is `:trusted` again
- resume the held run and assert it completes under the same run id while Auto
  stays armed
