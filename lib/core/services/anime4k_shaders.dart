import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

/// Anime4K 超分档位 → GLSL shader 链的单一事实来源。
///
/// media_kit 内核（桌面/iOS）与 Android 原生 mpv 内核都从这里取档位对应的
/// shader 列表，并把打包在 assets 里的 .glsl 落地成真实文件路径喂给 mpv
/// （mpv 只能从文件系统读 shader）。以前档位映射只写在 media_kit 适配器里，
/// 原生 mpv 适配器拿不到映射 → Android 超分完全不生效，抽到这里两端共用。
///
/// 六档 = **纯去噪放大**（Anime4K Upscale+Denoise），**不含任何 Restore/锐化**——
/// Restore CNN 会在动态画面上产生边缘振铃/拖影且最吃显卡，用户明确不需要，全部剔除。
/// 一条从核显到壮机的算力梯子（越往后越清晰、越吃显卡）：
///   单档 去噪 S / M / L（S 供核显）；叠加档 去噪叠加 M / L / VL（二次去噪更净，供强显卡）。
/// 链路：Clamp 高光 → 去噪放大(x2) →〔自动降采样回显示分辨率〕→〔叠加档:二次去噪 M〕→ 收尾放大。
/// 'off'/未知档位返回空列表(=关超分)。**键名沿用 modeA..modeAC 不变**（持久化/UI 兼容），
/// 仅内容与标签改为去噪梯子。
const Map<String, List<String>> kAnime4KShaderPresets = {
  // 去噪 S（核显/最轻）
  'modeA': [
    'Anime4K_Clamp_Highlights.glsl',
    'Anime4K_Upscale_Denoise_CNN_x2_S.glsl',
    'Anime4K_AutoDownscalePre_x2.glsl',
    'Anime4K_AutoDownscalePre_x4.glsl',
    'Anime4K_Upscale_CNN_x2_S.glsl',
  ],
  // 去噪 M（均衡）
  'modeB': [
    'Anime4K_Clamp_Highlights.glsl',
    'Anime4K_Upscale_Denoise_CNN_x2_M.glsl',
    'Anime4K_AutoDownscalePre_x2.glsl',
    'Anime4K_AutoDownscalePre_x4.glsl',
    'Anime4K_Upscale_CNN_x2_M.glsl',
  ],
  // 去噪 L（清晰）
  'modeC': [
    'Anime4K_Clamp_Highlights.glsl',
    'Anime4K_Upscale_Denoise_CNN_x2_L.glsl',
    'Anime4K_AutoDownscalePre_x2.glsl',
    'Anime4K_AutoDownscalePre_x4.glsl',
    'Anime4K_Upscale_CNN_x2_M.glsl',
  ],
  // 去噪叠加 M（M 去噪 + 二次 M 去噪，更净）
  'modeAA': [
    'Anime4K_Clamp_Highlights.glsl',
    'Anime4K_Upscale_Denoise_CNN_x2_M.glsl',
    'Anime4K_AutoDownscalePre_x2.glsl',
    'Anime4K_AutoDownscalePre_x4.glsl',
    'Anime4K_Upscale_Denoise_CNN_x2_M.glsl',
    'Anime4K_Upscale_CNN_x2_M.glsl',
  ],
  // 去噪叠加 L（L 去噪 + 二次 M 去噪，强）
  'modeBB': [
    'Anime4K_Clamp_Highlights.glsl',
    'Anime4K_Upscale_Denoise_CNN_x2_L.glsl',
    'Anime4K_AutoDownscalePre_x2.glsl',
    'Anime4K_AutoDownscalePre_x4.glsl',
    'Anime4K_Upscale_Denoise_CNN_x2_M.glsl',
    'Anime4K_Upscale_CNN_x2_M.glsl',
  ],
  // 去噪叠加 VL（VL 去噪 + 二次 M 去噪，壮机最强）
  'modeAC': [
    'Anime4K_Clamp_Highlights.glsl',
    'Anime4K_Upscale_Denoise_CNN_x2_VL.glsl',
    'Anime4K_AutoDownscalePre_x2.glsl',
    'Anime4K_AutoDownscalePre_x4.glsl',
    'Anime4K_Upscale_Denoise_CNN_x2_M.glsl',
    'Anime4K_Upscale_CNN_x2_M.glsl',
  ],
};

/// [level] 是否为一个开启超分的有效档位（非 off / 非未知）。
bool isAnime4KLevelEnabled(String? level) =>
    level != null && kAnime4KShaderPresets.containsKey(level);

String _shaderFileName(String shaderRef) {
  final normalized = shaderRef.replaceAll('\\', '/');
  final slash = normalized.lastIndexOf('/');
  return slash >= 0 ? normalized.substring(slash + 1) : normalized;
}

/// 把打包的 shader asset 落地成真实文件，返回其（正斜杠）路径。
/// 已存在且大小一致则跳过写入。
Future<String> _ensureShaderAssetFile(String shaderRef) async {
  final fileName = _shaderFileName(shaderRef);
  final assetPath = 'assets/mpv/shaders/$fileName';
  final supportDir = await getApplicationSupportDirectory();
  final shaderDir = Directory('${supportDir.path}/shaders');
  if (!shaderDir.existsSync()) {
    shaderDir.createSync(recursive: true);
  }

  final shaderFile = File('${shaderDir.path}/$fileName');
  final shaderData = await rootBundle.load(assetPath);
  final bytes = shaderData.buffer.asUint8List(
    shaderData.offsetInBytes,
    shaderData.lengthInBytes,
  );
  if (!shaderFile.existsSync() || await shaderFile.length() != bytes.length) {
    await shaderFile.writeAsBytes(bytes, flush: true);
  }
  return shaderFile.path.replaceAll('\\', '/');
}

/// 解析档位 → 已落地的 shader 文件路径列表。
/// 关闭 / 未知档位返回空列表。缺资源时抛出，让调用方回退提示。
Future<List<String>> resolveAnime4KShaderPaths(String? level) async {
  final refs = level == null ? null : kAnime4KShaderPresets[level];
  if (refs == null || refs.isEmpty) return const [];
  final paths = <String>[];
  for (final ref in refs) {
    paths.add(await _ensureShaderAssetFile(ref));
  }
  return paths;
}
