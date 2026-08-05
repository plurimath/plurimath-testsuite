# Spec fixtures

Each directory is a corpus root carrying **exactly one defect**, named after
the validator check it exists to trip; `healthy-*` fixtures carry none and
prove the neighbouring check does not overfire. The real corpus in `corpus/`
is the canonical healthy case and is never duplicated here. Symlink and
deep-nesting corpora cannot be committed, so the specs assemble those in a
tmpdir at runtime (see `with_fixture_copy` / `with_corpus` in
`spec/spec_helper.rb`).

Integrity fixtures embed computed sha256/bytes values; when the base payload
changes they must be recomputed, not hand-edited.

| Fixture | Check it exists for |
|---|---|
| `cases-missing-required` | schema: required property enforcement (`description` absent) |
| `cases-extra-property` | schema: `additionalProperties: false` on the payload root |
| `cases-bad-slug` | schema: `group` slug pattern |
| `cases-empty-cases` | schema: `cases` minItems |
| `cases-duplicate-targets` | schema: `targets` uniqueItems, duplicates named |
| `cases-unknown-expected-key` | schema: `expected` propertyNames (target formats only) |
| `cases-nonstring-input` | schema: `input` type |
| `cases-empty-input` | schema: `input` minLength |
| `cases-newline-in-id` | ECMA anchor translation: `^…$` must not pass an embedded newline |
| `cases-number-in-parse-tree` | schema: parse trees exclude numbers (anyOf) |
| `cases-malformed-node` | schema: a `class`-bearing object must be a well-formed node (if/then) |
| `cases-nonstring-key` | non-string mapping keys are reported |
| `pointer-escaped-property` | JSON-pointer escaping of `~` and `/` in property tokens |
| `yaml-anchor-alias` | YAML aliases are rejected as non-portable |
| `yaml-syntax-error` | unparseable YAML fails the file, not the run |
| `payload-not-a-mapping` | a payload must be a mapping |
| `nonfinite-numbers` | `.nan` / `.inf` / `+.inf` / `-.inf` rejected before schema evaluation |
| `nonfinite-under-nonstring-key` | pointer-token escaping for non-string keys |
| `schema-key-missing` | dispatch: `schema` key required |
| `schema-key-nonstring` | dispatch: `schema` must be a string, arrival named |
| `schema-unclaimed` | dispatch: declaration no schema claims |
| `schema-ambiguous` | dispatch: declaration claimed twice (with `schemas/ambiguous`) |
| `schemas/ambiguous` | schema dir: const and pattern both claiming one declaration |
| `schemas/duplicate-claim` | schema dir: identical `declares` rejected at load |
| `schemas/invalid-json` | schema dir: unparseable schema file rejected at load |
| `group-vs-filename` | cross: `group` equals the file stem |
| `format-vs-schema-segment` | cross: `input_format` equals the schema declaration's middle segment |
| `format-vs-directory` | cross: the group lives in the directory named after its format |
| `format-vs-case` | cross: every case keeps the group's `input_format` |
| `duplicate-case-ids` | cross: case ids unique within a group |
| `expected-outside-targets` | cross: `expected` keys ⊆ `targets` |
| `target-missing-expectation` | cross: `targets` ⊆ `expected` keys |
| `payloads-unsorted` | cross: provenance `payloads` sorted by path |
| `stray-root-file` | layout allowlist: stray file at the root |
| `stray-wrong-extension` | layout allowlist: `.yml` is not `.yaml` |
| `stray-dotfile` | layout allowlist: dotfiles are seen (FNM_DOTMATCH) |
| `stray-nested-dir` | layout allowlist: no third path level |
| `stray-uppercase` | layout allowlist: lowercase names only |
| `prov-committable-with-warnings` | provenance: warnings force `committable: false` |
| `prov-uncommittable-without-warnings` | provenance: no warnings force `committable: true` |
| `prov-committable-dirty-oracle` | provenance: committable output requires a clean oracle |
| `prov-clean-with-dirty-paths` | provenance: `clean: true` forbids `dirty_paths` (also pins report dedupe) |
| `prov-dirty-without-paths` | provenance: `clean: false` names at least one path |
| `prov-git-without-revision` | provenance: a git-sourced dependency requires its revision |
| `prov-bad-sha256` | provenance: sha256 pattern |
| `prov-path-escape` | provenance: payload paths stay relative, no `..` |
| `healthy-git-revision` | healthy twin: git+revision, platform build, null bundler, config override |
| `integrity-missing-provenance` | integrity: provenance required when payloads exist |
| `integrity-two-provenance` | integrity: exactly one file may declare the provenance schema |
| `integrity-provenance-not-at-root` | integrity: the provenance sits at the corpus root |
| `integrity-sha-mismatch` | integrity: recorded sha256 matches the file |
| `integrity-bytes-mismatch` | integrity: recorded byte count matches the file |
| `integrity-unrecorded-payload` | integrity: every payload on disk is recorded |
| `integrity-ghost-payload` | integrity: every recorded payload exists on disk |
| `integrity-duplicate-entry` | integrity: a path is recorded once |
| `integrity-skips-broken-provenance` | integrity: skipped when the provenance failed its schema |
| `healthy-minimal` | healthy twin: passes with integrity on; base for runtime mutations |
| `lockfiles/sample.lock` | generator: `parse_lockfile` fixture (all source kinds, leak tripwires) |
