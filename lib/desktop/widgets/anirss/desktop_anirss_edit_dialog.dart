import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/td_switch_tile.dart';

import '../../../core/sources/anirss/anirss_api.dart';
import '../../../core/sources/anirss/anirss_providers.dart';
import '../../../core/sources/anirss/models/ani.dart';
import '../native_feedback.dart';

/// 桌面端「订阅配置」对话框——对标 ani-rss 原版 `Ani.vue`（基本 / 自定义 两 Tab）。
///
/// 原版 PC 订阅之所以「方便又全面」，核心是这张表单：标题可一键套 TMDB、主 RSS / 字幕组、
/// 季 / 集数偏移 / 总集数、**匹配 / 排除是可视化标签编辑**（数组，不是一行字符串）、全局排除、
/// 剧场版、启用；自定义页还有集数规则 / 下载路径(可预览) / 重命名模版 / 各类开关。
/// 底部「刮削 / 预览 / 确定」。本对话框逐项复刻，保存即 `setAni` 回写。
///
/// 既能编辑已有订阅，也能在「添加」拿到 rssToAni 的 Ani 后用同一张表单微调。
Future<bool?> showDesktopAniRssEditDialog(
  BuildContext context,
  WidgetRef ref,
  AniModel ani, {
  bool isAdd = false,
}) {
  return showDialog<bool>(
    context: context,
    builder: (_) => _EditDialog(parentRef: ref, source: ani, isAdd: isAdd),
  );
}

class _EditDialog extends StatefulWidget {
  final WidgetRef parentRef;
  final AniModel source;
  final bool isAdd;
  const _EditDialog({
    required this.parentRef,
    required this.source,
    required this.isAdd,
  });

  @override
  State<_EditDialog> createState() => _EditDialogState();
}

class _EditDialogState extends State<_EditDialog>
    with SingleTickerProviderStateMixin {
  late TabController _tab;

  // 工作副本：编辑全程改这份 raw，确定时整体回传（无损保留未暴露字段）。
  late Map<String, dynamic> _raw;

  late final TextEditingController _title;
  late final TextEditingController _bgmUrl;
  late final TextEditingController _subgroup;
  late final TextEditingController _url;
  late final TextEditingController _season;
  late final TextEditingController _offset;
  late final TextEditingController _total;
  late final TextEditingController _tmdbGroupId;
  late final TextEditingController _customEpisodeStr;
  late final TextEditingController _customEpisodeGroupIndex;
  late final TextEditingController _downloadPath;
  late final TextEditingController _renameTemplate;

  bool _saving = false;
  bool _tmdbLoading = false;
  bool _pathLoading = false;
  String? _error;

  AniRssApi? get _api => widget.parentRef.read(aniRssApiProvider);

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    _raw = Map<String, dynamic>.from(widget.source.raw);
    _title = TextEditingController(text: _s('title'));
    _bgmUrl = TextEditingController(text: _s('bgmUrl'));
    _subgroup = TextEditingController(text: _s('subgroup'));
    _url = TextEditingController(text: _s('url'));
    _season = TextEditingController(text: (_i('season') ?? 1).toString());
    _offset = TextEditingController(text: (_i('offset') ?? 0).toString());
    _total = TextEditingController(
        text: (_i('totalEpisodeNumber') ?? 0) > 0
            ? _i('totalEpisodeNumber').toString()
            : '');
    _tmdbGroupId = TextEditingController(text: _tmdbGroup());
    _customEpisodeStr =
        TextEditingController(text: _s('customEpisodeStr'));
    _customEpisodeGroupIndex =
        TextEditingController(text: (_i('customEpisodeGroupIndex') ?? 0).toString());
    _downloadPath = TextEditingController(text: _s('downloadPath'));
    _renameTemplate = TextEditingController(text: _s('customRenameTemplate'));
  }

  @override
  void dispose() {
    _tab.dispose();
    for (final c in [
      _title,
      _bgmUrl,
      _subgroup,
      _url,
      _season,
      _offset,
      _total,
      _tmdbGroupId,
      _customEpisodeStr,
      _customEpisodeGroupIndex,
      _downloadPath,
      _renameTemplate,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  // ---- raw 读写助手 ----
  String _s(String k) => (_raw[k] ?? '').toString();
  int? _i(String k) => (_raw[k] as num?)?.toInt();
  bool _b(String k, {bool def = false}) {
    final v = _raw[k];
    if (v == null) return def;
    return v == true;
  }

  String _tmdbGroup() {
    final t = _raw['tmdb'];
    if (t is Map) return (t['tmdbGroupId'] ?? '').toString();
    return '';
  }

  List<String> _list(String k) {
    final v = _raw[k];
    if (v is List) return v.map((e) => e.toString()).toList();
    return <String>[];
  }

  void _setList(String k, List<String> v) => setState(() => _raw[k] = v);

  bool get _ova => _b('ova');

  // ---- 动作 ----
  Future<void> _resolveTmdb() async {
    final api = _api;
    if (api == null || _title.text.trim().isEmpty) return;
    setState(() => _tmdbLoading = true);
    try {
      _raw['title'] = _title.text.trim();
      final res = await api.getThemoviedbName(AniModel(_raw));
      setState(() {
        _raw['themoviedbName'] = res.raw['themoviedbName'];
        _raw['tmdb'] = res.raw['tmdb'];
        _tmdbGroupId.text = _tmdbGroup();
      });
      if (mounted) showDesktopMessage(context, 'TMDB 已解析：${_s('themoviedbName')}');
    } catch (e) {
      if (mounted) showDesktopMessage(context, 'TMDB 解析失败：$e', isError: true);
    } finally {
      if (mounted) setState(() => _tmdbLoading = false);
    }
  }

  Future<void> _previewPath() async {
    final api = _api;
    if (api == null) return;
    setState(() => _pathLoading = true);
    try {
      // 预览以「非自定义」口径求服务端默认落地位置。
      final probe = Map<String, dynamic>.from(_raw)..['customDownloadPath'] = false;
      final res = await api.downloadPath(AniModel(probe));
      final p = (res['downloadPath'] ?? '').toString();
      if (p.isNotEmpty) setState(() => _downloadPath.text = p);
    } catch (e) {
      if (mounted) showDesktopMessage(context, '获取下载位置失败：$e', isError: true);
    } finally {
      if (mounted) setState(() => _pathLoading = false);
    }
  }

  Future<void> _scrape(bool force) async {
    final api = _api;
    if (api == null) return;
    try {
      await api.scrape(_collect(), force: force);
      if (mounted) showDesktopMessage(context, force ? '已触发强制刮削' : '已触发刮削');
    } catch (e) {
      if (mounted) showDesktopMessage(context, '刮削失败：$e', isError: true);
    }
  }

  Future<void> _preview() async {
    final api = _api;
    if (api == null) return;
    showDialog<void>(
      context: context,
      builder: (_) => _PreviewDialog(api: api, ani: _collect()),
    );
  }

  /// 把表单控件回灌进 raw，得到可回传的 [AniModel]。
  AniModel _collect() {
    _raw['title'] = _title.text.trim();
    _raw['bgmUrl'] = _bgmUrl.text.trim();
    _raw['subgroup'] = _subgroup.text.trim();
    _raw['url'] = _url.text.trim();
    _raw['season'] = int.tryParse(_season.text.trim()) ?? 1;
    _raw['offset'] = int.tryParse(_offset.text.trim()) ?? 0;
    _raw['totalEpisodeNumber'] = int.tryParse(_total.text.trim()) ?? 0;
    if (_raw['tmdb'] is Map) {
      (_raw['tmdb'] as Map)['tmdbGroupId'] = _tmdbGroupId.text.trim();
    }
    _raw['customEpisodeStr'] = _customEpisodeStr.text.trim();
    _raw['customEpisodeGroupIndex'] =
        int.tryParse(_customEpisodeGroupIndex.text.trim()) ?? 0;
    _raw['downloadPath'] = _downloadPath.text.trim();
    _raw['customRenameTemplate'] = _renameTemplate.text.trim();
    return AniModel(Map<String, dynamic>.from(_raw));
  }

  Future<void> _save() async {
    final api = _api;
    if (api == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final ani = _collect();
      if (widget.isAdd) {
        await api.addAni(ani);
      } else {
        await api.setAni(ani);
      }
      widget.parentRef.invalidate(aniListProvider);
      if (mounted) {
        Navigator.of(context).pop(true);
        showDesktopMessage(context, widget.isAdd ? '订阅已添加' : '订阅已保存');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '${widget.isAdd ? '添加' : '保存'}失败：$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600, maxHeight: 720),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 标题栏
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 18, 16, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(widget.isAdd ? '添加订阅' : '修改订阅',
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w700)),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            TabBar(
              controller: _tab,
              tabs: const [Tab(text: '基本'), Tab(text: '自定义')],
            ),
            Expanded(
              child: TabBarView(
                controller: _tab,
                children: [
                  _baseTab(cs),
                  _customTab(cs),
                ],
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
                child: Text(_error!, style: TextStyle(color: cs.error)),
              ),
            const Divider(height: 1),
            // 底部动作栏
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: Row(
                children: [
                  if (!widget.isAdd)
                    PopupMenuButton<String>(
                      tooltip: '更多',
                      icon: const Icon(Icons.more_horiz),
                      onSelected: (v) {
                        if (v == 'scrape') _scrape(false);
                        if (v == 'scrapeF') _scrape(true);
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'scrape', child: Text('刮削')),
                        PopupMenuItem(
                            value: 'scrapeF', child: Text('刮削（覆盖已有）')),
                      ],
                    ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _preview,
                    icon: const Icon(Icons.grid_view_rounded, size: 18),
                    label: const Text('预览'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.check, size: 18),
                    label: const Text('确定'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _baseTab(ColorScheme cs) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
      children: [
        _field(
          '标题',
          TextField(
            controller: _title,
            decoration: _dec(),
          ),
          trailing: TextButton(
            onPressed: (_s('themoviedbName').isEmpty ||
                    _title.text.trim() == _s('themoviedbName'))
                ? null
                : () => setState(() => _title.text = _s('themoviedbName')),
            child: const Text('套用 TMDB 名'),
          ),
        ),
        _field(
          'TMDB',
          InputDecorator(
            decoration: _dec(),
            child: Text(
              _s('themoviedbName').isEmpty ? '未解析' : _s('themoviedbName'),
              style: TextStyle(
                  color: _s('themoviedbName').isEmpty
                      ? cs.onSurfaceVariant
                      : cs.primary),
            ),
          ),
          trailing: IconButton(
            tooltip: '解析 TMDB',
            onPressed: _tmdbLoading ? null : _resolveTmdb,
            icon: _tmdbLoading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
          ),
        ),
        if (!_ova && _raw['tmdb'] is Map)
          _field(
            '剧集组',
            TextField(
              controller: _tmdbGroupId,
              decoration: _dec(hint: '留空不使用剧集组'),
            ),
          ),
        _field('BgmUrl',
            TextField(controller: _bgmUrl, decoration: _dec(hint: 'https://bgm.tv/subject/...'))),
        _field('字幕组',
            TextField(controller: _subgroup, decoration: _dec(hint: '字幕组名'))),
        _field(
            '主 RSS',
            TextField(
                controller: _url,
                maxLines: 2,
                minLines: 1,
                decoration: _dec(hint: 'https://...'))),
        Row(
          children: [
            Expanded(
              child: _field(
                '季',
                TextField(
                  controller: _season,
                  enabled: !_ova,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: _dec(),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _field(
                '集数偏移',
                TextField(
                  controller: _offset,
                  enabled: !_ova,
                  keyboardType: const TextInputType.numberWithOptions(signed: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'^-?\d*'))
                  ],
                  decoration: _dec(),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _field(
                '总集数',
                TextField(
                  controller: _total,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: _dec(hint: '0=未知'),
                ),
              ),
            ),
          ],
        ),
        _field(
          '匹配',
          _RegexTagEditor(
            tags: _list('match'),
            emptyHint: '不限（匹配全部）',
            onChanged: (v) => _setList('match', v),
          ),
        ),
        _field(
          '排除',
          _RegexTagEditor(
            tags: _list('exclude'),
            emptyHint: '无',
            onChanged: (v) => _setList('exclude', v),
          ),
        ),
        _switch('全局排除', 'globalExclude', def: true),
        _switch('剧场版（OVA，不按季集匹配）', 'ova'),
        _switch('启用订阅', 'enable', def: true),
      ],
    );
  }

  Widget _customTab(ColorScheme cs) {
    final customEpisode = _b('customEpisode');
    final customPath = _b('customDownloadPath');
    final customRename = _b('customRenameTemplateEnable');
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
      children: [
        _switch('自定义集数规则', 'customEpisode'),
        if (customEpisode)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _customEpisodeStr,
                    decoration: _dec(hint: '集号提取正则'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _customEpisodeGroupIndex,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: _dec(hint: '组号'),
                  ),
                ),
              ],
            ),
          ),
        const Divider(height: 24),
        _switch('自定义下载位置', 'customDownloadPath'),
        if (customPath) ...[
          TextField(
            controller: _downloadPath,
            maxLines: 2,
            minLines: 1,
            decoration: _dec(hint: '下载路径'),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _pathLoading ? null : _previewPath,
              icon: _pathLoading
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh, size: 16),
              label: const Text('用默认规则填充'),
            ),
          ),
        ],
        const Divider(height: 24),
        _switch('自定义重命名模版', 'customRenameTemplateEnable'),
        if (customRename)
          TextField(
            controller: _renameTemplate,
            decoration: _dec(
                hint: r'${title} S${seasonFormat}E${episodeFormat}'),
          ),
        const Divider(height: 24),
        Text('其它', style: TextStyle(fontWeight: FontWeight.w700, color: cs.primary)),
        _check('遗漏检测', 'omit'),
        _check('自动上传', 'upload'),
        _check('只下载最新集', 'downloadNew'),
        _check('摸鱼检测', 'procrastinating'),
        _check('下载通知', 'message'),
        _check('完结迁移', 'completed'),
      ],
    );
  }

  // ---- 小部件 ----
  InputDecoration _dec({String? hint}) => InputDecoration(
        isDense: true,
        hintText: hint,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      );

  Widget _field(String label, Widget child, {Widget? trailing}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(label,
                  style: const TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w600)),
              const Spacer(),
              if (trailing != null) trailing,
            ],
          ),
          const SizedBox(height: 4),
          child,
        ],
      ),
    );
  }

  Widget _switch(String label, String key, {bool def = false}) {
    return TdSwitchTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(label),
      value: _b(key, def: def),
      onChanged: (v) => setState(() => _raw[key] = v),
    );
  }

  Widget _check(String label, String key, {bool def = false}) {
    return CheckboxListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      controlAffinity: ListTileControlAffinity.leading,
      title: Text(label),
      value: _b(key, def: def),
      onChanged: (v) => setState(() => _raw[key] = v ?? false),
    );
  }
}

/// 匹配 / 排除规则的可视化标签编辑器（对应 ani-rss `Exclude.vue`）。
///
/// 规则是字符串数组；可带字幕组限定，格式 `{{字幕组}}:正则`。空字幕组则纯正则。
class _RegexTagEditor extends StatelessWidget {
  final List<String> tags;
  final String emptyHint;
  final ValueChanged<List<String>> onChanged;
  const _RegexTagEditor({
    required this.tags,
    required this.emptyHint,
    required this.onChanged,
  });

  Future<void> _add(BuildContext context) async {
    final subgroupCtrl = TextEditingController();
    final regexCtrl = TextEditingController();
    final added = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加规则'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: subgroupCtrl,
              decoration: const InputDecoration(
                labelText: '字幕组',
                hintText: '留空匹配所有字幕组',
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: regexCtrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '正则',
                hintText: r'如 720、简、\d-\d',
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              final re = regexCtrl.text.trim();
              if (re.isEmpty) return;
              final sg = subgroupCtrl.text.trim();
              Navigator.pop(ctx, sg.isEmpty ? re : '{{$sg}}:$re');
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
    subgroupCtrl.dispose();
    regexCtrl.dispose();
    if (added != null && !tags.contains(added)) {
      onChanged([...tags, added]);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (tags.isEmpty)
          Chip(
            label: Text(emptyHint),
            visualDensity: VisualDensity.compact,
          ),
        for (final t in tags)
          Chip(
            label: Text(t, style: const TextStyle(fontSize: 12)),
            visualDensity: VisualDensity.compact,
            onDeleted: () => onChanged(tags.where((e) => e != t).toList()),
          ),
        ActionChip(
          avatar: const Icon(Icons.add, size: 16),
          label: const Text('添加'),
          visualDensity: VisualDensity.compact,
          onPressed: () => _add(context),
        ),
      ],
    );
  }
}

/// 订阅预览：列出当前规则会匹配到的剧集（对应 ani-rss 预览）。
class _PreviewDialog extends StatefulWidget {
  final AniRssApi api;
  final AniModel ani;
  const _PreviewDialog({required this.api, required this.ani});

  @override
  State<_PreviewDialog> createState() => _PreviewDialogState();
}

class _PreviewDialogState extends State<_PreviewDialog> {
  List<Map<String, dynamic>>? _items;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final preview = await widget.api.previewAni(widget.ani);
      setState(() => _items = AniRssApi.itemsOf(preview));
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('预览匹配剧集'),
      content: SizedBox(
        width: 420,
        height: 420,
        child: _error != null
            ? Center(child: Text('预览失败：$_error'))
            : _items == null
                ? const Center(child: CircularProgressIndicator())
                : _items!.isEmpty
                    ? const Center(child: Text('当前规则没有匹配到剧集'))
                    : ListView.separated(
                        itemCount: _items!.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final it = _items![i];
                          final name = (it['title'] ??
                                  it['name'] ??
                                  it['reName'] ??
                                  it['fileName'] ??
                                  '未命名')
                              .toString();
                          return ListTile(
                            dense: true,
                            leading: const Icon(Icons.movie_outlined, size: 20),
                            title: Text(name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13)),
                          );
                        },
                      ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('关闭')),
      ],
    );
  }
}
