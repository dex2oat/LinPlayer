import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/sources/media_source_backend.dart';
import '../../../core/sources/source_registry.dart';
import '../../theme/tv_design_tokens.dart';
import '../../theme/tv_metrics.dart';
import '../../widgets/tv_focusable.dart';
import '../../widgets/tv_grid.dart';
import '../../widgets/tv_text_field.dart';

/// TV 端「源类型选择器」：添加服务器第一步。观感对齐移动端
/// [SourcePickerScreen]（搜索框 + 一列 accent 图标卡片），交互换成焦点驱动。
class TvSourcePickerScreen extends StatefulWidget {
  const TvSourcePickerScreen({super.key});

  @override
  State<TvSourcePickerScreen> createState() => _TvSourcePickerScreenState();
}

class _TvSourcePickerScreenState extends State<TvSourcePickerScreen> {
  String _query = '';

  void _select(BuildContext context, SourceKind kind) {
    if (kind == SourceKind.emby) {
      context.go('/tv/add-emby');
    } else {
      context.push('/tv/add-source/${kind.name}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    final types = kSourceTypes.where((t) => t.matches(_query)).toList();
    return Scaffold(
      backgroundColor: TvDesignTokens.background,
      body: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: m.s(1400)),
          child: SingleChildScrollView(
            padding: EdgeInsets.all(m.spacingXxl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '选择要添加的服务',
                  style: TextStyle(
                    fontSize: m.fontSizeXxl,
                    color: TvDesignTokens.textPrimary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SizedBox(height: m.spacingLg),
                _searchField(m),
                SizedBox(height: m.spacingLg),
                if (types.isEmpty)
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: m.spacingXl),
                    child: Text(
                      '没有匹配的源类型',
                      style: TextStyle(
                        fontSize: m.fontSizeMd,
                        color: TvDesignTokens.textSecondary,
                      ),
                    ),
                  )
                else
                  TvResponsiveGrid(
                    minCellWidth: 460,
                    children: List.generate(types.length, (i) {
                      final t = types[i];
                      return TvFocusable(
                        autofocus: i == 0,
                        padding: EdgeInsets.all(m.s(4)),
                        onSelect: () => _select(context, t.kind),
                        child: _card(m, t),
                      );
                    }),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _searchField(TvMetrics m) {
    return TvTextField(
      hint: '搜索源类型（Emby、OpenList…）',
      prefixIcon: Icon(Icons.search,
          color: TvDesignTokens.textSecondary, size: m.s(28)),
      onChanged: (v) => setState(() => _query = v),
    );
  }

  Widget _card(TvMetrics m, SourceTypeDescriptor t) {
    return Container(
      padding: EdgeInsets.all(m.spacingLg),
      decoration: BoxDecoration(
        color: TvDesignTokens.surface,
        borderRadius: BorderRadius.circular(m.posterRadius),
      ),
      child: Row(
        children: [
          Container(
            width: m.s(56),
            height: m.s(56),
            decoration: BoxDecoration(
              color: t.accent.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(m.posterRadius),
            ),
            child: Icon(t.icon, color: t.accent, size: m.s(30)),
          ),
          SizedBox(width: m.spacingLg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.name,
                  style: TextStyle(
                    fontSize: m.fontSizeLg,
                    color: TvDesignTokens.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: m.spacingXs),
                Text(
                  t.subtitle,
                  style: TextStyle(
                    fontSize: m.fontSizeSm,
                    color: TvDesignTokens.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right,
              color: TvDesignTokens.textSecondary, size: m.s(28)),
        ],
      ),
    );
  }
}
