# azcopy on Azure Linux 3.0. No interpreter beyond the base shell: the scripts
# are POSIX sh plus awk.
#
#   docker build --platform linux/amd64 -t ghcr.io/dobbo-ca/containers/azcopy-move:10.32.6 .
#   docker push ghcr.io/dobbo-ca/containers/azcopy-move:10.32.6
#
# Why Azure Linux:
#   - Microsoft packages azcopy for tdnf, so no tarball and no version drift.
#   - glibc. Alpine and musl are NOT supported; azcopy has no apk package.
#
ARG BASE_IMAGE=mcr.microsoft.com/azurelinux/base/core:3.0
FROM ${BASE_IMAGE}

# An ARG declared before FROM leaves scope at the FROM. Redeclare it, or the
# base.name label below silently renders empty.
ARG BASE_IMAGE

# org.opencontainers.image.source is what makes GitHub attach this package to
# the repository, which is in turn what puts the README on the package page and
# gives it the repo's licence and visibility. Without it the package is an
# orphan with a blank page. The rest are conventional OCI metadata.
LABEL org.opencontainers.image.source="https://github.com/dobbo-ca/azcopy-move" \
      org.opencontainers.image.url="https://github.com/dobbo-ca/azcopy-move" \
      org.opencontainers.image.documentation="https://github.com/dobbo-ca/azcopy-move/blob/main/containers/azcopy/CONTAINER.md" \
      org.opencontainers.image.title="azcopy-move" \
      org.opencontainers.image.description="azcopy and a POSIX userland, nothing else. Runs the azcopy-move copy/verify/delete scripts as a Kubernetes CronJob." \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.base.name="${BASE_IMAGE}"

# Single source of truth for the azcopy version. CI reads this ARG for the
# chart's appVersion and for the image's azcopy alias tag. An unpinned
# `tdnf install azcopy` resolves to whatever is newest in the ms-oss repo,
# which can be a prerelease (verified: azcopy-10.33.0_beta-1 today) — always
# pin the exact version here.
ARG AZCOPY_VERSION=10.32.6

# Declared after the ARG so it can reference it. This names the version of the
# software IN the image, which is azcopy — not the image's own semver.
LABEL org.opencontainers.image.version="${AZCOPY_VERSION}"

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
    awk --version; \
    case "$(azcopy --version)" in \
      *"${AZCOPY_VERSION}"*) ;; \
      *) echo "installed azcopy does not match ARG AZCOPY_VERSION=${AZCOPY_VERSION}" >&2; exit 1 ;; \
    esac

# Must match podSecurityContext in values.yaml. A Kyverno or Pod Security
# Admission restricted profile rejects a container that starts as root.
RUN groupadd --gid 1000 azcopy \
 && useradd --uid 1000 --gid 1000 --home-dir /work --no-create-home --shell /sbin/nologin azcopy

# The root filesystem is mounted read only. Every writable path is an emptyDir.
USER 1000:1000
WORKDIR /work

ENTRYPOINT ["/bin/sh"]
