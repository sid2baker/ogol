# 19 Hardware Output Failure Faults Sequence Without Machine Restart

This scenario pins the `{:hardware_output_failed, :slave_down}` path at the
session boundary without depending on a live EtherCAT timeout.

## Scenario

Starting from a minimal workspace with one custom hardware module whose
`write_output/5` returns `{:error, :slave_down}` when the return valve is
opened:

1. replace the default packaging-line workspace with one machine, one topology,
   one sequence, and one custom hardware draft
2. compile the sequence artifact through `Session`
3. start the selected topology in running live mode
4. start the sequence run in Auto
5. drive `do_skill(:return_valve, :open)` through the session-owned command
   gateway
6. assert the run faults with the original `hardware_output_failed` /
   `slave_down` reason still visible and classified as `external_runtime`
7. assert the runtime stays up and the machine snapshot for `:return_valve`
   stays connected in `:closed` without a crash/restart cycle

## API Note

no API change needed

The public session/runtime APIs are enough to express this path honestly. A
real EtherCAT bus timeout is not required because the generated machine crash
originates at the hardware write boundary and can be reproduced with a custom
test hardware module.

## Fault Note

Expected behavior:

- a machine output write failure during a session-owned sequence run should stay
  visible all the way back at the sequence result
- the overall runtime should stay alive
- the machine process should stay alive and preserve its pre-request state when
  the external write fails

Behavior pinned by this scenario:

- the `:open` request returns `{:error, {:hardware_output_failed, :slave_down}}`
- the sequence run faults with the original hardware reason still visible
- fault classification is `external_runtime / abort_required / runtime_wide`
- no `machine_down` event is emitted and the machine snapshot does not restart

Visible runtime impact:

- the active sequence faults immediately instead of continuing, which is
  expected for this policy
- operators still see the underlying runtime problem without losing the machine
  process

## Repair Plan

- keep this scenario as the reproducer
- return retryable hardware boundary failures as request errors instead of
  machine exits
- classify those failures as `external_runtime`
- rerun the targeted scenario and the lower-level machine/sequence regressions
