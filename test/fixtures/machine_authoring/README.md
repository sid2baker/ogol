# Machine Authoring Corpus

This directory contains the first compact golden corpus for machine authoring.

It is intentionally small and targeted. The fixtures are meant to pin down:

- compatibility classification
- canonicalization expectations
- managed-subset boundaries
- runtime activation expectations for a few representative cases

The canonical manifest lives in:

- [manifest.term](/home/n0gg1n/Development/Work/opencode/ogol/fixtures/machine_authoring/manifest.term)

The source fixtures are grouped by expected compatibility outcome:

- `fully_editable/`
- `partially_representable/`
- `not_visually_editable/`

This corpus is for parser/classifier/printer/loader tests. Not every fixture is
expected to compile or activate today, and some are intentionally raw source
cases that should stay outside the current visual editing subset.
