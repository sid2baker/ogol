## Simulator Integration Loop

Scenario `08` keeps the checked-in commissioning example on the honest,
interruptible path: cancel the run while it is sitting on a verification delay
boundary and make sure session truth reports an `:aborted` terminal state,
releases active ownership, and keeps Auto armed.

Failure classification:
- runtime owner / sequence lifecycle bug

API note:
- no API change needed

Repair plan:
- keep the checked-in example as the reproducer
- cancel during one of its explicit `delay(...)` verification steps
- assert session truth settles on `:aborted` with owner handoff back to the
  manual operator while `control_mode` stays `:auto`
