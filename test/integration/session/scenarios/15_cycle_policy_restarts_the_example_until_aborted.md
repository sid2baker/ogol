## Simulator Integration Loop

Scenario `15` covers explicit Auto cycle policy.
When the selected run policy is `:cycle`, the commissioning example should
restart from a durable cycle boundary instead of completing after one pass.

Failure classification:
- sequence run-policy / cycle-boundary bug

API note:
- no API change needed

Repair plan:
- set the session-owned run policy to `:cycle`
- run the checked-in example sequence against the live simulator-backed topology
- assert the run stays active and increments `cycle_count`
- assert the run keeps `policy == :cycle`
- abort the run and assert ownership is released without leaving Auto
