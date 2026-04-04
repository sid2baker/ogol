## Simulator Integration Loop

Scenario `16` covers explicit acknowledgment of a terminal faulted run.
When a sequence fails because its own procedure logic times out, Auto should
stay armed, ownership should already be back with the manual operator, and the
operator should be able to acknowledge the faulted result back to `:idle`
without changing the selected run policy.

Failure classification:
- terminal fault acknowledgment / clear-result policy bug

API note:
- no API change needed

Repair plan:
- inject a small sequence-logic timeout into the checked-in commissioning example
- assert the run reaches `:faulted` with sequence-logic classification
- acknowledge the faulted run
- assert the run clears back to `:idle` while Auto stays armed
