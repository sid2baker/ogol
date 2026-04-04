## Scenario

Normal operator commands should be admitted only while Manual owns
orchestration.

This scenario uses the checked-in commissioning example and verifies:

1. when Auto is armed with no active run, manual machine commands are denied
2. when a sequence run owns orchestration, manual machine commands are denied
   with that run id
3. after the run completes, Auto remains armed and manual commands are still
   denied
4. returning to Manual restores operator command admission

## Failure Classification

- runtime owner reconciliation bug
- session/AutoController arbitration bug

## API Note

- no API change needed

## Repair Plan

1. boot the checked-in example against the UDP simulator path
2. arm Auto and assert operator commands are denied before any run is active
3. start the commissioning sequence and assert operator commands are denied
   while the run owns orchestration
4. wait for successful completion, assert Auto remains armed, and assert manual
   commands are still denied
5. return to Manual and assert the same machine command is admitted again
