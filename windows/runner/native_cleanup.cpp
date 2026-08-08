#include "native_cleanup.h"

#include <windows.h>

namespace native_cleanup {

namespace {

constexpr wchar_t kProxyLibrary[] = L"http_proxy.dll";
constexpr char kRestoreSystemProxy[] = "proxy_restore_system_proxy";

using RestoreSystemProxyFn = int (*)();

}  // namespace

void RestoreSystemProxy() {
  // Look the module up instead of loading it: this only has to work when the
  // Dart side already opened the library, and taking a second reference during
  // shutdown would be the wrong time to fail.
  const HMODULE library = ::GetModuleHandleW(kProxyLibrary);
  if (library == nullptr) {
    return;
  }

  const auto restore = reinterpret_cast<RestoreSystemProxyFn>(
      ::GetProcAddress(library, kRestoreSystemProxy));
  if (restore == nullptr) {
    return;
  }
  restore();
}

}  // namespace native_cleanup
