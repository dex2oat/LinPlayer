#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

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
  RegisterWindowChannel();
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

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
  if (is_fullscreen_) {
    RestoreWindowStyle();
  }
  window_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
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

void FlutterWindow::RegisterWindowChannel() {
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "com.linplayer/window",
          &flutter::StandardMethodCodec::GetInstance());

  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "setFullscreen") {
          bool fullscreen = false;
          if (const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments())) {
            const auto it = arguments->find(flutter::EncodableValue("fullscreen"));
            if (it != arguments->end()) {
              if (const auto* value = std::get_if<bool>(&it->second)) {
                fullscreen = *value;
              }
            }
          }
          result->Success(flutter::EncodableValue(SetFullscreen(fullscreen)));
          return;
        }

        if (call.method_name() == "isFullscreen") {
          result->Success(flutter::EncodableValue(IsFullscreen()));
          return;
        }

        result->NotImplemented();
      });
}

bool FlutterWindow::SetFullscreen(bool fullscreen) {
  HWND handle = GetHandle();
  if (!handle) {
    return is_fullscreen_;
  }

  if (fullscreen == is_fullscreen_) {
    return is_fullscreen_;
  }

  if (fullscreen) {
    saved_style_ = GetWindowLong(handle, GWL_STYLE);
    saved_ex_style_ = GetWindowLong(handle, GWL_EXSTYLE);
    GetWindowRect(handle, &saved_bounds_);

    MONITORINFO monitor_info = {sizeof(MONITORINFO)};
    GetMonitorInfo(MonitorFromWindow(handle, MONITOR_DEFAULTTONEAREST), &monitor_info);

    SetWindowLong(handle, GWL_STYLE, saved_style_ & ~WS_OVERLAPPEDWINDOW);
    SetWindowLong(handle, GWL_EXSTYLE, saved_ex_style_ & ~WS_EX_OVERLAPPEDWINDOW);
    SetWindowPos(handle, HWND_TOP,
                 monitor_info.rcMonitor.left,
                 monitor_info.rcMonitor.top,
                 monitor_info.rcMonitor.right - monitor_info.rcMonitor.left,
                 monitor_info.rcMonitor.bottom - monitor_info.rcMonitor.top,
                 SWP_FRAMECHANGED | SWP_NOOWNERZORDER | SWP_SHOWWINDOW);
    is_fullscreen_ = true;
    return true;
  }

  RestoreWindowStyle();
  return is_fullscreen_;
}

bool FlutterWindow::IsFullscreen() const {
  return is_fullscreen_;
}

void FlutterWindow::RestoreWindowStyle() {
  HWND handle = GetHandle();
  if (!handle) {
    is_fullscreen_ = false;
    return;
  }

  SetWindowLong(handle, GWL_STYLE, saved_style_);
  SetWindowLong(handle, GWL_EXSTYLE, saved_ex_style_);
  SetWindowPos(handle, HWND_NOTOPMOST,
               saved_bounds_.left,
               saved_bounds_.top,
               saved_bounds_.right - saved_bounds_.left,
               saved_bounds_.bottom - saved_bounds_.top,
               SWP_FRAMECHANGED | SWP_NOOWNERZORDER | SWP_SHOWWINDOW);
  is_fullscreen_ = false;
}
