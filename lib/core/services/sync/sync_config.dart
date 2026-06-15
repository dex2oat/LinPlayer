/// 同步后端代理配置（可选）。
///
/// 部署 `oauth-proxy/`（Cloudflare Pages）后，把它的地址填到 [kSyncProxyBaseUrl]，
/// 客户端将通过代理完成所有需要 client_secret 的令牌交换/刷新——secret 只存在
/// 代理的环境变量里，不再出现在客户端二进制中。
///
/// 留空（默认）则回退到客户端内置（混淆）凭据的直连模式，无需部署即可使用。
///
/// 注意：client_id / app_id 属于「公开标识符」，留在客户端是安全的；
/// 真正必须保护的是 secret，代理只负责注入它。
const String kSyncProxyBaseUrl = 'https://291277.xyz/api';

/// 可选共享密钥，需与代理环境变量 LINPLAYER_PROXY_KEY 一致。留空则不发送。
const String kSyncProxyKey = 'm4cfEohhuz4u142d3w';

bool get kUseSyncProxy => kSyncProxyBaseUrl.isNotEmpty;

/// 代理请求要附带的头（共享密钥）。
Map<String, String> syncProxyHeaders() =>
    kSyncProxyKey.isEmpty ? const {} : {'X-LinPlayer-Key': kSyncProxyKey};
