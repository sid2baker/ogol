## Scenario

An operator selects the next procedure while the session is idle, then starts that procedure in Auto.
While the run owns orchestration, the operator requests Manual takeover.

## Expected Behavior

- the selected procedure is stored as session truth rather than UI-local state
- selection is rejected while a procedure actively owns orchestration
- a Manual takeover request drives the run toward release and returns the cell to Manual
- the operator procedure catalog preserves the selected procedure after takeover release
