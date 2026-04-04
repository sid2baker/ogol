## Simulator Integration Loop

Scenario `10` covers runtime-loss trust invalidation instead of workspace drift.
If the active topology is stopped while Auto still owns a running sequence, the
run should move into `:held`, runtime trust should become `:invalidated`, and
ownership should remain with the sequence until the operator aborts or clears
it.

Failure classification:
- runtime loss / auto-controller lifecycle bug

API note:
- no API change needed

Repair plan:
- use the checked-in commissioning example on the simulator-backed topology
- stop the active topology while the sequence is running
- assert the run is held instead of silently cleared
- acknowledge the held run as explicit cleanup
