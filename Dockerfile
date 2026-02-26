# syntax=docker/dockerfile:1.21
FROM debian:stable-slim AS build

ARG DEBIAN_FRONTEND=noninteractive
# renovate: datasource=github-releases depName=ggml-org/llama.cpp versioning=regex:^b(?<major>\d+)$
ARG LLAMA_CPP_REF=b8156

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        ccache \
        cmake \
        git \
		rust-all \
        glslc \
        libvulkan-dev \
        ninja-build \
        pkg-config

WORKDIR /src
RUN git clone --depth 1 --branch "${LLAMA_CPP_REF}" https://github.com/ggml-org/llama.cpp.git

WORKDIR /src/llama.cpp
RUN cmake -S . -B build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_SHARED_LIBS=OFF \
      -DCMAKE_C_COMPILER_LAUNCHER=ccache \
      -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
      -DGGML_VULKAN=ON \
      -DLLAMA_BUILD_BORINGSSL=ON \
      -DLLAMA_BUILD_SERVER=ON \
	  -DLLAMA_LLGUIDANCE=ON
RUN cmake --build build --target llama-server -j"$(nproc)"

FROM golang:bookworm AS llama-swap-build

# renovate: datasource=github-releases depName=mostlygeek/llama-swap versioning=regex:^v(?<major>\d+)$
ARG LLAMA_SWAP_REF=v195
ARG TARGETARCH

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update \
    && apt-get install -y --no-install-recommends \
        git \
        make \
        nodejs \
        npm

WORKDIR /src
RUN git clone --depth 1 --branch "${LLAMA_SWAP_REF}" https://github.com/mostlygeek/llama-swap.git

WORKDIR /src/llama-swap
RUN --mount=type=cache,target=/go/pkg/mod,sharing=locked \
    --mount=type=cache,target=/root/.cache/go-build,sharing=locked \
    --mount=type=cache,target=/root/.npm,sharing=locked \
    mkdir -p /out \
    && make clean all \
    && cp "build/llama-swap-linux-${TARGETARCH:-amd64}" /out/llama-swap

FROM debian:stable-slim

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        libgomp1 \
        libvulkan1 \
        mesa-vulkan-drivers

COPY --from=build /src/llama.cpp/build/bin/llama-server /usr/local/bin/llama-server
COPY --from=llama-swap-build /out/llama-swap /usr/local/bin/llama-swap

EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/llama-swap"]
