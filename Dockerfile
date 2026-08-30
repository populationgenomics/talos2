# The single Talos image - the Python package, bcftools/htslib, echtvar, and SVAFotate.
#
# SVAFotate used to be built as a separate image because its dependency stack could not be
# reconciled with Hail's. Hail is no longer a dependency, and SVAFotate's setup.py asks only for
# pandas/numpy/pyranges/cyvcf2, with a ceiling on compatible pandas version.
#
# build with "docker build -t talos2:0.1.0 ."

# SVAFotate is not published to PyPI and the repository carries no releases or tags, so it is pinned to
# an explicit commit. Installed from the GitHub tarball rather than git+https, which keeps git out of the
# image. Last verified 2026-08-26.
ARG SVAFOTATE_COMMIT=30b5004a0f4d26959c6b9a82f165651585293626

FROM python:3.11-slim-bullseye AS base

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        bzip2 \
        ca-certificates \
        gnupg \
        libbz2-1.0 \
        libcurl4 \
        liblzma5 \
        procps \
        wget \
        zip \
        zlib1g && \
    rm -r /var/lib/apt/lists/* && \
    rm -r /var/cache/apt/*

FROM base AS compiler

ARG BCFTOOLS_VERSION=1.24

RUN apt-get update && apt-get install --no-install-recommends -y \
        gcc \
        libbz2-dev \
        libcurl4-openssl-dev \
        liblzma-dev \
        libssl-dev \
        make \
        zlib1g-dev && \
    rm -rf /var/lib/apt/lists/* && \
    wget https://github.com/samtools/bcftools/releases/download/${BCFTOOLS_VERSION}/bcftools-${BCFTOOLS_VERSION}.tar.bz2 && \
    tar -xf bcftools-${BCFTOOLS_VERSION}.tar.bz2 && \
    cd bcftools-${BCFTOOLS_VERSION} && \
    ./configure --enable-libcurl --enable-s3 --enable-gcs && \
    make && \
    strip bcftools plugins/*.so && \
    make DESTDIR=/bcftools_install install && \
    cd htslib-${BCFTOOLS_VERSION} && \
    make && \
    make DESTDIR=/bcftools_install install

# SVAFotate's dependency set is not wheel-complete on every architecture - sorted_nearest (via
# pyranges) publishes no wheels at all, and ncls publishes none for manylinux aarch64, so an arm64
# build compiles both from sdist. Wheeling the whole set here rather than naming the sdist-only
# packages keeps that architecture-dependent, and keeps gcc out of the final image.
RUN pip wheel --no-cache-dir --wheel-dir /sv_wheels \
        'pandas<3' \
        pyranges \
        ncls

FROM base AS talos

ARG SVAFOTATE_COMMIT

COPY --from=compiler /bcftools_install/usr/local/bin/* /usr/local/bin/
COPY --from=compiler /bcftools_install/usr/local/libexec/bcftools/* /usr/local/libexec/bcftools/

ARG ECHTVAR_VERSION=v0.2.2
ENV VERSION=0.1.0

RUN wget -q -O /bin/echtvar "https://github.com/brentp/echtvar/releases/download/${ECHTVAR_VERSION}/echtvar" && \
    chmod +x /bin/echtvar

COPY --from=ghcr.io/astral-sh/uv:0.9.26 /uv /uvx /bin/

# Enable bytecode compilation
ENV UV_COMPILE_BYTECODE=1

# Copy from the cache instead of linking since it's a mounted volume
ENV UV_LINK_MODE=copy

WORKDIR /talos2

# Install the project's dependencies using the lockfile and settings
RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    uv sync --all-extras --frozen --no-install-project --no-dev

# SVAFotate goes into the same venv, on top of the locked dependencies. It is deliberately not a
# pyproject dependency: `uv sync --frozen` would then need a relocked uv.lock, and the git-pinned
# source has no place in it. numpy and cyvcf2 are already present from the lock and satisfy
# SVAFotate's unpinned requirements, so this step leaves them alone.
#
# pandas<3 is the one pin that matters. pandas 3.x returns the new `str` dtype for string columns, and
# pyranges 0.1.4 predates it - its null_types() helper accepts only `object` or a dtype whose name
# contains "string", so every `svafotate annotate` run dies with "Exception: Unknown dtype str in a
# column SVTYPE". The quotes matter too: unquoted, `<3` is a shell redirect from a file named `3`.
COPY --from=compiler /sv_wheels /tmp/sv_wheels
RUN --mount=type=cache,target=/root/.cache/uv \
    uv pip install --python /talos2/.venv/bin/python --find-links /tmp/sv_wheels \
        'pandas<3' \
        pyranges \
        ncls \
        "https://github.com/fakedrtom/SVAFotate/archive/${SVAFOTATE_COMMIT}.tar.gz" && \
    rm -rf /tmp/sv_wheels

# Place executables in the environment at the front of the path
ENV PATH="/talos2/.venv/bin:$PATH"

# Add in the additional requirements that are most likely to change.
# --inexact so that installing the project does not prune the SVAFotate stack, which is not in uv.lock
COPY LICENSE pyproject.toml uv.lock README.md ./
COPY src src/
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --all-extras --frozen --no-dev --inexact

# both halves of the image have to survive each other's install - the Talos package and its cyvcf2,
# and the SVAFotate CLI. Cheap, and the failure mode it catches is otherwise a runtime one
RUN python -c "import talos2, cyvcf2, svafotate" && \
    bcftools --version && \
    tabix --version && \
    echtvar --version

COPY echtvar echtvar/
