# 18 Live Reconcile Waits For Slow Hardware Start Without Session Timeout

This scenario pins the runtime-start timeout fix at the session boundary.

## Scenario

Starting from a minimal workspace with one wired machine, one topology, and one
custom hardware module whose session child intentionally waits longer than the
old 15 second `Session.dispatch/1` timeout:

1. replace the default packaging-line workspace entries with a single machine,
   topology, and hardware draft
2. start `Session.set_desired_runtime({:running, :live})` in an isolated task
3. hold hardware startup past the old 15 second session timeout budget
4. assert the runtime-start task is still alive instead of exiting with a
   `GenServer.call` timeout
5. release hardware startup
6. assert the session call returns `:ok`
7. assert `Session.runtime_state/0` reaches running live for the selected
   topology without a runtime failure

## API Note

better integration helper API suggested

The current public `Session` surface is sufficient to express the scenario
honestly, but the reproducer needs an inline slow-start hardware module and a
custom gate helper. A reusable test helper for delayed runtime-owner or delayed
hardware startup would make future reconciliation scenarios smaller.

This is useful follow-up work, but not required to land the scenario honestly
now.

## Fault Note

Expected behavior:

- `Session.set_desired_runtime({:running, :live})` should remain a valid
  synchronous session operation even when topology-owned hardware startup takes
  longer than the generic session call timeout
- the call should return `:ok` once runtime reconcile completes
- session truth should report running live afterward

Actual behavior before the fix:

- `Session.set_desired_runtime({:running, :live})` used the generic 15 second
  `Session.dispatch/1` timeout
- `RuntimeOwner.reconcile/2` used the same bounded call budget
- a slow real hardware start could outlast that budget and crash the caller
  with a `GenServer.call` timeout instead of preserving session truth

Visible runtime impact:

- runtime start from session or Studio could exit instead of returning a clean
  runtime failure or success result
- callers lost the intended start feedback because the session call itself died

Suspected broken layer and why:

- the problem was in the session/runtime-owner boundary, not the reducer
- runtime reconcile is legitimately long-running work and should not share the
  generic interactive session timeout

## Repair Plan

- keep the scenario test as the reproducer
- patch the smallest honest layer:
  - `Session.dispatch/1` timeout policy for runtime-start operations
  - `RuntimeOwner.reconcile/3` and topology-runtime preparation timeout policy
- rerun the targeted scenario, then the session integration lane
