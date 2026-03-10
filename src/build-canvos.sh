#!/bin/bash
# build-canvos.sh
#
# Builds a Kairos edge installer ISO using the CanvOS submodule.
# Copies build artifacts to the top-level build/ directory.
#
# Usage:
#   ./build-canvos.sh [OPTIONS]
#
# After building, extract PXE artifacts with:
#   ./extract-kairos-pxe.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CANVOS_DIR="${PROJECT_DIR}/CanvOS"
BUILD_DIR="${PROJECT_DIR}/build"

# Defaults
OS_DISTRIBUTION="ubuntu"
OS_VERSION="22.04"
K8S_DISTRIBUTION="k3s"
CUSTOM_TAG="bcm-test"
IMAGE_REGISTRY="ttl.sh"
ISO_NAME="palette-edge-installer"
ARCH="amd64"
SKIP_BUILD=false
CLEAN=false

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Builds a Kairos edge installer ISO via the CanvOS submodule.

Options:
  --os-version VER     Ubuntu version (default: 22.04)
  --k8s-dist DIST      k3s or rke2 (default: k3s)
  --custom-tag TAG     Custom tag (default: bcm-test)
  --registry REG       Image registry (default: ttl.sh)
  --iso-name NAME      ISO filename (default: palette-edge-installer)
  --skip-build         Skip build, just copy existing artifacts
  --clean              Clean build artifacts before building
  -h, --help           Show this help

Outputs:
  build/${ISO_NAME}.iso
  build/${ISO_NAME}.iso.sha256

After building, extract PXE artifacts with:
  ./extract-kairos-pxe.sh
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --os-version)    OS_VERSION="$2"; shift 2 ;;
        --k8s-dist)      K8S_DISTRIBUTION="$2"; shift 2 ;;
        --custom-tag)    CUSTOM_TAG="$2"; shift 2 ;;
        --registry)      IMAGE_REGISTRY="$2"; shift 2 ;;
        --iso-name)      ISO_NAME="$2"; shift 2 ;;
        --skip-build)    SKIP_BUILD=true; shift ;;
        --clean)         CLEAN=true; shift ;;
        -h|--help)       usage ;;
        *)               echo "Unknown option: $1"; usage ;;
    esac
done

# ---- Preflight ----
if [[ ! -d "$CANVOS_DIR" ]]; then
    echo "ERROR: CanvOS directory not found at $CANVOS_DIR"
    echo "Initialize the submodule: git submodule update --init"
    exit 1
fi

if [[ ! -f "${CANVOS_DIR}/earthly.sh" ]]; then
    echo "ERROR: earthly.sh not found in CanvOS directory"
    echo "Initialize the submodule: git submodule update --init"
    exit 1
fi

if [[ "$SKIP_BUILD" != "true" ]]; then
    if ! command -v docker &>/dev/null; then
        echo "ERROR: Docker not found. Install Docker first."
        exit 1
    fi
    if ! docker info &>/dev/null 2>&1; then
        echo "ERROR: Docker is not running or current user lacks permission."
        exit 1
    fi
fi

# ---- Clean ----
if [[ "$CLEAN" == "true" ]]; then
    echo "Cleaning build artifacts..."
    rm -rf "${BUILD_DIR}"
    rm -rf "${CANVOS_DIR}/build"
fi

mkdir -p "${BUILD_DIR}"

# ---- Generate .arg ----
if [[ "$SKIP_BUILD" != "true" ]]; then
    echo "============================================"
    echo " Building CanvOS Kairos ISO"
    echo "============================================"
    echo " OS:          ${OS_DISTRIBUTION} ${OS_VERSION}"
    echo " K8s:         ${K8S_DISTRIBUTION}"
    echo " Tag:         ${CUSTOM_TAG}"
    echo " Registry:    ${IMAGE_REGISTRY}"
    echo " ISO Name:    ${ISO_NAME}"
    echo " Arch:        ${ARCH}"
    echo "============================================"
    echo ""

    # Generate .arg from template in src/canvos/
    ARG_TEMPLATE="${SCRIPT_DIR}/canvos/.arg.template"
    if [[ ! -f "$ARG_TEMPLATE" ]]; then
        echo "ERROR: .arg.template not found at $ARG_TEMPLATE"
        exit 1
    fi
    export CUSTOM_TAG IMAGE_REGISTRY OS_DISTRIBUTION OS_VERSION K8S_DISTRIBUTION ISO_NAME ARCH
    envsubst < "$ARG_TEMPLATE" > "${CANVOS_DIR}/.arg"

    # Copy any custom overlay files into CanvOS
    if [[ -d "${SCRIPT_DIR}/canvos/overlay" ]]; then
        echo "Copying custom overlay files into CanvOS..."
        cp -r "${SCRIPT_DIR}/canvos/overlay/"* "${CANVOS_DIR}/overlay/" 2>/dev/null || true
    fi

    echo "[1/2] Running CanvOS build (this may take a while)..."
    cd "${CANVOS_DIR}"
    ./earthly.sh +iso --ARCH="${ARCH}"
    cd "${PROJECT_DIR}"
fi

# ---- Copy artifacts ----
echo "[2/2] Copying artifacts to build/..."

ISO_FILE="${CANVOS_DIR}/build/${ISO_NAME}.iso"
SHA_FILE="${CANVOS_DIR}/build/${ISO_NAME}.iso.sha256"

if [[ ! -f "$ISO_FILE" ]]; then
    echo "ERROR: ISO not found at $ISO_FILE"
    echo "Build may have failed, or use --skip-build with an existing ISO."
    exit 1
fi

cp "${ISO_FILE}" "${BUILD_DIR}/"
[[ -f "$SHA_FILE" ]] && cp "${SHA_FILE}" "${BUILD_DIR}/"

ISO_SIZE=$(du -h "${BUILD_DIR}/${ISO_NAME}.iso" | cut -f1)

echo ""
echo "============================================"
echo " Build complete!"
echo "============================================"
echo " ${BUILD_DIR}/${ISO_NAME}.iso (${ISO_SIZE})"
[[ -f "${BUILD_DIR}/${ISO_NAME}.iso.sha256" ]] && echo " ${BUILD_DIR}/${ISO_NAME}.iso.sha256"
echo ""
echo " Next: ./extract-kairos-pxe.sh"
echo "============================================"
