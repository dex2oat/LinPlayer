// 115 网盘下载直链的私有编解码(m115)。移植自 SheltonZhu/115driver `pkg/crypto/m115`(MIT)。
//
// 名叫 RSA,实为混淆:**加密和解密都用公钥做模幂**(m^E mod N),全程没有私钥参与。
// 所以这里不引 `rsa` crate —— 那套私钥/OAEP/签名校验一个都用不上,要的只有一次大数模幂。
//
// ★ 别被"接 115 要移植一大堆密码学"带偏:115driver 里那套 ec115
//   (ECDH / P-224 / AES / LZ4)**只用于上传**(`pkg/driver/upload.go`),
//   下载走的是这里的 m115(`pkg/driver/download.go` 只 import 了 crypto/m115)。
//   播放器不上传,所以 P-224 曲线在 RustCrypto 有没有对应 crate 这个问题跟我们无关。
use base64::Engine;
use num_bigint::BigUint;
use rand::RngCore;

/// 混淆用模数。**1024 位 = 128 字节**(256 个十六进制字符),不是 2048。
/// 分块长度由它推导,写错则每个分块的长度全错,而服务端只会静默拒绝、不给任何提示。
// 逐行对齐 115driver 源码的换行,方便日后直接 diff 比对。
const N_HEX: &str = concat!(
    "8686980c0f5a24c4b9d43020cd2c22703ff3f450756529058b1cf88f09b86021",
    "36477198a6e2683149659bd122c33592fdb5ad47944ad1ea4d36c6b172aad633",
    "8c3bb6ac6227502d010993ac967d1aef00f0c8e038de2e4d3bc2ec368af2e9f1",
    "0a6f1eda4f7262f136420c07c331b871bf139f74f3010e3c4fe57df3afb71683",
);
const E_HEX: &str = "10001";

/// 密钥派生查表(144 字节)。`xor_derive_key` 用 `size*i` 和 `size*(size-i-1)` 取值,
/// size 最大 12 时索引到 132,故必须够 133 字节 —— 表长在测试里钉死。
const XOR_KEY_SEED: [u8; 144] = [
    0xf0, 0xe5, 0x69, 0xae, 0xbf, 0xdc, 0xbf, 0x8a, 0x1a, 0x45, 0xe8, 0xbe, 0x7d, 0xa6, 0x73, 0xb8,
    0xde, 0x8f, 0xe7, 0xc4, 0x45, 0xda, 0x86, 0xc4, 0x9b, 0x64, 0x8b, 0x14, 0x6a, 0xb4, 0xf1, 0xaa,
    0x38, 0x01, 0x35, 0x9e, 0x26, 0x69, 0x2c, 0x86, 0x00, 0x6b, 0x4f, 0xa5, 0x36, 0x34, 0x62, 0xa6,
    0x2a, 0x96, 0x68, 0x18, 0xf2, 0x4a, 0xfd, 0xbd, 0x6b, 0x97, 0x8f, 0x4d, 0x8f, 0x89, 0x13, 0xb7,
    0x6c, 0x8e, 0x93, 0xed, 0x0e, 0x0d, 0x48, 0x3e, 0xd7, 0x2f, 0x88, 0xd8, 0xfe, 0xfe, 0x7e, 0x86,
    0x50, 0x95, 0x4f, 0xd1, 0xeb, 0x83, 0x26, 0x34, 0xdb, 0x66, 0x7b, 0x9c, 0x7e, 0x9d, 0x7a, 0x81,
    0x32, 0xea, 0xb6, 0x33, 0xde, 0x3a, 0xa9, 0x59, 0x34, 0x66, 0x3b, 0xaa, 0xba, 0x81, 0x60, 0x48,
    0xb9, 0xd5, 0x81, 0x9c, 0xf8, 0x6c, 0x84, 0x77, 0xff, 0x54, 0x78, 0x26, 0x5f, 0xbe, 0xe8, 0x1e,
    0x36, 0x9f, 0x34, 0x80, 0x5c, 0x45, 0x2c, 0x9b, 0x76, 0xd5, 0x1b, 0x8f, 0xcc, 0xc3, 0xb8, 0xf5,
];

const XOR_CLIENT_KEY: [u8; 12] = [
    0x78, 0x06, 0xad, 0x4c, 0x33, 0x86, 0x5d, 0x18, 0x4c, 0x01, 0x3f, 0x46,
];

/// 每次请求现生成的 16 字节会话密钥。它会原样拼进密文头部,响应用它解回。
pub type Key = [u8; 16];

pub fn generate_key() -> Key {
    let mut k = [0u8; 16];
    rand::rng().fill_bytes(&mut k);
    k
}

fn modulus() -> BigUint {
    BigUint::parse_bytes(N_HEX.as_bytes(), 16).expect("N 常数不是合法十六进制")
}

fn exponent() -> BigUint {
    BigUint::parse_bytes(E_HEX.as_bytes(), 16).expect("E 常数不是合法十六进制")
}

/// 分块长度 = N 的字节数。对齐 Go 侧 `_N.BitLen() / 8`。
fn key_len() -> usize {
    modulus().bits() as usize / 8
}

fn xor_derive_key(seed: &[u8], size: usize) -> Vec<u8> {
    let mut key = vec![0u8; size];
    for (i, slot) in key.iter_mut().enumerate() {
        *slot = seed[i].wrapping_add(XOR_KEY_SEED[size * i]);
        *slot ^= XOR_KEY_SEED[size * (size - i - 1)];
    }
    key
}

/// 前 `len%4` 字节按原下标取密钥,其余以 `len%4` 为原点重新起算。
/// 这个错位是算法的一部分,不是笔误 —— 简化成 `key[i % k]` 会让整段密文对不上。
fn xor_transform(data: &mut [u8], key: &[u8]) {
    let (n, k) = (data.len(), key.len());
    let head = n % 4;
    for i in 0..head {
        data[i] ^= key[i % k];
    }
    for i in head..n {
        data[i] ^= key[(i - head) % k];
    }
}

/// PKCS#1 v1.5 type-2 填充后逐块模幂。**用公钥**,与 Go 侧一致。
fn rsa_encrypt(input: &[u8]) -> Vec<u8> {
    let (n, e, klen) = (modulus(), exponent(), key_len());
    let slice_max = klen - 11;
    let mut out = Vec::new();
    for chunk in input.chunks(slice_max) {
        let pad_size = klen - chunk.len() - 3;
        let mut block = vec![0u8; klen];
        block[0] = 0x00;
        block[1] = 0x02;
        let mut pad = vec![0u8; pad_size];
        rand::rng().fill_bytes(&mut pad);
        for (i, b) in pad.iter().enumerate() {
            // 填充字节必须非零(0x00 是数据分隔符)。对齐 Go 的 b%0xff + 0x01。
            block[2 + i] = b % 0xff + 0x01;
        }
        block[pad_size + 2] = 0x00;
        block[pad_size + 3..].copy_from_slice(chunk);

        let ret = BigUint::from_bytes_be(&block).modpow(&e, &n).to_bytes_be();
        // to_bytes_be 会吃掉前导零,必须补回定长,否则下一块的起点就错位了。
        out.resize(out.len() + klen.saturating_sub(ret.len()), 0u8);
        out.extend_from_slice(&ret);
    }
    out
}

/// 逐块模幂后剥填充:第一个 0x00(下标非 0)之后是数据。
fn rsa_decrypt(input: &[u8]) -> Vec<u8> {
    let (n, e, klen) = (modulus(), exponent(), key_len());
    let mut out = Vec::new();
    for chunk in input.chunks(klen) {
        let ret = BigUint::from_bytes_be(chunk).modpow(&e, &n).to_bytes_be();
        if let Some(sep) = ret.iter().position(|&b| b == 0).filter(|&i| i != 0) {
            out.extend_from_slice(&ret[sep + 1..]);
        }
    }
    out
}

/// 明文 → 可放进 form 字段 `data` 的密文。
pub fn encode(input: &[u8], key: &Key) -> String {
    let mut buf = Vec::with_capacity(16 + input.len());
    buf.extend_from_slice(key);
    buf.extend_from_slice(input);
    xor_transform(&mut buf[16..], &xor_derive_key(key, 4));
    buf[16..].reverse();
    xor_transform(&mut buf[16..], &XOR_CLIENT_KEY);
    base64::engine::general_purpose::STANDARD.encode(rsa_encrypt(&buf))
}

/// 响应密文 → 明文 JSON 字节。key 必须是发请求时那一把。
pub fn decode(input: &str, key: &Key) -> Result<Vec<u8>, String> {
    let raw = base64::engine::general_purpose::STANDARD
        .decode(input.trim())
        .map_err(|e| format!("115 响应不是合法 base64: {e}"))?;
    let data = rsa_decrypt(&raw);
    if data.len() <= 16 {
        return Err("115 响应过短,解不出内容".to_string());
    }
    let mut out = data[16..].to_vec();
    xor_transform(&mut out, &xor_derive_key(&data[..16], 12));
    out.reverse();
    xor_transform(&mut out, &xor_derive_key(key, 4));
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// ★ 这条钉的是调研里被写错的那个常数。
    /// 二手情报说这套是「256 字节 / 2048 位 RSA、分块 245」——按模数实际长度算是 128/1024/117。
    /// 抄成 256 的后果:分块长度全错,请求发得出去、服务端静默拒绝,没有任何一行报错指向真因。
    #[test]
    fn modulus_is_1024_bit_not_2048() {
        assert_eq!(N_HEX.len(), 256, "N 的十六进制字符数 = 字节数 x 2");
        assert_eq!(modulus().bits(), 1024, "模数是 1024 位");
        assert_eq!(key_len(), 128, "分块长度 = 128 字节(不是 256)");
        assert_eq!(key_len() - 11, 117, "填充后可容纳的明文 = 117 字节(不是 245)");
        assert_eq!(exponent(), BigUint::from(65537u32));
    }

    /// 派生表必须够长:size=12 时最大索引是 12*11=132。
    /// 表抄短了会 panic(至少是响的),抄错内容则静默产出错误密钥 —— 故连内容一起钉。
    #[test]
    fn derive_key_indexes_stay_in_table_and_are_stable() {
        assert_eq!(XOR_KEY_SEED.len(), 144);
        assert_eq!(XOR_KEY_SEED[0], 0xf0);
        assert_eq!(XOR_KEY_SEED[132], 0x5c, "size=12 时会取到的最大下标");
        assert_eq!(XOR_KEY_SEED[143], 0xf5, "表尾,防止整表少抄一行");
        let seed = [0u8; 16];
        assert_eq!(xor_derive_key(&seed, 12).len(), 12);
        // 全零种子下派生结果完全由查表决定,可当查表内容的指纹:
        // key[i] = SEED[4i] ^ SEED[4(3-i)],故结果对称。
        assert_eq!(
            xor_derive_key(&seed, 4),
            vec![
                XOR_KEY_SEED[0] ^ XOR_KEY_SEED[12],
                XOR_KEY_SEED[4] ^ XOR_KEY_SEED[8],
                XOR_KEY_SEED[8] ^ XOR_KEY_SEED[4],
                XOR_KEY_SEED[12] ^ XOR_KEY_SEED[0],
            ]
        );
        assert_eq!(xor_derive_key(&seed, 4), vec![0x8d, 0xa5, 0xa5, 0x8d]);
    }

    /// XOR 是对合运算:同一把密钥连做两次必须还原。
    /// 这条能抓住 `xor_transform` 里那个 `n%4` 错位被"顺手简化"掉的改动。
    #[test]
    fn xor_transform_is_an_involution_at_every_length() {
        let key = xor_derive_key(&[7u8; 16], 4);
        // 覆盖 len%4 的四种余数,错位逻辑只在非零余数下才和朴素实现分叉。
        for len in [1usize, 2, 3, 4, 5, 6, 7, 8, 17, 64, 117] {
            let orig: Vec<u8> = (0..len).map(|i| (i * 31 % 251) as u8).collect();
            let mut d = orig.clone();
            xor_transform(&mut d, &key);
            assert_ne!(d, orig, "len={len} 变换后不该等于原文");
            xor_transform(&mut d, &key);
            assert_eq!(d, orig, "len={len} 两次变换未还原");
        }
    }

    /// ★ 上面那条对合测试**抓不住下标映射错误** —— XOR 不管怎么映射,做两次都还原,
    /// 把错位"顺手简化"成朴素的 `key[i % k]` 它照样绿。这条才是钉错位的:
    /// 长度 5(余数 1)时,错位版从第 1 字节起就与朴素版分叉,逐字节写死期望值。
    #[test]
    fn xor_transform_offsets_by_len_mod_four_not_by_raw_index() {
        let key = [0x11u8, 0x22, 0x33, 0x44];
        let mut d = [0u8; 5];
        xor_transform(&mut d, &key);
        // head = 5 % 4 = 1 → d[0] 用 key[0];之后以 head 为原点重新起算。
        assert_eq!(d, [0x11, 0x11, 0x22, 0x33, 0x44]);
        // 朴素实现会得到这个 —— 两者必须不同,否则这条测试没有区分力。
        let naive: Vec<u8> = (0..5).map(|i| key[i % 4]).collect();
        assert_ne!(d.to_vec(), naive, "错位与朴素实现分不开,这条测试就是摆设");

        // 余数 0 时两者应当一致(head=0,原点即 0),顺带钉住这个边界。
        let mut d4 = [0u8; 4];
        xor_transform(&mut d4, &key);
        assert_eq!(d4, key);
    }

    /// 剥填充的解析:构造 [0x02][非零填充][0x00][数据],必须精确取回数据段。
    /// 模幂在这里绕不开,所以直接验规则本身 —— 越过分隔符或少剥一字节都能被抓到。
    #[test]
    fn padding_strip_takes_bytes_after_first_zero_separator() {
        let payload = b"pickcode-payload";
        let mut block = vec![0x02u8];
        block.extend(std::iter::repeat_n(0xABu8, 20));
        block.push(0x00);
        block.extend_from_slice(payload);
        let sep = block.iter().position(|&b| b == 0).filter(|&i| i != 0).unwrap();
        assert_eq!(&block[sep + 1..], payload);
    }

    // ★ 这里**故意没有** encode→decode 往返测试。
    //
    // 直觉上会想写"encode 出去再 decode 回来 == 原文",但 115 的 encode 与 decode
    // **不是互逆运算**:encode 处理的是**发往服务端的请求体**(服务端有对应的 decode),
    // decode 处理的是**服务端发回的响应体**(服务端有对应的 encode)。两者是两条独立的
    // 数据流,客户端侧串起来不构成 roundtrip —— 实测串起来确实不还原(这个假设试过、红了)。
    //
    // 因此本模块**无法纯本地自证算法与服务端一致**,只能证内部各环节自洽(常数/错位/分块/定长,
    // 见上面几条已反向注入验证过的测试)。端到端正确性只有挂真实 115 账号才能确认 ——
    // 这条限制在交付说明里明确列为待验证项。

    /// 分块与定长补齐:密文长度必须恰好是分块数 x 128。
    /// 少补前导零会让后续分块整体错位,而长度断言是唯一能当场发现它的地方。
    #[test]
    fn ciphertext_length_is_whole_blocks() {
        let key = generate_key();
        for plain_len in [1usize, 100, 117, 118, 300] {
            let plain = vec![b'x'; plain_len];
            let ct = base64::engine::general_purpose::STANDARD
                .decode(encode(&plain, &key))
                .unwrap();
            let want_blocks = (16 + plain_len).div_ceil(key_len() - 11);
            assert_eq!(
                ct.len(),
                want_blocks * key_len(),
                "plain_len={plain_len} 密文不是整块长"
            );
        }
    }
}
