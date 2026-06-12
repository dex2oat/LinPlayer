import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_interfaces.dart';
import '../api/emby_api.dart';
import 'app_preferences.dart';

enum AuthState { unauthenticated, authenticating, authenticated, error }

bool serverHasUsableAuth(ServerConfig? server) {
  final token = server?.authToken;
  return token != null && token.isNotEmpty;
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

  String get activeLineUrl {
    if (lines.isEmpty) return baseUrl;
    final safeIndex = activeLineIndex.clamp(0, lines.length - 1);
    return lines[safeIndex].url;
  }

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

final authStateProvider = StateProvider<AuthState>((ref) => AuthState.unauthenticated);

final serverListProvider = StateNotifierProvider<ServerListNotifier, List<ServerConfig>>((ref) {
  return ServerListNotifier();
});

final currentServerProvider = StateNotifierProvider<CurrentServerNotifier, ServerConfig?>((ref) {
  final notifier = CurrentServerNotifier(ref.read(serverListProvider));
  ref.listen<List<ServerConfig>>(serverListProvider, (_, next) {
    notifier.syncWithAvailableServers(
      next,
      preferredServerId: notifier.selectedServerId,
    );
  });
  return notifier;
});

final apiClientProvider = Provider<ApiClientFactory>((ref) {
  final server = ref.watch(currentServerProvider);
  if (server == null) throw StateError('未连接服务器，请先添加服务器');
  return EmbyApiClient(
    baseUrl: server.activeLineUrl,
    authToken: server.authToken,
    userId: server.userId,
  );
});

final currentUserProvider = FutureProvider<User?>((ref) async {
  final currentServer = ref.watch(currentServerProvider);
  if (!serverHasUsableAuth(currentServer)) return null;

  try {
    final api = ref.watch(apiClientProvider);
    return await api.user.getUser('current');
  } catch (_) {
    return null;
  }
});

class CurrentServerNotifier extends StateNotifier<ServerConfig?> {
  CurrentServerNotifier([List<ServerConfig> availableServers = const []])
      : super(_restoreCurrentServer(availableServers));

  static const _currentServerKey = 'linplayer_current_server_id';

  String? get selectedServerId => state?.id;

  static ServerConfig? _restoreCurrentServer(
    List<ServerConfig> servers, {
    String? preferredServerId,
  }) {
    try {
      final serverId =
          preferredServerId ?? AppPreferencesStore.instance.getString(_currentServerKey);
      if (serverId != null) {
        final saved = servers.where((server) => server.id == serverId).firstOrNull;
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
    syncWithAvailableServers(
      servers,
      preferredServerId: preferredServerId,
    );
  }

  void syncWithAvailableServers(
    List<ServerConfig> servers, {
    String? preferredServerId,
  }) {
    state = _restoreCurrentServer(
      servers,
      preferredServerId: preferredServerId,
    );
  }

  Future<void> _saveCurrentServer() async {
    try {
      final prefs = AppPreferencesStore.instance;
      if (state != null) {
        await prefs.setString(_currentServerKey, state!.id);
      } else {
        await prefs.remove(_currentServerKey);
      }
    } catch (_) {
      // Ignore persistence failures and keep the in-memory state.
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

class ServerListNotifier extends StateNotifier<List<ServerConfig>> {
  ServerListNotifier() : super(_loadServersSync());

  static const _serversKey = 'linplayer_servers';

  static List<ServerConfig> _loadServersSync() {
    try {
      final jsonStr = AppPreferencesStore.instance.getString(_serversKey);
      if (jsonStr != null) {
        final List<dynamic> jsonList = jsonDecode(jsonStr);
        final servers = jsonList
            .map((entry) => _serverConfigFromJson(entry as Map<String, dynamic>))
            .toList();
        debugPrint('[ServerList] Loaded ${servers.length} servers');
        for (final server in servers) {
          debugPrint(
            '[ServerList] Loaded ${server.name}: authToken=${server.authToken != null ? 'present' : 'null'}, userId=${server.userId}',
          );
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
      final jsonList = state.map(_serverConfigToJson).toList();
      debugPrint('[ServerList] Saving ${state.length} servers');
      for (final server in state) {
        debugPrint(
          '[ServerList] Server ${server.name}: authToken=${server.authToken != null ? 'present' : 'null'}, userId=${server.userId}',
        );
      }
      await AppPreferencesStore.instance.setString(_serversKey, jsonEncode(jsonList));
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
    state = state.where((server) => server.id != id).toList();
    _saveServers();
  }

  void updateServer(ServerConfig server) {
    state = state.map((entry) => entry.id == server.id ? server : entry).toList();
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
    state = state.map((server) {
      if (server.id == serverId) {
        final safeIndex = server.lines.isEmpty
            ? 0
            : lineIndex.clamp(0, server.lines.length - 1);
        return server.copyWith(activeLineIndex: safeIndex);
      }
      return server;
    }).toList();
    _saveServers();
  }
}

Map<String, dynamic> _serverConfigToJson(ServerConfig server) {
  return {
    'id': server.id,
    'name': server.name,
    'baseUrl': server.baseUrl,
    'iconUrl': server.iconUrl,
    'remark': server.remark,
    'lines': server.lines
        .map((line) => {
              'id': line.id,
              'name': line.name,
              'url': line.url,
              'remark': line.remark,
            })
        .toList(),
    'activeLineIndex': server.activeLineIndex,
    'username': server.username,
    'authToken': server.authToken,
    'userId': server.userId,
  };
}

ServerConfig _serverConfigFromJson(Map<String, dynamic> json) {
  final lines = (json['lines'] as List<dynamic>?)
          ?.map(
            (line) => ServerLine(
              id: line['id'] as String,
              name: line['name'] as String,
              url: line['url'] as String,
              remark: line['remark'] as String?,
            ),
          )
          .toList() ??
      const <ServerLine>[];
  final activeLineIndex = json['activeLineIndex'] as int? ?? 0;

  return ServerConfig(
    id: json['id'] as String,
    name: json['name'] as String,
    baseUrl: json['baseUrl'] as String,
    iconUrl: json['iconUrl'] as String?,
    remark: json['remark'] as String?,
    lines: lines,
    activeLineIndex: lines.isEmpty
        ? 0
        : activeLineIndex.clamp(0, lines.length - 1),
    username: _emptyToNull(json['username'] as String?),
    authToken: _emptyToNull(json['authToken'] as String?),
    userId: _emptyToNull(json['userId'] as String?),
  );
}

Map<String, dynamic> serverConfigToJson(ServerConfig server) => _serverConfigToJson(server);

ServerConfig serverConfigFromJson(Map<String, dynamic> json) => _serverConfigFromJson(json);

String? _emptyToNull(String? value) {
  if (value == null || value.isEmpty) return null;
  return value;
}
