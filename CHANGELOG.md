# Changelog

All notable changes to this project will be documented in this file.

Suggested headings per release (as appropriate) are:

* `Added` for new features.
* `Changed` for changes in existing functionality.
* `Deprecated` for soon-to-be removed features.
* `Removed` for now removed features.
* `Fixed` for any bug fixes.
* `Security` in case of vulnerabilities.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

<!--changelog-start-->
<!--latest-start-->

[0.1.0] - 2026-08

* Every `main.nf` run now writes `talos_input_YYYYMMDD.tsv` to the root of the output directory - a copy of the run's input TSV with each cohort's `history` cell repointed at the results JSON that run published, ready to be reviewed and used as the `--input_tsv` for the next reanalysis cycle.
* This aims to bridge the gap in the current implementation, where inputs and analysis outputs need to be manually updated for future cycles. Feel free to use this or ignore it :)

[0.0.2] - 2026-08

### Changed

* Really reduces the per job resource requirements. This may be insufficient in HUGE cohorts, but has been successful in mid-sized (50-genome) testing. Users are invited to customise based on local requirements.

### Fixed

* Fixes the mechanism NextFlow uses to find adjacent-files, and carry out file globbing. This was fine for local deployments, but buggy in cloud environments due to String trimming.

[0.0.1] - 2026-08

### Added

* Welcome to the new repository! This is Talos 2.0, designed to be easier to deploy outside the CPG and Hail Batch-using sites. Instead of using Hail/Spark as a processing framework, this reimagined version uses a more basic map/reduce framework, scattering the input data as sharded VCFs, annotating and filtering in pieces, and re-forming a final VCF input from the minimal set of relevant variants. No Hail runtime, no MatrixTables, no Spark cluster. Just VCFs. This feels like a good compromise given the considerations - this needs to remain site-agnostic, making few assumptions about available infrastructure, but needs to run relatively quickly across cohorts of all sizes. This will still present scaling issues at super-high cohort sizes, but it represents dramatic improvements over the original Talos implementation at non-Spark enabled sites.

### Changes from the original Talos

* The labelling/filtering phase which runs on the annotated data has been rewritten as a loop over an annotated VCF fragment, instead of requiring data to be read into a MatrixTable and processed in a single highly-resourced runtime.
* The annotation workflow no longer physically splits the input VCF (`SplitVcf` is gone - it was a serial pass over the whole callset). Scatter regions are now derived from the VCF index (`MakeScatterRegions`), with each `NormaliseVcf` task reading only its region from the input; `params.vcf_split_n` is now the target records per region, and `0` still disables the scatter.
* `MakeScatterRegions` now stages only the `.tbi` - `bcftools index -s` reads contig, length and record count from the index alone, so the whole-callset VCF is no longer localised into that task.
* Outputs are split per cohort: annotation products (annotated shards, shard manifest, annotated SV VCF) publish to `{cohort}_annotated/`, and analysis results to a dated `{cohort}_analysis_YYYYMMDD/`. The `{cohort}_annotated` directory is reusable across reanalysis cycles and safe to delete to force re-annotation. **Migration**: existing output directories keep annotation products in `{cohort}_outputs/` with no manifest - re-run `main.nf` once to regenerate into the new layout.
* Annotation writes a per-cohort `{cohort}_manifest.json` naming exactly the shards it produced, and is now idempotent: cohorts whose manifest already exists are reused (shards read from the manifest, never a directory glob), so stale shards from an earlier annotation run (e.g. a different `vcf_split_n`) can never be double-counted, and a reanalysis cycle is simply a re-run of `main.nf`. A new optional `params.annotated_dir` lets a run read annotation products from a different location than it publishes results to.
* VCF ingestion in ValidateMOI no longer iterates the full cohort three times per variant - depths, alt depths and AB ratios are sliced from the genotype arrays at carrier positions only, and phase data is read for carriers only. Per-variant config lookups (exomiser rank, de novo thresholds, CSQ field names) are now resolved once per process.

### Removed

* `talos_only.nf` - redundant now that annotation is idempotent; re-run `main.nf` for reanalysis cycles instead.

<!--latest-end-->
<!--changelog-end-->
