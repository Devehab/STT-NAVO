#!/bin/bash
# Builds build/Navo.app with swiftc directly (no SwiftPM needed, only the Swift compiler).
#   bash scripts/build-app.sh            release build
#   bash scripts/build-app.sh debug      debug build
# Signs with your "Apple Development" certificate when one is in the keychain (keeps the
# Accessibility permission across rebuilds), otherwise ad-hoc. Override with NAVO_SIGN_IDENTITY.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/Navo.app"
LOG="$BUILD_DIR/build.log"
mkdir -p "$BUILD_DIR"
# shellcheck source=signing.sh
. "$ROOT/scripts/signing.sh"

# The SDK must be built by the same Swift version as the compiler. A half-finished
# Command Line Tools update can leave a newer default SDK next to an older swiftc,
# so pick the newest installed macOS SDK whose Swift interface matches the compiler.
pick_sdk() {
  if [ -n "${NAVO_SDK:-}" ]; then
    echo "$NAVO_SDK"
    return
  fi
  local want default sdk iface have i
  want="$(swiftc --version 2>&1 | sed -n 's/.*Apple Swift version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -1)"
  default="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
  local candidates=()
  [ -n "$default" ] && candidates+=("$default")
  for sdk in "$(dirname "${default:-/Library/Developer/CommandLineTools/SDKs/x}")"/MacOSX*.sdk \
             /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk \
             /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX*.sdk; do
    [ -d "$sdk" ] && candidates+=("$sdk")
  done
  # Globs list SDKs oldest to newest, so walk backwards to prefer the newest match.
  for (( i=${#candidates[@]}-1; i>=0; i-- )); do
    sdk="${candidates[$i]}"
    [ "$sdk" = "$default" ] && [ "$i" -ne 0 ] && continue
    iface="$(ls "$sdk"/usr/lib/swift/Swift.swiftmodule/*.swiftinterface 2>/dev/null | head -1 || true)"
    [ -n "$iface" ] || continue
    have="$(sed -n 's/^\/\/ swift-compiler-version: Apple Swift version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' "$iface" | head -1)"
    if [ "$have" = "$want" ]; then
      echo "$sdk"
      return
    fi
  done
  echo "warning: no installed macOS SDK matches Swift $want. Your Command Line Tools are half-updated;" >&2
  echo "         reinstall them: sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install" >&2
  echo "${default}"
}

# "Navo" in the Share menu of Voice Memos and Finder. Optional: Navo works without it, so a
# failure here only prints a warning.
build_share_extension() {
  local sdk="$1" arch="$2"
  local src="$ROOT/Extensions/NavoShare"
  local appex="$APP/Contents/PlugIns/NavoShare.appex"
  [ -d "$src" ] || return 0
  echo "==> Share extension"
  rm -rf "$appex"
  mkdir -p "$appex/Contents/MacOS" "$appex/Contents/Resources"
  if ! swiftc -O \
      -parse-as-library \
      -swift-version 5 \
      -application-extension \
      -module-name NavoShare \
      -target "$arch-apple-macos14.0" \
      -sdk "$sdk" \
      -Xlinker -e -Xlinker _NSExtensionMain \
      "$src/ShareViewController.swift" \
      -o "$appex/Contents/MacOS/NavoShare"; then
    rm -rf "$appex"
    return 1
  fi
  cp "$src/Info.plist" "$appex/Contents/Info.plist"
  cp "$ROOT/Resources/AppIcon.icns" "$appex/Contents/Resources/AppIcon.icns"
}

# Signs the extension first: the app's signature seals the code inside it.
sign_share_extension() {
  local identity="$1"
  shift
  local appex="$APP/Contents/PlugIns/NavoShare.appex"
  [ -d "$appex" ] || return 0
  if ! codesign --force "$@" --entitlements "$ROOT/Extensions/NavoShare/NavoShare.entitlements" --sign "$identity" "$appex"; then
    echo "warning: could not sign the Share extension; building Navo without it."
    rm -rf "$appex"
  fi
}

build() {
  local sdk arch
  arch="$(uname -m)"
  sdk="$(pick_sdk)"
  echo "==> swiftc ($CONFIG, $arch)"
  swiftc --version 2>&1 | head -1
  echo "==> SDK: $sdk"

  local sources=()
  while IFS= read -r -d '' file; do
    sources+=("$file")
  done < <(find "$ROOT/Sources/Navo" -name '*.swift' -print0)

  local optimize=(-O -wmo)
  if [ "$CONFIG" = "debug" ]; then
    optimize=(-Onone -g)
  fi

  swiftc "${optimize[@]}" \
    -parse-as-library \
    -swift-version 5 \
    -module-name Navo \
    -target "$arch-apple-macos14.0" \
    -sdk "$sdk" \
    -lsqlite3 \
    -framework AVFoundation \
    -framework Carbon \
    -framework ApplicationServices \
    -framework ServiceManagement \
    "${sources[@]}" \
    -o "$BUILD_DIR/Navo"

  echo "==> Assembling Navo.app"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  mv "$BUILD_DIR/Navo" "$APP/Contents/MacOS/Navo"
  cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  rsync -a --delete \
    --exclude '__pycache__' --exclude '.pytest_cache' --exclude 'tests' --exclude '.venv' --exclude '.DS_Store' \
    "$ROOT/engine/" "$APP/Contents/Resources/engine/"
  chmod +x "$APP/Contents/Resources/engine/setup-engine.sh"

  if ! build_share_extension "$sdk" "$arch"; then
    echo "warning: the Share extension did not build (see above). Navo works without it; Share > Navo will be missing."
  fi

  local identity
  identity="$(navo_signing_identity)"
  case "$identity" in
    "-")
      echo "==> Ad-hoc signing: macOS will ask for Accessibility again after each rebuild."
      sign_share_extension -
      codesign --force --entitlements "$ROOT/Resources/Navo.entitlements" --sign - "$APP"
      ;;
    "$NAVO_LOCAL_CERT")
      echo "==> Signing with the local certificate: permissions survive rebuilds."
      sign_share_extension "$identity"
      codesign --force --entitlements "$ROOT/Resources/Navo.entitlements" --sign "$identity" "$APP"
      ;;
    *)
      echo "==> Signing with: $identity"
      # A Developer ID signature needs Apple's timestamp to be notarized (see package.sh).
      local extra=(--options runtime)
      case "$identity" in
        "Developer ID Application:"*) extra+=(--timestamp) ;;
      esac
      sign_share_extension "$identity" "${extra[@]}"
      codesign --force "${extra[@]}" --entitlements "$ROOT/Resources/Navo.entitlements" --sign "$identity" "$APP"
      ;;
  esac
  codesign --verify --verbose=1 "$APP"
  echo "==> Built $APP"
}

build 2>&1 | tee "$LOG"
