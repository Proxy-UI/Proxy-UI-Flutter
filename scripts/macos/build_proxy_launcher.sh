#!/bin/bash
set -euo pipefail

# Compile at app build time, never on the user's computer when they generate a
# launcher. Match every architecture of the enclosing desktop application.
source_dir="$PROJECT_DIR/ProxyLauncher"
output_dir="$BUILT_PRODUCTS_DIR/$EXECUTABLE_FOLDER_PATH"
intermediate="$DERIVED_FILE_DIR/proxy-launcher"
mkdir -p "$output_dir" "$intermediate"
outputs=()
for arch in $ARCHS; do
  output="$intermediate/ProxyLauncher-$arch"
  xcrun swiftc -O -target "${arch}-apple-macosx${MACOSX_DEPLOYMENT_TARGET}" \
    -sdk "$SDKROOT" -framework AppKit \
    "$source_dir/LauncherConfiguration.swift" "$source_dir/main.swift" -o "$output"
  outputs+=("$output")
done
xcrun lipo -create "${outputs[@]}" -output "$output_dir/CipherRelayProxyLauncher"
/usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" \
  --options runtime --timestamp=none "$output_dir/CipherRelayProxyLauncher"
