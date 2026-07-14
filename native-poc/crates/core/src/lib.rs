// LinPlayer 核心库:平台无关的数据源/网络/配置逻辑。
// 桌面(Tauri)与安卓(flutter_rust_bridge/uniffi)共用同一份;此处禁引任何桌面专属 crate。
pub mod config;
pub mod danmaku;
pub mod download;
pub mod emby;
pub mod http;
pub mod media;
pub mod net;
pub mod ranking;
pub mod source;

pub use config::{Account, AppConfig, Prefs, ProxyConfig};
pub use emby::{Item, LoginResult, PlaybackTarget, Session};
pub use media::Track;
pub use source::{MediaSourceBackend, SourceEntry, SourceKind, SourceServer};
