# Runtime-First Refactor Plan

## Summary

Refactor the system around two explicit authorities:

- `WorkspaceStore` is the only Studio domain state for user-authored source.
- `Deployment` is the only runtime owner of the active system.

Everything else is derived:

- workspace manifest is a projection of workspace source
- active deployment manifest is a projection of the current deployment
- BEAM code-loading state is an implementation detail, not app-level truth

This is the first phase of a larger refactor. It intentionally does not redesign Studio cells yet, but it must leave the system in a shape that makes that later work simpler.

## Canonical Model

- `WorkspaceStore`
  - source-only domain state
  - current Studio cell source text
  - no build/runtime/deployment mirrors
- `Workspace manifest`
  - derived from workspace source only
  - not stored independently
- `Deployment`
  - single owner of the active runtime
  - owns deploy, stop, restart, and coordinated hot upgrade of owned processes where supported
- `Active deployment manifest`
  - derived from deployment state
  - records what the active deployment introduced logically

UI/editor-local ephemeral state may still exist in LiveViews and components, but it must not become another source/build/runtime authority.

## Deployment Identity

Every deploy creates a new deployment generation with at least:

- `deployment_id`
- `started_at`
- workspace manifest snapshot
- logically introduced modules
- owned processes and runtime instances

This identity is required for logs, restarts, future upgrades, and reasoning about the active system over time.

## Manifest Design

The workspace-derived manifest and deployment-derived manifest should include at least:

- artifact kind
- module name
- source hash
- provenance
  - source origin or cell id
  - artifact name if different from module name

This is enough for UI diffing now and preserves identity for rename or move scenarios later.

## Deployment Pipeline

The runtime flow must be explicit and centralized:

1. read workspace source
2. derive workspace manifest
3. compile or evaluate deployable artifacts
4. build a deployment plan
5. activate the new deployment
6. record active deployment state
7. stop or replace the prior deployment as required

No scattered compile/start bookkeeping outside this boundary.

## Ownership Rules

Ownership must be explicit:

- a pid is owned only if it is started by the deployment supervisor tree or registered through a deployment-owned API
- any background or orphan process outside that path is a bug
- deployment "owns modules" only in the logical sense
  - it records which modules it introduced for this activation
  - it does not treat the global BEAM code server as deployment-owned state

Stopping a deployment must stop its owned pids. It does not need to model module unloading as a first-class undeploy concept.

## Upgrade Coordination

Hot code upgrade is not a separate subsystem. It is one deployment strategy.

The deployment layer must support upgrade planning and execution as part of the same runtime boundary.

For each deployable change, deployment decides one of:

- no-op
- code reload only
- hot code upgrade of owned processes
- restart owned processes
- replace the full deployment generation

The choice is based on:

- manifest diff
- artifact kind
- module upgrade capability
- runtime ownership
- safety policy

The low-level owned-process upgrade mechanism should preserve these rules:

- only upgrade processes the deployment owns and tracks
- require explicit `@vsn` and `code_change/3` contracts for upgradeable processes
- keep process state as plain data
- treat lingering old-code pids as a real post-upgrade signal
- remember that module names are global on one node, so there is one active code identity per module name

## Scope For This Batch

This batch should do:

- make `WorkspaceStore` source-only
- introduce deployment generation identity
- derive workspace and deployment manifests
- add pre-deploy diffing from source text
- make `Deployment` the only path for deploy/start/stop/restart
- make `Deployment` the only place where upgrade decisions happen
- implement owned pid registration
- leave behind the hooks needed for later selective hot upgrade

This batch should not do:

- final Studio cell redesign
- source persistence redesign beyond what this runtime boundary requires
- full per-artifact hot-upgrade policy coverage

The first implementation can keep upgrade policy narrow:

- machine-instance hot upgrade where supported
- fallback to restart or full redeploy for everything else

## Public Interfaces

Introduce or standardize:

- `Ogol.Studio.WorkspaceStore`
  - source-only Studio domain state
- `Ogol.Studio.Workspace.Manifest`
  - pure projection from workspace source
- `Ogol.Runtime.Deployment`
  - the single runtime owner
- `Ogol.Runtime.Deployment.Manifest`
  - projection of the active deployment
- `deployment_id` or equivalent generation identifier

Expected runtime API shape:

- inspect workspace-derived manifest
- inspect active deployment manifest
- diff workspace manifest vs active deployment manifest
- deploy current workspace
- stop active deployment
- restart active deployment
- coordinate hot upgrade of owned runtime instances where supported

Do not introduce a separate persistent candidate or build store.

## Test Plan

Add or update tests for these scenarios:

- workspace source produces the correct manifest without compiling
- manifest entries include provenance and stable module identity
- loading a new workspace shows correct `new/changed/unchanged/removed` diff against the active deployment
- deploy compiles or evaluates workspace modules and creates a new `deployment_id`
- active deployment records the workspace manifest snapshot used for activation
- stopping deployment stops owned runtime processes without mutating workspace source
- redeploy from changed workspace produces a new deployment generation and correct new active manifest
- pid ownership is centralized
  - started via deployment tree => owned
  - started outside deployment path => not owned and treated as a bug in tests
- machine-instance hot upgrade only applies to owned instances
- post-upgrade lingering pid detection is surfaced as a real signal
- no legacy store-specific start path remains
- no duplicate runtime/build mirrors remain in Studio stores

Regression checks should explicitly verify:

- workspace remains source-only
- deployment is the only runtime owner
- manifests are projections, not competing state
- BEAM code loading is not mirrored into another long-lived store

## Assumptions

- Workspace and candidate are the same concept; no separate candidate state will be introduced.
- "Loaded before deploy" means only "present in workspace source", not BEAM code loading.
- BEAM compilation/loading remains an implementation detail of deployment.
- Deployment owns processes and logical activation metadata, not the BEAM code server itself.
- Hot upgrade is part of deployment, not a separate store or Studio concern.
- Old paths should be deleted in the same refactor as soon as the new deployment path is canonical.
