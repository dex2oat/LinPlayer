import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';
import '../../../core/api/api_interfaces.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/media_providers.dart';
import '../../../core/providers/download_providers.dart';
import '../../../core/network/prefetch_proxy/prefetch_proxy.dart';
import '../../../core/services/app_logger.dart';
import '../../../core/services/cache_service.dart';
import '../../../core/services/danmaku_auto_loader.dart';
import '../../../core/services/download/download_helper.dart';
import '../../../core/services/font_service.dart';
import '../../../core/services/mpv_player_adapter.dart';
import '../../../core/services/subtitle_track_matcher.dart';
import '../../../core/services/translation/streaming_subtitle_translator.dart';
import '../../../core/services/intro_skip_controller.dart';
import '../../../core/services/translation/translation_actions.dart';
import '../../../core/services/translation/translation_engine.dart';
import '../../../core/services/translation/whisper/desktop_binary_manager.dart';
import '../../../core/services/translation/whisper/whisper_audio_extractor.dart';
import '../../../core/services/translation/whisper/whisper_model_manager.dart';
import '../../../core/services/translation/whisper/whisper_subtitle_controller.dart';
import '../../../core/services/translation/whisper/whisper_transcriber.dart';
import '../../../core/services/video_player_service.dart';
import '../../../core/services/watch_history/watch_history_models.dart';
import '../../../core/sources/source_playback.dart';
import '../../../core/sources/source_registry.dart';
import '../../../core/utils/playback_error_text.dart';
import '../../../core/utils/playback_url_resolver.dart';
import '../../../core/utils/track_preference.dart';
import '../../../core/widgets/player_settings_panel.dart';
import '../../../ui/widgets/common/danmaku_overlay.dart';
import '../../../ui/widgets/common/danmaku_search_widget.dart';
import '../../../ui/widgets/common/source_quality_button.dart';
import '../../shell/desktop_nav_model.dart';

part 'desktop_player_screen_state.dart';
part 'desktop_player_screen_panels.dart';

/// 桌面端播放器 - 全新设计
///
/// 专为桌面端（Windows/Linux）优化的沉浸式播放器界面：
/// - 独立的桌面控制栏布局（顶栏、底栏、侧边浮动按钮）
/// - 鼠标移动自动显示/隐藏控制栏
/// - 丰富的键盘快捷键支持
/// - 视频区域热区点击交互
class DesktopPlayerScreen extends ConsumerStatefulWidget {
  final String itemId;
  final String? mediaSourceId;

  /// 非空表示「网盘/聚合源直链播放」：复用本播放页全部能力播放网盘直链。
  final SourcePlayback? sourcePlay;

  const DesktopPlayerScreen({
    super.key,
    required this.itemId,
    this.mediaSourceId,
    this.sourcePlay,
  });

  @override
  ConsumerState<DesktopPlayerScreen> createState() =>
      _DesktopPlayerScreenState();
}
