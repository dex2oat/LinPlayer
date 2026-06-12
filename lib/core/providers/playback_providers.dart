import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_interfaces.dart';
import '../utils/platform_utils.dart';
import 'app_preferences.dart';

String get defaultPlayerCoreKey => isDesktopPlatform ? 'mpv' : 'exoPlayer';

String normalizePlayerCore(String? value) {
  switch (value) {
    case 'mpv':
    case 'media_kit':
      return 'mpv';
    case 'exoPlayer':
    case 'video_player':
      return 'exoPlayer';
    default:
      return defaultPlayerCoreKey;
  }
}

final playerCoreProvider = StateNotifierProvider<PreferenceNotifier<String>, String>((ref) {
  return PreferenceNotifier<String>(
    defaultValue: defaultPlayerCoreKey,
    readValue: (prefs) => normalizePlayerCore(prefs.getString('linplayer_player_core')),
    writeValue: (prefs, value) async {
      await prefs.setString('linplayer_player_core', normalizePlayerCore(value));
    },
  );
});

final defaultPlaybackSpeedProvider =
    StateNotifierProvider<PreferenceNotifier<double>, double>((ref) {
  return PreferenceNotifier<double>(
    defaultValue: 1.0,
    readValue: (prefs) => prefs.getDouble('linplayer_default_playback_speed'),
    writeValue: (prefs, value) async {
      await prefs.setDouble('linplayer_default_playback_speed', value);
    },
  );
});

final skipForwardStepProvider = StateNotifierProvider<PreferenceNotifier<int>, int>((ref) {
  return PreferenceNotifier<int>(
    defaultValue: 10,
    readValue: (prefs) => prefs.getInt('linplayer_skip_forward_step'),
    writeValue: (prefs, value) async {
      await prefs.setInt('linplayer_skip_forward_step', value);
    },
  );
});

final longPressSpeedProvider =
    StateNotifierProvider<PreferenceNotifier<double>, double>((ref) {
  return PreferenceNotifier<double>(
    defaultValue: 2.0,
    readValue: (prefs) => prefs.getDouble('linplayer_long_press_speed'),
    writeValue: (prefs, value) async {
      await prefs.setDouble('linplayer_long_press_speed', value);
    },
  );
});

final hardwareDecodingProvider =
    StateNotifierProvider<PreferenceNotifier<bool>, bool>((ref) {
  return PreferenceNotifier<bool>(
    defaultValue: true,
    readValue: (prefs) => prefs.getBool('linplayer_hardware_decoding'),
    writeValue: (prefs, value) async {
      await prefs.setBool('linplayer_hardware_decoding', value);
    },
  );
});

final backgroundPlaybackProvider =
    StateNotifierProvider<PreferenceNotifier<bool>, bool>((ref) {
  return PreferenceNotifier<bool>(
    defaultValue: true,
    readValue: (prefs) => prefs.getBool('linplayer_background_playback'),
    writeValue: (prefs, value) async {
      await prefs.setBool('linplayer_background_playback', value);
    },
  );
});

final autoPlayNextProvider = StateNotifierProvider<PreferenceNotifier<bool>, bool>((ref) {
  return PreferenceNotifier<bool>(
    defaultValue: true,
    readValue: (prefs) => prefs.getBool('linplayer_auto_play_next'),
    writeValue: (prefs, value) async {
      await prefs.setBool('linplayer_auto_play_next', value);
    },
  );
});

final danmakuEnabledProvider =
    StateNotifierProvider<PreferenceNotifier<bool>, bool>((ref) {
  return PreferenceNotifier<bool>(
    defaultValue: true,
    readValue: (prefs) => prefs.getBool('linplayer_danmaku_enabled'),
    writeValue: (prefs, value) async {
      await prefs.setBool('linplayer_danmaku_enabled', value);
    },
  );
});

final danmakuOpacityProvider =
    StateNotifierProvider<PreferenceNotifier<double>, double>((ref) {
  return PreferenceNotifier<double>(
    defaultValue: 0.8,
    readValue: (prefs) => prefs.getDouble('linplayer_danmaku_opacity'),
    writeValue: (prefs, value) async {
      await prefs.setDouble('linplayer_danmaku_opacity', value);
    },
  );
});

final danmakuFontSizeProvider =
    StateNotifierProvider<PreferenceNotifier<double>, double>((ref) {
  return PreferenceNotifier<double>(
    defaultValue: 0.5,
    readValue: (prefs) => prefs.getDouble('linplayer_danmaku_font_size'),
    writeValue: (prefs, value) async {
      await prefs.setDouble('linplayer_danmaku_font_size', value);
    },
  );
});

final danmakuSpeedProvider =
    StateNotifierProvider<PreferenceNotifier<double>, double>((ref) {
  return PreferenceNotifier<double>(
    defaultValue: 0.5,
    readValue: (prefs) => prefs.getDouble('linplayer_danmaku_speed'),
    writeValue: (prefs, value) async {
      await prefs.setDouble('linplayer_danmaku_speed', value);
    },
  );
});

final danmakuDensityProvider =
    StateNotifierProvider<PreferenceNotifier<double>, double>((ref) {
  return PreferenceNotifier<double>(
    defaultValue: 0.5,
    readValue: (prefs) => prefs.getDouble('linplayer_danmaku_density'),
    writeValue: (prefs, value) async {
      await prefs.setDouble('linplayer_danmaku_density', value);
    },
  );
});

final danmakuDelayProvider = StateProvider<double>((ref) => 0.0);
final danmakuDedupProvider = StateProvider<bool>((ref) => false);
final danmakuDedupWindowProvider = StateProvider<double>((ref) => 10.0);
final loadedDanmakuProvider = StateProvider<List<DanmakuItem>>((ref) => []);

final danmakuBlockwordsProvider =
    StateNotifierProvider<DanmakuBlockwordsNotifier, List<String>>((ref) {
  return DanmakuBlockwordsNotifier();
});

class DanmakuBlockwordsNotifier extends StateNotifier<List<String>> {
  DanmakuBlockwordsNotifier() : super([]);

  void addWord(String word) {
    if (word.isNotEmpty && !state.contains(word)) {
      state = [...state, word];
    }
  }

  void removeWord(String word) {
    state = state.where((entry) => entry != word).toList();
  }

  void importWords(List<String> words) {
    final newWords = words.where((word) => word.isNotEmpty && !state.contains(word)).toList();
    if (newWords.isNotEmpty) {
      state = [...state, ...newWords];
    }
  }

  void importUserBlocks(List<String> userIds) {
    final prefixedIds = userIds.map((id) => 'uid:$id').toList();
    importWords(prefixedIds);
  }

  void clear() {
    state = [];
  }
}

final preferredSubtitleLanguageProvider =
    StateNotifierProvider<PreferenceNotifier<String>, String>((ref) {
  return PreferenceNotifier<String>(
    defaultValue: 'chi',
    readValue: (prefs) => prefs.getString('linplayer_preferred_subtitle_language'),
    writeValue: (prefs, value) async {
      await prefs.setString('linplayer_preferred_subtitle_language', value);
    },
  );
});

final preferredAudioLanguageProvider =
    StateNotifierProvider<PreferenceNotifier<String>, String>((ref) {
  return PreferenceNotifier<String>(
    defaultValue: 'jpn',
    readValue: (prefs) => prefs.getString('linplayer_preferred_audio_language'),
    writeValue: (prefs, value) async {
      await prefs.setString('linplayer_preferred_audio_language', value);
    },
  );
});

final preferredVersionProvider =
    StateNotifierProvider<PreferenceNotifier<String>, String>((ref) {
  return PreferenceNotifier<String>(
    defaultValue: '原盘',
    readValue: (prefs) => prefs.getString('linplayer_preferred_version'),
    writeValue: (prefs, value) async {
      await prefs.setString('linplayer_preferred_version', value);
    },
  );
});

final rememberBrightnessProvider =
    StateNotifierProvider<PreferenceNotifier<bool>, bool>((ref) {
  return PreferenceNotifier<bool>(
    defaultValue: true,
    readValue: (prefs) => prefs.getBool('linplayer_remember_brightness'),
    writeValue: (prefs, value) async {
      await prefs.setBool('linplayer_remember_brightness', value);
    },
  );
});

final playerBrightnessProvider = StateProvider<double>((ref) => 1.0);

final subtitleFontProvider = StateNotifierProvider<PreferenceNotifier<String>, String>((ref) {
  return PreferenceNotifier<String>(
    defaultValue: '默认',
    readValue: (prefs) => prefs.getString('linplayer_subtitle_font'),
    writeValue: (prefs, value) async {
      await prefs.setString('linplayer_subtitle_font', value);
    },
  );
});

final mpvDolbyVisionFixProvider =
    StateNotifierProvider<PreferenceNotifier<bool>, bool>((ref) {
  return PreferenceNotifier<bool>(
    defaultValue: false,
    readValue: (prefs) => prefs.getBool('linplayer_mpv_dolby_vision_fix'),
    writeValue: (prefs, value) async {
      await prefs.setBool('linplayer_mpv_dolby_vision_fix', value);
    },
  );
});

final impellerEnabledProvider =
    StateNotifierProvider<PreferenceNotifier<bool>, bool>((ref) {
  return PreferenceNotifier<bool>(
    defaultValue: false,
    readValue: (prefs) => prefs.getBool('linplayer_impeller_enabled'),
    writeValue: (prefs, value) async {
      await prefs.setBool('linplayer_impeller_enabled', value);
    },
  );
});

final exoLibassProvider = StateNotifierProvider<PreferenceNotifier<bool>, bool>((ref) {
  return PreferenceNotifier<bool>(
    defaultValue: false,
    readValue: (prefs) => prefs.getBool('linplayer_exo_libass'),
    writeValue: (prefs, value) async {
      await prefs.setBool('linplayer_exo_libass', value);
    },
  );
});

final aspectRatioProvider = StateProvider<String>((ref) => '自动');
final skipOpeningStartProvider = StateProvider<int>((ref) => 0);
final skipOpeningEndProvider = StateProvider<int>((ref) => 0);
final skipEndingStartProvider = StateProvider<int>((ref) => 0);
final skipEndingEndProvider = StateProvider<int>((ref) => 0);
final skipAutoModeProvider = StateProvider<bool>((ref) => false);
final sleepTimerRemainingProvider = StateProvider<Duration?>((ref) => null);
final subtitleDelayProvider = StateProvider<double>((ref) => 0.0);
final audioDelayProvider = StateProvider<double>((ref) => 0.0);
final subtitleSizeProvider = StateProvider<double>((ref) => 0.5);
final subtitlePositionProvider = StateProvider<double>((ref) => 0.0);

final subtitleBackgroundProvider =
    StateNotifierProvider<PreferenceNotifier<bool>, bool>((ref) {
  return PreferenceNotifier<bool>(
    defaultValue: false,
    readValue: (prefs) => prefs.getBool('linplayer_subtitle_background'),
    writeValue: (prefs, value) async {
      await prefs.setBool('linplayer_subtitle_background', value);
    },
  );
});

final anime4KLevelProvider = StateProvider<String>((ref) => 'off');
