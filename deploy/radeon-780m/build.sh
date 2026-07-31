#!/bin/bash
# Build the Vulkan backend for Radeon 780M (gfx1103).
#
# Distro glslc is usually too old to compile llama.cpp's feature-test shaders.
# CMake probes each extension and silently omits any it cannot build, so an old
# glslc yields a quietly reduced binary. This fetches a current shaderc.
set -euo pipefail

REPO_DIR="${REPO_DIR:-/root/llama.cpp}"
BUILD_DIR="${BUILD_DIR:-$REPO_DIR/build-vk2}"
SDK_DIR="${SDK_DIR:-/root/vksdk}"
JOBS="${JOBS:-$(nproc)}"

echo "== deps =="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  build-essential cmake ninja-build git ccache pkg-config curl \
  libcurl4-openssl-dev libvulkan-dev vulkan-tools spirv-headers \
  spirv-tools glslang-tools mesa-vulkan-drivers

echo "== newer Mesa (RADV) from kisak PPA =="
# 26.x measured +13-22% on prompt processing vs Ubuntu 24.04's 25.2.8
apt-get install -y -qq software-properties-common
add-apt-repository -y ppa:kisak/kisak-mesa
apt-get update -qq
apt-get install -y -qq --allow-downgrades mesa-vulkan-drivers libdrm2 libdrm-amdgpu1

echo "== current glslc =="
if [ ! -x "$(find "$SDK_DIR" -name glslc -type f 2>/dev/null | head -1)" ]; then
  mkdir -p "$SDK_DIR"
  curl -sL -o /tmp/vulkansdk.tar.xz \
    "https://sdk.lunarg.com/sdk/download/latest/linux/vulkan_sdk.tar.xz"
  tar xJf /tmp/vulkansdk.tar.xz -C "$SDK_DIR" --wildcards '*/x86_64/bin/glslc'
  rm -f /tmp/vulkansdk.tar.xz
fi
GLSLC=$(find "$SDK_DIR" -name glslc -type f | head -1)
echo "glslc: $($GLSLC --version | head -1)"

echo "== configure =="
export CCACHE_DIR="${CCACHE_DIR:-/root/.ccache}"
cmake -B "$BUILD_DIR" -S "$REPO_DIR" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_VULKAN=ON \
  -DGGML_NATIVE=ON \
  -DLLAMA_CURL=ON \
  -DLLAMA_BUILD_TESTS=OFF \
  -DGGML_CCACHE=ON \
  -DVulkan_GLSLC_EXECUTABLE="$GLSLC"

echo "== build =="
cmake --build "$BUILD_DIR" -j "$JOBS"

echo "== device check =="
"$BUILD_DIR/bin/llama-bench" --list-devices
