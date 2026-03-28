# Studio Bundle Format

This document defines the default single-file bundle format for saving and
loading a complete Ogol Studio application configuration.

The format is intentionally Elixir source-first.

## 1. Goals

Use one file to persist:

- generated artifact source
- cross-artifact composition and deployment wiring
- optional Studio workspace hints

Do not use the bundle file to persist:

- live runtime process state
- alarms, events, or snapshots
- old-code drain status
- transient OTP state

## 2. Core Rule

Per-artifact configuration belongs in generated artifact modules.

Cross-artifact composition belongs in the bundle manifest.

The manifest must not become a second copy of artifact configuration.

## 3. File Format

Use a single Elixir source file with extension:

- `.ogol.ex`

The file contains:

1. one bundle manifest module
2. zero or more generated artifact modules

Example:

```elixir
defmodule Ogol.Bundle.PackagingLine do
  @bundle %{
    kind: :studio_bundle,
    format: 1,
    app_id: "packaging_line",
    title: "Packaging Line",
    versioning: %{
      bundle_revision: "r42",
      release: %{
        version: "1.3.0",
        classification: :minor,
        based_on: "1.2.4"
      }
    },
    artifacts: [
      %{
        kind: :driver,
        id: "packaging_outputs",
        module: Ogol.Generated.Drivers.PackagingOutputs,
        source_digest: "sha256:..."
      },
      %{
        kind: :machine,
        id: "packaging_line",
        module: Ogol.Generated.Machines.PackagingLine,
        source_digest: "sha256:..."
      }
    ],
    wiring: %{
      topology: %{root_machine: "packaging_line"},
      deployments: %{},
      panel_assignments: %{}
    },
    workspace: %{
      open_artifact: {:driver, "packaging_outputs"},
      editor_mode: :visual
    }
  }

  def manifest, do: @bundle
end

defmodule Ogol.Generated.Drivers.PackagingOutputs do
  # generated source
end

defmodule Ogol.Generated.Machines.PackagingLine do
  # generated source
end
```

## 4. Manifest Contract

The manifest must identify itself explicitly.

The manifest must also be strictly literal.

Use one of these shapes only:

- `@bundle %{...}` plus `def manifest, do: @bundle`
- `def manifest, do: %{...}`

`manifest/0` must return a literal map composed only of:

- Elixir literals
- lists
- tuples
- module aliases

It must not contain:

- function calls
- macros
- computed expressions
- runtime lookups
- dynamic concatenation or interpolation

This keeps Studio import parse-only. It must be possible to recover manifest
data from AST without compiling or executing bundle source.

Required fields:

- `kind: :studio_bundle`
- `format: 1`
- `app_id`
- `artifacts`
- `wiring`

Optional fields:

- `title`
- `versioning`
- `workspace`
- `metadata`

### 4.1 Artifact Inventory

Each artifact entry must include:

- `kind`
- `id`
- `module`
- `source_digest`

Optional fields:

- `title`
- `status_hint`
- `metadata`

The inventory describes bundle membership. It does not duplicate full artifact
config.

### 4.2 Wiring

`wiring` holds cross-artifact composition only.

Examples:

- topology root relationships
- deployment mappings
- panel assignments
- machine-to-topology references
- default runtime entrypoints

`wiring` must not restate the full internals of each artifact.

### 4.3 Workspace

`workspace` is optional convenience data only.

Examples:

- last open artifact
- selected editor mode
- tab or panel hints

If `workspace` is missing or invalid, the bundle still loads successfully.

### 4.4 Versioning

Bundle versioning should distinguish:

- bundle file format compatibility
- authoring revision identity
- release version identity

These are not the same thing.

Use:

- `format`
  - the bundle file format version
- `versioning.bundle_revision`
  - a non-semver revision identifier for the saved bundle
- `versioning.release`
  - optional release metadata for candidate or deployed bundles

Recommended shape:

```elixir
versioning: %{
  bundle_revision: "r42",
  release: %{
    version: "1.3.0",
    classification: :minor,
    based_on: "1.2.4"
  }
}
```

Rules:

- `format` is for import/export compatibility only
- `bundle_revision` identifies the saved work revision
- `release.version` is semantic versioning for release intent
- `release.classification` should be one of:
  - `:patch`
  - `:minor`
  - `:major`
- `release.based_on` records the release the bundle was compared against

Draft bundles do not need semantic version metadata.

Candidate or deployable bundles should carry release metadata.

### 4.5 Release Versioning Policy

Use semantic versions for released and deployed bundles, not for every draft.

The intended model is:

- drafts -> revision ids
- candidates -> build or revision ids
- deployed releases -> semantic versions

Compact rule:

> revisions identify work, semantic versions identify releases, and deploy
> always creates a new release.

### 4.6 SemVer Scope

Primary semantic versioning should apply to the deployment bundle or armed
release, not necessarily to every internal artifact revision.

The release boundary is what matters:

- what is deployed
- what is compared against the currently armed live system
- what operators and engineers can roll back to

### 4.7 Deploy Behavior

On deploy:

- always create a new immutable release version
- compare `Candidate` vs `Armed Live`
- run compatibility analyzers
- classify the bump as:
  - `patch`
  - `minor`
  - `major`
- mint the next release version automatically

Deploy must not silently reuse the old release identity.

### 4.8 Compatibility Classification

The version bump must come from explicit compatibility rules.

It must not be guessed from a vague "something changed" heuristic.

Use `patch` for:

- fixes
- internal improvements
- changes that preserve meaning, public interfaces, workflow, and operational
  expectations

Use `minor` for:

- backward-compatible capability additions
- additive changes that do not break existing contracts

Use `major` for:

- changed contracts
- changed meanings
- changed workflow expectations
- changed commissioning or deployment compatibility

### 4.9 Safety Rule

If analyzers are uncertain, the system must not silently under-bump.

The system should:

- default conservatively upward, or
- require explicit override

Every release should record why it was classified as:

- `patch`
- `minor`
- `major`

## 5. Ordering Rules

Ordering must be deterministic.

Write modules in this order:

1. manifest module first
2. artifact modules sorted by `{kind, id}`

Stable ordering matters for:

- readable diffs
- reproducible exports
- easier review

## 6. Source of Truth

The bundle has two durable layers:

- artifact source
- bundle composition metadata

Within the bundle:

- generated artifact modules are the source of truth for artifact behavior and
  config
- manifest data is the source of truth for inventory and cross-artifact
  composition
- workspace metadata is optional and non-authoritative

## 7. Import Rules

Studio import must parse and classify the bundle.

Studio import must not compile or execute bundle source.

The default parser path should use:

- `Code.string_to_quoted/2`

If comment-preserving import or export becomes important, the implementation may
use:

- `Code.string_to_quoted_with_comments/2`

Classification and import logic must still remain parse-only.

### 7.1 Import Algorithm

1. read file contents
2. parse source into AST
3. extract all top-level `defmodule` blocks
4. identify the manifest module by explicit manifest shape
5. read `manifest/0` data from the extracted manifest AST
6. extract raw source for every artifact module
7. match artifact modules against manifest entries
8. classify each artifact with the correct definition family
9. restore workspace hints if present

Import implementations must define a deterministic source-slicing strategy for
recovering the exact original text of each top-level `defmodule` block.

AST parsing is used for classification and manifest recovery, but Studio should
still preserve the exact raw module source text for source-first editing and
digest validation.

### 7.2 Classification

For each artifact:

1. select the definition family from `kind`
2. pass raw module source to `from_source/1`
3. store both:
   - recovered model state
   - exact raw source

Classification outcomes:

- `{:ok, model}`
- `{:partial, model, diagnostics}`
- `:unsupported`

### 7.3 Import Recovery Rules

If classification returns:

- `{:ok, model}`
  - restore visual and source state
- `{:partial, model, diagnostics}`
  - restore partial visual state
  - keep exact source
  - surface diagnostics
- `:unsupported`
  - keep exact source
  - mark artifact source-only
  - do not pretend visuals are current

Studio must preserve the raw per-module source exactly, even when recovery is
partial or unsupported.

### 7.4 Digest Validation

During import, Studio should compare:

- manifest `source_digest`
- digest of the extracted raw module source

`source_digest` should be computed from the exact raw module source text stored
in the bundle, not from canonical regenerated source.

This rule keeps digest validation predictable and aligned with the actual
imported source of truth.

If they differ:

- keep loading the bundle
- mark the artifact with a warning
- prefer the extracted raw source as the actual imported source

## 8. Activation Rules

Opening a bundle and activating a bundle are different operations.

### 8.1 Open Bundle

Open means:

- parse
- classify
- restore Studio state

Open does not:

- build
- load modules
- apply runtime changes

### 8.2 Activate Bundle

Activate means:

1. build all artifacts
2. validate cross-artifact wiring
3. apply artifacts in dependency order
4. publish deployment mappings

Suggested dependency order:

1. drivers
2. hardware or simulator definitions
3. machines
4. topology
5. HMI surfaces
6. runtime deployment mappings

Activation must use the shared Studio host rules:

- non-loading build
- latest-only apply
- blocked apply is normal

## 9. Export Rules

Studio export should:

1. collect all included artifacts
2. generate canonical source for each artifact
3. compute per-artifact `source_digest`
4. generate manifest source
5. concatenate modules in canonical order
6. format the final bundle source

Export should be reproducible for the same logical content.

## 10. Artifact Families

The same bundle file may include multiple Studio Cell artifact families, such
as:

- drivers
- machines
- topology
- HMI surfaces
- simulator definitions
- master definitions

Each family remains responsible for:

- `schema/0`
- `cast_model/1`
- `to_source/2`
- `from_source/1`

The bundle layer does not replace family-specific recovery logic.

## 11. Error Handling

Import should fail clearly when:

- no manifest module exists
- multiple manifest modules exist
- the manifest shape is invalid
- an artifact listed in the manifest is missing from the file
- an extracted module cannot be matched to a manifest entry

Import should degrade, not fail, when:

- an artifact is `:unsupported`
- classification is partial
- a source digest mismatch is detected
- workspace metadata is invalid

## 12. Non-Goals

This format does not define:

- direct execution of bundle source
- arbitrary helper modules inside the bundle
- runtime snapshots
- log/event capture
- old-code retention state
- sandboxing of untrusted Elixir code

## 13. Summary

Use a single-file Elixir bundle format for Studio bundles.

The file contains:

- one manifest module
- many generated artifact modules
- optional workspace hints

Studio import is:

- parse
- classify
- recover

Runtime activation is:

- build
- validate
- apply

That keeps source authoritative while still allowing a complete application
configuration to be saved and restored from one file.
