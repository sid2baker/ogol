# Semantic Versioning

This document defines how Ogol should version deployed and armed releases.

The main decision is:

> use semantic versions for released and deployed versions, not for every draft.

## 1. Versioning Model

The intended model is:

- drafts -> revision ids
- candidates -> build/revision ids
- deployed releases -> semantic versions

Compact rule:

> revisions identify work, semantic versions identify releases, and deploy
> always creates a new release.

## 2. SemVer Scope

Primary semantic versioning should apply to the deployment bundle or armed
release, not necessarily to every internal artifact revision.

That means the release boundary is what matters:

- what is deployed
- what is compared against the currently armed live system
- what operators and engineers can roll back to

## 3. Deploy Behavior

On deploy:

- always create a new immutable release version
- compare `Candidate` vs `Armed Live`
- run compatibility analyzers
- classify the bump as:
  - `patch`
  - `minor`
  - `major`
- mint the next release version automatically

Deploy should not silently reuse the old release identity.

## 4. Compatibility Classification

The version bump must come from explicit compatibility rules.

It must not be guessed from a vague “something changed” heuristic.

### 4.1 Patch

Use `patch` for:

- fixes
- internal improvements
- changes that preserve meaning, public interfaces, workflow, and operational
  expectations

### 4.2 Minor

Use `minor` for:

- backward-compatible capability additions
- additive changes that do not break existing contracts

### 4.3 Major

Use `major` for:

- changed contracts
- changed meanings
- changed workflow expectations
- changed commissioning or deployment compatibility

## 5. Safety Rule

If the analyzers are uncertain, the system must not silently under-bump.

The system should:

- default conservatively upward, or
- require explicit override

Every release should record why it was classified as:

- `patch`
- `minor`
- `major`

## 6. Summary

The baseline rule is:

- revisions identify work
- semantic versions identify releases
- deploy always creates a new release
- analyzers decide `patch`, `minor`, or `major`
