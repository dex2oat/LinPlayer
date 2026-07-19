// CF 优选:IP 段采样 + 测速引擎 + 本地钉 IP 反代。
pub mod proxy;
pub mod ranges;
pub mod runtime;
pub mod speedtest;

pub use proxy::{start as start_proxy, CfProxyHandle};
pub use speedtest::{run as speed_test, CfIpMode, CfSpeedTestOptions, CfTestResult};
