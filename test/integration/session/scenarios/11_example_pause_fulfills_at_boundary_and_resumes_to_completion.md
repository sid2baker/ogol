## Simulator Integration Loop

Scenario `11` covers the orderly pause path for Auto mode.
If the operator requests pause while the checked-in commissioning example is
running, the request should stay pending until the current step reaches a
committed boundary, then the run should enter `:paused` and remain owned by the
sequence until the operator resumes it.

Failure classification:
- sequence runner / auto-controller pause lifecycle bug

API note:
- no API change needed

Repair plan:
- use the checked-in commissioning example on the simulator-backed topology
- request pause while the sequence is inside a visible delay step
- assert pending pause intent is admitted before it is fulfilled
- assert the run reaches `:paused` with resumability metadata intact
- resume the run and assert it completes while Auto stays armed
