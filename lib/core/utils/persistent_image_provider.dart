import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui show Codec;
import 'package:extended_image/extended_image.dart' show ExtendedImageProvider, keyToMd5;
import 'package:http_client_helper/http_client_helper.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';

/// 持久化网络图片 Provider
/// 
/// 基于 ExtendedNetworkImageProvider 修改，将缓存目录从临时目录改为应用文档目录，
/// 确保图片缓存持久化，退出应用后重新进入不需要重新下载。
class PersistentNetworkImageProvider
    extends ImageProvider<PersistentNetworkImageProvider>
    with ExtendedImageProvider<PersistentNetworkImageProvider> {
  
  PersistentNetworkImageProvider(
    this.url, {
    this.scale = 1.0,
    this.headers,
    this.cache = true,
    this.retries = 3,
    this.timeLimit,
    this.timeRetry = const Duration(milliseconds: 100),
    this.cacheKey,
    this.printError = true,
    this.cacheRawData = false,
    this.cancelToken,
    this.imageCacheName,
    this.cacheMaxAge,
  });

  @override
  final String? imageCacheName;
  @override
  final bool cacheRawData;
  final Duration? timeLimit;
  final int retries;
  final Duration timeRetry;
  final bool cache;
  final String url;
  final double scale;
  final Map<String, String>? headers;
  final CancellationToken? cancelToken;
  final String? cacheKey;
  final bool printError;
  final Duration? cacheMaxAge;

  static String? _persistentCachePath;

  static Future<String> get _cachePath async {
    if (_persistentCachePath != null) return _persistentCachePath!;
    final appDir = await getApplicationDocumentsDirectory();
    _persistentCachePath = join(appDir.path, 'persistent_image_cache');
    final dir = Directory(_persistentCachePath!);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return _persistentCachePath!;
  }

  @override
  ImageStreamCompleter loadImage(
    PersistentNetworkImageProvider key,
    ImageDecoderCallback decode,
  ) {
    final StreamController<ImageChunkEvent> chunkEvents =
        StreamController<ImageChunkEvent>();

    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, chunkEvents, decode),
      scale: key.scale,
      chunkEvents: chunkEvents.stream,
      debugLabel: key.url,
      informationCollector: () {
        return <DiagnosticsNode>[
          DiagnosticsProperty<ImageProvider>('Image provider', this),
          DiagnosticsProperty<PersistentNetworkImageProvider>('Image key', key),
        ];
      },
    );
  }

  @override
  Future<PersistentNetworkImageProvider> obtainKey(
      ImageConfiguration configuration) {
    return SynchronousFuture<PersistentNetworkImageProvider>(this);
  }

  Future<ui.Codec> _loadAsync(
    PersistentNetworkImageProvider key,
    StreamController<ImageChunkEvent> chunkEvents,
    ImageDecoderCallback decode,
  ) async {
    assert(key == this);
    final String md5Key = cacheKey ?? keyToMd5(key.url);
    ui.Codec? result;
    if (cache) {
      try {
        final Uint8List? data = await _loadCache(key, chunkEvents, md5Key);
        if (data != null) {
          result = await instantiateImageCodec(data, decode);
        }
      } catch (e) {
        if (printError) debugPrint('PersistentNetworkImageProvider: $e');
      }
    }

    if (result == null) {
      try {
        final Uint8List? data = await _loadNetwork(key, chunkEvents);
        if (data != null) {
          result = await instantiateImageCodec(data, decode);
        }
      } catch (e) {
        if (printError) debugPrint('PersistentNetworkImageProvider: $e');
      }
    }

    if (result == null) {
      return Future<ui.Codec>.error(StateError('Failed to load $url.'));
    }

    return result;
  }

  Future<Uint8List?> _loadCache(
    PersistentNetworkImageProvider key,
    StreamController<ImageChunkEvent>? chunkEvents,
    String md5Key,
  ) async {
    final Directory cacheDir = Directory(await _cachePath);
    Uint8List? data;

    if (cacheDir.existsSync()) {
      final File cacheFile = File(join(cacheDir.path, md5Key));
      if (cacheFile.existsSync()) {
        if (key.cacheMaxAge != null) {
          final DateTime now = DateTime.now();
          final FileStat fs = cacheFile.statSync();
          if (now.subtract(key.cacheMaxAge!).isAfter(fs.changed)) {
            cacheFile.deleteSync(recursive: true);
          } else {
            data = await cacheFile.readAsBytes();
          }
        } else {
          data = await cacheFile.readAsBytes();
        }
      }
    } else {
      await cacheDir.create(recursive: true);
    }

    if (data == null) {
      data = await _loadNetwork(key, chunkEvents);
      if (data != null) {
        await File(join(cacheDir.path, md5Key)).writeAsBytes(data);
      }
    }

    return data;
  }

  Future<Uint8List?> _loadNetwork(
    PersistentNetworkImageProvider key,
    StreamController<ImageChunkEvent>? chunkEvents,
  ) async {
    try {
      final Uri resolved = Uri.base.resolve(key.url);
      final HttpClientResponse? response = await _tryGetResponse(resolved);
      if (response == null || response.statusCode != HttpStatus.ok) {
        if (response != null) {
          await response.drain<List<int>>(<int>[]);
        }
        return null;
      }

      final Uint8List bytes = await consolidateHttpClientResponseBytes(
        response,
        onBytesReceived: chunkEvents != null
            ? (int cumulative, int? total) {
                chunkEvents.add(ImageChunkEvent(
                  cumulativeBytesLoaded: cumulative,
                  expectedTotalBytes: total,
                ));
              }
            : null,
      );
      if (bytes.lengthInBytes == 0) {
        return Future<Uint8List>.error(
            StateError('NetworkImage is an empty file: $resolved'));
      }

      return bytes;
    } on OperationCanceledError catch (_) {
      if (printError) debugPrint('User cancel request $url.');
      return Future<Uint8List>.error(StateError('User cancel request $url.'));
    } catch (e) {
      if (printError) debugPrint('$e');
    } finally {
      await chunkEvents?.close();
    }
    return null;
  }

  Future<HttpClientResponse> _getResponse(Uri resolved) async {
    final HttpClientRequest request = await httpClient.getUrl(resolved);
    headers?.forEach((String name, String value) {
      request.headers.add(name, value);
    });
    final HttpClientResponse response = await request.close();
    if (timeLimit != null) {
      response.timeout(timeLimit!);
    }
    return response;
  }

  Future<HttpClientResponse?> _tryGetResponse(Uri resolved) async {
    cancelToken?.throwIfCancellationRequested();
    return await RetryHelper.tryRun<HttpClientResponse>(
      () {
        return CancellationTokenSource.register(
          cancelToken,
          _getResponse(resolved),
        );
      },
      cancelToken: cancelToken,
      timeRetry: timeRetry,
      retries: retries,
    );
  }

  static final HttpClient _sharedHttpClient = HttpClient()
    ..autoUncompress = false;

  static HttpClient get httpClient {
    HttpClient client = _sharedHttpClient;
    assert(() {
      if (debugNetworkImageHttpClientProvider != null) {
        client = debugNetworkImageHttpClientProvider!();
      }
      return true;
    }());
    return client;
  }

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) return false;
    return other is PersistentNetworkImageProvider &&
        url == other.url &&
        scale == other.scale &&
        cache == other.cache &&
        cacheKey == other.cacheKey &&
        retries == other.retries &&
        imageCacheName == other.imageCacheName &&
        cacheMaxAge == other.cacheMaxAge;
  }

  @override
  int get hashCode => Object.hash(
        url,
        scale,
        cache,
        cacheKey,
        retries,
        imageCacheName,
        cacheMaxAge,
      );

  @override
  String toString() => '$runtimeType("$url", scale: $scale)';
}
