## Simulator Integration Loop

Scenario `09` exercises the first real trust-loss path: the active topology is
still running, but the workspace drifts underneath it while Auto owns the cell.
That should invalidate runtime trust and move the current run into `:held`
instead of letting it continue as if the realized world still matched the
workspace.

Failure classification:
- session reducer / auto-controller trust invalidation bug

API note:
- no API change needed

Repair plan:
- use the checked-in commissioning example so the sequence is live on a real
  runtime-backed workspace
- mutate one machine source while the run is sitting on a verification delay
- assert session truth reports invalidated runtime trust and a held sequence run
- acknowledge the held run as cleanup and assert Auto ownership is released
