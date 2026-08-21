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

A payload's `description` names the defect the file itself carries
("Healthy template with one planted defect: …"). Payloads inside
`integrity-*` roots keep the plain healthy description on purpose: the file
is genuinely healthy, the defect lives in the provenance record beside it —
and rewording them would invalidate the recorded byte counts.

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
| `rejections-healthy` | healthy twin: a valid rejection payload, so the defective ones below fail only on their planted defect |
| `rejections-missing-error` | rejections schema: `error` required, which is the whole record |
| `rejections-unknown-category` | rejections schema: `error.category` enum, so a typo cannot become a category nothing matches |
| `rejections-with-expected` | rejections schema: `additionalProperties: false` on a case, so a rejection cannot also claim a rendering |
| `rejections-empty-input` | rejections schema: `input` minLength, since an implementation must be given something to refuse |
| `rejections-negative-index` | rejections schema: `error.index` minimum |
| `rejections-wrong-group` | rejections cross-field: `group` matches the file name |
| `rejections-case-format-drift` | rejections cross-field: a case does not switch input format mid-group |
| `rejections-duplicate-id` | rejections cross-field: ids are unique within a group |
| `rejections-index-past-end` | rejections cross-field: the offset lies inside `preprocessed` |
| `rejections-index-at-end` | healthy twin: offset == length, as a premature-end failure gives, must still pass |
| `cases2-healthy` | healthy twin: a valid `cases/2` payload, so the defective ones below fail only on their planted defect |
| `cases2-outcome-both` | cases/2 schema: `oneOf` exclusivity — an outcome cannot both render and refuse |
| `cases2-outcome-empty` | cases/2 schema: `oneOf` exhaustiveness — an outcome that says nothing is not a third state |
| `cases2-outcome-bare-string` | cases/2 schema: the bare string a `cases/1` case writes here is refused, so a v1 case cannot be pasted in and lose its discrimination |
| `cases2-outcome-extra-key` | cases/2 schema: `additionalProperties: false` inside an outcome branch |
| `cases2-unknown-error-category` | cases/2 schema: `error.category` enum, so a typo cannot become a category nothing matches |
| `cases2-error-with-index` | cases/2 schema: no `error.index` — a render-time refusal has no position in `preprocessed` |
| `cases2-wrong-group` | cases/2 cross-field: `group` matches the file name |
| `cases2-format-vs-schema-segment` | cases/2 cross-field: `input_format` equals the schema declaration's middle segment |
| `cases2-format-vs-directory` | cases/2 cross-field: the group lives in the directory named after its format |
| `cases2-case-format-drift` | cases/2 cross-field: a case does not switch input format mid-group |
| `cases2-duplicate-id` | cases/2 cross-field: ids are unique within a group |
| `cases2-expected-outside-targets` | cases/2 cross-field: `expected` keys ⊆ `targets` |
| `cases2-target-missing-expectation` | cases/2 cross-field: `targets` ⊆ `expected` keys |
| `unregistered-kind` | dispatch: a payload kind with no cross-field checks registered fails, rather than being checked by its schema alone (with `schemas/unregistered-kind`) |
| `schemas/unregistered-kind` | schema dir: a valid schema for a kind scripts/validate.rb registers no cross-field checks for |
| `lockfiles/sample.lock` | generator: `parse_lockfile` fixture (all source kinds, leak tripwires) |
