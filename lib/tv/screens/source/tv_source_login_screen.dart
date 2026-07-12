import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/providers/server_providers.dart';
import '../../../core/sources/media_source_backend.dart';
import '../../../core/sources/source_login_service.dart';
import '../../../core/sources/source_registry.dart';
import '../../../ui/screens/source/quark_qr_login_view.dart';
import '../../theme/tv_design_tokens.dart';
import '../../theme/tv_metrics.dart';
import '../../widgets/tv_button.dart';
import '../../widgets/tv_focusable.dart';
import '../../widgets/tv_text_field.dart';

/// TV 端网盘/聚合源登录页（账密型 OpenList/Ani-rss/飞牛 + 夸克扫码/Cookie）。
///
/// 观感对齐移动端 [SourceLoginScreen]：accent 图标头部 + 带前缀图标的输入行 +
/// 夸克分段切换 + 二维码；聚焦输入框唤起 leanback IME，交互焦点驱动。
class TvSourceLoginScreen extends ConsumerStatefulWidget {
  final SourceKind kind;

  const TvSourceLoginScreen({super.key, required this.kind});

  @override
  ConsumerState<TvSourceLoginScreen> createState() =>
      _TvSourceLoginScreenState();
}

class _TvSourceLoginScreenState extends ConsumerState<TvSourceLoginScreen> {
  final _urlController = TextEditingController();
  final _userController = TextEditingController();
  final _passController = TextEditingController();
  final _nameController = TextEditingController();
  final _cookieController = TextEditingController();
  bool _loading = false;
  String? _error;
  int _quarkMethod = 0; // 0=扫码，1=Cookie

  SourceTypeDescriptor get _descriptor =>
      sourceTypeOf(widget.kind) ?? kSourceTypes.first;

  bool get _isQuark => widget.kind == SourceKind.quark;
  bool get _isCookieLogin => _isQuark && _quarkMethod == 1;

  void _onLoggedIn(ServerConfig server) {
    ref.read(serverListProvider.notifier).addServer(server);
    ref.read(currentServerProvider.notifier).state = server;
    ref.read(authStateProvider.notifier).state = AuthState.authenticated;
    if (mounted) context.go('/tv/home');
  }

  @override
  void dispose() {
    _urlController.dispose();
    _userController.dispose();
    _passController.dispose();
    _nameController.dispose();
    _cookieController.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (_isCookieLogin) {
      if (_cookieController.text.trim().isEmpty) {
        setState(() => _error = '请粘贴 Cookie');
        return;
      }
    } else if (_urlController.text.trim().isEmpty) {
      setState(() => _error = '请填写服务器地址');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final server = await _login();
      if (mounted) _onLoggedIn(server);
    } on SourceException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '连接失败：$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<dynamic> _login() {
    switch (widget.kind) {
      case SourceKind.openlist:
        return SourceLoginService.loginOpenList(
          name: _nameController.text,
          baseUrl: _urlController.text,
          username: _userController.text,
          password: _passController.text,
        );
      case SourceKind.anirss:
        return SourceLoginService.loginAniRss(
          name: _nameController.text,
          baseUrl: _urlController.text,
          username: _userController.text,
          password: _passController.text,
        );
      case SourceKind.feiniu:
        return SourceLoginService.loginFeiniu(
          name: _nameController.text,
          baseUrl: _urlController.text,
          username: _userController.text,
          password: _passController.text,
        );
      case SourceKind.quark:
        return SourceLoginService.loginQuarkCookie(
          name: _nameController.text,
          cookie: _cookieController.text,
        );
      default:
        throw SourceException('该源暂未支持登录');
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = context.tv;
    // 电视横版双栏：左品牌介绍，右登录表单（夸克扫码/Cookie、账密型地址）。
    return Scaffold(
      backgroundColor: TvDesignTokens.background,
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: m.s(1360)),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: m.spacingXxl,
                vertical: m.spacingXl,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 5, child: _infoPane(m)),
                  SizedBox(width: m.spacingXxl),
                  Expanded(flex: 6, child: _formPane(m)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 左栏：源类型品牌介绍（accent 图标 + 名称 + 说明）。
  Widget _infoPane(TvMetrics m) {
    final d = _descriptor;
    return Container(
      padding: EdgeInsets.all(m.spacingXl),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            d.accent.withValues(alpha: 0.20),
            d.accent.withValues(alpha: 0.04),
          ],
        ),
        borderRadius: BorderRadius.circular(m.s(20)),
        border: Border.all(color: d.accent.withValues(alpha: 0.32), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: m.s(96),
            height: m.s(96),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: d.accent.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(m.s(20)),
            ),
            child: Icon(d.icon, color: d.accent, size: m.s(52)),
          ),
          SizedBox(height: m.spacingLg),
          Text(
            '添加 ${d.name}',
            style: TextStyle(
              fontSize: m.fontSizeXxl,
              color: TvDesignTokens.textPrimary,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: m.spacingSm),
          Text(
            d.subtitle,
            style: TextStyle(
              fontSize: m.fontSizeMd,
              color: TvDesignTokens.textSecondary,
              height: TvDesignTokens.lineHeightRelaxed,
            ),
          ),
        ],
      ),
    );
  }

  /// 右栏：登录表单（备注名 + 夸克扫码/Cookie 或 账密地址 + 按钮）。
  Widget _formPane(TvMetrics m) {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _field(
            m: m,
            label: '备注名称（可选）',
            controller: _nameController,
            prefixIcon: Icons.label_outline,
          ),
          SizedBox(height: m.spacingLg),
          if (_isQuark) ...[
            _quarkMethodToggle(m),
            SizedBox(height: m.spacingLg),
            if (_quarkMethod == 0)
              Center(
                child: QuarkQrLoginView(
                  currentName: () => _nameController.text,
                  onSuccess: _onLoggedIn,
                ),
              )
            else
              _field(
                m: m,
                label: 'Cookie',
                controller: _cookieController,
                hint: '__pus=...; __puus=...; ...',
                autofocus: true,
                maxLines: 4,
                prefixIcon: Icons.cookie_outlined,
              ),
          ] else ...[
            _field(
              m: m,
              label: '服务器地址',
              controller: _urlController,
              hint: 'https://example.com:5244',
              autofocus: true,
              keyboardType: TextInputType.url,
              prefixIcon: Icons.link,
            ),
            SizedBox(height: m.spacingLg),
            _field(
              m: m,
              label: '用户名',
              controller: _userController,
              prefixIcon: Icons.person_outline,
            ),
            SizedBox(height: m.spacingLg),
            _field(
              m: m,
              label: '密码',
              controller: _passController,
              obscure: true,
              prefixIcon: Icons.lock_outline,
            ),
          ],
          if (_error != null) ...[
            SizedBox(height: m.spacingLg),
            Text(
              _error!,
              style: TextStyle(
                fontSize: m.fontSizeSm,
                color: TvDesignTokens.error,
              ),
            ).animate().shake(duration: 400.ms),
          ],
          SizedBox(height: m.spacingXl),
          Row(
            children: [
              // 扫码方式无需「连接」按钮（扫码确认后自动完成）。
              if (!(_isQuark && _quarkMethod == 0)) ...[
                if (_loading)
                  Padding(
                    padding: EdgeInsets.only(right: m.spacingLg),
                    child: SizedBox(
                      width: m.s(28),
                      height: m.s(28),
                      child: const CircularProgressIndicator(
                        color: TvDesignTokens.brand,
                        strokeWidth: 3,
                      ),
                    ),
                  ),
                TvButton(
                  text: _loading ? '连接中…' : '登录并添加',
                  icon: Icons.link,
                  onPressed: _loading ? null : _connect,
                ),
                SizedBox(width: m.spacingMd),
              ],
              TvButton(
                text: '取消',
                outlined: true,
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _quarkMethodToggle(TvMetrics m) {
    Widget chip(int value, String label, IconData icon) {
      final selected = _quarkMethod == value;
      return TvFocusable(
        padding: EdgeInsets.all(m.s(4)),
        onSelect: () => setState(() {
          _quarkMethod = value;
          _error = null;
        }),
        child: Container(
          padding: EdgeInsets.symmetric(
              horizontal: m.spacingLg, vertical: m.spacingMd),
          decoration: BoxDecoration(
            color: selected
                ? TvDesignTokens.brand.withValues(alpha: 0.18)
                : TvDesignTokens.surface,
            borderRadius: BorderRadius.circular(m.posterRadius),
            border: selected
                ? Border.all(color: TvDesignTokens.brand, width: 2)
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: m.s(22),
                  color: selected
                      ? TvDesignTokens.brand
                      : TvDesignTokens.textPrimary),
              SizedBox(width: m.spacingSm),
              Text(label,
                  style: TextStyle(
                      fontSize: m.fontSizeSm,
                      color: selected
                          ? TvDesignTokens.brand
                          : TvDesignTokens.textPrimary)),
            ],
          ),
        ),
      );
    }

    return Row(
      children: [
        chip(0, '扫码登录', Icons.qr_code),
        SizedBox(width: m.spacingMd),
        chip(1, 'Cookie', Icons.cookie_outlined),
      ],
    );
  }

  Widget _field({
    required TvMetrics m,
    required String label,
    required TextEditingController controller,
    String? hint,
    IconData? prefixIcon,
    bool obscure = false,
    bool autofocus = false,
    TextInputType? keyboardType,
    int maxLines = 1,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: m.fontSizeSm,
            color: TvDesignTokens.textSecondary,
          ),
        ),
        SizedBox(height: m.spacingXs),
        TvTextField(
          controller: controller,
          hint: hint,
          obscureText: obscure,
          autofocus: autofocus,
          maxLines: maxLines,
          keyboardType: keyboardType,
          prefixIcon: prefixIcon == null
              ? null
              : Icon(prefixIcon,
                  color: TvDesignTokens.textSecondary, size: m.s(26)),
        ),
      ],
    );
  }
}
