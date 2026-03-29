# Bundle Format

This document defines the intended file format for exporting and importing an
Ogol Studio revision.

The old framing treated a bundle as a large manifest for everything in Studio:
artifacts, workspace hints, deployment wiring, and sometimes even environment
choices. That made the format too broad and too redundant.

The redesigned rule is simpler:

> A bundle is a serialized revision snapshot.

It captures what the application is, not where it is currently running.

## 1. Core Model

Studio should be understood in four layers:

- `Draft`
  - the mutable working copy in Studio
- `Revision`
  - an immutable snapshot created by deploy
- `Target`
  - where a revision is activated
  - for example `simulator`, `lab`, or real hardware
- `Activation`
  - the act of running one revision on one target

A bundle only represents a `Revision`.

A bundle does not represent:

- the current draft session
- the currently active runtime
- live OTP process state
- simulator process state
- panel socket state
- event logs, alarms, snapshots, or drains

## 2. Scope

A bundle should capture application definition only.

That means bundle content may include:

- drivers
- EtherCAT configuration
- machines
- topology
- HMI screens
- minimal revision metadata relevant to identity, export, and compatibility

That means bundle content must not include:

- simulator runtime state
- simulator target selection
- live master state
- bus snapshots
- current machine field values
- panel assignment runtime state
- Studio UI workspace state

If simulator configuration becomes exportable, it should be treated as target
configuration, not bundled into the application revision by default.

## 3. Design Goals

The format should be:

- source-first
- immutable once exported
- parseable without executing code
- deterministic to render
- small in surface area
- honest about what belongs to a revision versus a target

## 4. File Shape

Use a single Elixir source file:

- extension: `.ogol.ex`

The file contains:

1. one manifest module
2. one or more artifact modules

Ordering must be deterministic:

1. manifest first
2. artifact modules sorted by `{kind, id}`

The single `.ogol.ex` file is a packaging format for deterministic export and
import.

It is not a claim that the revision is semantically "one source file".

A revision still consists of multiple source modules. The bundle just packages
them into one transport file.

## 5. Manifest Meaning

The manifest should identify the revision and index the module sources contained
in the file.

It should not become a second source of truth for artifact configuration.

The module sources that follow the manifest remain authoritative for artifact
behavior.

The manifest is only responsible for:

- revision identity
- bundle format compatibility
- artifact inventory
- minimal revision metadata

The manifest is not responsible for:

- restating machine internals
- restating topology internals
- restating driver internals
- workspace/editor state
- runtime activation state

## 6. Manifest Contract

The manifest must be literal and parse-only recoverable.

Allowed shapes:

- `@bundle %{...}` plus `def manifest, do: @bundle`
- `def manifest, do: %{...}`

`manifest/0` must return a literal map composed only of:

- literals
- lists
- tuples
- module aliases
- maps

It must not contain:

- function calls
- macros
- runtime lookups
- interpolation
- computed expressions

## 7. Required Manifest Fields

Required fields:

- `kind: :ogol_revision_bundle`
- `format`
- `app_id`
- `revision`
- `sources`

Optional fields:

- `title`
- `exported_at`
- `metadata`

Recommended shape:

```elixir
defmodule Ogol.Bundle.PackAndInspect.R12 do
  @bundle %{
    kind: :ogol_revision_bundle,
    format: 2,
    app_id: "pack_and_inspect",
    revision: "r12",
    title: "Pack and Inspect",
    exported_at: "2026-03-29T15:40:00Z",
    sources: [
      %{
        kind: :driver,
        id: "packaging_outputs",
        module: Ogol.Generated.Drivers.PackagingOutputs,
        digest: "sha256:..."
      },
      %{
        kind: :machine,
        id: "inspection_station",
        module: Ogol.Generated.Machines.InspectionStation,
        digest: "sha256:..."
      },
      %{
        kind: :topology,
        id: "pack_and_inspect_cell",
        module: Ogol.Generated.Topologies.PackAndInspectCell,
        digest: "sha256:..."
      }
    ]
  }

  def manifest, do: @bundle
end
```

## 8. Source Inventory

`sources` is the only required index inside the manifest.

`sources` is exhaustive for revision inventory inside the bundle.

That means:

- every artifact module in the file that belongs to the revision must appear in
  `sources`
- modules listed in `sources` must exist in the file
- top-level modules not listed in `sources` should be ignored for import and
  surfaced as warnings
- import logic must not guess revision membership from stray modules outside the
  declared source inventory

Each source entry must contain:

- `kind`
- `id`
- `module`
- `digest`

Optional fields:

- `title`
- `metadata`

The source inventory exists to:

- identify included modules
- classify them on import
- validate source integrity

It does not exist to duplicate artifact configuration already contained in the
module source itself.

## 9. Revision Identity

`revision` is the identity of the exported snapshot.

Rules:

- revisions are immutable
- revisions are not semantic versions
- revisions identify snapshots, not releases in the product-marketing sense

Examples:

- `r12`
- `r57`
- `2026-03-29.4`

The bundle format should not require semantic versioning.

If release metadata is needed later, it should live in optional metadata, not in
the core contract.

`exported_at`, if present, should be stored as an ISO8601 UTC string.

Example:

- `"2026-03-29T15:40:00Z"`

This keeps the manifest strictly parse-only and avoids needing special handling
for sigil forms in manifest recovery.

## 10. What Is Not In The Bundle

The bundle intentionally excludes target and activation state.

That means it must not encode:

- `simulator` versus `real hardware`
- active panel assignment
- live runtime topology selection
- active EtherCAT master state
- simulator process pid, port, or backend session
- active HMI deployment slot

Those belong to:

- target configuration
- activation metadata
- runtime state

not to the revision snapshot itself.

Compatibility metadata may describe whether a revision can be activated on a
class of target, but it must not encode current target selection or live target
state.

## 11. Simulator

Simulator needs special clarity.

Simulator is not the revision.

Simulator is one possible target for running a revision.

So:

- a bundle may include application-facing EtherCAT configuration
- a bundle should not include live simulator process state
- a bundle should not imply that the revision is only for simulator use

If Studio later needs import/export for target definitions, that should be a
separate format or a clearly separate target section with different semantics.

The default bundle format should stay revision-only.

## 12. Import Rules

Import must be parse-only.

Import should:

1. read file contents
2. parse source with `Code.string_to_quoted/2`
3. extract top-level modules
4. identify the single manifest module
5. read literal manifest data
6. extract raw source for every listed artifact module
7. classify each artifact by `kind`
8. restore those sources into Studio as a new mutable draft

Import must not:

- compile modules just to inspect them
- execute manifest code
- execute artifact code
- activate anything

## 13. Import Result

Importing a bundle should create a draft from that revision.

That means:

- bundle input is immutable revision source
- Studio output is a new mutable draft based on it

Open/import and activate/deploy are separate operations.

## 14. Digest Rules

`digest` should be computed from the exact raw module source stored in the file.

It must not be computed from regenerated canonical source.

This means formatting is part of the digested payload.

Whitespace, comments, and exact source layout are intentionally part of source
identity for bundle import/export.

If digest validation fails on import:

- keep loading
- preserve the extracted raw source
- mark the artifact as mismatched

The source in the file is still the authority.

## 15. Classification Rules

Each source entry is classified by `kind`.

`kind` should be treated as a closed application-defined set for the current
bundle format version.

Examples today:

- `:driver`
- `:ethercat`
- `:machine`
- `:topology`
- `:hmi`

Future bundle format versions may extend that set, but importers should not
treat unknown kinds as implicitly supported.

Classification outcomes:

- `{:ok, model}`
- `{:partial, model, diagnostics}`
- `:unsupported`

Studio should always preserve exact source even when classification is partial
or unsupported.

## 16. Export Rules

Export should:

1. collect the sources that make up the selected revision
2. compute source digests
3. render the minimal manifest
4. concatenate the manifest and module sources
5. format deterministically

Export should not inject:

- workspace hints
- active editor tab
- selected Studio page
- live target choice
- activation state

## 17. Deploy And Activate

The bundle format must stay aligned with the product model:

- `Deploy`
  - freeze the current draft into a new immutable revision
- `Activate`
  - run a chosen revision on a chosen target

So a bundle corresponds to deploy output, not activation state.

That also means the bundle format should not encode:

- hot upgrade instructions
- OTP release upgrade scripts
- live switchover state

Those are runtime concerns, not revision-format concerns.

## 18. Relationship To Hot Code Upgrade

OTP hot code upgrade is a platform/runtime concern.

The bundle format should not assume:

- all artifacts can hot-upgrade in place
- all revisions activate via `code_change/3`
- all targets support the same activation strategy

The bundle should only define the revision payload.

How that revision is activated on a target is intentionally separate.

## 19. Future Extensions

These can be added later without changing the core rule:

- revision notes
- author identity
- signing
- compatibility markers
- target export as a separate format
- diff metadata

They should remain optional and must not turn the manifest back into a second
artifact configuration language.

## 20. Summary

The bundle format should stay small:

- one manifest
- one immutable revision identity
- one source inventory
- source modules as the real artifact truth

The key rule is:

> bundle = revision snapshot

Everything about draft editing, targets, simulator/runtime environment, and
activation belongs elsewhere.
