#!/usr/bin/env bash
# Build libprojectM for Apple tvOS (device + simulator) and package as an XCFramework.
#
# Prerequisites:
#   - Xcode 14.2+ (for tvOS 16 SDK) or Xcode 15+ (for tvOS 17 SDK)
#   - CMake 3.26+
#   - The three guarded upstream edits applied (GladLoader, PlatformLibraryNames, GLResolver)
#
# Output: apps/tvos/Frameworks/libprojectM.xcframework
#
# Usage:
#   ./apps/tvos/scripts/build-libprojectm-xcframework.sh [--clean]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
OUT_DIR="${REPO_ROOT}/apps/tvos16/Frameworks"
BUILD_ROOT="${REPO_ROOT}/build-tvos"
TOOLCHAIN="${SCRIPT_DIR}/toolchains/tvos.cmake"
XCFRAMEWORK_NAME="libprojectM.xcframework"
XCFRAMEWORK_PATH="${OUT_DIR}/${XCFRAMEWORK_NAME}"

# The CMake target name for libprojectM (see src/libprojectM/CMakeLists.txt).
CMAKE_TARGET="projectM"

# The static archive name CMake produces. libprojectM ships as libprojectM-4.a.
LIB_ARCHIVE_NAME="libprojectM-4.a"

if [[ ! -f "${TOOLCHAIN}" ]]; then
    echo "ERROR: toolchain file not found at ${TOOLCHAIN}" >&2
    exit 1
fi

if [[ "${1-}" == "--clean" ]]; then
    echo "Cleaning ${BUILD_ROOT} and ${XCFRAMEWORK_PATH}"
    rm -rf "${BUILD_ROOT}" "${XCFRAMEWORK_PATH}"
fi

mkdir -p "${OUT_DIR}" "${BUILD_ROOT}"

configure_and_build() {
    local sdk="$1"      # appletvos | appletvsimulator
    local build_dir="${BUILD_ROOT}/${sdk}"

    # Resolve the SDK path for the cross-compilation sysroot.
    local sdk_path
    sdk_path="$(xcrun --sdk "${sdk}" --show-sdk-path)"

    echo "=== Configuring ${sdk} ==="
    # Use Unix Makefiles instead of Xcode generator to avoid the "new build system"
    # error where custom commands (GenerateScanner) are attached to multiple targets.
    cmake -S "${REPO_ROOT}" -B "${build_dir}" \
        -G "Unix Makefiles" \
        -DCMAKE_TOOLCHAIN_FILE="${TOOLCHAIN}" \
        -DCMAKE_OSX_SYSROOT="${sdk_path}" \
        -DCMAKE_BUILD_TYPE=Release

    echo "=== Building ${sdk} ==="
    cmake --build "${build_dir}" --config Release --target "${CMAKE_TARGET}" -j "$(sysctl -n hw.ncpu)"
}

find_archive() {
    local sdk="$1"
    local build_dir="${BUILD_ROOT}/${sdk}"
    # Unix Makefiles generator puts the lib directly under src/libprojectM/
    local candidate
    candidate=$(find "${build_dir}" -type f -name "${LIB_ARCHIVE_NAME}" | head -n 1)
    if [[ -z "${candidate}" ]]; then
        echo "ERROR: could not locate ${LIB_ARCHIVE_NAME} under ${build_dir}" >&2
        exit 1
    fi
    printf '%s' "${candidate}"
}

configure_and_build appletvos
configure_and_build appletvsimulator

DEVICE_LIB="$(find_archive appletvos)"
SIM_LIB="$(find_archive appletvsimulator)"

echo "=== Creating XCFramework ==="
echo "Device lib:    ${DEVICE_LIB}"
echo "Simulator lib: ${SIM_LIB}"

# Headers: merge the static API headers with the CMake-generated headers (export macros, version).
HEADERS_SRC="${REPO_ROOT}/src/api/include"
if [[ ! -d "${HEADERS_SRC}/projectM-4" ]]; then
    echo "ERROR: expected headers at ${HEADERS_SRC}/projectM-4" >&2
    exit 1
fi

# Stage a merged headers directory so xcodebuild -create-xcframework gets everything.
MERGED_HEADERS="${BUILD_ROOT}/merged-headers"
rm -rf "${MERGED_HEADERS}"
mkdir -p "${MERGED_HEADERS}/projectM-4"
cp "${HEADERS_SRC}"/projectM-4/*.h "${MERGED_HEADERS}/projectM-4/"
# Copy generated headers (projectM_export.h, version.h, etc.) from the device build.
DEVICE_GEN="${BUILD_ROOT}/appletvos/src/api/include/projectM-4"
if [[ -d "${DEVICE_GEN}" ]]; then
    cp "${DEVICE_GEN}"/*.h "${MERGED_HEADERS}/projectM-4/"
fi

rm -rf "${XCFRAMEWORK_PATH}"
xcodebuild -create-xcframework \
    -library "${DEVICE_LIB}" -headers "${MERGED_HEADERS}" \
    -library "${SIM_LIB}"    -headers "${MERGED_HEADERS}" \
    -output "${XCFRAMEWORK_PATH}"

echo ""
echo "=== XCFramework built at ${XCFRAMEWORK_PATH} ==="
ls "${XCFRAMEWORK_PATH}"
