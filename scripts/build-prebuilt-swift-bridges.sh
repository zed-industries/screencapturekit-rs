#!/usr/bin/env bash
# Builds the Swift bridge static libraries of this crate, `apple-cf` and
# `apple-metal` into one archive for builds that cannot run `swift build`.
#
# Each crate's build script links its library from the directory named by
# APPLE_SWIFT_BRIDGES_PREBUILT_DIR, so unpack the archive and point that
# variable at it.
#
# Usage: build-prebuilt-swift-bridges.sh APPLE_CF_DIR APPLE_METAL_DIR OUTPUT_DIR

set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "usage: $0 APPLE_CF_DIR APPLE_METAL_DIR OUTPUT_DIR" >&2
    exit 2
fi

screencapturekit_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
apple_cf_directory="$(cd "$1" && pwd)"
apple_metal_directory="$(cd "$2" && pwd)"
mkdir -p "$3"
output_directory="$(cd "$3" && pwd)"
archive="$output_directory/apple-swift-bridges-aarch64-macos.tar.gz"

# The oldest macOS the libraries run on. Targets older than 13 make the Swift
# compiler reference compatibility libraries that only Xcode's toolchain has.
deployment_target=13.0
# The macOS versions whose APIs the ScreenCaptureKit bridge compiles in. They
# must cover the `macos_*` Cargo feature the consumer enables, which implies
# the earlier ones.
screencapturekit_sdk_defines=(MACOS13 MACOS14 MACOS14_2 MACOS14_4 MACOS15)

work_directory="$(mktemp -d)"
trap 'rm -rf "$work_directory"' EXIT
mkdir -p "$work_directory/lib"

build_bridge() {
    local name="$1" crate_directory="$2" library="$3"
    shift 3
    local source_directory="$crate_directory/swift-bridge"
    local scratch_directory="$work_directory/$name"
    # Absolute paths would tie the archive to the machine that built it.
    swift build -c release --triple "arm64-apple-macosx$deployment_target" \
        --package-path "$source_directory" --scratch-path "$scratch_directory" \
        -Xswiftc -file-prefix-map -Xswiftc "$source_directory=$name" \
        -Xswiftc -file-prefix-map -Xswiftc "$scratch_directory=$name-build" \
        -Xswiftc -gnone \
        "$@"
    cp "$scratch_directory/release/lib$library.a" "$work_directory/lib/"
    strip -S "$work_directory/lib/lib$library.a"
}

build_bridge apple-cf "$apple_cf_directory" AppleCFBridge
build_bridge apple-metal "$apple_metal_directory" AppleMetalBridge
screencapturekit_flags=()
for define in "${screencapturekit_sdk_defines[@]}"; do
    screencapturekit_flags+=(-Xswiftc "-DSCREENCAPTUREKIT_HAS_${define}_SDK")
done
build_bridge screencapturekit "$screencapturekit_directory" ScreenCaptureKitBridge \
    "${screencapturekit_flags[@]}"

if grep -a -l -e "$work_directory" -e "$screencapturekit_directory" \
    -e "$apple_cf_directory" -e "$apple_metal_directory" "$work_directory"/lib/*.a; then
    echo "error: the libraries above still name a build directory" >&2
    exit 1
fi

COPYFILE_DISABLE=1 tar -czf "$archive" -C "$work_directory/lib" \
    libAppleCFBridge.a libAppleMetalBridge.a libScreenCaptureKitBridge.a
echo "$archive"
shasum -a 256 "$archive" | cut -d' ' -f1
