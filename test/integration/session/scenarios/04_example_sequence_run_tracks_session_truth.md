# 04 Example Sequence Run Tracks Session Truth

This scenario pins the contract for running the checked-in commissioning
sequence through `Session` once the example topology is live.

## Scenario

Starting from the checked-in `pump_skid_commissioning_bench` example:

1. switch the imported EtherCAT hardware from real `:raw` transport to
   simulator-friendly `:udp`
2. boot the EtherCAT simulator
3. compile the checked-in sequence through `Session`
4. reconcile topology runtime to `{:running, :live}`
5. start the sequence through `Session.start_sequence_run/1`
6. assert that session-owned sequence run truth advances to `:completed`
7. assert that the final run snapshot still points at the active deployment

## API Note

no API change needed

## Expected Behavior

- the checked-in example sequence can run against the checked-in example topology
- sequence lifecycle is visible through `Session.sequence_run_state/0`
- session truth reaches `:running` immediately for the active run and later `:completed`
- the completed run keeps the deployment id and clears `last_error`
- the active topology stays running after sequence completion

## Fault Note

No fault is currently expected here. This is the first session-level end-to-end
sequence execution scenario.

## Repair Plan

- keep the scenario test as the reproducer
- if it fails later, patch the smallest honest layer:
  - example hardware draft rewriting
  - sequence compilation through session
  - topology runtime bring-up
  - session-owned sequence runner feedback
- rerun the targeted test first, then the session integration lane
