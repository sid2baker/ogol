## Simulator Integration Loop

Scenario `14` covers fault classification for resumable held runs.
When workspace drift invalidates runtime trust underneath an active sequence,
the run should not only enter `:held`; it should also classify the fault as an
external runtime problem that requires operator acknowledgment and has
runtime-wide scope.

Failure classification:
- held-run fault-classification contract bug

API note:
- no API change needed

Repair plan:
- hold the commissioning example by drifting the active sequence source
- assert the held run keeps its resumable boundary
- assert the held run classifies the fault as
  `external_runtime / operator_ack_required / runtime_wide`
