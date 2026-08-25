#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SAMPLE_COUNT="${1:-${MARKLOOK_BENCHMARK_SAMPLES:-20}}"
FULL_RUN="${MARKLOOK_BENCHMARK_FULL_RUN:-0}"

if [[ "$(uname -m)" != "arm64" ]]; then
    echo "Reload performance targets are defined for Apple Silicon; this runner requires arm64." >&2
    exit 2
fi

case "$SAMPLE_COUNT" in
    ""|*[!0-9]*)
        echo "Sample count must be an integer from 20 through 100." >&2
        exit 2
        ;;
esac

if (( SAMPLE_COUNT < 20 || SAMPLE_COUNT > 100 )); then
    echo "Sample count must be from 20 through 100 so p95 is meaningful." >&2
    exit 2
fi

if [[ "$FULL_RUN" != "0" && "$FULL_RUN" != "1" ]]; then
    echo "MARKLOOK_BENCHMARK_FULL_RUN must be 0 or 1." >&2
    exit 2
fi

OUTPUT_DIR="$ROOT_DIR/.build/reload-benchmarks"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DERIVED_DATA_DIR="$OUTPUT_DIR/DerivedData-$TIMESTAMP"
RESULT_DIRECTORY="$OUTPUT_DIR/ReloadBenchmarks-$TIMESTAMP"
SHARED_SOURCE_PACKAGES_DIR="$ROOT_DIR/.build/SourcePackages"
mkdir -p "$RESULT_DIRECTORY"

PACKAGE_FLAGS=(-clonedSourcePackagesDirPath "$SHARED_SOURCE_PACKAGES_DIR")
if [[ -d "$SHARED_SOURCE_PACKAGES_DIR/checkouts" ]]; then
    PACKAGE_FLAGS+=(-disableAutomaticPackageResolution)
fi

export MARKLOOK_RUN_BENCHMARKS=1
export MARKLOOK_BENCHMARK_SAMPLES="$SAMPLE_COUNT"
export MARKLOOK_BENCHMARK_FULL_RUN="$FULL_RUN"

echo "Running MarkLook Release reload benchmarks with $SAMPLE_COUNT samples per size."

xcodebuild \
    -quiet \
    -project "$ROOT_DIR/MarkLook.xcodeproj" \
    -scheme MarkLook \
    -configuration Release \
    -destination "platform=macOS,arch=arm64" \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    "${PACKAGE_FLAGS[@]}" \
    -enableCodeCoverage NO \
    CLANG_COVERAGE_MAPPING=NO \
    CODE_SIGNING_ALLOWED=NO \
    ENABLE_TESTABILITY=YES \
    build-for-testing

RELEASE_PRODUCTS_DIR="$DERIVED_DATA_DIR/Build/Products/Release"
TEST_BINARY="$(find "$RELEASE_PRODUCTS_DIR" \
    -path '*/MarkLookTests.xctest/Contents/MacOS/MarkLookTests' \
    -type f \
    -print \
    -quit)"
COVERAGE_BINARIES=(
    "$RELEASE_PRODUCTS_DIR/MarkLook.app/Contents/MacOS/MarkLook"
    "$TEST_BINARY"
)

for binary in "${COVERAGE_BINARIES[@]}"; do
    if [[ ! -f "$binary" ]]; then
        echo "Expected Release benchmark binary was not produced: $binary" >&2
        exit 1
    fi

    if otool -l "$binary" | grep -Eq '__LLVM_COV|__llvm_prf|__llvm_cov' \
        || nm "$binary" | grep -Eq '__llvm_prf|__llvm_profile'; then
        echo "Coverage instrumentation is still present in $binary; refusing to benchmark." >&2
        exit 1
    fi
done

echo "Verified Release app and test binaries contain no LLVM coverage sections or symbols."

XCTESTRUN_FILE="$(find "$DERIVED_DATA_DIR/Build/Products" -name 'MarkLook_*.xctestrun' -print -quit)"
if [[ -z "$XCTESTRUN_FILE" ]]; then
    echo "Xcode did not produce a MarkLook xctestrun file." >&2
    exit 1
fi

UNIT_TEST_ENVIRONMENT=":TestConfigurations:0:TestTargets:0:EnvironmentVariables"
/usr/libexec/PlistBuddy \
    -c "Delete $UNIT_TEST_ENVIRONMENT:MARKLOOK_RUN_BENCHMARKS" \
    "$XCTESTRUN_FILE" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy \
    -c "Delete $UNIT_TEST_ENVIRONMENT:MARKLOOK_BENCHMARK_SAMPLES" \
    "$XCTESTRUN_FILE" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy \
    -c "Delete $UNIT_TEST_ENVIRONMENT:MARKLOOK_BENCHMARK_FULL_RUN" \
    "$XCTESTRUN_FILE" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy \
    -c "Add $UNIT_TEST_ENVIRONMENT:MARKLOOK_RUN_BENCHMARKS string 1" \
    "$XCTESTRUN_FILE"
/usr/libexec/PlistBuddy \
    -c "Add $UNIT_TEST_ENVIRONMENT:MARKLOOK_BENCHMARK_SAMPLES string $SAMPLE_COUNT" \
    "$XCTESTRUN_FILE"
/usr/libexec/PlistBuddy \
    -c "Add $UNIT_TEST_ENVIRONMENT:MARKLOOK_BENCHMARK_FULL_RUN string $FULL_RUN" \
    "$XCTESTRUN_FILE"

BENCHMARK_TESTS=(
    "ReloadPerformanceTests/testCoreReloadP95Budget50KB|Core-50KB"
    "ReloadPerformanceTests/testCoreReloadP95Budget100KB|Core-100KB"
    "ReloadPerformanceTests/testCoreReloadP95Budget1MB|Core-1MB"
    "ReloadPerformanceTests/testCoreReloadP95Budget5MB|Core-5MB"
    "ReloadPerformanceTests/testTwentyAtomicSavesPerSecondEventuallyDisplaysFinalBytes|Atomic-Burst"
)
OVERALL_STATUS=0

for entry in "${BENCHMARK_TESTS[@]}"; do
    TEST_IDENTIFIER="${entry%%|*}"
    RESULT_NAME="${entry#*|}"
    echo "Running $RESULT_NAME."
    if xcodebuild \
        -xctestrun "$XCTESTRUN_FILE" \
        -destination "platform=macOS,arch=arm64" \
        -enableCodeCoverage NO \
        CLANG_COVERAGE_MAPPING=NO \
        -resultBundlePath "$RESULT_DIRECTORY/$RESULT_NAME.xcresult" \
        test-without-building \
        -only-testing:"MarkLookTests/$TEST_IDENTIFIER"
    then
        :
    else
        OVERALL_STATUS=1
    fi
done

echo "Benchmark result bundles: $RESULT_DIRECTORY"
exit "$OVERALL_STATUS"
