import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';

class LibassBridge {
  static const _channel = MethodChannel('com.linplayer/libass');
  static bool _available = false;
  static bool _checked = false;

  static Future<bool> isAvailable() async {
    if (_checked) return _available;
    try {
      _available = await _channel.invokeMethod<bool>('isLibassAvailable') ?? false;
    } on PlatformException catch (_) {
      _available = false;
    } on MissingPluginException catch (_) {
      _available = false;
    }
    _checked = true;
    return _available;
  }

  static Future<bool> init({required int width, required int height}) async {
    try {
      return await _channel.invokeMethod<bool>('initLibass', {
        'width': width,
        'height': height,
      }) ?? false;
    } on PlatformException catch (_) {
      return false;
    }
  }

  static Future<bool> loadSubFile(String path) async {
    try {
      return await _channel.invokeMethod<bool>('loadSubFile', {
        'path': path,
      }) ?? false;
    } on PlatformException catch (_) {
      return false;
    }
  }

  static Future<bool> loadSubMemory(Uint8List data, {String codec = 'ass'}) async {
    try {
      return await _channel.invokeMethod<bool>('loadSubMemory', {
        'data': data,
        'codec': codec,
      }) ?? false;
    } on PlatformException catch (_) {
      return false;
    }
  }

  static Future<bool> setFontSize(int size) async {
    try {
      return await _channel.invokeMethod<bool>('setFontSize', {
        'size': size,
      }) ?? false;
    } on PlatformException catch (_) {
      return false;
    }
  }

  static Future<bool> setFontName(String name) async {
    try {
      return await _channel.invokeMethod<bool>('setFontName', {
        'name': name,
      }) ?? false;
    } on PlatformException catch (_) {
      return false;
    }
  }

  static Future<List<LibassBlendRect>?> renderFrame(int ptsMs) async {
    try {
      final raw = await _channel.invokeMethod<Uint8List?>('renderFrame', {
        'ptsMs': ptsMs,
      });
      if (raw == null) return null;
      return _parseRenderResult(raw);
    } on PlatformException catch (_) {
      return null;
    }
  }

  static Future<void> dispose() async {
    try {
      await _channel.invokeMethod<bool>('dispose');
    } on PlatformException catch (_) {}
    _available = false;
    _checked = false;
  }

  static List<LibassBlendRect>? _parseRenderResult(Uint8List raw) {
    final rects = <LibassBlendRect>[];
    int offset = 0;
    final data = raw.buffer.asByteData();

    while (offset + 20 <= raw.length) {
      final w = data.getInt32(offset, Endian.host);
      offset += 4;
      final h = data.getInt32(offset, Endian.host);
      offset += 4;
      final stride = data.getInt32(offset, Endian.host);
      offset += 4;
      final dstX = data.getInt32(offset, Endian.host);
      offset += 4;
      final dstY = data.getInt32(offset, Endian.host);
      offset += 4;

      if (w <= 0 || h <= 0) break;
      final pixelCount = w * h;
      final byteCount = pixelCount * 4;
      if (offset + byteCount > raw.length) break;

      final pixels = Uint8List.sublistView(raw, offset, offset + byteCount);
      offset += byteCount;

      rects.add(LibassBlendRect(
        width: w,
        height: h,
        stride: stride,
        dstX: dstX,
        dstY: dstY,
        pixels: pixels,
      ));
    }
    return rects.isEmpty ? null : rects;
  }
}

class LibassBlendRect {
  final int width;
  final int height;
  final int stride;
  final int dstX;
  final int dstY;
  final Uint8List pixels;

  const LibassBlendRect({
    required this.width,
    required this.height,
    required this.stride,
    required this.dstX,
    required this.dstY,
    required this.pixels,
  });

  Future<ui.Image> toImage() async {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      width,
      height,
      ui.PixelFormat.rgba8888,
      (ui.Image image) => completer.complete(image),
    );
    return completer.future;
  }
}
