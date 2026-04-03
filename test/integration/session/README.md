# Session Integration Loop

Use this folder as a bounded self-improvement loop for session truth and
runtime reconciliation.

The rule is simple:

1. Write a short scenario spec first as `scenarios/NN_case_name.md`.
2. Add the smallest failing integration test as `scenarios/NN_case_name_test.exs`.
3. Classify the failure:
   - session reducer or state bug
   - runtime owner reconciliation bug
   - deployment or artifact-runtime sync bug
   - the test/helper API is making the scenario awkward to write or assert
4. Say explicitly whether a better API should exist:
   - no API change needed
   - better `Session` API would help
   - better `RuntimeOwner` or runtime-state API would help
   - better integration helper API would help
5. If the scenario exposed a real fault, describe it concretely:
   - expected session truth or reconciliation behavior
   - actual behavior
   - visible runtime impact
   - suspected broken layer and why
6. Write a short fix plan before editing code:
   - keep the failing test as the reproducer
   - patch the smallest honest layer
   - add or tighten cheaper unit coverage when it pins the same bug cleanly
   - rerun the targeted test and the relevant broader suite
7. Fix the smallest layer that unblocks the scenario:
   - wrong reducer output -> fix `Session.State`
   - wrong reconciliation behavior -> fix `Session.RuntimeOwner`
   - wrong artifact status propagation -> fix deployment/session feedback
   - awkward API -> improve helpers or public session/runtime surfaces if that is the real blocker
8. Re-run the targeted test, then the session integration lane.
9. Commit the fix with the scenario test path in the commit message body so history points back to the regression that found it.
10. Only then move to a harder scenario.

The point is to keep every improvement tied to a concrete scenario instead of
letting the loop invent arbitrary refactors.

## Scope

This folder is for integration tests where shared session truth is the main contract:

- `Ogol.Session.Workspace` as document state
- `Ogol.Session.State` as collaborative truth
- `Ogol.Session.RuntimeState` as desired and observed runtime truth
- `Ogol.Session.RuntimeOwner` as the reconciliation boundary

If a test is really about pure lowering, source parsing, or a local state
transition that does not need `Session` or Phoenix, it belongs in `test/unit`.

If it is a real browser flow, it belongs in `test/integration/playwright`.

If it needs `Phoenix.LiveViewTest`, routes, patching, controller requests, or
rendered HTML assertions, it does not belong in this loop. Those are separate
web-layer integration concerns and belong in `test/integration/web`.

## Naming

- Scenario doc: `scenarios/NN_case_name.md`
- Matching test: `scenarios/NN_case_name_test.exs`
- Shared harness code lives in `test/integration/support/`

This folder already contains broader session-backed integration tests. New
scenario-driven regressions should follow the numbered pair format above and
should exercise `Session` directly instead of going through LiveView.

## Required Outputs Per Scenario

Every worthwhile session scenario should leave behind these artifacts:

- a short scenario note and matching test
- an explicit API note:
  - `no API change needed`
  - `better Session API suggested`
  - `better RuntimeOwner or runtime-state API suggested`
  - `better test/helper API suggested`
- when a fault is found, a concrete fault description:
  - what broke
  - what should have happened
  - what actually happened
  - how the failure stayed visible in session truth or runtime reconciliation
- a short repair plan
- the fix itself, unless the repo is genuinely blocked
- a commit that mentions the triggering test path, for example
  `Found by: test/integration/session/scenarios/NN_case_name_test.exs`

Do not stop at "bug found". The expected loop is reproduce -> describe ->
plan -> fix -> verify -> commit.

## Initial Invariant Ladder

Start with scenarios like these before inventing broader ones:

- `00`: workspace load populates canonical session state
- `01`: source edit makes runtime unrealized without changing observed runtime
- `02`: compile updates artifact runtime through session only
- `03`: desired live reconciles through the runtime owner
- `04`: runtime stop or crash feeds observed state back into session
- `05`: runtime reconciliation failure feeds back into session truth
- `06`: reset clears desired and observed runtime state coherently
- `07`: artifact-runtime inventory stays session-owned after compile/delete cycles

These are examples of the contract ladder, not a frozen backlog. Add a new
number only when you have a concrete regression story to pin down.

## Session Assertions

Prefer assertions on public, shared behavior:

- `Session.get_state/0`
- `Session.runtime_state/0`
- workspace entries and artifact runtime status exposed through `Session`

Avoid assertions that depend on old side channels or hidden deployment internals
unless the scenario is explicitly about that boundary.

The standard question is:

- does session truth say the right thing?
- does runtime reconciliation follow from that truth?

## API Pressure Is Signal

When a scenario is awkward, say why.

The loop should explicitly call out when a better API would improve the work:

- Session API pressure:
  - callers need too much internal knowledge to express a valid operation
  - public session helpers are too weak to observe the relevant truth
- RuntimeOwner or runtime-state API pressure:
  - desired/observed transitions are hard to express or verify honestly
  - deployment identity, adapter state, or reconciliation failures are not exposed clearly
- Test API pressure:
  - setup is too repetitive
  - assertions require too much process or PubSub boilerplate
  - the scenario needs sleeps because helpers lack a real trigger or observation point

If a better API seems warranted, say so explicitly even if the current change
does not implement it. Also say whether that API change is:

- required to land the scenario honestly now
- useful follow-up work, but not required for the current fix

Prefer small, truthful API improvements over helper-local hacks or brittle
test code.

## Commit Expectations

If a scenario exposes a real bug or a required API improvement, commit the fix
after verification.

That commit should:

- mention the triggering scenario test path in the body, for example
  `Found by: test/integration/session/03_runtime_reconcile_test.exs`
- summarize the fault in plain language
- summarize the fix and any API adjustments
- mention validation that was run

The commit should make it easy to answer:

- which test found this fault?
- what was broken?
- what changed to fix it?

## Common Anti-Patterns

Avoid these when extending the session integration suite:

- asserting on runtime side channels when the same truth is already in `Session.State`
- treating "editing" as a runtime mode instead of comparing workspace state with realized runtime state
- mixing web-layer tests into a session-only scenario
- fixing an awkward test by reaching into private process state instead of improving helpers
- leaving a reproduced session-truth bug unfixed after writing the failing scenario

When one of those feels tempting, it usually means one of three things:

- the session model is missing a clearer truth boundary
- the runtime owner is not feeding observations back cleanly
- the integration helper surface needs a smaller honest abstraction

## Current Rule Of Thumb

- If the scenario is awkward because session truth is hard to express, improve the operation or helper surface.
- If the scenario is easy to trigger but hard to assert, improve session-backed observability before changing runtime behavior.
- If the scenario exposes runtime-owner API pressure, say so explicitly instead of normalizing awkward reconciliation patterns in the test.
- If the scenario exposes a mismatch between desired and observed runtime truth, fix the bug before stacking more scenarios on top, and commit with the triggering test path.
- Keep the state boundary honest:
  source is canonical, session is shared truth, and runtime owner realizes that truth.
