#!/usr/bin/env bash
# 交叉编译 linplayer-core 为安卓 .rlib(证明"一份 Rust 核桌面+安卓两吃")。
# 在 Git Bash 里跑:  bash scripts/build-android.sh [arm64-v8a] [armeabi-v7a] ...
# 默认只编 arm64-v8a(手机/TV 主力)。
#
# 为什么这么绕(Windows 宿主特有的 bindgen 坑,逐条对应):
#   1. rquickjs-sys 不随包发 aarch64-linux-android 的 FFI bindings → 必须开 `bindgen` 现生成
#      (见 core/Cargo.toml 的 [target.'cfg(target_os="android")'] )。
#   2. `bindgen` 特性经 proc-macro rquickjs-macro(永远编 host)传导 → HOST 的 rquickjs-sys
#      也被迫跑 bindgen。所以 host + android 两个 bindgen 都得喂对。
#   3. NDK 的 libclang.dll:只有较新 NDK(如 30.x)带,老的(27.x)不带 → 自动挑带的那个。
#   4. libclang 当 DLL 加载时 InstalledDir 为空,找不到自己的 builtin 头(stdbool.h)
#      → 显式 `-resource-dir` 指到 NDK 的 lib/clang/<ver>。
#   5. host bindgen(msvc)还缺 WinSDK/CRT 头(stdio.h)→ 从 vcvars64.bat 灌 %INCLUDE%。
#   6. 我预置 BINDGEN_EXTRA_CLANG_ARGS_<triple> 后 cargo-ndk 不再补 sysroot → 得自带 --sysroot。
set -euo pipefail

cd "$(dirname "$0")/.."   # 仓库根

ABIS=("$@"); [ ${#ABIS[@]} -eq 0 ] && ABIS=("arm64-v8a")

# --- 挑一个带 libclang.dll 的 NDK(新的优先)---
SDK="${ANDROID_HOME:-$LOCALAPPDATA/Android/Sdk}"
NDK=""
for d in $(ls -d "$SDK"/ndk/* 2>/dev/null | sort -rV); do
  if [ -f "$d/toolchains/llvm/prebuilt/windows-x86_64/bin/libclang.dll" ]; then NDK="$d"; break; fi
done
[ -z "$NDK" ] && { echo "找不到带 libclang.dll 的 NDK(装一个 NDK 30+):$SDK/ndk/*"; exit 1; }
PB="$NDK/toolchains/llvm/prebuilt/windows-x86_64"
RESDIR="$(ls -d "$PB"/lib/clang/* 2>/dev/null | sort -rV | head -1)"   # clang resource dir(含 stdbool.h)
echo "NDK      = $NDK"
echo "resource = $RESDIR"

export ANDROID_NDK_HOME="$(cygpath -w "$NDK")"
export LIBCLANG_PATH="$(cygpath -w "$PB/bin")"
export PATH="$PB/bin:$PATH"
RES="$(cygpath -m "$RESDIR")"
SYSROOT="$(cygpath -m "$PB/sysroot")"

# dash 命名的环境变量 bash 不能 `export`(非法标识符),统一走 `env NAME=VAL` 前缀传进子进程。
ENVV=( "LIBCLANG_PATH=$LIBCLANG_PATH" "ANDROID_NDK_HOME=$ANDROID_NDK_HOME" )

# --- host bindgen:builtin 头(resource-dir)+ WinSDK 头(vcvars 的 INCLUDE)---
ENVV+=( "BINDGEN_EXTRA_CLANG_ARGS=-resource-dir=$RES" )
if [ -n "${INCLUDE:-}" ]; then
  ENVV+=( "INCLUDE=$INCLUDE" ); echo "INCLUDE  = 沿用当前环境(host bindgen 用)"
else
  # 直接 glob 找 vcvars64.bat(vswhere 默认过滤不含 BuildTools,不可靠)。只搜存在的目录(否则 set -e 会被 find 的非零退出坑掉)。
  VCVARS=""
  for base in "/c/Program Files/Microsoft Visual Studio" "/c/Program Files (x86)/Microsoft Visual Studio"; do
    [ -d "$base" ] || continue
    f="$(find "$base" -name vcvars64.bat 2>/dev/null | head -1 || true)"
    [ -n "$f" ] && { VCVARS="$f"; break; }
  done
  if [ -n "$VCVARS" ]; then
    # 必须用临时批处理逐行运行:`cmd /c "call vcvars && echo %INCLUDE%"` 里 %INCLUDE% 在解析期就展开了(那时还是空)。
    # 注意:变量别叫 TMP —— 那是 Windows 临时目录环境变量,覆盖成文件路径会让 link.exe 崩(LNK1104)。
    VCBAT="$(mktemp --suffix=.bat)"
    printf '@echo off\r\ncall "%s" >nul 2>&1\r\necho __INCB__\r\necho %%INCLUDE%%\r\necho __INCE__\r\n' "$(cygpath -w "$VCVARS")" > "$VCBAT"
    INC="$(cmd //c "$(cygpath -w "$VCBAT")" 2>/dev/null | sed -n '/__INCB__/,/__INCE__/p' | sed '1d;$d' | tr -d '\r')"
    rm -f "$VCBAT"
    if [ -n "$INC" ]; then ENVV+=( "INCLUDE=$INC" ); echo "INCLUDE  = 从 vcvars64 注入(host bindgen 用)"
    else echo "警告:vcvars64 未产出 INCLUDE,host bindgen 可能缺 WinSDK 头。"; fi
  else
    echo "警告:找不到 vcvars64.bat,host bindgen 可能缺 WinSDK 头。装 VS Build Tools,或先在 x64 Native Tools 命令行里跑本脚本。"
  fi
fi

# --- 每个 rust 目标三元组:sysroot + resource-dir(cargo-ndk 见预置就不再补 sysroot)---
declare -A TRIPLE=( [arm64-v8a]=aarch64-linux-android [armeabi-v7a]=armv7-linux-androideabi
                    [x86]=i686-linux-android [x86_64]=x86_64-linux-android )
for abi in "${ABIS[@]}"; do
  t="${TRIPLE[$abi]:-}"; [ -z "$t" ] && { echo "未知 ABI:$abi"; exit 1; }
  ENVV+=( "BINDGEN_EXTRA_CLANG_ARGS_$t=--sysroot=$SYSROOT -resource-dir=$RES" )
done

TFLAGS=(); for abi in "${ABIS[@]}"; do TFLAGS+=(-t "$abi"); done
echo "编译 ABIs: ${ABIS[*]}"
exec env "${ENVV[@]}" cargo ndk "${TFLAGS[@]}" build --release -p linplayer-core
