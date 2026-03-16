#!/bin/bash
# build-kairos-container.sh
#
# Builds a Kairos container image using kairos-init with Ubuntu 24.04 base
# and BCM-matching kernel. Used by Option B (raw disk image via dd).
#
# The container image is consumed by AuroraBoot to generate a raw disk
# image with proper COS partition layout.
#
# Usage:
#   ./build-kairos-container.sh [OPTIONS]
#
# After building, generate raw disk image with:
#   ./generate-raw-image.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/build/kairos-container"

# Defaults
KAIROS_INIT_VERSION="v0.6.2"
IMAGE_VERSION="1.0.0"
KERNEL_VERSION="${KAIROS_KERNEL_VERSION:-6.8.0-87-generic}"
IMAGE_REGISTRY="${KAIROS_CONTAINER_REGISTRY:-ttl.sh}"
IMAGE_TAG="kairos-bcm"
CUSTOM_TAG="${CUSTOM_TAG:-latest}"
SKIP_PUSH=false
CLEAN=false

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Builds a Kairos container image (Ubuntu 24.04 + BCM kernel) for Option B.

Options:
  --registry REG       Image registry (default: ttl.sh)
  --tag TAG            Image tag (default: latest)
  --kernel-version VER BCM kernel version (default: 6.8.0-87-generic)
  --skip-push          Build only, don't push to registry
  --clean              Remove existing build artifacts first
  -h, --help           Show this help

Outputs:
  build/kairos-container-image.ref   Full image reference

After building, generate raw disk image with:
  ./generate-raw-image.sh
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --registry)        IMAGE_REGISTRY="$2"; shift 2 ;;
        --tag)             CUSTOM_TAG="$2"; shift 2 ;;
        --kernel-version)  KERNEL_VERSION="$2"; shift 2 ;;
        --skip-push)       SKIP_PUSH=true; shift ;;
        --clean)           CLEAN=true; shift ;;
        -h|--help)         usage ;;
        *)                 echo "Unknown option: $1"; usage ;;
    esac
done

# ---- Preflight ----
if ! command -v docker &>/dev/null; then
    echo "ERROR: Docker not found. Install Docker first."
    exit 1
fi
if ! docker info &>/dev/null 2>&1; then
    echo "ERROR: Docker is not running or current user lacks permission."
    exit 1
fi

# ---- Clean ----
if [[ "$CLEAN" == "true" ]]; then
    echo "Cleaning build artifacts..."
    rm -rf "${BUILD_DIR}"
    rm -f "${PROJECT_DIR}/build/kairos-container-image.ref"
fi

mkdir -p "${BUILD_DIR}"

FULL_IMAGE="${IMAGE_REGISTRY}/${IMAGE_TAG}:${CUSTOM_TAG}"

echo "============================================"
echo " Building Kairos Container Image (Option B)"
echo "============================================"
echo " Base:        Ubuntu 24.04"
echo " Kernel:      ${KERNEL_VERSION}"
echo " Kairos-init: ${KAIROS_INIT_VERSION}"
echo " Image:       ${FULL_IMAGE}"
echo "============================================"
echo ""

# ---- Generate Dockerfile ----
echo "[1/4] Generating Dockerfile..."

cat > "${BUILD_DIR}/Dockerfile" <<DOCKERFILE
FROM quay.io/kairos/kairos-init:${KAIROS_INIT_VERSION} AS kairos-init
FROM ubuntu:24.04
ARG VERSION=${IMAGE_VERSION}

# Phase 1: Install Kairos components, skip default kernel
RUN --mount=type=bind,from=kairos-init,src=/kairos-init,dst=/kairos-init \\
  /kairos-init -s install --version "\${VERSION}" --skip-step installKernel

# Install BCM-matching kernel
RUN apt-get update && apt-get install -y --no-install-recommends \\
  linux-image-${KERNEL_VERSION} \\
  linux-modules-${KERNEL_VERSION} \\
  linux-modules-extra-${KERNEL_VERSION} \\
  && rm -rf /var/lib/apt/lists/*

# BCM compatibility packages
RUN apt-get update && apt-get install -y --no-install-recommends \\
  wget initramfs-tools ifupdown \\
  && rm -rf /var/lib/apt/lists/*

# Phase 2: Init — finds installed kernel, generates initramfs via dracut
RUN --mount=type=bind,from=kairos-init,src=/kairos-init,dst=/kairos-init \\
  /kairos-init -s init --version "\${VERSION}"

# Copy BCM overlay files (compat fixes, sync scripts, network config)
COPY overlay/ /
DOCKERFILE

# ---- Copy overlay ----
echo "[2/4] Copying overlay files..."
if [[ -d "${SCRIPT_DIR}/canvos/overlay/files" ]]; then
    mkdir -p "${BUILD_DIR}/overlay"
    cp -r "${SCRIPT_DIR}/canvos/overlay/files/"* "${BUILD_DIR}/overlay/"
else
    echo "WARNING: No overlay files found at ${SCRIPT_DIR}/canvos/overlay/files"
    mkdir -p "${BUILD_DIR}/overlay"
fi

# ---- Build ----
echo "[3/4] Building container image (this may take a while)..."
docker build \
    --build-arg VERSION="${IMAGE_VERSION}" \
    -t "${FULL_IMAGE}" \
    "${BUILD_DIR}"

# ---- Validate ----
echo ""
echo "Validating build..."

# Check kairos-agent is present
if docker run --rm "${FULL_IMAGE}" kairos-agent version 2>/dev/null; then
    echo "  [OK] kairos-agent present"
else
    echo "  [WARN] kairos-agent version check failed (may still work)"
fi

# Check kernel version
BUILT_KERNEL=$(docker run --rm "${FULL_IMAGE}" bash -c 'ls /boot/vmlinuz-* 2>/dev/null | head -1 | sed "s|/boot/vmlinuz-||"' 2>/dev/null || true)
if [[ "$BUILT_KERNEL" == "$KERNEL_VERSION" ]]; then
    echo "  [OK] Kernel matches: ${BUILT_KERNEL}"
else
    echo "  [WARN] Kernel mismatch: expected ${KERNEL_VERSION}, got ${BUILT_KERNEL:-none}"
fi

# ---- Push ----
if [[ "$SKIP_PUSH" == "true" ]]; then
    echo ""
    echo "Skipping push (--skip-push)"
else
    echo "[4/4] Pushing to registry..."
    docker push "${FULL_IMAGE}"
fi

# ---- Write image ref ----
mkdir -p "${PROJECT_DIR}/build"
echo "${FULL_IMAGE}" > "${PROJECT_DIR}/build/kairos-container-image.ref"

IMAGE_SIZE=$(docker image inspect "${FULL_IMAGE}" --format='{{.Size}}' 2>/dev/null || echo "unknown")
if [[ "$IMAGE_SIZE" != "unknown" ]]; then
    IMAGE_SIZE="$(( IMAGE_SIZE / 1048576 )) MB"
fi

echo ""
echo "============================================"
echo " Build complete!"
echo "============================================"
echo " Image:  ${FULL_IMAGE}"
echo " Size:   ${IMAGE_SIZE}"
echo " Ref:    build/kairos-container-image.ref"
echo ""
echo " Next: ./generate-raw-image.sh"
echo "============================================"
