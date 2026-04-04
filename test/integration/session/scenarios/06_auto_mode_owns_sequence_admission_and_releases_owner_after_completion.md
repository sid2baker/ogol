# 06 auto mode owns sequence admission and releases owner after completion

## Scenario

This scenario pins the first Auto-mode control contract slice in session truth.

The contract is:

1. a sequence run may not start while control mode is `:manual`
2. arming Auto does not itself create a sequence owner
3. admitting a run moves ownership to `{:sequence_run, run_id}`
4. switching back to Manual is denied while a run owns orchestration
5. after successful completion, ownership returns to `:manual_operator`
6. Auto remains armed after terminal completion until Manual is requested

## Failure Classification

- session reducer/state bug
- auto-controller ownership bug
- session/runtime feedback bug

## API Note

- no API change needed

## Repair Plan

1. keep the failing session scenario as the reproducer
2. patch the smallest honest boundary:
   - session-owned control mode / owner truth
   - auto-controller feedback
3. rerun the scenario and the session/web/browser sequence slices
