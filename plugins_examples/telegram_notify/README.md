# Telegram 播放通知插件

每看完一集，自动通过 Telegram Bot 给你发一条消息。

## 功能
- 监听播放器 `onPlayEnd` 事件
- 通过 `ctx.storage` 保存 `botToken` / `chatId`
- 通过 `ctx.http.post` 调用 Telegram Bot API（`https://api.telegram.org`，已加入域名白名单）
- 在「插件 → 设置」中以表单填写配置（`ctx.ui.showForm`）

## 申请权限
`player.read`、`http`、`storage`、`ui`、`extensions`

## 使用
1. 用 BotFather 创建一个 Bot，拿到 **Bot Token**。
2. 给你的 Bot 发一条消息，并向 `@userinfobot` 查询你的 **Chat ID**。
3. 在 LinPlayer 中安装本插件（见下方打包说明），启用并同意权限。
4. 在插件条目点击「设置」，填入 Bot Token 与 Chat ID，保存。
5. 看完任意一集后，即可在 Telegram 收到通知。

## 打包为 .lpk
`.lpk` 就是一个包含 `manifest.json` 和 `main.js` 的 zip。仓库根目录提供了打包脚本：

```bash
dart run tools/pack_plugin.dart plugins_examples/telegram_notify
# 产物：dist/plugins/com.linplayer.telegram-notify-1.0.0.lpk
```

也可手动：把该目录下的文件压缩为 zip，再改后缀为 `.lpk`。

打包产物可在 App 的「设置 → 插件 → +」中安装。
