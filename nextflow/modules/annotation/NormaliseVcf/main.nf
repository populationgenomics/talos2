process NormaliseVcf {
    container params.container

    // normalise one scatter region of the cohort VCF - this is where the scatter actually happens,
    // reading only the region's blocks through the index. --regions-overlap 0 assigns a record to
    // the shard containing its POS, so a deletion spanning a region boundary is emitted exactly once.
    // region 'all' streams the whole file (pre-sharded inputs, or scatter disabled) and needs no
    // index - tbi is [] on that path, staging nothing.
    // ref_genome here is used to create parsimonious representations
    input:
        tuple val(cohort), path(vcf), path(tbi), val(region)
        path ref_genome

    output:
        tuple val(cohort), path("*_normalised.vcf.bgz"), path("*_normalised.vcf.bgz.tbi")

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
            -Oz \
            --no-version \
            -o "${out_name}_normalised.vcf.bgz" \
            -W=tbi - -- -t AC,AF,AN
        """
}
