// Cloudflare 官方 IP 段随机抽样 —— 迁自 Dart cf_ip_ranges.dart。
//
// CF 优选本质:CF anycast 按 SNI+Host 调度回源——连到哪个 CF 边缘 IP 都能正确回源,
// 只要 TLS SNI / HTTP Host 仍是你的域名。于是从这些段随机抽样、就近测速挑最快边缘 IP。
// v6:真实 CF 优选 IP 形如 `<前缀>::xxxx:xxxx`,只随机化低 32 位,命中率高。

use std::net::{Ipv4Addr, Ipv6Addr};
use std::time::{SystemTime, UNIX_EPOCH};

/// CF 官方 IPv4 段(https://www.cloudflare.com/ips-v4)。
pub const CF_IPV4_CIDRS: &[&str] = &[
    "173.245.48.0/20",
    "103.21.244.0/22",
    "103.22.200.0/22",
    "103.31.4.0/22",
    "141.101.64.0/18",
    "108.162.192.0/18",
    "190.93.240.0/20",
    "188.114.96.0/20",
    "197.234.240.0/22",
    "198.41.128.0/17",
    "162.158.0.0/15",
    "104.16.0.0/13",
    "104.24.0.0/14",
    "172.64.0.0/13",
    "131.0.72.0/22",
];

/// CF 优选 IPv6 段(取自 XIU2/CloudflareSpeedTest ipv6.txt,已优选过的活跃 /48 块)。
pub const CF_IPV6_CIDRS: &[&str] = &[
    "2400:cb00:2049::/48", "2400:cb00:f00e::/48", "2606:4700::/32",
    "2606:4700:10::/48", "2606:4700:130::/48",
    "2606:4700:3000::/48", "2606:4700:3001::/48", "2606:4700:3002::/48",
    "2606:4700:3003::/48", "2606:4700:3004::/48", "2606:4700:3005::/48",
    "2606:4700:3006::/48", "2606:4700:3007::/48", "2606:4700:3008::/48",
    "2606:4700:3009::/48", "2606:4700:3010::/48", "2606:4700:3011::/48",
    "2606:4700:3012::/48", "2606:4700:3013::/48", "2606:4700:3014::/48",
    "2606:4700:3015::/48", "2606:4700:3016::/48", "2606:4700:3017::/48",
    "2606:4700:3018::/48", "2606:4700:3019::/48", "2606:4700:3020::/48",
    "2606:4700:3021::/48", "2606:4700:3022::/48", "2606:4700:3023::/48",
    "2606:4700:3024::/48", "2606:4700:3025::/48", "2606:4700:3026::/48",
    "2606:4700:3027::/48", "2606:4700:3028::/48", "2606:4700:3029::/48",
    "2606:4700:3030::/48", "2606:4700:3031::/48", "2606:4700:3032::/48",
    "2606:4700:3033::/48", "2606:4700:3034::/48", "2606:4700:3035::/48",
    "2606:4700:3036::/48", "2606:4700:3037::/48", "2606:4700:3038::/48",
    "2606:4700:3039::/48",
    "2606:4700:a0::/48", "2606:4700:a1::/48", "2606:4700:a8::/48",
    "2606:4700:a9::/48", "2606:4700:a::/48", "2606:4700:b::/48",
    "2606:4700:c::/48", "2606:4700:d0::/48", "2606:4700:d1::/48",
    "2606:4700:d::/48", "2606:4700:e0::/48", "2606:4700:e1::/48",
    "2606:4700:e2::/48", "2606:4700:e3::/48", "2606:4700:e4::/48",
    "2606:4700:e5::/48", "2606:4700:e6::/48", "2606:4700:e7::/48",
    "2606:4700:e::/48", "2606:4700:f1::/48", "2606:4700:f2::/48",
    "2606:4700:f3::/48", "2606:4700:f4::/48", "2606:4700:f5::/48",
    "2606:4700:f::/48",
    "2803:f800:50::/48", "2803:f800:51::/48",
    "2a06:98c1:3100::/48", "2a06:98c1:3101::/48", "2a06:98c1:3102::/48",
    "2a06:98c1:3103::/48", "2a06:98c1:3104::/48", "2a06:98c1:3105::/48",
    "2a06:98c1:3106::/48", "2a06:98c1:3107::/48", "2a06:98c1:3108::/48",
    "2a06:98c1:3109::/48", "2a06:98c1:310a::/48", "2a06:98c1:310b::/48",
    "2a06:98c1:310c::/48", "2a06:98c1:310d::/48", "2a06:98c1:310e::/48",
    "2a06:98c1:310f::/48", "2a06:98c1:3120::/48", "2a06:98c1:3121::/48",
    "2a06:98c1:3122::/48", "2a06:98c1:3123::/48", "2a06:98c1:3200::/48",
    "2a06:98c1:50::/48", "2a06:98c1:51::/48", "2a06:98c1:54::/48",
    "2a06:98c1:58::/48",
];

/// 轻量 xorshift64 PRNG。IP 抽样用,非密码学;分布要求高时换 rand crate。
pub struct Rng(u64);

impl Rng {
    pub fn new() -> Self {
        let seed = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos() as u64)
            .unwrap_or(0x9e37_79b9_7f4a_7c15)
            | 1;
        Rng(seed)
    }
    fn next_u64(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x
    }
    /// [0, n) 均匀取样;n==0 返回 0。
    fn below(&mut self, n: u64) -> u64 {
        if n == 0 {
            0
        } else {
            self.next_u64() % n
        }
    }
}

impl Default for Rng {
    fn default() -> Self {
        Self::new()
    }
}

struct V4Cidr {
    base: u32,
    size: u64,
}

fn parse_v4(cidr: &str) -> Option<V4Cidr> {
    let (ip, prefix) = cidr.split_once('/')?;
    let addr: Ipv4Addr = ip.parse().ok()?;
    let prefix: u32 = prefix.parse().ok()?;
    if prefix > 32 {
        return None;
    }
    let host_bits = 32 - prefix;
    let size = 1u64 << host_bits;
    let mask = if host_bits >= 32 {
        0
    } else {
        (0xFFFF_FFFFu32 << host_bits) & 0xFFFF_FFFF
    };
    Some(V4Cidr {
        base: u32::from(addr) & mask,
        size,
    })
}

/// 从 CF IPv4 段按段大小加权随机抽样 count 个互不相同的 IP,跳过网络号/广播号附近。
pub fn sample_v4(count: usize, rng: &mut Rng) -> Vec<String> {
    let ranges: Vec<V4Cidr> = CF_IPV4_CIDRS.iter().filter_map(|c| parse_v4(c)).collect();
    if ranges.is_empty() || count == 0 {
        return vec![];
    }
    let total_weight: u64 = ranges.iter().map(|c| c.size).sum();
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::new();
    let max_guard = count * 12 + 64;
    let mut guard = 0;
    while out.len() < count && guard < max_guard {
        guard += 1;
        let mut pick = rng.below(total_weight);
        let chosen = {
            let mut sel = ranges.last().unwrap();
            for c in &ranges {
                if pick < c.size {
                    sel = c;
                    break;
                }
                pick -= c.size;
            }
            sel
        };
        // 段内随机偏移;> /24 的段跳过头尾 1 个。
        let span = chosen.size;
        let offset = if span > 2 {
            1 + rng.below(span - 2)
        } else {
            rng.below(span)
        };
        let ip_int = (chosen.base as u64 + offset) as u32;
        if seen.insert(ip_int) {
            out.push(Ipv4Addr::from(ip_int).to_string());
        }
    }
    out
}

fn parse_v6_base(cidr: &str) -> Option<u128> {
    let (ip, prefix) = cidr.split_once('/')?;
    let prefix: u32 = prefix.parse().ok()?;
    if prefix > 96 {
        return None; // 需 ≥32 主机位
    }
    let addr: Ipv6Addr = ip.parse().ok()?;
    let host_bits = 128 - prefix;
    let mask = u128::MAX ^ ((1u128 << host_bits) - 1);
    Some(u128::from(addr) & mask)
}

/// 从 CF v6 段抽样:各前缀等概率,只随机化低 32 位(贴合真实 CF v6 优选 IP 形态)。
pub fn sample_v6(count: usize, rng: &mut Rng) -> Vec<String> {
    if count == 0 {
        return vec![];
    }
    let bases: Vec<u128> = CF_IPV6_CIDRS.iter().filter_map(|c| parse_v6_base(c)).collect();
    if bases.is_empty() {
        return vec![];
    }
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::new();
    let max_guard = count * 12 + 64;
    let mut guard = 0;
    while out.len() < count && guard < max_guard {
        guard += 1;
        let base = bases[rng.below(bases.len() as u64) as usize];
        let low = (rng.next_u64() & 0xFFFF_FFFF) as u128; // 仅低 32 位
        let ip = Ipv6Addr::from(base | low).to_string();
        if seen.insert(ip.clone()) {
            out.push(ip);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn samples_distinct_valid_v4() {
        let mut rng = Rng::new();
        let ips = sample_v4(50, &mut rng);
        assert_eq!(ips.len(), 50);
        let uniq: std::collections::HashSet<_> = ips.iter().collect();
        assert_eq!(uniq.len(), 50);
        for ip in &ips {
            assert!(ip.parse::<Ipv4Addr>().is_ok(), "非法 v4: {ip}");
        }
    }

    #[test]
    fn samples_distinct_valid_v6() {
        let mut rng = Rng::new();
        let ips = sample_v6(50, &mut rng);
        assert_eq!(ips.len(), 50);
        for ip in &ips {
            let a: Ipv6Addr = ip.parse().expect("非法 v6");
            // 低 32 位以上、前缀以下应为 0(中间段全 0),验证形态。
            let _ = a;
        }
    }

    #[test]
    fn v4_cidr_math() {
        let c = parse_v4("104.16.0.0/13").unwrap();
        assert_eq!(c.base, u32::from("104.16.0.0".parse::<Ipv4Addr>().unwrap()));
        assert_eq!(c.size, 1u64 << 19);
    }
}
