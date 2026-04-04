## Simulator Integration Loop

Scenario `13` covers held-run invalidation when the active topology generation
changes underneath it.
If a sequence is held for workspace drift, then the exact source is restored,
the run may become resumable again. But if the active topology is rebuilt into
a new generation before the operator resumes it, that held run must become
non-resumable.

Failure classification:
- runtime generation / held-resume invalidation bug

API note:
- no API change needed

Repair plan:
- hold the commissioning example through workspace drift
- restore the exact source and confirm the held run is resumable again
- reapply the live topology to force a new realized generation
- assert runtime trust invalidates with `:topology_generation_changed`
- assert the held run keeps its original generation, loses resumability, and
  refuses resume
- acknowledge the held run as cleanup once resume is no longer allowed
