process NormaliseVcf {
    container params.container

    // normalise one scatter region of the cohort VCF - this is where the scatter actually happens,
    // reading only the region's blocks through the index. --regions-overlap 0 assigns a record to
    // the shard containing its POS, so a deletion spanning a region boundary is emitted exactly once.
    // region 'all' streams the whole file (pre-sharded inputs, or scatter disabled) and needs no
    // index - tbi is [] on that path, staging nothing.
    // ref_genome here is used to create parsimonious representations
    //
    // Two outputs per shard: the full-width normalised BCF (all samples, only ever read again by the
    // lift-over in AnnotateShard - BCF because it is cheaper to write and re-read than bgzipped text;
    // indexed because bcftools annotate needs an index on both sides when -a is a VCF),
    // and a sites-only VCF (no FORMAT columns) which is what echtvar and bcftools csq actually run on.
    // Both come from the same normalised stream, so records correspond 1:1 by CHROM/POS/REF/ALT.
    // fill-tags runs before the sites are extracted, as AC/AF/AN need the genotypes
    input:
        tuple val(cohort), path(vcf), path(tbi), val(region)
        path ref_genome

    output:
        tuple val(cohort), path("*_normalised.bcf"), path("*_normalised.bcf.csi"), path("*_sites.vcf.bgz")

    script:
        def out_name = region == 'all' ? vcf.simpleName : "${vcf.simpleName}_${region.replaceAll(/[:\-]/, '_')}"
        // --regions-overlap 0 = POS-in-region only, so boundary-spanning records land in exactly one shard
        def region_args = region == 'all' ? '' : "--regions ${region} --regions-overlap 0"
        """
        set -euo pipefail

        bcftools norm \
            -m -any \
            -f ${ref_genome} \
            ${region_args} \
            -Ou ${vcf} \
            --no-version | \
        bcftools +fill-tags \
            -Ob \
            --no-version \
            -o "${out_name}_normalised.bcf" \
            -W - -- -t AC,AF,AN

        # -G drops all samples/genotypes - the annotation tools only need the sites
        bcftools view \
            -G \
            -Oz \
            --no-version \
            -o "${out_name}_sites.vcf.bgz" \
            "${out_name}_normalised.bcf"
        """
}
