# Session Refactor Plan

## Goal

Align Ogol's session/workspace/runtime boundary more closely with Livebook:

- `Ogol.Session.Workspace` is the document
- `Ogol.Session.Data` is the collaborative session truth
- `Ogol.Session` is the server process
- `Ogol.Runtime` is outside the session boundary

The system should start with an empty workspace. Examples should be loaded explicitly through Studio home using the same revision-loading path as any other checked-in revision.

## Target Shape

The public backend API should be small and intentional.

Primary `Session` API:

- `register_client/1`
- `get_data/0`
- `dispatch/1`
- `open_revision_source/2`
- `load_example/2`
- `save_current_revision/1`
- `export_current_revision/1`
- `deploy_current_revision/1`

The web layer should mostly:

1. mount from `Session.register_client/1` and `Session.get_data/0`
2. apply broadcast operations locally
3. send mutations back through `Session`

## Invariants

- Source is the only persisted authority.
- The workspace starts empty unless a revision is explicitly opened.
- Examples are just checked-in revision sources, not a separate loader model.
- Operation broadcast is session plumbing, not a domain action.
- Session actions should come from `Data`, not from ad hoc LiveView-side effect helpers.
- Revision save and deploy must persist the selected `topology_id` and `hardware_config_id` explicitly.

## Plan

### 1. Reduce the `Session` API

Make `Ogol.Session` the only backend entry the web layer is supposed to know.

- keep client registration and data access
- keep revision/example open-save-export-deploy entrypoints
- stop teaching the web layer the broad `list_/fetch_/replace_/reset_` bag as the primary interface
- move remaining convenience accessors behind session-owned workflows or make them internal

### 2. Unify Workspace IO

Make open, example load, export, save revision, and deploy revision all operate on the same current workspace snapshot.

- use one explicit revision-loading path for file import and examples
- make export read from the current `Workspace`
- make save and deploy use the same revision assembly logic
- delete special-case loading behavior that bypasses the normal workspace flow

### 3. Keep the Livebook Line Strict

`Data` should own collaborative session truth and derive real actions.

- `Workspace` handles document-level state and pure helpers
- `Data.apply_operation/2` mutates session truth and returns derived actions
- `Session` broadcasts accepted operations itself
- `Session` executes derived actions inline
- transport-level broadcasting must not be modeled as a domain action

### 4. Make Runtime Intent Explicit

Session-owned runtime intent should be represented explicitly instead of being scattered through convenience calls.

- add a runtime substate under `Ogol.Session.Data`
- track selected deploy target and known active deployment state there
- treat compile/deploy/stop/restart as consequences of session state and user intent
- feed runtime updates back into `Data` as operations where needed

### 5. Make Examples Boring

Examples should just be revision sources surfaced by Studio home.

- remove any remaining seeded/default example assumptions
- keep example metadata only for home-page presentation and navigation hints
- ensure loading an example is equivalent to opening a revision source
- avoid hidden workspace population outside the session/revision path

### 6. Tighten Revision Semantics

Open, save, export, and deploy should preserve explicit target choices.

- persist selected `topology_id` and `hardware_config_id` in revision metadata
- prefer metadata over artifact-order inference when reloading revisions
- make sequence-only and other non-deployable workspaces use save/export flows, not deploy
- make source-only hardware configs still count as real workspace truth

### 7. Migrate the Web Layer

LiveViews should render from local replicated `session_data`, not from broad backend querying.

- mount from session data
- keep local projections over `Data.workspace`
- send operations through `dispatch/1`
- use a very small number of explicit session-level IO commands for open/save/export/deploy

### 8. Delete Aggressively

At the end of each slice:

- remove superseded helpers
- remove compatibility branches
- remove old tests that still teach the superseded model
- update docs to teach only the empty-workspace, session-owned workflow

## Implementation Order

Recommended execution order:

1. reduce the `Session` API
2. unify revision/example/open/save/export/deploy assembly
3. migrate web callers to the smaller session boundary
4. add richer runtime session state in `Data`
5. delete the remaining compatibility paths

## Done When

- a fresh session starts empty
- Studio home loads examples through the same path as opening a revision file
- the web layer talks to the backend through `Session`
- revision save and deploy preserve explicit runtime target choices
- `Data` owns collaborative truth and derives session actions cleanly
- the old convenience-heavy session surface is gone
