# FNTV API 请求清单

来源基于当前代码里的请求调用点：`src/modules/fn_api/api.ts`、`src/modules/fn_api/request.ts`、`src/modules/proxy/pkg/fnapi/api.go`、`src/modules/proxy/internal/logic/api/*.go`、`src/modules/proxy/pkg/utils/*.go`、`src/main/handlers/plugins/fnid_login.ts`、`src/modules/updater/updateChecker.ts`。

## 通用 FN NAS 请求

FN NAS API 的基础地址为用户配置的 `baseURL` / `domain`，下面路径都拼在它后面。

通用请求头：

| Header | 值 / 参数 |
| --- | --- |
| `Content-Type` | `application/json` |
| `Authorization` | 登录后保存的 `token`；登录、FN ID 换 token 时可为空 |
| `Cookie` | 默认 `mode=relay`；FN ID 获取配置时可能额外带浏览器 Cookie |
| `Authx` | `nonce=<随机数>&timestamp=<时间戳>&sign=<签名>` |

`Authx.sign` 计算参数：`md5(api_key + "_" + url + "_" + nonce + "_" + timestamp + "_" + md5(JSON.stringify(body) 或空字符串) + "_" + api_secret)`。

POST/PUT 请求体：TypeScript 请求封装会自动追加 `nonce` 字段；Go 封装只会在 body 是 map 时追加。表里只列业务参数，自动 `nonce` 单独说明。

## FN NAS API

| 功能 | Method | Path | 参数 |
| --- | --- | --- | --- |
| 用户登录 | `POST` | `/v/api/v1/login` | Body: `app_name` 固定为 `trimemedia-web`，`username`，`password`。自动 `nonce`。 |
| 获取系统配置 / OAuth 配置 | `GET` | `/v/api/v1/sys/config` | 无 path/query/body 参数。FN ID 流程里可用浏览器 Cookie 或额外 `Cookie: <cookie>; mode=relay`。 |
| OAuth 授权码换 token | `POST` | `/v/api/v1/auth` | Body: `source` 固定为 `Trim-NAS`，`code`。自动 `nonce`。 |
| 用户登出 | `POST` | `/v/api/v1/logout` | 无业务参数。自动 `nonce`。 |
| 获取用户信息 | `GET` | `/v/api/v1/user/info` | 无 API 参数。本地方法可传客户端选项 `timeout`、`tryTimes`。 |
| 获取播放信息 | `POST` | `/v/api/v1/play/info` | Body: `item_guid`。类型还支持可选 `media_guid`、`audio_guid`、`subtitle_guid`、`video_guid`；当前代码只传 `item_guid`。自动 `nonce`。 |
| 获取播放质量 | `POST` | `/v/api/v1/play/quality` | Body: `media_guid`。自动 `nonce`。 |
| 获取流列表 | `GET` | `/v/api/v1/stream/list/{itemGuid}` | Path: `itemGuid`。无 body。 |
| 获取剧集列表 | `GET` | `/v/api/v1/episode/list/{id}` | Path: `id`，通常是父级/季 GUID。无 body。 |
| 获取媒体库 / 文件夹项目列表 | `POST` | `/v/api/v1/item/list` | Body: `parent_guid`，`exclude_folder`，`sort_column`，`sort_type`。当前调用值：`parent_guid` 来自当前视频的父级 GUID，`exclude_folder=1`，`sort_column=sort_title`，`sort_type=ASC`。自动 `nonce`。 |
| 下载字幕 | `GET` | `/v/api/v1/subtitle/dl/{id}` | Path: `id` 为字幕流 GUID。无 body。 |
| 获取媒体 Range 流 | `GET` | `/v/api/v1/media/range/{mediaGuid}` | Path: `mediaGuid`。请求头通常带 `Authorization: token`、`Cookie: mode=relay`、播放器透传的 `Range`。该请求由播放器/本地代理直连，不走 `fn.request` 的 `Authx` 封装。 |
| 标记已观看 | `POST` | `/v/api/v1/item/watched` | Body: `item_guid`。自动 `nonce`。 |
| 记录播放状态 | `POST` | `/v/api/v1/play/record` | Body: `item_guid`，`media_guid`，`video_guid`，`audio_guid`，`subtitle_guid`，`play_link`，`ts`，`duration`。自动 `nonce`。 |
| 获取播放流信息 | `POST` | `/v/api/v1/stream` | Body: `header.User-Agent=["trim_player"]`，`level=1`，`media_guid`，`ip`。Go 代理里 `ip` 由 `account` 转 UUID。自动 `nonce`。 |
| 设置跳过片头片尾 | `POST` | `/v/api/v1/play/setConfigByItem` | Body: `guid` 为父级 GUID，`skip_opening`，`skip_ending`。该请求只在 Go 本地代理里调用。 |

## 本地代理 API

本地代理服务地址固定为 `http://127.0.0.1:22345`。

| 功能 | Method | Path | 参数 |
| --- | --- | --- | --- |
| 播放视频代理 | `GET` | `/api/v1/playvideo/{itemGuid}` | Path: `itemGuid`。Query: `token`，`skipVerify` (`1`/`0`)，`account`，`domain`，`useNasLocal` (`1`/`0`)，`sourceIndex`。播放器请求头会透传，常见 `Range`、`User-Agent`。 |
| 获取跳过片头片尾 | `GET` | `/api/v1/skipinfo/{itemGuid}` | Path: `itemGuid`。Query: `token`，`domain`，`skipVerify` (`1`/`0`)。 |
| 设置跳过片头片尾 | `POST` | `/api/v1/skipinfo` | Body: `guid`，`skipStart`，`skipEnd`。`token`、`domain`、`skipVerify` 可从 query 或 JSON body 绑定；代码要求 `token`、`domain`、`guid` 必填。 |

本地代理内部还会向上游发请求：

| 功能 | Method | URL | 参数 |
| --- | --- | --- | --- |
| 透明代理上游请求 | 跟随播放器请求方法，通常 `GET` | `targetURL`，可能是 `{domain}/v/api/v1/media/range/{mediaGuid}` 或云盘直链 | Path/query 来自 `targetURL`。Header: 透传播放器的 `User-Agent`、`Accept`、`Accept-Language`、`Accept-Encoding`、`Cache-Control`、`Pragma`、`Range`、`If-Range`、`If-Modified-Since`、`If-None-Match`；NAS 模式额外加 `Authorization=token`、`Cookie=<原 Cookie>; mode=relay`；云盘模式可加云盘 `Cookie` 和 `User-Agent`。Body 原样透传。 |
| 云盘文件大小探测 | `GET` | `direct_link_qualities[0].url` | Header: 代理头 + `Range: bytes=0-0`。无 body。用于读取 `Content-Range` / `Content-Type`。 |
| 云盘分片下载 | `GET` | `direct_link_qualities[0].url` | Header: 代理头 + `Range: bytes={start}-{end}`。`start` 来自播放器 `Range` 起点或 `0`，`end=min(start+10MiB-1,total-1)`。无 body。 |

## 媒体库相关页面路由

这些是 Electron 主窗口加载的飞牛影视 Web 页面路由，不是本项目手写的 API 封装。媒体库页面内部自己发出的接口请求由上游 Web UI 控制，当前仓库没有构造那些请求的代码；本项目只识别这些路由来避免播放结束后强制刷新媒体库页面。

| 功能 | Method | URL / Path | 参数 |
| --- | --- | --- | --- |
| 媒体库页面 | `GET` | `{baseUrl}/v/library/{...}` | Path 参数由飞牛影视 Web UI 决定。 |
| 收藏页面 | `GET` | `{baseUrl}/v/favorite` | 无本项目构造的 query/body 参数。 |
| 列表页面 | `GET` | `{baseUrl}/v/list/{...}` | Path 参数由飞牛影视 Web UI 决定。 |
| 文件夹页面 | `GET` | `{baseUrl}/v/folder/{...}` | Path 参数由飞牛影视 Web UI 决定。 |

## FN ID / OAuth 辅助请求

| 功能 | Method | URL / Path | 参数 |
| --- | --- | --- | --- |
| 打开 FN Connect | `GET` | `https://5ddd.com/{fnId}` | Path: `fnId` 为输入的 FN ID。Cookie: `mode=relay`。 |
| 打开授权页 | `GET` | `{baseUrl}/signin` | Query: `client_id={appId}`，`redirect_uri={baseUrl}/v/oauth/result`。 |
| 页面内获取系统配置 | `GET` | `/v/api/v1/sys/config` | Fetch 参数: `credentials: include`，无 body。用于从 FN Connect 页面拿 `nas_oauth.app_id` / `nas_oauth.url`。 |
| 授权响应拦截 | 页面发起 | `/oauthapi/authorize` | 本项目只 hook XHR/fetch 响应，不主动构造请求。需要响应里有 `data.code`。 |
| 新用户引导状态拦截 | 页面发起 | `/sac/rpcproxy/v1/new-user-guide/status` | 本项目只 hook XHR/fetch，用于拿 Cookie。请求参数由页面自身决定。 |

## 更新检查请求

| 功能 | Method | URL | 参数 |
| --- | --- | --- | --- |
| 检查 GitHub 最新版本 | `GET` | `https://api.github.com/repos/{owner}/{repo}/releases/latest` | Path: `owner` 默认 `QiaoKes`，`repo` 默认 `fntv-electron`。Header: `User-Agent=fntv-electron/{currentVersion}`。Timeout: `10000ms`。无 query/body。 |

## 拦截但不发送的请求

| 功能 | URL pattern | 参数 |
| --- | --- | --- |
| 登录页跳转拦截 | `http(s)://*/v/login`、`http(s)://*/v/welcome` | 无业务参数；Electron `webRequest` 拦截后取消请求并打开本地登录页。 |
| Web UI 登出拦截 | `http(s)://*/v/api/v1/user/logout` | 无业务参数；Electron `webRequest` 拦截后取消请求、清配置和 Cookie。注意它不是代码里 `ApiService.logout()` 使用的 `/v/api/v1/logout`。 |
| 原站播放信息请求探测 | `*/api/v1/play/info` | 从原站 fetch/XHR body 里读取 `item_guid`，随后返回假响应阻止原请求继续。 |
