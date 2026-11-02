 # CPG Deployment

`cpg_main.nf` is the CPG entrypoint. It runs the same pipeline as `main.nf` (the shared `TALOS_PIPELINE`, in
`nextflow/talos_pipeline.nf`), but you don't give it an input TSV. Instead it takes Metamist cohort IDs, finds
each cohort's inputs in Metamist, and publishes each cohort to its own dataset bucket. Outside CPG, use
`main.nf`.

Terms used here (cohort, dataset, sequencing group, access level, dataset bucket) are defined in `GLOSSARY.md`.
[ADR 0001](https://github.com/populationgenomics/talos/blob/main/docs/adr/0001-publishdir-over-workflow-outputs.md)
explains why there are two entrypoints.

## Running

```bash
nextflow -c nextflow.config run cpg_main.nf \
    --cohort_ids COH0001,COH0002 \
    --access_level test \
    --sequencing_type genome \
    --talos_config gs://.../talos.toml
```

| **Parameter**     | **Description**                                                                                                                                |
|-------------------|------------------------------------------------------------------------------------------------------------------------------------------------|
| `cohort_ids`      | Metamist cohort IDs: a list (e.g. in a params file) or a comma-delimited string. Repeats are dropped                                           |
| `access_level`    | `test`, `standard` or `full`. `test` publishes to `gs://cpg-<dataset>-test`, the others to `gs://cpg-<dataset>-main`                          |
| `sequencing_type` | `genome` or `exome`. One per run                                                                                                               |
| `talos_config`    | The CPG `talos.toml`. Its generic sections, plus that dataset's `[cohorts.<dataset>]` section, make up each cohort's config (see [Config](#config)) |

All four are required. The run exits before any task starts if any is missing or invalid. `input_tsv` and
`outdir` are ignored. All other params (reference data, `processed_annotations`, containers) are the same as
for `main.nf`. See [Nextflow Configuration](NextflowConfiguration.md).

## Output layout

Each cohort publishes under its dataset bucket:

```
gs://cpg-<dataset>-{main|test}/<sequencing_type>/talos/<cohort>/
├── annotated/                 annotation products, reused by every later run
└── analysis_YYYYMMDD/         this run's results, including the HTML report
    └── inputs/                the generated inputs, see below
```

The date is fixed once, when the run starts. As with `main.nf`, a cohort whose `annotated/` manifest already
exists isn't re-annotated. Delete `annotated/` to force re-annotation. No next-cycle input TSV is written.

`cohortRoot()` in `cpg_main.nf` and `cohort_root()` in `talos.cpg_internal.input_tsv_from_metamist` build the
same path. If you change one, change the other.

## Finding inputs: `InputTsvFromMetamist`

The first process runs `python -m talos.cpg_internal.input_tsv_from_metamist`. It runs in the Talos
container, which installs the `cpg` extra (`metamist`), and uses the task's ambient Google credentials. It
retries once, and then stops the run, since nothing else can start without it.

### Which cohorts it accepts

It refuses the whole run, listing every problem together, if any cohort:

- is missing from Metamist, or isn't visible to the run's credentials
- belongs to a project that doesn't match the access level (`<dataset>-test` at `test`, `<dataset>` otherwise)
- has sequencing groups from a different project
- has no active, short-read SGs of the requested sequencing type
- has a participant with more than one usable SG

It also refuses a run with more than one cohort from the same dataset. Run those separately.

SGs of other types or technologies are skipped with a warning. Sample IDs are SG IDs throughout: the VCFs
must already use SG IDs as sample names.

### Inputs

Analyses are looked up on the cohort's Metamist project (completed, active), filtered on
`meta.sequencing_type` unless stated otherwise. The newest one by completion time is used, and partial-dataset
outputs (paths containing `_families-`) are skipped.

| **Column**     | **Source**                                                                                                     | **Required** |
|----------------|----------------------------------------------------------------------------------------------------------------|--------------|
| `path`         | Analysis type `vcf`, `meta.stage = TalosDatasetVcf`. **Placeholder** until the seqr-loader release that writes it | yes          |
| `pedigree`     | Generated from the project pedigree, filtered to the cohort's SGs, with HPO terms as a 7th column              | yes, per SG  |
| `ext_ids`      | Generated: `SG ID <tab> participant external ID`                                                               | -            |
| `config`       | Generated: see [Config](#config)                                                                               | -            |
| `seqr_map`     | Generated: `{SG ID: seqr family GUID}`, if the project's meta has `is_seqr` and `seqr-project-<sequencing_type>` | no           |
| `sv_annotated` | Analysis type `single_dataset_sv_annotated`, genome only, not filtered on sequencing type                      | no           |
| `mito`         | Analysis type `vcf`, `meta.stage = GenerateMitoJointCall`                                                      | no           |
| `str`          | Analysis type `vcf`, `meta.stage = MakeStripyJointCall`                                                        | no           |
| `history`      | Analysis type `aip-results`. Talos v1 results are lifted forward on read                                       | no           |

A missing small-variant VCF, or an SG with no pedigree entry, fails the run. Optional inputs are left blank
when they're absent. The analysis types and stages are constants at the top of the generator.

Exome gCNV isn't supported. Exome cohorts have no SV input.

The dataset-wide small-variant VCF is subset to the pedigree's samples during annotation, so only the
cohort's samples are annotated and stored (see [Pedigree & Phenotypes](Pedigree.md)). The pre-annotated SV,
mito and STR VCFs aren't subset in Nextflow. Each filtering stage reads only the pedigree's samples.

### Generated files

Everything is gathered and checked before anything is written, so a refused run leaves nothing behind. Each
cohort's files are then written to `analysis_YYYYMMDD/inputs/`:

```
<cohort>_pedigree.ped
<cohort>_ext_ids.tsv
<cohort>_config.toml
<cohort>_seqr_map.json     only if the dataset is in seqr
<cohort>_input.tsv         this cohort's row, with full URIs, as main.nf would take it
```

The `<cohort>_input.tsv` also has a `cpg_dataset` column, which `main.nf` ignores. You can use it to rerun one
cohort with `main.nf` if you need to.

## Config

`talos_config` is shaped like `production-pipelines-configuration/config/talos/talos.toml`. Each cohort's
config is:

- every section of that file except `cohorts`, plus top-level `dataset` and `sequencing_type`
- overridden by the dataset's `[cohorts.<dataset>]` section, **only for the keys it sets**:

| **`[cohorts.<dataset>]` key**     | **Becomes**                               |
|-----------------------------------|-------------------------------------------|
| `forbidden`                       | `GeneratePanelData.forbidden_genes`       |
| `forced_panels`                   | `GeneratePanelData.forced_panels`         |
| `blacklist`                       | `GeneratePanelData.blacklist`             |
| `solved_cases`                    | `ValidateMOI.solved_cases`                |
| `<sequencing_type>.external_labels` | `CreateTalosHTML.external_labels`       |
| `hyperlinks`                      | `CreateTalosHTML.hyperlinks`              |

If the dataset is in seqr, seqr family-page and variant links replace any `hyperlinks`.

Set `RunSvFiltering.gnomad_population` to the prefix of GATK-SV's population frequency fields
(`<prefix>_sv_AF`, `<prefix>_sv_SVID`). Pre-annotated SV VCFs aren't renamed, so with the default
(`gnomad_v4.1`) no SV would match a population frequency. See
[Pre-annotated SV VCFs](SvAnnotation.md#pre-annotated-sv-vcfs).

## Reanalysis

`history` is the dataset's latest `aip-results` analysis. **`cpg_main.nf` doesn't register its results in
Metamist yet**, so a later run picks up the latest result that was registered, which may be from Talos v1, and
not the previous `cpg_main.nf` run's results. Registering results is planned as a follow-up change.

## Known gaps

- Metamist access from a Google Batch task hasn't been tested yet. Locally, without credentials,
  `InputTsvFromMetamist` fails with `DefaultCredentialsError`.
- The small-variant VCF analysis type and stage are placeholders (`SMALL_VARIANT_VCF` in the generator).
- Results aren't registered in Metamist (see [Reanalysis](#reanalysis)).
