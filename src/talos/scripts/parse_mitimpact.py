"""
takes the MitImpact database (zipped) as input, outputs a new VCF file.

Supports both:
- MitImpact 3.1.3 (MitImpact_db_3.1.3.txt.zip) - tab-delimited
- MitImpact 4 (e.g. MitImpact4_V059 zip containing MitImpact4_V059.csv) - comma-delimited, quoted fields

input columns: LOADS. THERE'S LOADS OF COLUMNS
relevant columns:
Chr Start Ref Alt APOGEE2 APOGEE2_probability APOGEE2_score

MitImpact 4 also covers non-coding (tRNA/rRNA/D-loop) positions, where the APOGEE2 fields are empty.
Those rows are skipped, as are duplicate Chr/Start/Ref/Alt rows (overlapping genes, e.g. ATP8/ATP6, ND4L/ND4),
where the first record is retained.
"""

import csv
import gzip
import io
import sys
import zipfile
from argparse import ArgumentParser
from importlib import resources

REQUIRED = ['Chr', 'Start', 'Ref', 'Alt', 'APOGEE2', 'APOGEE2_probability', 'APOGEE2_score']


def _pick_member(zf: zipfile.ZipFile) -> str:
    """choose the data file inside the zip, ignoring directories and macOS metadata."""
    candidates = [
        name
        for name in zf.namelist()
        if not name.endswith('/') and '__MACOSX' not in name and not name.split('/')[-1].startswith('.')
    ]
    for ext in ('.csv', '.txt', '.tsv'):
        for name in candidates:
            if name.lower().endswith(ext):
                return name
    return candidates[0]


def _detect_delimiter(header_line: str) -> str:
    return '\t' if header_line.count('\t') > header_line.count(',') else ','


def _clean(value: str | None) -> str:
    value = (value or '').strip()
    return '' if value in ('', '.', 'NA', 'nan', 'NaN') else value


def main(input_mitimpact: str, output: str):
    csv.field_size_limit(sys.maxsize)
    with zipfile.ZipFile(input_mitimpact, 'r') as mitimpact_opened:
        filename = _pick_member(mitimpact_opened)
        with (
            mitimpact_opened.open(filename, 'r') as handle,
            gzip.open(output, 'wt') as out,
            (resources.files('talos') / 'vcf_headers' / 'mitimpact_header.txt').open() as head_in,
        ):
            # transcribe the required header
            for header_line in head_in:
                out.write(header_line)

            handle_data = io.TextIOWrapper(handle, encoding='utf-8-sig', newline='')
            first_line = handle_data.readline()
            delimiter = _detect_delimiter(first_line)
            fieldnames = next(csv.reader([first_line], delimiter=delimiter))
            missing = [col for col in REQUIRED if col not in fieldnames]
            if missing:
                raise ValueError(f'{filename} is missing required MitImpact columns: {missing}')

            reader = csv.DictReader(handle_data, fieldnames=fieldnames, delimiter=delimiter)
            seen: set[tuple[str, str, str, str]] = set()
            written = 0
            for line in reader:
                apogee2 = _clean(line['APOGEE2'])
                apogee2_score = _clean(line['APOGEE2_score'])
                apogee2_prob = _clean(line['APOGEE2_probability'])
                if not (apogee2 or apogee2_score or apogee2_prob):
                    continue

                chrom = line['Chr'].strip()
                if not chrom.startswith('chr'):
                    chrom = 'chrM' if chrom in ('M', 'MT') else f'chr{chrom}'
                pos = line['Start'].strip()
                ref = line['Ref'].strip()
                alt = line['Alt'].strip()

                key = (chrom, pos, ref, alt)
                if key in seen:
                    continue
                seen.add(key)

                out.write(
                    f'{chrom}\t{pos}\t.\t{ref}\t{alt}\t60\tPASS\t'
                    f'apogee2={apogee2 or "."};apogee2_score={apogee2_score or "."};'
                    f'apogee2_probability={apogee2_prob or "."}\n',
                )
                written += 1
            print(f'Parsed {filename} (delimiter={delimiter!r}), wrote {written} variants', file=sys.stderr)


if __name__ == '__main__':
    parser = ArgumentParser()
    parser.add_argument('--input', required=True, help='Input zipped MitImpact file (3.1.3 txt or 4.x csv)')
    parser.add_argument('--output', required=True, help='output VCF')
    args = parser.parse_args()
    main(input_mitimpact=args.input, output=args.output)
