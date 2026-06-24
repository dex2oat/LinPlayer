cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# VS 2026/MSVC 在中文代码页(936)下会把 UTF-8 源码里的中文注释判为 C4819，叠加 Flutter
# 模板的 /WX(警告即错误)直接构建失败。强制以 UTF-8 解析源文件，从根上消除 C4819。
target_compile_options(${BINARY_NAME} PRIVATE "/utf-8")

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# 构建完成后自动替换完整版 libmpv-2.dll，以启用 media-kit 预编译包中缺失的
# hdmv_pgs_subtitle 解码器。可通过 -DLINPLAYER_UPGRADE_LIBMPV=OFF 或设置环境变量
# LINPLAYER_SKIP_LIBMPV_UPGRADE=1 关闭。
option(LINPLAYER_UPGRADE_LIBMPV "Upgrade libmpv-2.dll for PGS/SUP support" ON)
if(LINPLAYER_UPGRADE_LIBMPV AND NOT DEFINED ENV{LINPLAYER_SKIP_LIBMPV_UPGRADE})
  add_custom_command(
    TARGET ${BINARY_NAME} POST_BUILD
    COMMAND powershell -ExecutionPolicy Bypass -File "${CMAKE_SOURCE_DIR}/scripts/upgrade_libmpv_for_pgs.ps1" -BuildOutput "$<TARGET_FILE_DIR:${BINARY_NAME}>" -AllowFailure
    COMMENT "升级 libmpv-2.dll 以支持 PGS/SUP 图形字幕"
    VERBATIM
  )
endif()
