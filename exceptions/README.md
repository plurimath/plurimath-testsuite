# Historical rejection offsets

`rejection-offsets.json` records current Ruby oracle positions that differ from
historical rejection payloads. Like the explicit historical YAML exemptions
proposed in #59, each record names the exact payload path and SHA-256, source
revision, input, reason and replacement. The payload and sealed snapshots stay
unchanged. Consumers must continue requiring rejection and the exact replacement
offset; this is not permission to skip a row or accept a range of positions.

The two UnicodeMath broken-bar rows historically map to original offset 1.
Current `Umath` 0.2.4 reports character offset 2 (UTF-8 byte offsets 3 and 4).
The manifest pins the current Plurimath source revision used to probe the stage.
`ruby scripts/validate-rejection-offsets.rb` rejects edited payloads, missing or
changed rows, duplicate exceptions and missing oracle provenance. Consumer tests
must also check the historical original offset before applying a replacement.

Retire or remeasure these explicit records when the payload changes. Do not
change immutable historical generation bytes to fit a current implementation.
