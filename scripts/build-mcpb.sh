#!/bin/bash
# Builds the universal CheContainerMCP binary, signs it with Developer ID (hardened runtime),
# notarizes it (unless SKIP_NOTARIZE=1), writes the .sha256 and packs the .mcpb.
# A failed or interrupted run removes this version's artifacts so nothing half-built looks shippable.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"
NAME=CheContainerMCP
SERVER_DIR="mcpb/server"
BINARY="$SERVER_DIR/$NAME"

VERSION=$(grep -E 'static let current = "' Sources/CheContainerMCPCore/Version.swift | sed -E 's/.*"([^"]+)".*/\1/')
[[ -n "$VERSION" ]] || { echo "✗ cannot read AppVersion.current" >&2; exit 1; }
MANIFEST_VERSION=$(python3 -c 'import json;print(json.load(open("mcpb/manifest.json"))["version"])')
[[ "$VERSION" == "$MANIFEST_VERSION" ]] || {
    echo "✗ Version drift: Version.swift=$VERSION, mcpb/manifest.json=$MANIFEST_VERSION" >&2; exit 1; }
PACKED="mcpb/che-container-mcp-$VERSION.mcpb"

cleanup() { rm -f "$BINARY" "$BINARY.sha256" "$PACKED" "$PACKED.sha256"; }
trap 'status=$?; if [[ $status -ne 0 ]]; then cleanup; echo "✗ build failed; artifacts removed" >&2; fi' EXIT
cleanup

echo "[1/5] Building universal release binary ($VERSION)"
swift build -c release --arch arm64 --arch x86_64
BUILT="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/$NAME"
[[ -f "$BUILT" ]] || { echo "✗ $BUILT not found" >&2; exit 1; }
ARCHS=$(lipo -archs "$BUILT")
[[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] || { echo "✗ not universal: $ARCHS" >&2; exit 1; }
mkdir -p "$SERVER_DIR"
cp "$BUILT" "$BINARY"
[[ "$("$BINARY" --version)" == "$NAME $VERSION" ]] || { echo "✗ --version does not report $VERSION" >&2; exit 1; }

echo "[2/5] Signing with Developer ID (hardened runtime)"
: "${DEVELOPER_ID:?DEVELOPER_ID not set}"
codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$BINARY"
codesign --verify --strict --verbose=2 "$BINARY"

if [[ "${SKIP_NOTARIZE:-}" == "1" ]]; then
    echo "[3/5] Notarization skipped (SKIP_NOTARIZE=1) — this binary is not distributable"
else
    echo "[3/5] Notarizing (1-15 minutes)"
    : "${NOTARY_PROFILE:?NOTARY_PROFILE not set}"
    ZIP="$(mktemp -d)/$NAME.zip"
    ditto -c -k --keepParent "$BINARY" "$ZIP"
    # Capture first: `tee | grep -q` would SIGPIPE tee and fail the pipeline under pipefail.
    NOTARY_OUT=$(xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1) || true
    echo "$NOTARY_OUT" >&2
    grep -q "status: Accepted" <<<"$NOTARY_OUT" || { echo "✗ notarization was not accepted" >&2; exit 1; }
    spctl --assess --type install --verbose=2 "$BINARY"
fi

echo "[4/5] Writing checksum"
shasum -a 256 "$BINARY" | awk '{print $1}' > "$BINARY.sha256"

echo "[5/5] Packing $PACKED"
if command -v mcpb >/dev/null 2>&1; then
    (cd mcpb && mcpb pack . "$(basename "$PACKED")")
    shasum -a 256 "$PACKED" | awk '{print $1}' > "$PACKED.sha256"
else
    echo "ℹ mcpb CLI not installed; skipped packing (npm i -g @anthropic-ai/mcpb)"
fi
echo "✓ $BINARY ($ARCHS)"
