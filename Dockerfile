# syntax=docker/dockerfile:1

# renovate: datasource=github-releases depName=ggml-org/llama.cpp versioning=regex:^b(?<major>\d+)$
ARG LLAMA_CPP_REF=b9466

ARG SCCACHE_REDIS_ENDPOINT=
ARG SCCACHE_LOG=info
ARG SCCACHE_VERSION=v0.15.0

FROM debian:trixie-slim AS build
ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        cmake \
        curl \
        git \
        libssl-dev \
        mold \
        npm \
        rust-all \
        spirv-headers \
        tar \
        glslc \
        libvulkan-dev \
        ninja-build \
        pkg-config

# Install sccache with remote cache features enabled.
ARG SCCACHE_VERSION
RUN <<EOS
set -eu
case "${TARGETARCH}" in
    amd64) sccache_arch='x86_64-unknown-linux-musl' ;;
    arm64) sccache_arch='aarch64-unknown-linux-musl' ;;
    *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;;
esac
curl -fsSL -o /tmp/sccache.tar.gz \
    "https://github.com/mozilla/sccache/releases/download/${SCCACHE_VERSION}/sccache-${SCCACHE_VERSION}-${sccache_arch}.tar.gz"
tar -xzf /tmp/sccache.tar.gz -C /tmp
install "/tmp/sccache-${SCCACHE_VERSION}-${sccache_arch}/sccache" /usr/local/bin/sccache
rm -rf /tmp/sccache.tar.gz "/tmp/sccache-${SCCACHE_VERSION}-${sccache_arch}"
EOS

WORKDIR /src
ARG LLAMA_CPP_REF
RUN git clone --depth 1 --branch "${LLAMA_CPP_REF}" https://github.com/ggml-org/llama.cpp.git

WORKDIR /src/llama.cpp

RUN cmake -S . -B build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_SHARED_LIBS=OFF \
      -DCMAKE_C_COMPILER_LAUNCHER=sccache \
      -DCMAKE_CXX_COMPILER_LAUNCHER=sccache \
      -DCMAKE_EXE_LINKER_FLAGS=-fuse-ld=mold \
      -DCMAKE_SHARED_LINKER_FLAGS=-fuse-ld=mold \
      -DCMAKE_MODULE_LINKER_FLAGS=-fuse-ld=mold \
      -DGGML_VULKAN=ON \
      -DLLAMA_BUILD_BORINGSSL=ON \
      -DLLAMA_BUILD_SERVER=ON \
      -DLLAMA_BUILD_UI=ON \
      -DLLAMA_LLGUIDANCE=ON

ARG SCCACHE_REDIS_ENDPOINT
ARG SCCACHE_LOG
ENV SCCACHE_DIR=/root/.cache/sccache
RUN --mount=type=cache,target=/root/.cache/sccache,sharing=locked <<EOS
set -eu
if [ -z "${SCCACHE_REDIS_ENDPOINT:-}" ]; then
  unset SCCACHE_REDIS_ENDPOINT
fi
sccache --start-server
sccache --show-stats

export RUSTC_WRAPPER=$(which sccache)
cmake --build build --target llama-server llama-cli -j"$(nproc)"

sccache --show-stats
sccache --stop-server
EOS

FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive
# Pull Mesa from trixie-backports while keeping the rest of runtime on trixie.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    echo 'deb http://deb.debian.org/debian trixie-backports main' > /etc/apt/sources.list.d/trixie-backports.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        libgomp1 \
        libvulkan1 \
    && apt-get install -y --no-install-recommends -t trixie-backports \
        mesa-vulkan-drivers \
    && rm -f /etc/apt/sources.list.d/trixie-backports.list

COPY --from=build /src/llama.cpp/build/bin/llama-server /usr/local/bin/llama-server

EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/llama-server"]
