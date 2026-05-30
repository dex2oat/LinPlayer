import 'dart:ui' as ui;
import 'package:flutter/scheduler.dart';
import 'package:flutter/material.dart';
import '../../../core/api/api_interfaces.dart';

class DanmakuOverlay extends StatefulWidget {
  final List<DanmakuItem> items;
  final Duration position;
  final bool isPlaying;
  final double opacity;
  final double fontSizeFactor;
  final double speedFactor;
  final double densityFactor;

  const DanmakuOverlay({
    super.key,
    required this.items,
    required this.position,
    this.isPlaying = true,
    this.opacity = 0.8,
    this.fontSizeFactor = 0.5,
    this.speedFactor = 0.5,
    this.densityFactor = 0.5,
  });

  @override
  State<DanmakuOverlay> createState() => _DanmakuOverlayState();
}

class _DanmakuOverlayState extends State<DanmakuOverlay>
    with SingleTickerProviderStateMixin {
  Ticker? _ticker;
  Duration _tickerElapsed = Duration.zero;
  Duration _smoothPosition = Duration.zero;
  Duration _lastSyncPosition = Duration.zero;
  Duration _lastSyncElapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _smoothPosition = widget.position;
    _lastSyncPosition = widget.position;
    _ticker = createTicker(_onTick)..start();
  }

  void _onTick(Duration elapsed) {
    _tickerElapsed = elapsed;
    if (!widget.isPlaying) return;
    final delta = elapsed - _lastSyncElapsed;
    _smoothPosition = _lastSyncPosition + delta;
    setState(() {});
  }

  @override
  void didUpdateWidget(DanmakuOverlay old) {
    super.didUpdateWidget(old);
    if (widget.position != old.position) {
      _lastSyncPosition = widget.position;
      _lastSyncElapsed = _tickerElapsed;
      _smoothPosition = widget.position;
    }
    if (widget.isPlaying && !old.isPlaying) {
      _lastSyncPosition = _smoothPosition;
      _lastSyncElapsed = _tickerElapsed;
    }
  }

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: widget.opacity,
      child: CustomPaint(
        painter: DanmakuPainter(
          items: widget.items,
          videoPosition: _smoothPosition,
          fontSizeFactor: widget.fontSizeFactor,
          speedFactor: widget.speedFactor,
          densityFactor: widget.densityFactor,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _DanmakuTrackItem {
  final DanmakuItem item;
  double startY;
  final double width;
  final ui.Paragraph paragraph;

  _DanmakuTrackItem({
    required this.item,
    required this.startY,
    required this.width,
    required this.paragraph,
  });
}

class DanmakuPainter extends CustomPainter {
  final List<DanmakuItem> items;
  final Duration videoPosition;
  final double fontSizeFactor;
  final double speedFactor;
  final double densityFactor;

  static const double _maxFontSize = 36.0;
  static const double _minFontSize = 12.0;
  static const double _baseSpeed = 120.0;
  static const double _topBottomDuration = 5.0;
  static const double _trackHeight = 32.0;
  static const double _padding = 4.0;
  static const double _visibleWindow = 30.0;

  static List<DanmakuItem>? _cachedItems;
  static double? _cachedFs;
  static double? _cachedWidth;
  static List<ui.Paragraph?>? _paragraphs;
  static List<double>? _itemWidths;

  DanmakuPainter({
    required this.items,
    required this.videoPosition,
    required this.fontSizeFactor,
    required this.speedFactor,
    required this.densityFactor,
  });

  double get _fontSize =>
      _minFontSize + (_maxFontSize - _minFontSize) * fontSizeFactor;
  double get _speed => _baseSpeed * (0.5 + speedFactor);
  double get _currentSeconds => videoPosition.inMilliseconds / 1000.0;
  int get _maxVisible =>
      (items.length * (0.3 + densityFactor * 0.7)).round().clamp(50, items.length);

  void _ensureCache(Size size) {
    final fs = _fontSize;
    if (!identical(_cachedItems, items) ||
        _cachedFs != fs ||
        _cachedWidth != size.width) {
      _cachedItems = items;
      _cachedFs = fs;
      _cachedWidth = size.width;
      _paragraphs = List<ui.Paragraph?>.filled(items.length, null);
      _itemWidths = List<double>.filled(items.length, 0);
    }
  }

  _DanmakuTrackItem _getTrackItem(int index, Size size) {
    _ensureCache(size);
    var p = _paragraphs![index];
    if (p == null) {
      final item = items[index];
      final fs = item.size > 0 ? (item.size / 25.0 * _fontSize) : _fontSize;
      p = _buildParagraph(item, size, fs);
      _paragraphs![index] = p;
      _itemWidths![index] = p.maxIntrinsicWidth + _padding * 2;
    }
    return _DanmakuTrackItem(
      item: items[index],
      startY: 0,
      width: _itemWidths![index],
      paragraph: p,
    );
  }

  ui.Paragraph _buildParagraph(DanmakuItem item, Size size, double fs) {
    final color = Color(item.color);
    final displayText = item.count > 1 ? '${item.text} ×${item.count}' : item.text;
    final builder = ui.ParagraphBuilder(ui.ParagraphStyle(
      fontSize: fs,
      maxLines: 1,
      ellipsis: '',
    ))
      ..pushStyle(ui.TextStyle(
        color: color,
        background: ui.Paint()..color = const Color(0x60000000),
        fontSize: fs,
      ))
      ..addText(displayText);
    final paragraph = builder.build();
    paragraph.layout(ui.ParagraphConstraints(width: size.width));
    return paragraph;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (items.isEmpty || size.isEmpty) return;

    final trackCount = (size.height / _trackHeight).floor();
    if (trackCount <= 0) return;

    _ensureCache(size);

    final visibleItems = <_DanmakuTrackItem>[];
    var added = 0;
    for (var i = 0; i < items.length; i++) {
      if (added >= _maxVisible) break;
      final diff = items[i].time - _currentSeconds;
      if (diff < -_visibleWindow || diff > _visibleWindow) continue;
      visibleItems.add(_getTrackItem(i, size));
      added++;
    }

    final scrollTracks = List<_DanmakuTrackItem?>.filled(trackCount, null);
    final topTracks = <int, List<_DanmakuTrackItem>>{};
    final bottomTracks = <int, List<_DanmakuTrackItem>>{};

    for (final trackItem in visibleItems) {
      final type = trackItem.item.type;
      if (type == 4) {
        _layoutFixed(trackItem, bottomTracks, trackCount);
      } else if (type == 5) {
        _layoutFixed(trackItem, topTracks, trackCount);
      } else {
        _layoutScroll(trackItem, scrollTracks, trackCount, size);
      }
    }

    for (final trackItem in visibleItems) {
      final x = _computeX(trackItem, size);
      if (x + trackItem.width < 0 || x > size.width) continue;
      canvas.drawParagraph(trackItem.paragraph, Offset(x, trackItem.startY));
    }
  }

  void _layoutScroll(_DanmakuTrackItem trackItem,
      List<_DanmakuTrackItem?> tracks, int trackCount, Size size) {
    final x = _computeX(trackItem, size);
    for (var i = 0; i < trackCount; i++) {
      final existing = tracks[i];
      if (existing == null) {
        trackItem.startY = i * _trackHeight + _padding;
        tracks[i] = trackItem;
        return;
      }
      final existingX = _computeX(existing, size);
      final existingRight = existingX + existing.width;
      if (x > existingRight + _padding * 2) {
        trackItem.startY = i * _trackHeight + _padding;
        tracks[i] = trackItem;
        return;
      }
    }
    trackItem.startY = (trackCount - 1) * _trackHeight + _padding;
  }

  void _layoutFixed(_DanmakuTrackItem trackItem,
      Map<int, List<_DanmakuTrackItem>> tracks, int trackCount) {
    for (var i = 0; i < trackCount; i++) {
      final trackList = tracks[i];
      if (trackList == null || trackList.isEmpty) {
        tracks[i] = [trackItem];
        trackItem.startY = i * _trackHeight + _padding;
        return;
      }
      final last = trackList.last;
      final diff = _currentSeconds - last.item.time;
      if (diff > _topBottomDuration) {
        trackList.add(trackItem);
        trackItem.startY = i * _trackHeight + _padding;
        return;
      }
    }
    trackItem.startY = (trackCount - 1) * _trackHeight + _padding;
  }

  double _computeX(_DanmakuTrackItem trackItem, Size size) {
    final type = trackItem.item.type;
    final elapsed = _currentSeconds - trackItem.item.time;
    if (elapsed < 0) return -trackItem.width;

    if (type == 4 || type == 5) {
      return (size.width - trackItem.width) / 2;
    }

    final totalDuration =
        size.width / _speed + trackItem.width / _speed;
    final progress = elapsed / totalDuration;
    final startX = size.width + _padding;
    final endX = -trackItem.width - _padding;
    return startX + (endX - startX) * progress;
  }

  @override
  bool shouldRepaint(DanmakuPainter oldDelegate) {
    return oldDelegate.videoPosition != videoPosition ||
        oldDelegate.items != items ||
        oldDelegate.fontSizeFactor != fontSizeFactor ||
        oldDelegate.speedFactor != speedFactor;
  }
}
