#!/bin/bash
set -euo pipefail

case ",${DART_DEFINES:-}," in
  *,TUFDX0FQUF9TVE9SRT10cnVl,*) ;;
  *) echo "error: Store builds require MAC_APP_STORE=true in Dart defines." >&2; exit 1 ;;
esac
native="$PROJECT_DIR/../native/macos-app-store/$PROXY_RUST_PROFILE/libhttp_proxy.dylib"
if [[ ! -f "$native" ]]; then
  echo "error: Build the store native artifacts with scripts/macos/build-app-store.py from the Rust repository." >&2
  exit 1
fi
# Check the feature marker before copying: a desktop dylib must never silently
# turn a store build back into the privileged-helper implementation.
symbols="$(/usr/bin/nm -gU "$native")"
if [[ "$symbols" != *"_proxy_packet_tunnel_create"* ]]; then
  echo "error: The native library was not built with the mac-app-store feature." >&2
  exit 1
fi
echo "$PRODUCT_NAME.app" > "$PROJECT_DIR/Flutter/ephemeral/.app_filename"
"$FLUTTER_ROOT/packages/flutter_tools/bin/macos_assemble.sh" embed
destination="$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH/Frameworks/libhttp_proxy.dylib"
mkdir -p "$(dirname "$destination")"
cp "$native" "$destination"
if [[ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$destination"
fi
if [[ -e "$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH/MacOS/http-proxy-tun-helper" ]]; then
  echo "error: A privileged helper is present in the store output. Use a clean store build directory." >&2
  exit 1
fi
