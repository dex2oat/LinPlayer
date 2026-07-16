#ifndef RUNNER_NATIVE_MPV_RENDER_H_
#define RUNNER_NATIVE_MPV_RENDER_H_

#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <map>
#include <memory>
#include <string>
#include <vector>

// M1 · Windows 原生 mpv 渲染验证。
//
// 用 libmpv 的 `--wid` 把 mpv 嵌进一个子 HWND，vo=gpu-next + gpu-context=d3d11,
// mpv 自己建 D3D11 swapchain 直接上屏——**绕开 media_kit 的离屏纹理 + ANGLE(GLES→D3D11)
// 逐帧翻译**，这正是「5060 都卡」的根源。此里程碑只为在真机上测「原生直出 + 重超分」
// 的流畅度：控制暂用 mpv 自带 OSC（osc=yes + 键鼠绑定），Flutter 控件叠加 / 完整方法
// 平价 / 事件推送留到 M2+。位置/时长由 Dart 侧轮询 getProperty，避免 M1 引入跨线程
// 事件 marshaling 的复杂度与风险。
class NativeMpvRender {
 public:
  // [messenger] Flutter 引擎信使；[top_level] 顶层窗口（mpv 子窗口的父，也是挖洞
  // 坐标基准）；[flutter_view] Flutter 视图窗口（在它的窗口区域上挖洞让视频透出）。
  // mpv 作为 Flutter 视图的兄弟子窗口挂在顶层窗口下、z-order 压到最底。
  static std::unique_ptr<NativeMpvRender> Create(
      flutter::BinaryMessenger* messenger, HWND top_level, HWND flutter_view);

  NativeMpvRender(flutter::BinaryMessenger* messenger, HWND top_level,
                  HWND flutter_view);
  ~NativeMpvRender();

  NativeMpvRender(const NativeMpvRender&) = delete;
  NativeMpvRender& operator=(const NativeMpvRender&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // 首次使用时从 exe 同目录加载 libmpv-2.dll 并解析所需函数指针。
  bool EnsureLibmpvLoaded(std::string* error);
  bool CreateChildWindow(std::string* error);
  bool InitPlayer(const std::string& url, int64_t start_ms,
                  const std::vector<std::string>& shader_paths,
                  const std::map<std::string, std::string>& headers,
                  const std::string& user_agent, std::string* error);
  void ApplyShaders(const std::vector<std::string>& shader_paths);
  // M1 控制：给 mpv 绑数字键切超分预设（0=关，1..N=各档），每档带 OSD 提示。
  // 每个 binding 是 {key, label, paths[]}。mpv 输入命令支持 ';' 链式，故一键即可
  // clr + 逐个 append + show-text，无需事件回传。
  void BindSuperresKeys(const flutter::EncodableList& bindings);
  void MoveChild(int left, int top, int width, int height);
  // 在 Flutter 视图窗口上挖洞：可见区域 = 整视图 −（视频洞 − cutouts）。
  // cutouts 是当前盖在视频上的 Flutter 控件（控制栏/面板），保持不透明可见。
  // 全部为物理像素、以 Flutter 视图左上角为原点。
  void SetHole(const RECT& video_rect, const std::vector<RECT>& cutouts);
  void ClearHole();
  std::string GetProp(const std::string& name);
  void SetProp(const std::string& name, const std::string& value);
  void Command(const std::vector<std::string>& args);
  void Shutdown();

  HWND top_level_window_ = nullptr;    // mpv 子窗口的父 + 挖洞坐标基准
  HWND flutter_view_window_ = nullptr;  // 在它的窗口区域上挖洞
  HWND child_window_ = nullptr;         // mpv 子窗口（顶层的兄弟子窗口，z 最底）
  void* mpv_ = nullptr;  // mpv_handle*
  HMODULE libmpv_ = nullptr;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_NATIVE_MPV_RENDER_H_
