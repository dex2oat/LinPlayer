import 'dart:convert';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api/api_interfaces.dart';
import '../api/emby_api.dart';

import '../services/cache_service.dart';
import '../services/ext_domain_service.dart';
import '../utils/platform_utils.dart';

SharedPreferences? _sharedPreferences;

Future<void> initializeAppPreferences() async {
  _sharedPreferences = await SharedPreferences.getInstance();
}

SharedPreferences get _prefs {
  final prefs = _sharedPreferences;
  if (prefs == null) {
    throw StateError(
      'SharedPreferences has not been initialized. Call initializeAppPreferences() before running the app.',
    );
  }
  return prefs;
}

/// 当前API客户端Provider
/// 
/// 基于当前活跃服务器自动创建EmbyApiClient；
/// 未登录时回退MockApiClient（用于首次启动/服务器列表页）。
final apiClientProvider = Provider<ApiClientFactory>((ref) {
  final server = ref.watch(currentServerProvider);
  if (server == null) throw StateError('未连接服务器，请先添加服务器');
  final client = EmbyApiClient(
    baseUrl: server.activeLineUrl,
    authToken: server.authToken,
    userId: server.userId,
  );
  return client;
});

/// 认证状态Provider
final authStateProvider = StateProvider<AuthState>((ref) => AuthState.unauthenticated);

enum AuthState { unauthenticated, authenticating, authenticated, error }

bool serverHasUsableAuth(ServerConfig? server) {
  final token = server?.authToken;
  return token != null && token.isNotEmpty;
}

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

typedef PreferenceReader<T> = T? Function(SharedPreferences prefs);
typedef PreferenceWriter<T> = Future<void> Function(SharedPreferences prefs, T value);

class PreferenceNotifier<T> extends StateNotifier<T> {
  PreferenceNotifier({
    required T defaultValue,
    required PreferenceReader<T> readValue,
    required PreferenceWriter<T> writeValue,
  })  : _writeValue = writeValue,
        super(readValue(_prefs) ?? defaultValue);

  final PreferenceWriter<T> _writeValue;

  @override
  set state(T value) {
    super.state = value;
    _save(value);
  }

  Future<void> _save(T value) async {
    try {
      await _writeValue(_prefs, value);
    } catch (_) {
      // Ignore preference write failures and keep the in-memory state.
    }
  }
}

/// 当前服务器Provider
final currentServerProvider = StateNotifierProvider<CurrentServerNotifier, ServerConfig?>((ref) {
  return CurrentServerNotifier(ref.read(serverListProvider));
});

class CurrentServerNotifier extends StateNotifier<ServerConfig?> {
  CurrentServerNotifier([List<ServerConfig> availableServers = const []])
      : super(_restoreCurrentServer(availableServers));

  static const _currentServerKey = 'linplayer_current_server_id';

  static ServerConfig? _restoreCurrentServer(
    List<ServerConfig> servers, {
    String? preferredServerId,
  }) {
    try {
      final serverId = preferredServerId ?? _prefs.getString(_currentServerKey);
      if (serverId != null) {
        final saved = servers.where((s) => s.id == serverId).firstOrNull;
        if (saved != null) {
          return saved;
        }
      }
    } catch (_) {
      // Ignore restore failures and fall back below.
    }
    return servers.firstOrNull;
  }

  Future<void> loadFromSaved(
    List<ServerConfig> servers, {
    String? preferredServerId,
  }) async {
    super.state = _restoreCurrentServer(
      servers,
      preferredServerId: preferredServerId,
    );
  }

  Future<void> _saveCurrentServer() async {
    try {
      final prefs = _prefs;
      if (state != null) {
        await prefs.setString(_currentServerKey, state!.id);
      } else {
        await prefs.remove(_currentServerKey);
      }
    } catch (e) {
      // 保存失败
    }
  }

  @override
  set state(ServerConfig? value) {
    super.state = value;
    _saveCurrentServer();
  }

  void clear() {
    state = null;
  }
}

class ServerConfig {
  final String id;
  final String name;
  final String baseUrl;
  final String? iconUrl;
  final String? remark;
  final List<ServerLine> lines;
  final int activeLineIndex;
  final String? username;
  final String? authToken;
  final String? userId;
  
  ServerConfig({
    required this.id,
    required this.name,
    required this.baseUrl,
    this.iconUrl,
    this.remark,
    this.lines = const [],
    this.activeLineIndex = 0,
    this.username,
    this.authToken,
    this.userId,
  });
  
  String get activeLineUrl => lines.isNotEmpty ? lines[activeLineIndex].url : baseUrl;
  
  ServerConfig copyWith({
    String? id,
    String? name,
    String? baseUrl,
    String? iconUrl,
    String? remark,
    List<ServerLine>? lines,
    int? activeLineIndex,
    String? username,
    String? authToken,
    String? userId,
  }) {
    return ServerConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      baseUrl: baseUrl ?? this.baseUrl,
      iconUrl: iconUrl ?? this.iconUrl,
      remark: remark ?? this.remark,
      lines: lines ?? this.lines,
      activeLineIndex: activeLineIndex ?? this.activeLineIndex,
      username: username ?? this.username,
      authToken: authToken ?? this.authToken,
      userId: userId ?? this.userId,
    );
  }
}

class ServerLine {
  final String id;
  final String name;
  final String url;
  final String? remark;
  
  ServerLine({
    required this.id,
    required this.name,
    required this.url,
    this.remark,
  });
}

/// 服务器列表Provider
final serverListProvider = StateNotifierProvider<ServerListNotifier, List<ServerConfig>>((ref) {
  return ServerListNotifier();
});

class ServerListNotifier extends StateNotifier<List<ServerConfig>> {
  ServerListNotifier() : super(_loadServersSync());

  static const _serversKey = 'linplayer_servers';

  static List<ServerConfig> _loadServersSync() {
    try {
      final prefs = _prefs;
      final jsonStr = prefs.getString(_serversKey);
      if (jsonStr != null) {
        final List<dynamic> jsonList = jsonDecode(jsonStr);
        final servers = jsonList.map((e) => _serverConfigFromJson(e as Map<String, dynamic>)).toList();
        debugPrint('[ServerList] Loaded ${servers.length} servers');
        for (final server in servers) {
          debugPrint('[ServerList] Loaded ${server.name}: authToken=${server.authToken != null ? 'present' : 'null'}, userId=${server.userId}');
        }
        return servers;
      }
    } catch (e) {
      debugPrint('[ServerList] Load failed: $e');
    }
    return const [];
  }

  Future<void> _saveServers() async {
    try {
      final prefs = _prefs;
      final jsonList = state.map((s) => _serverConfigToJson(s)).toList();
      debugPrint('[ServerList] Saving ${state.length} servers');
      for (final server in state) {
        debugPrint('[ServerList] Server ${server.name}: authToken=${server.authToken != null ? 'present' : 'null'}, userId=${server.userId}');
      }
      await prefs.setString(_serversKey, jsonEncode(jsonList));
      debugPrint('[ServerList] Save completed');
    } catch (e) {
      debugPrint('[ServerList] Save failed: $e');
    }
  }

  void addServer(ServerConfig server) {
    state = [...state, server];
    _saveServers();
  }

  void removeServer(String id) {
    state = state.where((s) => s.id != id).toList();
    _saveServers();
  }

  void updateServer(ServerConfig server) {
    state = state.map((s) => s.id == server.id ? server : s).toList();
    _saveServers();
  }

  void replaceServers(List<ServerConfig> servers) {
    state = List<ServerConfig>.from(servers);
    _saveServers();
  }

  void reorderServers(int oldIndex, int newIndex) {
    final servers = List<ServerConfig>.from(state);
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }
    final server = servers.removeAt(oldIndex);
    servers.insert(newIndex, server);
    state = servers;
    _saveServers();
  }

  void setActiveLine(String serverId, int lineIndex) {
    state = state.map((s) {
      if (s.id == serverId) {
        return s.copyWith(activeLineIndex: lineIndex);
      }
      return s;
    }).toList();
    _saveServers();
  }
}

Map<String, dynamic> _serverConfigToJson(ServerConfig s) {
  return {
    'id': s.id,
    'name': s.name,
    'baseUrl': s.baseUrl,
    'iconUrl': s.iconUrl,
    'remark': s.remark,
    'lines': s.lines.map((l) => {
      'id': l.id,
      'name': l.name,
      'url': l.url,
      'remark': l.remark,
    }).toList(),
    'activeLineIndex': s.activeLineIndex,
    'username': s.username,
    'authToken': s.authToken,
    'userId': s.userId,
  };
}

ServerConfig _serverConfigFromJson(Map<String, dynamic> json) {
  return ServerConfig(
    id: json['id'] as String,
    name: json['name'] as String,
    baseUrl: json['baseUrl'] as String,
    iconUrl: json['iconUrl'] as String?,
    remark: json['remark'] as String?,
    lines: (json['lines'] as List<dynamic>?)?.map((l) => ServerLine(
      id: l['id'] as String,
      name: l['name'] as String,
      url: l['url'] as String,
      remark: l['remark'] as String?,
    )).toList() ?? [],
    activeLineIndex: json['activeLineIndex'] as int? ?? 0,
    username: _emptyToNull(json['username'] as String?),
    authToken: _emptyToNull(json['authToken'] as String?),
    userId: _emptyToNull(json['userId'] as String?),
  );
}

Map<String, dynamic> serverConfigToJson(ServerConfig server) => _serverConfigToJson(server);

ServerConfig serverConfigFromJson(Map<String, dynamic> json) => _serverConfigFromJson(json);

/// 将空字符串转换为 null（清理旧数据中的空字符串）
String? _emptyToNull(String? value) {
  if (value == null || value.isEmpty) return null;
  return value;
}

/// 当前用户Provider
final currentUserProvider = FutureProvider<User?>((ref) async {
  final api = ref.watch(apiClientProvider);
  final currentServer = ref.watch(currentServerProvider);

  if (!serverHasUsableAuth(currentServer)) return null;
  
  try {
    return await api.user.getUser('current');
  } catch (e) {
    return null;
  }
});

/// 主题模式Provider
enum ThemeModeOption { light, dark, system }

enum StartupPageOption { home, servers, resume }

ThemeModeOption parseThemeMode(String? value) {
  return switch (value) {
    'light' => ThemeModeOption.light,
    'dark' => ThemeModeOption.dark,
    _ => ThemeModeOption.system,
  };
}

String themeModeLabel(ThemeModeOption mode) {
  switch (mode) {
    case ThemeModeOption.light:
      return '浅色';
    case ThemeModeOption.dark:
      return '深色';
    case ThemeModeOption.system:
      return '跟随系统';
  }
}

Locale? parseLocaleTag(String? value) {
  switch (value) {
    case null:
    case '':
    case 'system':
      return null;
    case 'zh':
    case 'zh_CN':
      return const Locale('zh', 'CN');
    case 'en':
      return const Locale('en');
    default:
      final parts = value.split(RegExp('[-_]'));
      if (parts.isEmpty || parts.first.isEmpty) return null;
      return parts.length > 1 ? Locale(parts.first, parts[1]) : Locale(parts.first);
  }
}

String localeToPreferenceTag(Locale? locale) {
  if (locale == null) return 'system';
  return locale.toLanguageTag().replaceAll('-', '_');
}

StartupPageOption parseStartupPage(String? value) {
  return switch (value) {
    'servers' => StartupPageOption.servers,
    'resume' => StartupPageOption.resume,
    _ => StartupPageOption.home,
  };
}

bool _usesEnglishLabels(Locale? locale) => locale?.languageCode == 'en';

String localizedThemeModeLabel(ThemeModeOption mode, {Locale? displayLocale}) {
  final english = _usesEnglishLabels(displayLocale);
  switch (mode) {
    case ThemeModeOption.light:
      return english ? 'Light' : '浅色';
    case ThemeModeOption.dark:
      return english ? 'Dark' : '深色';
    case ThemeModeOption.system:
      return english ? 'Follow system' : '跟随系统';
  }
}

String localizedLocaleLabel(Locale? locale, {Locale? displayLocale}) {
  final english = _usesEnglishLabels(displayLocale);
  if (locale == null) {
    return english ? 'Follow system' : '跟随系统';
  }
  final normalized = locale.toLanguageTag().replaceAll('-', '_');
  switch (normalized) {
    case 'zh':
    case 'zh_CN':
      return english ? 'Simplified Chinese' : '简体中文';
    case 'en':
      return 'English';
    default:
      return normalized;
  }
}

String startupPageLabel(StartupPageOption option, {Locale? displayLocale}) {
  final english = _usesEnglishLabels(displayLocale);
  switch (option) {
    case StartupPageOption.home:
      return english ? 'Home' : '首页';
    case StartupPageOption.servers:
      return english ? 'Servers' : '服务器列表';
    case StartupPageOption.resume:
      return english ? 'Continue watching' : '继续观看';
  }
}

const String resumeRoutePath = '/resume';

String mobileStartupLocationFor(StartupPageOption option) {
  return switch (option) {
    StartupPageOption.home => '/home',
    StartupPageOption.servers => '/',
    StartupPageOption.resume => resumeRoutePath,
  };
}

String desktopStartupLocationFor(StartupPageOption option) {
  return switch (option) {
    StartupPageOption.home => '/',
    StartupPageOption.servers => '/servers',
    StartupPageOption.resume => resumeRoutePath,
  };
}

final themeModeProvider =
    StateNotifierProvider<PreferenceNotifier<ThemeModeOption>, ThemeModeOption>((ref) {
  return PreferenceNotifier<ThemeModeOption>(
    defaultValue: ThemeModeOption.system,
    readValue: (prefs) => parseThemeMode(prefs.getString('linplayer_theme_mode')),
    writeValue: (prefs, value) async {
      await prefs.setString('linplayer_theme_mode', value.name);
    },
  );
});

final localeProvider = StateNotifierProvider<PreferenceNotifier<Locale?>, Locale?>((ref) {
  return PreferenceNotifier<Locale?>(
    defaultValue: null,
    readValue: (prefs) => parseLocaleTag(prefs.getString('linplayer_locale')),
    writeValue: (prefs, value) async {
      if (value == null) {
        await prefs.remove('linplayer_locale');
      } else {
        await prefs.setString('linplayer_locale', localeToPreferenceTag(value));
      }
    },
  );
});

final startupPageProvider =
    StateNotifierProvider<PreferenceNotifier<StartupPageOption>, StartupPageOption>((ref) {
  return PreferenceNotifier<StartupPageOption>(
    defaultValue: StartupPageOption.home,
    readValue: (prefs) => parseStartupPage(prefs.getString('linplayer_startup_page')),
    writeValue: (prefs, value) async {
      await prefs.setString('linplayer_startup_page', value.name);
    },
  );
});

String localeLabel(Locale? locale) {
  if (locale == null) {
    return '跟随系统';
  }
  final normalized = locale.toLanguageTag().replaceAll('-', '_');
  switch (normalized) {
    case 'zh':
    case 'zh_CN':
      return '简体中文';
    case 'en':
      return 'English';
    default:
      return normalized;
  }
}

/// 播放器内核Provider
final playerCoreProvider = StateNotifierProvider<PreferenceNotifier<String>, String>((ref) {
  return PreferenceNotifier<String>(
    defaultValue: defaultPlayerCoreKey,
    readValue: (prefs) => normalizePlayerCore(prefs.getString('linplayer_player_core')),
    writeValue: (prefs, value) async {
      await prefs.setString('linplayer_player_core', normalizePlayerCore(value));
    },
  );
});

/// 默认播放速度Provider
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

/// 快进步长Provider（秒）
final skipForwardStepProvider = StateNotifierProvider<PreferenceNotifier<int>, int>((ref) {
  return PreferenceNotifier<int>(
    defaultValue: 10,
    readValue: (prefs) => prefs.getInt('linplayer_skip_forward_step'),
    writeValue: (prefs, value) async {
      await prefs.setInt('linplayer_skip_forward_step', value);
    },
  );
});

/// 长按快进倍速Provider
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

/// 硬件解码Provider
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

/// 后台播放Provider
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

/// 自动播放下一集Provider
final autoPlayNextProvider = StateNotifierProvider<PreferenceNotifier<bool>, bool>((ref) {
  return PreferenceNotifier<bool>(
    defaultValue: true,
    readValue: (prefs) => prefs.getBool('linplayer_auto_play_next'),
    writeValue: (prefs, value) async {
      await prefs.setBool('linplayer_auto_play_next', value);
    },
  );
});

/// 弹幕开关Provider
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

/// 弹幕透明度Provider
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

/// 弹幕字号Provider
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

/// 弹幕速度Provider
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

/// 弹幕密度Provider
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

/// 弹幕延迟Provider (秒)
final danmakuDelayProvider = StateProvider<double>((ref) => 0.0);

/// 弹幕去重开关Provider
final danmakuDedupProvider = StateProvider<bool>((ref) => false);

/// 弹幕去重时间窗口Provider (秒)
final danmakuDedupWindowProvider = StateProvider<double>((ref) => 10.0);

/// 已加载的弹幕列表Provider
final loadedDanmakuProvider = StateProvider<List<DanmakuItem>>((ref) => []);

/// 弹幕屏蔽词列表Provider
final danmakuBlockwordsProvider = StateNotifierProvider<DanmakuBlockwordsNotifier, List<String>>((ref) {
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
    state = state.where((w) => w != word).toList();
  }

  void importWords(List<String> words) {
    final newWords = words.where((w) => w.isNotEmpty && !state.contains(w)).toList();
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

/// ==========================================
/// 播放器设置Providers
/// ==========================================

/// 首选字幕语言Provider
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

/// 首选音频语言Provider
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

/// 首选版本Provider
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

/// 记忆亮度Provider
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

/// 当前播放亮度值Provider (0.0 - 1.0)
final playerBrightnessProvider = StateProvider<double>((ref) => 1.0);

/// 字幕字体Provider
final subtitleFontProvider = StateNotifierProvider<PreferenceNotifier<String>, String>((ref) {
  return PreferenceNotifier<String>(
    defaultValue: '默认',
    readValue: (prefs) => prefs.getString('linplayer_subtitle_font'),
    writeValue: (prefs, value) async {
      await prefs.setString('linplayer_subtitle_font', value);
    },
  );
});

/// MPV自动修正杜比视界颜色Provider
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

/// 启用Impeller渲染引擎Provider
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

/// EXO播放器使用libass渲染ASS字幕Provider
final exoLibassProvider = StateNotifierProvider<PreferenceNotifier<bool>, bool>((ref) {
  return PreferenceNotifier<bool>(
    defaultValue: false,
    readValue: (prefs) => prefs.getBool('linplayer_exo_libass'),
    writeValue: (prefs, value) async {
      await prefs.setBool('linplayer_exo_libass', value);
    },
  );
});

/// 画面比例Provider
final aspectRatioProvider = StateProvider<String>((ref) => '自动');

/// 跳过片头开始时间（秒）
final skipOpeningStartProvider = StateProvider<int>((ref) => 0);

/// 跳过片头结束时间（秒）
final skipOpeningEndProvider = StateProvider<int>((ref) => 0);

/// 跳过片尾开始时间（秒）
final skipEndingStartProvider = StateProvider<int>((ref) => 0);

/// 跳过片尾结束时间（秒）
final skipEndingEndProvider = StateProvider<int>((ref) => 0);

/// 跳过模式：true=自动跳过, false=显示按钮
final skipAutoModeProvider = StateProvider<bool>((ref) => false);

/// 定时关闭剩余时间Provider
final sleepTimerRemainingProvider = StateProvider<Duration?>((ref) => null);

/// 字幕同步偏移Provider（秒）
final subtitleDelayProvider = StateProvider<double>((ref) => 0.0);

/// 音频同步偏移Provider（秒）
final audioDelayProvider = StateProvider<double>((ref) => 0.0);

/// 字幕大小Provider（0.0 - 1.0）
final subtitleSizeProvider = StateProvider<double>((ref) => 0.5);

/// 字幕位置Provider（0.0 - 1.0）
final subtitlePositionProvider = StateProvider<double>((ref) => 0.0);

/// 字幕黑色背景Provider
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

/// Anime4K 档位Provider ('off', 'modeA', 'modeB', 'modeC')
final anime4KLevelProvider = StateProvider<String>((ref) => 'off');

/// ==========================================
/// 外观设置Providers
/// ==========================================

/// 隐藏每日推荐Provider
final hideDailyRecommendationsProvider =
    StateNotifierProvider<PreferenceNotifier<bool>, bool>((ref) {
  return PreferenceNotifier<bool>(
    defaultValue: false,
    readValue: (prefs) => prefs.getBool('linplayer_hide_daily_recommendations'),
    writeValue: (prefs, value) async {
      await prefs.setBool('linplayer_hide_daily_recommendations', value);
    },
  );
});

/// 屏蔽的媒体库ID列表Provider
final hiddenLibrariesProvider = StateNotifierProvider<HiddenLibrariesNotifier, Set<String>>((ref) {
  return HiddenLibrariesNotifier();
});

class HiddenLibrariesNotifier extends StateNotifier<Set<String>> {
  HiddenLibrariesNotifier() : super({});

  void toggle(String libraryId) {
    if (state.contains(libraryId)) {
      state = Set.from(state)..remove(libraryId);
    } else {
      state = Set.from(state)..add(libraryId);
    }
  }

  void clear() {
    state = {};
  }
}

/// ==========================================
/// 缓存设置Providers
/// ==========================================

final imageCacheExpiryDaysProvider = StateProvider<int>((ref) => 14);

final videoCacheMaxSizeMBProvider = StateProvider<int>((ref) => 1024);

class CacheSizeInfo {
  final int imageBytes;
  final int videoBytes;
  CacheSizeInfo({required this.imageBytes, required this.videoBytes});
  int get totalBytes => imageBytes + videoBytes;
  String get imageFormatted => CacheService.formatBytes(imageBytes);
  String get videoFormatted => CacheService.formatBytes(videoBytes);
  String get totalFormatted => CacheService.formatBytes(totalBytes);
}

final cacheSizeProvider = FutureProvider<CacheSizeInfo>((ref) async {
  return CacheSizeInfo(
    imageBytes: await CacheService.getImageCacheSize(),
    videoBytes: await CacheService.getVideoCacheSize(),
  );
});

/// ==========================================
/// WebDAV备份Providers
/// ==========================================

/// WebDAV配置Provider
final webdavConfigProvider = StateNotifierProvider<WebdavConfigNotifier, WebdavConfig?>((ref) {
  return WebdavConfigNotifier();
});

class WebdavConfigNotifier extends StateNotifier<WebdavConfig?> {
  WebdavConfigNotifier() : super(null);

  void setConfig(String serverUrl, String username, String password) {
    state = WebdavConfig(
      serverUrl: serverUrl,
      username: username,
      password: password,
    );
  }

  void clearConfig() {
    state = null;
  }
}

class WebdavConfig {
  final String serverUrl;
  final String username;
  final String password;

  WebdavConfig({
    required this.serverUrl,
    required this.username,
    required this.password,
  });
}

/// ==========================================
/// 扩展线路同步Providers
/// ==========================================

/// 扩展线路同步服务Provider
final extDomainServiceProvider = Provider<ExtDomainService>((ref) {
  return ExtDomainService();
});

/// 扩展线路同步配置Provider（按服务器ID存储）
final extDomainConfigProvider = StateNotifierProvider<ExtDomainConfigNotifier, Map<String, ExtDomainConfig>>((ref) {
  return ExtDomainConfigNotifier();
});

class ExtDomainConfigNotifier extends StateNotifier<Map<String, ExtDomainConfig>> {
  ExtDomainConfigNotifier() : super({}) {
    _loadConfig();
  }

  static const _configKey = 'linplayer_ext_domain_configs';

  Future<void> _loadConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_configKey);
      if (jsonStr != null) {
        final json = jsonDecode(jsonStr) as Map<String, dynamic>;
        state = json.map((key, value) => MapEntry(
          key,
          ExtDomainConfig(
            extDomainUrl: value['extDomainUrl'] as String,
            autoSync: value['autoSync'] as bool? ?? false,
          ),
        ));
      }
    } catch (e) {
      // 加载失败
    }
  }

  Future<void> _saveConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = state.map((key, value) => MapEntry(key, {
        'extDomainUrl': value.extDomainUrl,
        'autoSync': value.autoSync,
      }));
      await prefs.setString(_configKey, jsonEncode(json));
    } catch (e) {
      // 保存失败
    }
  }

  void setConfig(String serverId, String extDomainUrl, {bool autoSync = false}) {
    state = {
      ...state,
      serverId: ExtDomainConfig(
        extDomainUrl: extDomainUrl,
        autoSync: autoSync,
      ),
    };
    _saveConfig();
  }

  void clearConfig(String serverId) {
    final newState = Map<String, ExtDomainConfig>.from(state);
    newState.remove(serverId);
    state = newState;
    _saveConfig();
  }

  void setAutoSync(String serverId, bool autoSync) {
    final config = state[serverId];
    if (config != null) {
      state = {
        ...state,
        serverId: ExtDomainConfig(
          extDomainUrl: config.extDomainUrl,
          autoSync: autoSync,
        ),
      };
      _saveConfig();
    }
  }

  ExtDomainConfig? getConfig(String serverId) => state[serverId];
}

class ExtDomainConfig {
  final String extDomainUrl;
  final bool autoSync;

  ExtDomainConfig({
    required this.extDomainUrl,
    this.autoSync = false,
  });
}

/// 同步线路结果Provider
final syncExtDomainsProvider = FutureProvider.family<List<ExtServerLine>, String>((ref, serverId) async {
  final service = ref.read(extDomainServiceProvider);
  final configs = ref.read(extDomainConfigProvider);
  final config = configs[serverId];
  final servers = ref.read(serverListProvider);

  if (config == null || config.extDomainUrl.isEmpty) {
    return [];
  }

  final server = servers.where((s) => s.id == serverId).firstOrNull;
  if (server == null || server.authToken == null) {
    return [];
  }

  try {
    return await service.fetchExtDomains(
      extDomainUrl: config.extDomainUrl,
      embyServerUrl: server.baseUrl,
      embyToken: server.authToken!,
    );
  } catch (e) {
    return [];
  }
});
