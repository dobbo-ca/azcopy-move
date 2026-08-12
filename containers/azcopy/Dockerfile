# azcopy on Azure Linux 3.0. No interpreter beyond the base shell: the scripts
# are POSIX sh plus awk.
#
#   docker build --platform linux/amd64 -t ghcr.io/dobbo-ca/azcopy-move/azcopy:10.32.4 .
#   docker push ghcr.io/dobbo-ca/azcopy-move/azcopy:10.32.4
#
# Why Azure Linux:
#   - Microsoft packages azcopy for tdnf, so no tarball and no version drift.
#   - glibc. Alpine and musl are NOT supported; azcopy has no apk package.
#
ARG BASE_IMAGE=mcr.microsoft.com/azurelinux/base/core:3.0
FROM ${BASE_IMAGE}

# Single source of truth for the azcopy version. CI reads this ARG for the
# chart's appVersion and for the image's azcopy alias tag. An unpinned
# `tdnf install azcopy` resolves to whatever is newest in the ms-oss repo,
# which can be a prerelease (verified: azcopy-10.33.0_beta-1 today) — always
# pin the exact version here.
ARG AZCOPY_VERSION=10.32.4

# azcopy       the only tool the scripts call
# gawk         the parse and decide logic
# sed grep coreutils   text handling in the shell scripts
# ca-certificates      TLS to *.core.windows.net
# shadow-utils         useradd, build time only
# No --nodocs: tdnf 3.5.8 in Azure Linux 3.0 does not have that option and
# fails the build with "Error(908) : Command line error".
RUN set -eux; \
    tdnf -y install \
        azcopy-${AZCOPY_VERSION} \
        gawk \
        sed \
        grep \
        coreutils \
        ca-certificates \
        shadow-utils; \
    tdnf clean all; \
    rm -rf /var/cache/tdnf; \
    command -v azcopy; \
    azcopy --version; \
    awk --version | head -1

# Must match podSecurityContext in values.yaml. A Kyverno or Pod Security
# Admission restricted profile rejects a container that starts as root.
RUN groupadd --gid 1000 azcopy \
 && useradd --uid 1000 --gid 1000 --home-dir /work --no-create-home --shell /sbin/nologin azcopy

# The root filesystem is mounted read only. Every writable path is an emptyDir.
USER 1000:1000
WORKDIR /work

ENTRYPOINT ["/bin/sh"]
