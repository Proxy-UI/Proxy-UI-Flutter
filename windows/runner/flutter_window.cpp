#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "native_cleanup.h"
#include "single_instance.h"
#include "startup_launch.h"

namespace {

constexpr char kSingleInstanceChannel[] = "proxy_ui/single_instance";
constexpr char kSecondInstanceMethod[] = "onSecondInstance";

constexpr char kStartupChannel[] = "proxy_ui/startup";
constexpr char kIsStartupEnabled[] = "isEnabled";
constexpr char kSetStartupEnabled[] = "setEnabled";

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  single_instance_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kSingleInstanceChannel,
          &flutter::StandardMethodCodec::GetInstance());
  single_instance::RegisterMainWindow(GetHandle());

  // Point an existing sign-in entry at wherever the app lives now, so moving or
  // reinstalling it does not leave Windows launching a path that is gone.
  if (startup_launch::IsEnabled()) {
    startup_launch::SetEnabled(true);
  }

  startup_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kStartupChannel,
          &flutter::StandardMethodCodec::GetInstance());
  startup_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() == kIsStartupEnabled) {
          result->Success(flutter::EncodableValue(startup_launch::IsEnabled()));
          return;
        }
        if (call.method_name() == kSetStartupEnabled) {
          const auto* enabled = std::get_if<bool>(call.arguments());
          if (enabled == nullptr) {
            result->Error("invalid_argument", "Expected a boolean");
            return;
          }
          if (!startup_launch::SetEnabled(*enabled)) {
            result->Error("registry_error",
                          "Windows rejected the sign-in entry change");
            return;
          }
          result->Success(flutter::EncodableValue(startup_launch::IsEnabled()));
          return;
        }
        result->NotImplemented();
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  single_instance_channel_ = nullptr;
  startup_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  const UINT activation_message = single_instance::ActivationMessage();
  if (activation_message != 0 && message == activation_message) {
    // Raise the window here rather than from Dart: this runs while the second
    // process is still alive and holding the foreground grant open, and it also
    // works when the UI isolate is busy.
    single_instance::RaiseWindow(hwnd);
    if (single_instance_channel_) {
      single_instance_channel_->InvokeMethod(kSecondInstanceMethod, nullptr);
    }
    return 0;
  }

  if (message == WM_ENDSESSION && wparam != FALSE) {
    // Sign-out or shutdown. Dart may never be scheduled again and no Rust
    // destructor will run, so the system proxy has to be handed back here or
    // the next sign-in starts with the machine pointing at a dead listener.
    native_cleanup::RestoreSystemProxy();
  }

  if (message == WM_DESTROY) {
    single_instance::UnregisterMainWindow(hwnd);
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
