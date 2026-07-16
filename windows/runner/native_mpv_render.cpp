#include "native_mpv_render.h"

#include <flutter/encodable_value.h>
#include <windowsx.h>  // GET_X_LPARAM / GET_Y_LPARAM

#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

#include "mpv/client.h"

namespace {

// libmpv 导出函数指针（动态加载，避免编译期链接 mpv.lib）。
using PFN_mpv_create = mpv_handle* (*)();
using PFN_mpv_initialize = int (*)(mpv_handle*);
using PFN_mpv_terminate_destroy = void (*)(mpv_handle*);
using PFN_mpv_set_option_string = int (*)(mpv_handle*, const char*, const char*);
using PFN_mpv_set_property_string = int (*)(mpv_handle*, const char*,
                                            const char*);
using PFN_mpv_get_property_string = char* (*)(mpv_handle*, const char*);
using PFN_mpv_command = int (*)(mpv_handle*, const char**);
using PFN_mpv_free = void (*)(void*);

struct MpvApi {
  PFN_mpv_create create = nullptr;
  PFN_mpv_initialize initialize = nullptr;
  PFN_mpv_terminate_destroy terminate_destroy = nullptr;
  PFN_mpv_set_option_string set_option_string = nullptr;
  PFN_mpv_set_property_string set_property_string = nullptr;
  PFN_mpv_get_property_string get_property_string = nullptr;
  PFN_mpv_command command = nullptr;
  PFN_mpv_free free = nullptr;
  bool ok() const {
    return create && initialize && terminate_destroy && set_option_string &&
           set_property_string && get_property_string && command && free;
  }
};

MpvApi g_api;

// 当前活动 mpv 句柄，供 ChildWndProc 把鼠标事件转发进 mpv 输入系统。
// gpu-context=d3d11 直接在 --wid 上出画，mpv 不建自己的子窗口，鼠标全落到我们的
// WndProc，必须手动转发，否则 OSC/uosc 收不到输入、点不动。InitPlayer 设、Shutdown 清。
mpv_handle* g_input_mpv = nullptr;

const wchar_t kChildClassName[] = L"LinPlayerMpvChild";

// 发一条 mpv 命令（argv 以 nullptr 结尾）。
void SendMpvCmd(const char** argv) {
  if (g_input_mpv && g_api.command) g_api.command(g_input_mpv, argv);
}

// 把鼠标坐标喂给 mpv（客户区像素 = mpv VO 像素，1:1）。
void SendMpvMouse(int x, int y) {
  char xs[16], ys[16];
  _snprintf_s(xs, sizeof(xs), _TRUNCATE, "%d", x);
  _snprintf_s(ys, sizeof(ys), _TRUNCATE, "%d", y);
  const char* c[] = {"mouse", xs, ys, nullptr};
  SendMpvCmd(c);
}

void SendMpvBtn(const char* action, const char* btn) {
  const char* c[] = {action, btn, nullptr};
  SendMpvCmd(c);
}

// exe 所在目录（wide）。
std::wstring ExeDirW() {
  wchar_t buf[MAX_PATH];
  const DWORD n = GetModuleFileNameW(nullptr, buf, MAX_PATH);
  if (n == 0 || n >= MAX_PATH) return std::wstring();
  std::wstring p(buf, n);
  const size_t slash = p.find_last_of(L"\\/");
  return slash == std::wstring::npos ? std::wstring() : p.substr(0, slash);
}

std::string Utf8(const std::wstring& w) {
  if (w.empty()) return std::string();
  const int len = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, nullptr, 0,
                                      nullptr, nullptr);
  if (len <= 0) return std::string();
  std::string out(static_cast<size_t>(len - 1), '\0');
  WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, out.data(), len, nullptr,
                      nullptr);
  return out;
}

LRESULT CALLBACK ChildWndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  switch (msg) {
    case WM_ERASEBKGND:
      return 1;  // mpv 自绘，禁止背景擦除以免闪黑。
    case WM_MOUSEACTIVATE:
      // 点视频不抢键盘焦点：焦点留在 Flutter 顶层窗口，空格/方向键等快捷键照常生效。
      return MA_NOACTIVATE;
    case WM_MOUSEMOVE:
      SendMpvMouse(GET_X_LPARAM(lp), GET_Y_LPARAM(lp));
      return 0;
    case WM_LBUTTONDOWN:
      SendMpvMouse(GET_X_LPARAM(lp), GET_Y_LPARAM(lp));
      SendMpvBtn("keydown", "MBTN_LEFT");
      SetCapture(hwnd);  // 拖动进度条时鼠标出界也能收到 UP。
      return 0;
    case WM_LBUTTONUP:
      SendMpvMouse(GET_X_LPARAM(lp), GET_Y_LPARAM(lp));
      SendMpvBtn("keyup", "MBTN_LEFT");
      ReleaseCapture();
      return 0;
    case WM_LBUTTONDBLCLK:
      SendMpvMouse(GET_X_LPARAM(lp), GET_Y_LPARAM(lp));
      SendMpvBtn("keydown", "MBTN_LEFT_DBL");
      SendMpvBtn("keyup", "MBTN_LEFT_DBL");
      return 0;
    case WM_RBUTTONDOWN:
      SendMpvMouse(GET_X_LPARAM(lp), GET_Y_LPARAM(lp));
      SendMpvBtn("keydown", "MBTN_RIGHT");
      return 0;
    case WM_RBUTTONUP:
      SendMpvMouse(GET_X_LPARAM(lp), GET_Y_LPARAM(lp));
      SendMpvBtn("keyup", "MBTN_RIGHT");
      return 0;
    case WM_MOUSEWHEEL:
      SendMpvBtn("keypress", GET_WHEEL_DELTA_WPARAM(wp) > 0 ? "WHEEL_UP"
                                                            : "WHEEL_DOWN");
      return 0;
    default:
      break;
  }
  return DefWindowProc(hwnd, msg, wp, lp);
}

// 从 EncodableMap 取字符串/整数，缺失返回默认。
std::string GetString(const flutter::EncodableMap& m, const char* key,
                      const std::string& def = std::string()) {
  const auto it = m.find(flutter::EncodableValue(key));
  if (it == m.end()) return def;
  if (const auto* s = std::get_if<std::string>(&it->second)) return *s;
  return def;
}

int64_t GetInt(const flutter::EncodableMap& m, const char* key, int64_t def) {
  const auto it = m.find(flutter::EncodableValue(key));
  if (it == m.end()) return def;
  if (const auto* i = std::get_if<int64_t>(&it->second)) return *i;
  if (const auto* i32 = std::get_if<int32_t>(&it->second)) return *i32;
  if (const auto* d = std::get_if<double>(&it->second))
    return static_cast<int64_t>(*d);
  return def;
}

std::vector<std::string> GetStringList(const flutter::EncodableMap& m,
                                       const char* key) {
  std::vector<std::string> out;
  const auto it = m.find(flutter::EncodableValue(key));
  if (it == m.end()) return out;
  if (const auto* list = std::get_if<flutter::EncodableList>(&it->second)) {
    for (const auto& e : *list) {
      if (const auto* s = std::get_if<std::string>(&e)) out.push_back(*s);
    }
  }
  return out;
}

std::map<std::string, std::string> GetStringMap(const flutter::EncodableMap& m,
                                                const char* key) {
  std::map<std::string, std::string> out;
  const auto it = m.find(flutter::EncodableValue(key));
  if (it == m.end()) return out;
  if (const auto* map = std::get_if<flutter::EncodableMap>(&it->second)) {
    for (const auto& kv : *map) {
      const auto* k = std::get_if<std::string>(&kv.first);
      const auto* v = std::get_if<std::string>(&kv.second);
      if (k && v) out[*k] = *v;
    }
  }
  return out;
}

}  // namespace

std::unique_ptr<NativeMpvRender> NativeMpvRender::Create(
    flutter::BinaryMessenger* messenger, HWND top_level, HWND flutter_view) {
  return std::make_unique<NativeMpvRender>(messenger, top_level, flutter_view);
}

NativeMpvRender::NativeMpvRender(flutter::BinaryMessenger* messenger,
                                 HWND top_level, HWND flutter_view)
    : top_level_window_(top_level), flutter_view_window_(flutter_view) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "com.linplayer/native_render",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleMethodCall(call, std::move(result));
      });
}

NativeMpvRender::~NativeMpvRender() { Shutdown(); }

bool NativeMpvRender::EnsureLibmpvLoaded(std::string* error) {
  if (libmpv_ && g_api.ok()) return true;
  // libmpv-2.dll 由 media_kit 打进 exe 同目录。
  libmpv_ = LoadLibraryW(L"libmpv-2.dll");
  if (!libmpv_) {
    *error = "无法加载 libmpv-2.dll (LoadLibrary 失败)";
    return false;
  }
  g_api.create =
      reinterpret_cast<PFN_mpv_create>(GetProcAddress(libmpv_, "mpv_create"));
  g_api.initialize = reinterpret_cast<PFN_mpv_initialize>(
      GetProcAddress(libmpv_, "mpv_initialize"));
  g_api.terminate_destroy = reinterpret_cast<PFN_mpv_terminate_destroy>(
      GetProcAddress(libmpv_, "mpv_terminate_destroy"));
  g_api.set_option_string = reinterpret_cast<PFN_mpv_set_option_string>(
      GetProcAddress(libmpv_, "mpv_set_option_string"));
  g_api.set_property_string = reinterpret_cast<PFN_mpv_set_property_string>(
      GetProcAddress(libmpv_, "mpv_set_property_string"));
  g_api.get_property_string = reinterpret_cast<PFN_mpv_get_property_string>(
      GetProcAddress(libmpv_, "mpv_get_property_string"));
  g_api.command =
      reinterpret_cast<PFN_mpv_command>(GetProcAddress(libmpv_, "mpv_command"));
  g_api.free =
      reinterpret_cast<PFN_mpv_free>(GetProcAddress(libmpv_, "mpv_free"));
  if (!g_api.ok()) {
    *error = "libmpv-2.dll 缺少所需导出函数";
    return false;
  }
  return true;
}

bool NativeMpvRender::CreateChildWindow(std::string* error) {
  if (child_window_) return true;
  static bool class_registered = false;
  HINSTANCE inst = GetModuleHandle(nullptr);
  if (!class_registered) {
    WNDCLASSW wc = {};
    wc.style = CS_DBLCLKS;  // 需要 WM_LBUTTONDBLCLK（转 MBTN_LEFT_DBL 给 mpv）。
    wc.lpfnWndProc = ChildWndProc;
    wc.hInstance = inst;
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    wc.hbrBackground = reinterpret_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
    wc.lpszClassName = kChildClassName;
    if (!RegisterClassW(&wc)) {
      *error = "注册 mpv 子窗口类失败";
      return false;
    }
    class_registered = true;
  }
  // mpv 作为顶层窗口的子（Flutter 视图的兄弟），**不加 WS_CLIPSIBLINGS**：
  // 它 z-order 压在 Flutter 视图之下，CLIPSIBLINGS 会让高 z 的 Flutter 视图矩形
  // 把 mpv 的绘制全裁掉（视图铺满客户区）→ mpv 反而不可见。去掉后由 Flutter 视图
  // 的窗口区域(挖洞)决定哪里露出 mpv。WS_EX_NOACTIVATE：点它不抢焦点，键盘留给 Flutter。
  child_window_ = CreateWindowExW(WS_EX_NOACTIVATE, kChildClassName, L"",
                                  WS_CHILD | WS_VISIBLE, 0, 0, 16, 16,
                                  top_level_window_, nullptr, inst, nullptr);
  if (!child_window_) {
    *error = "创建 mpv 子窗口失败";
    return false;
  }
  // 压到兄弟里的最底层，确保 Flutter 视图始终在其上（洞处才露出 mpv）。
  SetWindowPos(child_window_, HWND_BOTTOM, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  return true;
}

bool NativeMpvRender::InitPlayer(
    const std::string& url, int64_t start_ms,
    const std::vector<std::string>& shader_paths,
    const std::map<std::string, std::string>& headers,
    const std::string& user_agent, std::string* error) {
  Shutdown();  // 复用前先清干净。
  if (!EnsureLibmpvLoaded(error)) return false;
  if (!CreateChildWindow(error)) return false;

  mpv_handle* ctx = g_api.create();
  if (!ctx) {
    *error = "mpv_create 失败";
    return false;
  }

  // wid 必须在 initialize 之前设置（VO 在 init 阶段绑定窗口）。
  char wid_buf[32];
  _snprintf_s(wid_buf, sizeof(wid_buf), _TRUNCATE, "%lld",
              static_cast<long long>(reinterpret_cast<intptr_t>(child_window_)));
  g_api.set_option_string(ctx, "wid", wid_buf);

  // 原生直出：gpu-next + d3d11，mpv 自建 swapchain 上屏，不经 ANGLE。
  g_api.set_option_string(ctx, "vo", "gpu-next");
  g_api.set_option_string(ctx, "gpu-context", "d3d11");
  g_api.set_option_string(ctx, "hwdec", "d3d11va");
  g_api.set_option_string(ctx, "force-window", "yes");
  g_api.set_option_string(ctx, "keep-open", "yes");
  g_api.set_option_string(ctx, "idle", "yes");
  g_api.set_option_string(ctx, "terminal", "no");
  // 加载 uosc 控制栏（目录脚本，入口 uosc/main.lua）+ 诊断日志。关键：libmpv 默认
  // config=no，不会从 config-dir 自动发现脚本，故用 scripts=<uosc 目录> 显式加载。
  // config-dir 供 uosc 读 script-opts/uosc.conf、fonts/ 图标字体。log-file 写运行日志。
  {
    const std::wstring exe = ExeDirW();
    if (!exe.empty()) {
      const std::string cfg = Utf8(exe + L"\\mpv-config");
      const std::string uosc = Utf8(exe + L"\\mpv-config\\scripts\\uosc");
      const std::string logf = Utf8(exe + L"\\mpv-native.log");
      if (!cfg.empty()) g_api.set_option_string(ctx, "config-dir", cfg.c_str());
      if (!uosc.empty()) g_api.set_option_string(ctx, "scripts", uosc.c_str());
      if (!logf.empty()) g_api.set_option_string(ctx, "log-file", logf.c_str());
    }
  }
  g_api.set_option_string(ctx, "load-scripts", "yes");
  // M2 挖洞 v2：由自研 linplayer_ui.lua 画控制栏。关内置 OSC 让它顶替；关 mpv 默认
  // 鼠标绑定（Lua 用 forced binding 全接管 MBTN/滚轮，免得 mpv 自己响应点击/双击全屏）。
  g_api.set_option_string(ctx, "osc", "no");
  g_api.set_option_string(ctx, "input-default-bindings", "no");
  g_api.set_option_string(ctx, "cursor-autohide", "no");
  g_api.set_option_string(ctx, "window-dragging", "no");  // 别让点击视频拖动窗口。
  // OSD 字体用系统中文字体，保证标题/中文按钮标签（字幕/音轨/超分…）不出豆腐块。
  g_api.set_option_string(ctx, "osd-font", "Microsoft YaHei");
  // 安全：与三端一致拉黑 magicyuv（CVE-2026-8461）。
  g_api.set_option_string(ctx, "vd", "-magicyuv");
  // 逐流鉴权（网盘/聚合源直链）。
  if (!user_agent.empty())
    g_api.set_option_string(ctx, "user-agent", user_agent.c_str());
  if (!headers.empty()) {
    std::string fields;
    for (const auto& kv : headers) {
      if (_stricmp(kv.first.c_str(), "user-agent") == 0) continue;
      if (!fields.empty()) fields += ",";
      fields += kv.first + ": " + kv.second;
    }
    if (!fields.empty())
      g_api.set_option_string(ctx, "http-header-fields", fields.c_str());
  }
  // 续播点：交给 start 选项，loadfile 阶段原生定位。
  if (start_ms > 0) {
    char start_buf[32];
    _snprintf_s(start_buf, sizeof(start_buf), _TRUNCATE, "%.3f",
                static_cast<double>(start_ms) / 1000.0);
    g_api.set_option_string(ctx, "start", start_buf);
  }

  if (g_api.initialize(ctx) < 0) {
    g_api.terminate_destroy(ctx);
    *error = "mpv_initialize 失败";
    return false;
  }
  mpv_ = ctx;
  g_input_mpv = ctx;  // 让 ChildWndProc 能把鼠标事件转发进这个 mpv。

  // 超分 shader（initialize 之后应用）。
  ApplyShaders(shader_paths);

  // 加载视频。
  const char* cmd[] = {"loadfile", url.c_str(), nullptr};
  g_api.command(ctx, cmd);
  return true;
}

void NativeMpvRender::ApplyShaders(
    const std::vector<std::string>& shader_paths) {
  if (!mpv_) return;
  mpv_handle* ctx = static_cast<mpv_handle*>(mpv_);
  {
    const char* clr[] = {"change-list", "glsl-shaders", "clr", "", nullptr};
    g_api.command(ctx, clr);
  }
  for (const auto& path : shader_paths) {
    const char* add[] = {"change-list", "glsl-shaders", "append", path.c_str(),
                         nullptr};
    g_api.command(ctx, add);
  }
}

void NativeMpvRender::BindSuperresKeys(
    const flutter::EncodableList& bindings) {
  if (!mpv_) return;
  mpv_handle* ctx = static_cast<mpv_handle*>(mpv_);
  for (const auto& e : bindings) {
    const auto* m = std::get_if<flutter::EncodableMap>(&e);
    if (!m) continue;
    const std::string key = GetString(*m, "key");
    if (key.empty()) continue;
    const std::string label = GetString(*m, "label");
    const std::vector<std::string> paths = GetStringList(*m, "paths");
    // 一条链式命令：清空 → 逐个 append（路径加引号防空格）→ 提示。
    std::string cmd = "no-osd change-list glsl-shaders clr \"\"";
    for (const auto& p : paths) {
      cmd += "; no-osd change-list glsl-shaders append \"" + p + "\"";
    }
    cmd += "; show-text \"超分: " + label + "\" 2000";
    const char* kb[] = {"keybind", key.c_str(), cmd.c_str(), nullptr};
    g_api.command(ctx, kb);
  }
  // M2：不再 show-text 提示（会画进洞里）。超分由 Flutter Anime4K 菜单驱动
  // （applyShaders 通道），mpv 子窗口无键盘焦点，这些 keybind 只是保留不生效。
}

void NativeMpvRender::MoveChild(int left, int top, int width, int height) {
  if (!child_window_) return;
  MoveWindow(child_window_, left, top, width > 0 ? width : 1,
             height > 0 ? height : 1, TRUE);
  // 每次移动后重申「压到兄弟最底」，防窗口激活/子窗口重建打乱 z-order。
  SetWindowPos(child_window_, HWND_BOTTOM, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
}

void NativeMpvRender::SetHole(const RECT& video_rect,
                              const std::vector<RECT>& cutouts) {
  if (!flutter_view_window_) return;
  RECT vc;
  if (!GetClientRect(flutter_view_window_, &vc)) return;
  // 有效洞 = 视频矩形 − 所有 cutout（cutout 是盖在视频上、需保持不透明的 Flutter 控件）。
  HRGN hole = CreateRectRgn(video_rect.left, video_rect.top, video_rect.right,
                            video_rect.bottom);
  for (const auto& c : cutouts) {
    HRGN cut = CreateRectRgn(c.left, c.top, c.right, c.bottom);
    CombineRgn(hole, hole, cut, RGN_DIFF);
    DeleteObject(cut);
  }
  // ① Flutter 视图可见区 = 整视图 − 洞。洞处 Flutter 不绘制 → 露出其下的 mpv。
  HRGN visible = CreateRectRgn(0, 0, vc.right, vc.bottom);
  CombineRgn(visible, visible, hole, RGN_DIFF);
  SetWindowRgn(flutter_view_window_, visible, TRUE);  // 系统接管 visible。
  // ② mpv 窗口也裁成洞的形状：只在洞内显示。否则 mpv 的 D3D11 直出会无视子窗口
  //    z-order 盖住 cutout 区里的 Flutter 面板/控制栏（面板死活不显的真凶）。
  //    洞是客户区坐标，mpv 原点在 (video.left, video.top)，平移到 mpv 局部坐标。
  if (child_window_) {
    HRGN mpv_rgn = CreateRectRgn(0, 0, 0, 0);
    CopyRgn(mpv_rgn, hole);
    OffsetRgn(mpv_rgn, -video_rect.left, -video_rect.top);
    SetWindowRgn(child_window_, mpv_rgn, TRUE);  // 系统接管 mpv_rgn。
  }
  DeleteObject(hole);
}

void NativeMpvRender::ClearHole() {
  if (flutter_view_window_) {
    SetWindowRgn(flutter_view_window_, nullptr, TRUE);  // 还原整块 Flutter 视图。
  }
  if (child_window_) {
    SetWindowRgn(child_window_, nullptr, TRUE);  // 还原 mpv 窗口整块。
  }
}

std::string NativeMpvRender::GetProp(const std::string& name) {
  if (!mpv_) return std::string();
  char* v = g_api.get_property_string(static_cast<mpv_handle*>(mpv_),
                                      name.c_str());
  if (!v) return std::string();
  std::string out(v);
  g_api.free(v);
  return out;
}

void NativeMpvRender::SetProp(const std::string& name,
                              const std::string& value) {
  if (!mpv_) return;
  g_api.set_property_string(static_cast<mpv_handle*>(mpv_), name.c_str(),
                            value.c_str());
}

void NativeMpvRender::Command(const std::vector<std::string>& args) {
  if (!mpv_ || args.empty()) return;
  std::vector<const char*> argv;
  argv.reserve(args.size() + 1);
  for (const auto& a : args) argv.push_back(a.c_str());
  argv.push_back(nullptr);
  g_api.command(static_cast<mpv_handle*>(mpv_), argv.data());
}

void NativeMpvRender::Shutdown() {
  ClearHole();  // 离场先还原 Flutter 视图整块，别把洞留给下一个页面。
  g_input_mpv = nullptr;  // 先断输入转发，避免 WndProc 用到已销毁句柄。
  if (mpv_) {
    g_api.terminate_destroy(static_cast<mpv_handle*>(mpv_));
    mpv_ = nullptr;
  }
  if (child_window_) {
    DestroyWindow(child_window_);
    child_window_ = nullptr;
  }
}

void NativeMpvRender::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  const flutter::EncodableMap* args =
      std::get_if<flutter::EncodableMap>(call.arguments());
  flutter::EncodableMap empty;
  const flutter::EncodableMap& a = args ? *args : empty;

  if (method == "init") {
    const std::string url = GetString(a, "url");
    const int64_t start_ms = GetInt(a, "startMs", 0);
    const std::vector<std::string> shaders = GetStringList(a, "shaders");
    const std::map<std::string, std::string> headers =
        GetStringMap(a, "headers");
    const std::string ua = GetString(a, "userAgent");
    std::string error;
    if (InitPlayer(url, start_ms, shaders, headers, ua, &error)) {
      // 数字键超分绑定（0=关，1..N=各档）。
      const auto bit = a.find(flutter::EncodableValue("superres"));
      if (bit != a.end()) {
        if (const auto* list = std::get_if<flutter::EncodableList>(&bit->second)) {
          BindSuperresKeys(*list);
        }
      }
      result->Success(flutter::EncodableValue(true));
    } else {
      result->Error("INIT_FAILED", error);
    }
    return;
  }
  if (method == "setRect") {
    const int left = static_cast<int>(GetInt(a, "left", 0));
    const int top = static_cast<int>(GetInt(a, "top", 0));
    int width = static_cast<int>(GetInt(a, "width", 0));
    int height = static_cast<int>(GetInt(a, "height", 0));
    if (width <= 0 || height <= 0) {
      // 缺矩形时铺满顶层客户区（起播首帧兜底）。
      RECT rc;
      if (top_level_window_ && GetClientRect(top_level_window_, &rc)) {
        width = rc.right - rc.left;
        height = rc.bottom - rc.top;
      }
    }
    MoveChild(left, top, width, height);
    // cutouts：盖在视频上、需保持不透明的 Flutter 控件矩形，每项 [l,t,w,h]（物理像素）。
    std::vector<RECT> cutouts;
    const auto cit = a.find(flutter::EncodableValue("cutouts"));
    if (cit != a.end()) {
      if (const auto* list =
              std::get_if<flutter::EncodableList>(&cit->second)) {
        for (const auto& e : *list) {
          const auto* r = std::get_if<flutter::EncodableList>(&e);
          if (!r || r->size() < 4) continue;
          auto num = [](const flutter::EncodableValue& v) -> int {
            if (const auto* i = std::get_if<int64_t>(&v))
              return static_cast<int>(*i);
            if (const auto* i32 = std::get_if<int32_t>(&v))
              return static_cast<int>(*i32);
            if (const auto* d = std::get_if<double>(&v))
              return static_cast<int>(*d);
            return 0;
          };
          const int cl = num((*r)[0]), ct = num((*r)[1]);
          const int cw = num((*r)[2]), ch = num((*r)[3]);
          cutouts.push_back(RECT{cl, ct, cl + cw, ct + ch});
        }
      }
    }
    const RECT video{left, top, left + width, top + height};
    SetHole(video, cutouts);
    result->Success();
    return;
  }
  if (method == "getProperty") {
    result->Success(flutter::EncodableValue(GetProp(GetString(a, "name"))));
    return;
  }
  if (method == "setProperty") {
    SetProp(GetString(a, "name"), GetString(a, "value"));
    result->Success();
    return;
  }
  if (method == "command") {
    Command(GetStringList(a, "args"));
    result->Success();
    return;
  }
  if (method == "applyShaders") {
    ApplyShaders(GetStringList(a, "shaders"));
    result->Success();
    return;
  }
  if (method == "getPointer") {
    // 返回鼠标在顶层客户区里的坐标（物理像素）。Dart 轮询比对，检测到在视频洞上
    // 移动就唤出控制栏——洞不属于 Flutter 窗口，onHover 收不到，只能靠这个补。
    // 用 GetCursorPos（全局，绕开 mpv 子窗口吃事件），比订阅 WndProc 稳。
    POINT p;
    if (GetCursorPos(&p) && top_level_window_ &&
        ScreenToClient(top_level_window_, &p)) {
      const bool primary_down = (GetAsyncKeyState(VK_LBUTTON) & 0x8000) != 0;
      result->Success(flutter::EncodableValue(flutter::EncodableMap{
          {flutter::EncodableValue("x"),
           flutter::EncodableValue(static_cast<int64_t>(p.x))},
          {flutter::EncodableValue("y"),
           flutter::EncodableValue(static_cast<int64_t>(p.y))},
          {flutter::EncodableValue("primaryDown"),
           flutter::EncodableValue(primary_down)},
      }));
    } else {
      result->Success();
    }
    return;
  }
  if (method == "dispose") {
    Shutdown();
    result->Success();
    return;
  }
  result->NotImplemented();
}
