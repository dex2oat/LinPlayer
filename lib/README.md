# Linplayer Mobile - UI 项目

## 项目概述

本项目是 Linplayer 的 Flutter 移动端 UI 实现，基于 DESIGN.md 设计文档构建。

## 技术栈

- **Flutter** + **Dart**
- **Riverpod** - 状态管理
- **GoRouter** - 路由
- **Material 3** - UI组件

## 项目结构

```
lib/
├── main.dart                          # 入口
├── app.dart                           # 应用根组件
├── core/
│   ├── api/
│   │   ├── api_interfaces.dart        # API抽象接口（供后端接入）
│   │   ├── api_response.dart          # API响应包装
│   │   └── mock_api.dart              # Mock实现（UI开发测试用）
│   ├── models/                        # 数据模型（在api_interfaces中定义）
│   ├── providers/
│   │   ├── app_providers.dart         # 全局Providers（认证、服务器、主题等）
│   │   └── media_providers.dart       # 媒体数据Providers
│   ├── theme/
│   │   ├── app_theme.dart             # Material 3主题配置
│   │   └── app_colors.dart            # 设计Token/颜色
│   └── utils/
│       └── cn.dart                    # className工具
├── routes/
│   └── app_router.dart                # GoRouter路由配置
└── ui/
    ├── screens/
    │   ├── server/                    # 服务器页面
    │   │   ├── server_list_screen.dart
    │   │   ├── add_server_screen.dart
    │   │   ├── server_lines_screen.dart
    │   │   └── icon_select_screen.dart
    │   ├── home/                      # 首页
    │   │   └── home_screen.dart
    │   ├── detail/                    # 详情页
    │   │   ├── media_detail_screen.dart
    │   │   └── season_detail_screen.dart
    │   ├── search/                    # 搜索页
    │   │   └── search_screen.dart
    │   ├── player/                    # 播放页
    │   │   └── player_screen.dart
    │   ├── settings/                  # 设置页
    │   │   └── settings_screen.dart
    │   ├── library/                   # 媒体库详情
    │   │   └── library_detail_screen.dart
    │   └── download/                  # 下载页
    │       └── download_screen.dart
    └── widgets/
        └── common/
            └── media_widgets.dart     # 通用媒体组件
```

## API 接口接入说明

### 1. 接口位置

所有API接口定义在 `lib/core/api/api_interfaces.dart` 中。

### 2. 需要实现的接口

API开发人员需要实现以下接口：

```dart
// 认证
abstract class AuthApi { ... }

// 用户
abstract class UserApi { ... }

// 服务器
abstract class ServerApi { ... }

// 首页
abstract class HomeApi { ... }

// 媒体库
abstract class LibraryApi { ... }

// 媒体项（详情、季、集）
abstract class MediaApi { ... }

// 搜索
abstract class SearchApi { ... }

// 播放
abstract class PlaybackApi { ... }

// 收藏
abstract class FavoriteApi { ... }

// 会话
abstract class SessionApi { ... }

// 图片
abstract class ImageApi { ... }

// 弹幕
abstract class DanmakuApi { ... }
```

### 3. 工厂接口

实现 `ApiClientFactory` 接口，将所有API实现组合在一起：

```dart
class EmbyApiClient implements ApiClientFactory {
  @override
  AuthApi get auth => EmbyAuthApi();
  
  @override
  HomeApi get home => EmbyHomeApi();
  
  // ... 其他API
}
```

### 4. 替换Mock

在 `lib/core/providers/app_providers.dart` 中替换：

```dart
// 当前使用Mock
final apiClientProvider = Provider<ApiClientFactory>((ref) => MockApiClient());

// 替换为真实实现
final apiClientProvider = Provider<ApiClientFactory>((ref) => EmbyApiClient());
```

### 5. 数据模型

所有数据模型（`MediaItem`, `Episode`, `Season`, `Library` 等）已在接口文件中定义，
API开发人员需要根据实际API响应调整这些模型。

## 运行项目

```bash
# 获取依赖
flutter pub get

# 运行（开发模式）
flutter run

# 构建发布版本
flutter build apk --release
```

## 设计规范

- 品牌色: `#5B8DEF` (靛蓝)
- 间距基准: 4px等比 (4, 8, 12, 16, 24, 32, 48, 64)
- 字号比例: Major Third 1.25x
- 圆角: 4, 8, 12, 16, 24
- 使用 Material 3 组件
- 支持深浅模式

## 功能模块

### 已完成UI

- ✅ 服务器列表（条形/矩形视图、拖拽排序、更多菜单）
- ✅ 添加服务器（手动输入、批量解析、导入配置）
- ✅ 服务器线路管理（添加/编辑/删除/切换）
- ✅ 图标选择（本地图片/网络图标库）
- ✅ 首页（随机推荐轮播、继续观看、媒体库、最新内容）
- ✅ 剧详情页（封面、简介、季选择、集数选择）
- ✅ 电影详情页（封面、播放按钮、版本信息）
- ✅ 搜索页（搜索历史、聚合搜索）
- ✅ 播放页（手势控制、倍速、进度条、设置弹窗）
- ✅ 设置页（通用/播放器/弹幕/关于/备份）
- ✅ 媒体库详情页（筛选、网格布局）
- ✅ 下载页（下载列表、进度显示）

### 待接入功能

- 🔄 Emby API 真实实现
- 🔄 视频播放器内核（mpv/ExoPlayer）
- 🔄 弹幕渲染引擎
- 🔄 本地数据库（Drift）
- 🔄 图片缓存（extended_image）
- 🔄 国际化（slang）

## 贡献指南

1. API开发人员：实现 `lib/core/api/api_interfaces.dart` 中的接口
2. UI开发人员：使用已有的Providers，不要直接调用API
3. 所有状态管理使用 Riverpod
