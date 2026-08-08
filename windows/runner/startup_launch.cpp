#include "startup_launch.h"

#include <windows.h>

#include <string>

namespace startup_launch {

namespace {

constexpr wchar_t kRunKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr wchar_t kValueName[] = L"ProxyWithFlutter";

std::wstring ExecutablePath() {
  // MAX_PATH is not enough on a long-path enabled system, so grow until the
  // buffer is genuinely larger than the answer.
  std::wstring path(MAX_PATH, L'\0');
  for (;;) {
    const DWORD length = ::GetModuleFileNameW(nullptr, path.data(),
                                              static_cast<DWORD>(path.size()));
    if (length == 0) {
      return std::wstring();
    }
    if (length < path.size()) {
      path.resize(length);
      return path;
    }
    path.resize(path.size() * 2);
  }
}

// Quoted so that a path containing spaces is not split into command and
// arguments when the shell runs it.
std::wstring QuotedExecutablePath() {
  const std::wstring path = ExecutablePath();
  if (path.empty()) {
    return path;
  }
  return L"\"" + path + L"\"";
}

}  // namespace

bool IsEnabled() {
  HKEY key = nullptr;
  if (::RegOpenKeyExW(HKEY_CURRENT_USER, kRunKey, 0, KEY_QUERY_VALUE, &key) !=
      ERROR_SUCCESS) {
    return false;
  }
  const LSTATUS status =
      ::RegQueryValueExW(key, kValueName, nullptr, nullptr, nullptr, nullptr);
  ::RegCloseKey(key);
  return status == ERROR_SUCCESS;
}

bool SetEnabled(bool enabled) {
  HKEY key = nullptr;
  if (::RegCreateKeyExW(HKEY_CURRENT_USER, kRunKey, 0, nullptr,
                        REG_OPTION_NON_VOLATILE, KEY_SET_VALUE | KEY_QUERY_VALUE,
                        nullptr, &key, nullptr) != ERROR_SUCCESS) {
    return false;
  }

  LSTATUS status = ERROR_SUCCESS;
  if (enabled) {
    const std::wstring command = QuotedExecutablePath();
    if (command.empty()) {
      ::RegCloseKey(key);
      return false;
    }
    status = ::RegSetValueExW(
        key, kValueName, 0, REG_SZ,
        reinterpret_cast<const BYTE*>(command.c_str()),
        static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
  } else {
    status = ::RegDeleteValueW(key, kValueName);
    // Already absent is the state the caller asked for.
    if (status == ERROR_FILE_NOT_FOUND) {
      status = ERROR_SUCCESS;
    }
  }

  ::RegCloseKey(key);
  return status == ERROR_SUCCESS;
}

}  // namespace startup_launch
