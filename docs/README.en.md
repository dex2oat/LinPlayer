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
  <b>English</b> ·
  <a href="README.ja.md">日本語</a>
</p>

**LinPlayer** is a cross-platform third-party Emby client covering **mobile (Android / iOS)**, **desktop (Windows / Linux / macOS)** and **TV (Android TV / tvOS)**, evolving on Flutter as its single long-term codebase.

> Each platform uses its own native UI language (Material / fluent_ui / macos_ui / adaptive TV), while sharing the same core logic.

## Features

- **Dual player cores**
  - **ExoPlayer** (Android native): lightweight and stable, with text subtitles (SRT/ASS/WEBVTT/TTML)
  - **MPV** (media_kit / libmpv): full-format support, HDR / Dolby Vision, native PGS/SUP graphic subtitles, Anime4K upscaling
- **Danmaku**: multiple backends including DanDanPlay, smart episode matching, parallel sources, outline / display-area rendering — on all three platforms
- **Rankings**: DanDanPlay anime chart + TMDB movie/TV chart (toggleable)
- **Multi-source browsing**: beyond Emby, network-disk / aggregation sources (OpenList, Quark Cookie/QR, Ani-rss, etc.)
- **Subtitles**: auto-load Emby subtitle streams, track switching, delay adjustment, font/size/position settings; full libass effects on MPV
- **Downloads**: custom multi-threaded (ranged) download engine, unified across platforms
- **Proxy**: per-platform custom proxy + Cloudflare best-IP local reverse proxy; Android TV bundles the mihomo core + zashboard panel
- **Plugin system**: QuickJS script engine, each plugin in its own isolate with crash/timeout isolation
- **Casting**: DLNA
- **Remote control**: control the TV client from a phone via QR (built-in HTTP server + web control page)
- **In-app updates**: dual channel (stable / pre) overwrite updates
- **Playback reporting**: complete Emby progress sync, with cross-server resume

## Screenshots

### Desktop

> Content shown courtesy of [**UHD MEDIA**](https://www.uhdnow.com).

<table>
  <tr>
    <td colspan="2"><img src="images/screenshots/pc-player.png" width="100%" alt="Player"><br><sub><b>Player</b></sub></td>
  </tr>
  <tr>
    <td width="50%"><img src="images/screenshots/pc-home.png" width="100%" alt="Home"><br><sub><b>Home</b></sub></td>
    <td width="50%"><img src="images/screenshots/pc-library.png" width="100%" alt="Library"><br><sub><b>Library</b></sub></td>
  </tr>
  <tr>
    <td><img src="images/screenshots/pc-series-detail.png" width="100%" alt="Series detail"><br><sub><b>Series Detail</b></sub></td>
    <td><img src="images/screenshots/pc-movie-detail.png" width="100%" alt="Movie detail"><br><sub><b>Movie Detail</b></sub></td>
  </tr>
  <tr>
    <td><img src="images/screenshots/pc-rankings.png" width="100%" alt="Rankings"><br><sub><b>Rankings</b></sub></td>
    <td><img src="images/screenshots/pc-search.png" width="100%" alt="Search"><br><sub><b>Search</b></sub></td>
  </tr>
  <tr>
    <td><img src="images/screenshots/pc-favorites.png" width="100%" alt="Favorites"><br><sub><b>Favorites</b></sub></td>
    <td><img src="images/screenshots/pc-settings.png" width="100%" alt="Settings"><br><sub><b>Settings</b></sub></td>
  </tr>
  <tr>
    <td><img src="images/screenshots/pc-add-server-1.png" width="100%" alt="Add server 1"><br><sub><b>Add Server ①</b></sub></td>
    <td><img src="images/screenshots/pc-add-server-2.png" width="100%" alt="Add server 2"><br><sub><b>Add Server ②</b></sub></td>
  </tr>
  <tr>
    <td colspan="2" width="50%"><img src="images/screenshots/pc-add-server-3.png" width="100%" alt="Add server 3"><br><sub><b>Add Server ③</b></sub></td>
  </tr>
</table>

### Mobile

> Content shown courtesy of [**BAVA**](https://shop.mebimmer.de).

<table>
  <tr>
    <td colspan="3"><img src="images/screenshots/mobile-player.jpg" width="100%" alt="Player"><br><sub><b>Player</b></sub></td>
  </tr>
  <tr>
    <td width="33%"><img src="images/screenshots/mobile-home.jpg" width="100%" alt="Home"><br><sub><b>Home</b></sub></td>
    <td width="33%"><img src="images/screenshots/mobile-series-detail.jpg" width="100%" alt="Series detail"><br><sub><b>Series Detail</b></sub></td>
    <td width="33%"><img src="images/screenshots/mobile-episode-detail.jpg" width="100%" alt="Episode detail"><br><sub><b>Episode Detail</b></sub></td>
  </tr>
  <tr>
    <td><img src="images/screenshots/mobile-movie-detail.jpg" width="100%" alt="Movie detail"><br><sub><b>Movie Detail</b></sub></td>
    <td><img src="images/screenshots/mobile-rankings.jpg" width="100%" alt="Rankings"><br><sub><b>Rankings</b></sub></td>
    <td><img src="images/screenshots/mobile-settings.jpg" width="100%" alt="Settings"><br><sub><b>Settings</b></sub></td>
  </tr>
</table>

## Development & Tech

Player-core comparison, local development & builds, and the tech stack — see the **[development docs →](DEVELOPMENT.md)**.

## Disclaimer

### About Content & Media

- LinPlayer is a **purely local player / third-party client**. It **does not provide, store, host, or distribute any video content**, and ships with no built-in content sources.
- All media shown and played inside the app comes from **servers the user adds themselves (e.g. Emby) or network sources the user configures themselves**. The origin, copyright, and legality of that content **are solely the user's responsibility**.
- Please only play content you **lawfully own or are authorized to access**, and comply with the laws and regulations of your country/region. Any dispute, loss, or legal liability arising from improper use **is borne solely by the user** and is unrelated to this project or its developers.
- This project is **free, open-source, and non-profit**; it makes no money from content distribution in any form. If a rights holder finds certain content inappropriate, the issue lies with the content's source — please contact the corresponding resource/server provider.

### About Anonymous Telemetry & Privacy

- To continuously improve stability, LinPlayer integrates [Sentry](https://sentry.io) for **crash/error reporting** and **anonymous active-usage statistics** (used only to understand crashes and rough usage scale).
- We **never collect any information that can identify you personally**: no accounts, passwords, cookies, tokens, server addresses, library contents, watch history, or IP addresses. **No screen recording, no behavior tracking.**
- Reported data contains only **anonymous crash stack traces, app version, and platform/OS type** and similar technical info, with devices distinguished by a random anonymous identifier (counting heads, not identities).
- We **never sell, share, or use this data for advertising or any commercial purpose**. The configuration is publicly auditable: [`lib/core/services/telemetry.dart`](../lib/core/services/telemetry.dart).

## License

[LICENSE](../LICENSE)

## Acknowledgements

LinPlayer stands on the shoulders of these open-source projects, media services and cores:

### Player Cores

- [media-kit](https://github.com/media-kit/media-kit) — cross-platform media player (libmpv wrapper)
- [mpv](https://github.com/mpv-player/mpv) / [libmpv](https://github.com/mpv-player/mpv) — full-format playback core
- [ExoPlayer / androidx media](https://github.com/androidx/media) — Android native player
- [MPVKit](https://github.com/mpvkit/MPVKit) — libmpv integration for tvOS
- [shinchiro mpv-winbuild](https://github.com/shinchiro/mpv-winbuild-cmake) — full-featured libmpv prebuilds for Windows
- [Anime4K](https://github.com/bloc97/Anime4K) — real-time upscaling GLSL shaders

### UI & Framework

- [Flutter](https://flutter.dev) / [Riverpod](https://riverpod.dev) / [go_router](https://pub.dev/packages/go_router)
- [TDesign Flutter](https://github.com/Tencent/tdesign-flutter) — Tencent TDesign component library (vendored & patched)
- [fluent_ui](https://github.com/bdlukaa/fluent_ui) — Windows Fluent style
- [macos_ui](https://github.com/GroovinChip/macos_ui) — macOS native style
- [flutter_animate](https://pub.dev/packages/flutter_animate) — unified motion across platforms

### Services & Data Sources

- [Emby](https://emby.media/) — media server
- [DanDanPlay](https://www.dandanplay.com/) — danmaku and anime ranking data
- [TMDB](https://www.themoviedb.org/) — movie/TV ranking data
- [Bangumi (bgm.tv)](https://bgm.tv/) — anime tracking progress and collection sync
- [anibt](https://anibt.net) — thanks to the operator for providing a domestic Bangumi reverse proxy (API and image acceleration) that makes tracking sync work out of the box; also a new-generation BT/magnet search site — rich resources, clean experience, recommended
- [Trakt](https://trakt.tv/) — movie/TV watch history sync (Scrobble)
- [OpenList](https://github.com/OpenListTeam/OpenList) — network-disk aggregation source

### Emby Servers

Thanks to the following Emby servers for providing UI demos and long-term support:

- [UHD MEDIA](https://www.uhdnow.com) — desktop screenshots content
- [BAVA](https://shop.mebimmer.de) — mobile screenshots content

### Network & Proxy

- [mihomo (Clash.Meta)](https://github.com/MetaCubeX/mihomo) — proxy core bundled on Android TV
- [zashboard](https://github.com/Zephyruso/zashboard) — mihomo control panel
- [socks5_proxy](https://pub.dev/packages/socks5_proxy) — SOCKS proxy support

### Scripting & Tools

- [flutter_qjs](https://github.com/ekibun/flutter_qjs) / [QuickJS](https://bellard.org/quickjs/) — plugin script engine (vendored & patched)
- [dio](https://github.com/cfug/dio) / [extended_image](https://github.com/fluttercandies/extended_image) / [archive](https://pub.dev/packages/archive) and other pub.dev packages

> Content from TMDB and DanDanPlay remains the copyright of its respective owners; this project only aggregates and displays it, and does not store or distribute copyrighted media.

## Star History

<a href="https://www.star-history.com/?type=date&repos=zzzwannasleep%2FLinPlayer">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=zzzwannasleep/linplayer&type=date&theme=dark&legend=top-left&sealed_token=YzGbSgSFzLcAXL2bfZUBGY625cNArNjNErV_fzvJkGSGpr_Xo8X3sXD8xRJf0Nehyt_OzmkyLq61xHqLXMn2i9APoG2uXgW_Z7nNRZArCQ-HjjGtU6fMFg" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=zzzwannasleep/linplayer&type=date&legend=top-left&sealed_token=YzGbSgSFzLcAXL2bfZUBGY625cNArNjNErV_fzvJkGSGpr_Xo8X3sXD8xRJf0Nehyt_OzmkyLq61xHqLXMn2i9APoG2uXgW_Z7nNRZArCQ-HjjGtU6fMFg" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=zzzwannasleep/linplayer&type=date&legend=top-left&sealed_token=YzGbSgSFzLcAXL2bfZUBGY625cNArNjNErV_fzvJkGSGpr_Xo8X3sXD8xRJf0Nehyt_OzmkyLq61xHqLXMn2i9APoG2uXgW_Z7nNRZArCQ-HjjGtU6fMFg" />
 </picture>
</a>

## Project Activity

![Alt](https://repobeats.axiom.co/api/embed/4858243f2148dfeaa4e82f119fa918f3ec581a11.svg "Repobeats analytics image")

## Sponsors

Thanks to everyone supporting LinPlayer on [Afdian](https://afdian.com/a/zzzwannasleep) (list updated in real time):

<p align="center">
  <a href="https://afdian.com/a/zzzwannasleep"><img src="https://291277.xyz/afdian/sponsors.svg" alt="Afdian sponsors"></a>
</p>

## Join the Channel

Telegram channel [**@MikudesuChannels**](https://t.me/MikudesuChannels) — releases, previews and discussion.
