# LinPlayer

<p align="center">
  <a href="https://github.com/zzzwannasleep/LinPlayer/stargazers"><img src="https://img.shields.io/github/stars/zzzwannasleep/LinPlayer?style=flat&logo=github&label=Stars" alt="Stars"></a>
  <a href="https://github.com/zzzwannasleep/LinPlayer/releases"><img src="https://img.shields.io/github/v/release/zzzwannasleep/LinPlayer?label=stable&color=blue" alt="Stable"></a>
  <a href="https://github.com/zzzwannasleep/LinPlayer/releases"><img src="https://img.shields.io/github/v/release/zzzwannasleep/LinPlayer?include_prereleases&label=pre-release&color=orange" alt="Pre-release"></a>
  <a href="https://github.com/zzzwannasleep/LinPlayer/releases"><img src="https://img.shields.io/github/downloads/zzzwannasleep/LinPlayer/total?label=downloads&color=green&logo=github" alt="Downloads"></a>
  <a href="https://github.com/zzzwannasleep/LinPlayer/blob/main/LICENSE"><img src="https://img.shields.io/github/license/zzzwannasleep/LinPlayer" alt="License"></a>
  <img src="https://img.shields.io/badge/Flutter-3.24+-02569B?logo=flutter" alt="Flutter">
  <a href="https://github.com/zzzwannasleep/LinPlayer/actions"><img src="https://img.shields.io/github/actions/workflow/status/zzzwannasleep/LinPlayer/build.yml?branch=main&label=build&logo=github" alt="Build"></a>
  <a href="https://t.me/MikudesuChannels"><img src="https://img.shields.io/badge/Telegram-MikudesuChannels-26A5E4?logo=telegram&logoColor=white" alt="Telegram"></a>
</p>

<p align="center">
  <a href="../README.md">简体中文</a> ·
  <a href="README.en.md">English</a> ·
  <b>日本語</b>
</p>

**LinPlayer** は、**モバイル（Android / iOS）**、**デスクトップ（Windows / Linux / macOS）**、**テレビ（Android TV / tvOS）** をカバーするクロスプラットフォームの Emby サードパーティクライアントで、Flutter を唯一の長期コードベースとして進化しています。

> 各プラットフォームはそれぞれのネイティブ UI 言語（Material / fluent_ui / macos_ui / TV アダプティブ）を使いつつ、同じコアロジックを共有します。

## 機能

- **デュアル再生コア**
  - **ExoPlayer**（Android ネイティブ）：軽量で安定、テキスト字幕（SRT/ASS/WEBVTT/TTML）に対応
  - **MPV**（media_kit / libmpv）：全フォーマット対応、HDR / Dolby Vision、PGS/SUP グラフィック字幕のネイティブ対応、Anime4K 超解像
- **弾幕（コメント）**：DanDanPlay など複数バックエンドに対応、話数の自動マッチング、ソース並列取得、縁取り／表示領域レンダリング、三端で利用可能
- **ランキング**：DanDanPlay アニメランキング + TMDB 映画・ドラマランキング（切替可）
- **マルチソース閲覧**：Emby 以外にネットワークディスク／集約ソース（OpenList、Quark Cookie/QR、Ani-rss など）に対応
- **字幕**：Emby 字幕ストリームの自動読み込み、トラック切替、遅延調整、フォント／サイズ／位置設定；MPV は libass のフル特効
- **ダウンロード**：自作のマルチスレッド（レンジ分割）ダウンロードエンジン、三端で統一
- **プロキシ**：三端カスタムプロキシ + Cloudflare 最速 IP ローカルリバースプロキシ；Android TV は mihomo コア + zashboard パネルを内蔵
- **プラグインシステム**：QuickJS スクリプトエンジン、各プラグインは独立 isolate でクラッシュ／タイムアウトを隔離
- **キャスト**：DLNA
- **リモコン**：スマホの QR でテレビ端を操作（内蔵 HTTP サーバー + Web コントロールページ）
- **アプリ内アップデート**：デュアルチャンネル（stable / pre）の上書き更新
- **再生レポート**：完全な Emby 進捗同期、サーバー跨ぎのレジューム対応

## スクリーンショット

### デスクトップ

> 表示コンテンツは [**UHD MEDIA**](https://www.uhdnow.com) のご提供です。

<table>
  <tr>
    <td colspan="2"><img src="images/screenshots/pc-player.png" width="100%" alt="プレーヤー"><br><sub><b>プレーヤー</b></sub></td>
  </tr>
  <tr>
    <td width="50%"><img src="images/screenshots/pc-home.png" width="100%" alt="ホーム"><br><sub><b>ホーム</b></sub></td>
    <td width="50%"><img src="images/screenshots/pc-library.png" width="100%" alt="ライブラリ"><br><sub><b>ライブラリ</b></sub></td>
  </tr>
  <tr>
    <td><img src="images/screenshots/pc-series-detail.png" width="100%" alt="シリーズ詳細"><br><sub><b>シリーズ詳細</b></sub></td>
    <td><img src="images/screenshots/pc-movie-detail.png" width="100%" alt="映画詳細"><br><sub><b>映画詳細</b></sub></td>
  </tr>
  <tr>
    <td><img src="images/screenshots/pc-rankings.png" width="100%" alt="ランキング"><br><sub><b>ランキング</b></sub></td>
    <td><img src="images/screenshots/pc-search.png" width="100%" alt="検索"><br><sub><b>検索</b></sub></td>
  </tr>
  <tr>
    <td><img src="images/screenshots/pc-favorites.png" width="100%" alt="お気に入り"><br><sub><b>お気に入り</b></sub></td>
    <td><img src="images/screenshots/pc-settings.png" width="100%" alt="設定"><br><sub><b>設定</b></sub></td>
  </tr>
  <tr>
    <td><img src="images/screenshots/pc-add-server-1.png" width="100%" alt="サーバー追加 1"><br><sub><b>サーバー追加 ①</b></sub></td>
    <td><img src="images/screenshots/pc-add-server-2.png" width="100%" alt="サーバー追加 2"><br><sub><b>サーバー追加 ②</b></sub></td>
  </tr>
  <tr>
    <td colspan="2" width="50%"><img src="images/screenshots/pc-add-server-3.png" width="100%" alt="サーバー追加 3"><br><sub><b>サーバー追加 ③</b></sub></td>
  </tr>
</table>

### モバイル

> 表示コンテンツは [**BAVA サーバー**](https://shop.mebimmer.de) のご提供です。

<table>
  <tr>
    <td colspan="3"><img src="images/screenshots/mobile-player.jpg" width="100%" alt="プレーヤー"><br><sub><b>プレーヤー</b></sub></td>
  </tr>
  <tr>
    <td width="33%"><img src="images/screenshots/mobile-home.jpg" width="100%" alt="ホーム"><br><sub><b>ホーム</b></sub></td>
    <td width="33%"><img src="images/screenshots/mobile-series-detail.jpg" width="100%" alt="シリーズ詳細"><br><sub><b>シリーズ詳細</b></sub></td>
    <td width="33%"><img src="images/screenshots/mobile-episode-detail.jpg" width="100%" alt="エピソード詳細"><br><sub><b>エピソード詳細</b></sub></td>
  </tr>
  <tr>
    <td><img src="images/screenshots/mobile-movie-detail.jpg" width="100%" alt="映画詳細"><br><sub><b>映画詳細</b></sub></td>
    <td><img src="images/screenshots/mobile-rankings.jpg" width="100%" alt="ランキング"><br><sub><b>ランキング</b></sub></td>
    <td><img src="images/screenshots/mobile-settings.jpg" width="100%" alt="設定"><br><sub><b>設定</b></sub></td>
  </tr>
</table>

## 開発と技術

再生コアの比較、ローカル開発とビルド、技術スタックは **[開発ドキュメント →](DEVELOPMENT.md)** を参照してください。

## 免責事項

### コンテンツ・リソースについて

- LinPlayer は**純粋なローカルプレーヤー / サードパーティクライアント**であり、それ自体は**いかなる映像リソースも提供・保存・ホスト・配布しません**。コンテンツソースも内蔵していません。
- アプリ内で表示・再生されるすべてのメディアは、**ユーザー自身が追加したサーバー（Emby など）またはユーザー自身が設定したネットワーク上の提供元**に由来し、その出所・著作権・適法性は**すべてユーザー自身の責任**です。
- **合法的に所有している、または利用を許諾されている**コンテンツのみを再生し、お住まいの国・地域の法令を遵守してください。利用者の不適切な使用に起因するいかなる紛争・損失・法的責任も**利用者自身が負う**ものとし、本プロジェクトおよび開発者とは一切関係ありません。
- 本プロジェクトは**無料・オープンソース・非営利**のソフトウェアであり、コンテンツの伝播からいかなる形でも利益を得ません。権利者の方がコンテンツを不適切とお考えの場合、問題は提供元にありますので、該当するリソース／サーバーの提供者へお問い合わせください。

### 匿名テレメトリとプライバシーについて

- 安定性を継続的に改善するため、LinPlayer は [Sentry](https://sentry.io) を用いた**クラッシュ／エラー報告**と**匿名のアクティブ利用統計**（クラッシュ状況とおおよその利用規模の把握のみに使用）を組み込んでいます。
- 私たちは**個人を特定できる情報を一切収集しません**。アカウント、パスワード、Cookie、トークン、サーバーアドレス、ライブラリの内容、視聴履歴、IP アドレスは収集せず、**画面録画も行動追跡も行いません**。
- 報告されるデータは、**匿名のクラッシュスタックトレース、アプリのバージョン、プラットフォーム／OS の種類**などの技術情報のみで、ランダムな匿名識別子で端末を区別します（人数を数えるだけで、身元は特定しません）。
- 私たちはこのデータを**販売・共有したり、広告その他いかなる商業目的にも使用しません**。設定は公開されており検証可能です：[`lib/core/services/telemetry.dart`](../lib/core/services/telemetry.dart)。

## ライセンス

[LICENSE](../LICENSE)

## 謝辞

LinPlayer は以下のオープンソースプロジェクト、メディアサービス、コアの肩の上に立っています：

### 再生コア

- [media-kit](https://github.com/media-kit/media-kit) — クロスプラットフォームメディアプレーヤー（libmpv ラッパー）
- [mpv](https://github.com/mpv-player/mpv) / [libmpv](https://github.com/mpv-player/mpv) — 全フォーマット再生コア
- [ExoPlayer / androidx media](https://github.com/androidx/media) — Android ネイティブプレーヤー
- [MPVKit](https://github.com/mpvkit/MPVKit) — tvOS 向け libmpv 統合
- [shinchiro mpv-winbuild](https://github.com/shinchiro/mpv-winbuild-cmake) — Windows 向けフル機能 libmpv プリビルド
- [Anime4K](https://github.com/bloc97/Anime4K) — リアルタイム超解像 GLSL シェーダー

### UI とフレームワーク

- [Flutter](https://flutter.dev) / [Riverpod](https://riverpod.dev) / [go_router](https://pub.dev/packages/go_router)
- [TDesign Flutter](https://github.com/Tencent/tdesign-flutter) — Tencent TDesign コンポーネントライブラリ（vendored & パッチ適用）
- [fluent_ui](https://github.com/bdlukaa/fluent_ui) — Windows Fluent スタイル
- [macos_ui](https://github.com/GroovinChip/macos_ui) — macOS ネイティブスタイル
- [flutter_animate](https://pub.dev/packages/flutter_animate) — 三端統一モーション

### サービスとデータソース

- [Emby](https://emby.media/) — メディアサーバー
- [DanDanPlay](https://www.dandanplay.com/) — 弾幕とアニメランキングデータ
- [TMDB](https://www.themoviedb.org/) — 映画・ドラマランキングデータ
- [Bangumi (bgm.tv)](https://bgm.tv/) — アニメの視聴進捗とコレクション同期
- [anibt](https://anibt.net) — 国内向け Bangumi リバースプロキシ（API と画像の高速化）を LinPlayer に提供いただき、視聴同期がそのまま使える状態に。次世代の BT／マグネット検索サイトでもあり、リソース豊富で快適、おすすめです
- [Trakt](https://trakt.tv/) — 映画・ドラマの視聴履歴同期（Scrobble）
- [OpenList](https://github.com/OpenListTeam/OpenList) — ネットワークディスク集約ソース

### Emby サーバー

UI デモと長期的なサポートを提供いただいた以下の Emby サーバーに感謝します：

- [UHD MEDIA](https://www.uhdnow.com) — デスクトップのスクリーンショット提供
- [BAVA サーバー](https://shop.mebimmer.de) — モバイルのスクリーンショット提供

### ネットワークとプロキシ

- [mihomo (Clash.Meta)](https://github.com/MetaCubeX/mihomo) — Android TV 内蔵プロキシコア
- [zashboard](https://github.com/Zephyruso/zashboard) — mihomo コントロールパネル
- [socks5_proxy](https://pub.dev/packages/socks5_proxy) — SOCKS プロキシ対応

### スクリプトとツール

- [flutter_qjs](https://github.com/ekibun/flutter_qjs) / [QuickJS](https://bellard.org/quickjs/) — プラグインスクリプトエンジン（vendored & パッチ適用）
- [dio](https://github.com/cfug/dio) / [extended_image](https://github.com/fluttercandies/extended_image) / [archive](https://pub.dev/packages/archive) など pub.dev のパッケージ

> TMDB と DanDanPlay のコンテンツの著作権はそれぞれの権利者に帰属します。本プロジェクトは集約・表示を行うのみで、著作権保護されたメディアの保存や配布は行いません。

## Star History

<a href="https://www.star-history.com/?type=date&repos=zzzwannasleep%2FLinPlayer">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=zzzwannasleep/linplayer&type=date&theme=dark&legend=top-left&sealed_token=YzGbSgSFzLcAXL2bfZUBGY625cNArNjNErV_fzvJkGSGpr_Xo8X3sXD8xRJf0Nehyt_OzmkyLq61xHqLXMn2i9APoG2uXgW_Z7nNRZArCQ-HjjGtU6fMFg" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=zzzwannasleep/linplayer&type=date&legend=top-left&sealed_token=YzGbSgSFzLcAXL2bfZUBGY625cNArNjNErV_fzvJkGSGpr_Xo8X3sXD8xRJf0Nehyt_OzmkyLq61xHqLXMn2i9APoG2uXgW_Z7nNRZArCQ-HjjGtU6fMFg" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=zzzwannasleep/linplayer&type=date&legend=top-left&sealed_token=YzGbSgSFzLcAXL2bfZUBGY625cNArNjNErV_fzvJkGSGpr_Xo8X3sXD8xRJf0Nehyt_OzmkyLq61xHqLXMn2i9APoG2uXgW_Z7nNRZArCQ-HjjGtU6fMFg" />
 </picture>
</a>

## プロジェクトの活動

![Alt](https://repobeats.axiom.co/api/embed/4858243f2148dfeaa4e82f119fa918f3ec581a11.svg "Repobeats analytics image")

## スポンサー

[Afdian（爱发电）](https://afdian.com/a/zzzwannasleep) で LinPlayer を支援してくださっている皆様に感謝します（リストはリアルタイム更新）：

<p align="center">
  <a href="https://afdian.com/a/zzzwannasleep"><img src="https://291277.xyz/afdian/sponsors.svg" alt="Afdian スポンサー"></a>
</p>

## チャンネル

Telegram チャンネル [**@MikudesuChannels**](https://t.me/MikudesuChannels) —— リリース、更新予告、ディスカッション。
