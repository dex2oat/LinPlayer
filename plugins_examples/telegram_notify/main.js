// Telegram 播放通知插件
//
// 行为：监听播放器的 onPlayEnd 事件，每看完一集就通过 Telegram Bot 发一条消息。
// 配置：在「插件 -> 设置」里填写 Bot Token 和 Chat ID，保存到 ctx.storage。
//
// 可用能力（均在 manifest.permissions 中声明）：
//   player.read  -> ctx.player.on / ctx.player.getCurrentMedia
//   http         -> ctx.http.post（仅 https，白名单 api.telegram.org）
//   storage      -> ctx.storage 持久化配置
//   ui           -> ctx.ui.showForm / showToast
//   extensions   -> 通过 manifest 的 settingsPages 暴露设置入口

'use strict';

// 设置页入口：由 manifest 的 settingsPages.handler = "openSettings" 触发。
async function openSettings() {
  const botToken = (await ctx.storage.get('botToken')) || '';
  const chatId = (await ctx.storage.get('chatId')) || '';

  const values = await ctx.ui.showForm({
    title: 'Telegram 通知设置',
    fields: [
      {
        key: 'botToken',
        label: 'Bot Token',
        type: 'text',
        default: botToken,
        hint: '从 @BotFather 获取，例如 123456:ABC-DEF...'
      },
      {
        key: 'chatId',
        label: 'Chat ID',
        type: 'text',
        default: chatId,
        hint: '你的数字 chat id（可向 @userinfobot 查询）'
      }
    ],
    submitLabel: '保存',
    cancelLabel: '取消'
  });

  if (!values) return; // 用户取消
  await ctx.storage.set('botToken', (values.botToken || '').trim());
  await ctx.storage.set('chatId', (values.chatId || '').trim());
  ctx.ui.showToast('Telegram 设置已保存');
}

// 向 Telegram 发送一条文本消息。
async function sendTelegram(text) {
  const botToken = await ctx.storage.get('botToken');
  const chatId = await ctx.storage.get('chatId');
  if (!botToken || !chatId) {
    ctx.log.warn('尚未配置 botToken / chatId，跳过本次通知');
    return;
  }

  const url = 'https://api.telegram.org/bot' + botToken + '/sendMessage';
  try {
    const res = await ctx.http.post(
      url,
      { chat_id: chatId, text: text },
      { headers: { 'Content-Type': 'application/json' } }
    );
    if (res.status >= 200 && res.status < 300) {
      ctx.log.info('Telegram 通知已发送');
    } else {
      ctx.log.error('Telegram 通知失败，HTTP ' + res.status);
    }
  } catch (e) {
    ctx.log.error('Telegram 请求异常: ' + e);
  }
}

// 把当前媒体拼成一句可读标题。
function formatTitle(media) {
  if (!media) return '一集';
  if (media.seriesName && media.indexNumber != null) {
    let t = media.seriesName + ' 第' + media.indexNumber + '集';
    if (media.name) t += '《' + media.name + '》';
    return t;
  }
  return media.name || '一集';
}

// 监听「播放结束」事件。
ctx.player.on('onPlayEnd', async function (evt) {
  try {
    const media = await ctx.player.getCurrentMedia();
    const title = formatTitle(media);
    await sendTelegram('🎬 LinPlayer：你刚看完 ' + title);
  } catch (e) {
    ctx.log.error('处理 onPlayEnd 失败: ' + e);
  }
});

ctx.onEnable(function () {
  ctx.log.info('Telegram 播放通知插件已启用');
});

ctx.onDisable(function () {
  ctx.log.info('Telegram 播放通知插件已禁用');
});
