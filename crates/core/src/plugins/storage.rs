//! 每插件独立 KV 存储,持久化为 `<data>/<pluginId>/storage.json`(港自 Dart plugin_storage.dart)。
//! 序列化后总大小上限 5MB,超限 set 抛错不写入。

use std::collections::BTreeMap;
use std::path::PathBuf;

use serde_json::Value;
use tokio::sync::Mutex;

pub const MAX_BYTES: usize = 5 * 1024 * 1024;

pub struct PluginStorage {
    plugin_id: String,
    file: PathBuf,
    inner: Mutex<Inner>,
}

struct Inner {
    data: BTreeMap<String, Value>,
    loaded: bool,
}

impl PluginStorage {
    pub fn new(plugin_id: impl Into<String>, data_dir: PathBuf) -> Self {
        Self {
            plugin_id: plugin_id.into(),
            file: data_dir.join("storage.json"),
            inner: Mutex::new(Inner { data: BTreeMap::new(), loaded: false }),
        }
    }

    async fn ensure_loaded(&self, inner: &mut Inner) {
        if inner.loaded {
            return;
        }
        if let Ok(raw) = tokio::fs::read_to_string(&self.file).await {
            if let Ok(Value::Object(m)) = serde_json::from_str::<Value>(&raw) {
                inner.data = m.into_iter().collect();
            }
        }
        inner.loaded = true;
    }

    async fn persist(&self, inner: &Inner) -> Result<(), String> {
        if let Some(parent) = self.file.parent() {
            tokio::fs::create_dir_all(parent)
                .await
                .map_err(|e| format!("建存储目录失败: {e}"))?;
        }
        let obj: serde_json::Map<String, Value> =
            inner.data.iter().map(|(k, v)| (k.clone(), v.clone())).collect();
        let encoded = serde_json::to_string(&Value::Object(obj)).unwrap();
        tokio::fs::write(&self.file, encoded)
            .await
            .map_err(|e| format!("写存储失败: {e}"))
    }

    pub async fn get(&self, key: &str) -> Value {
        let mut inner = self.inner.lock().await;
        self.ensure_loaded(&mut inner).await;
        inner.data.get(key).cloned().unwrap_or(Value::Null)
    }

    pub async fn keys(&self) -> Vec<String> {
        let mut inner = self.inner.lock().await;
        self.ensure_loaded(&mut inner).await;
        inner.data.keys().cloned().collect()
    }

    pub async fn set(&self, key: &str, value: Value) -> Result<(), String> {
        let mut inner = self.inner.lock().await;
        self.ensure_loaded(&mut inner).await;
        // 先算加入后的大小,超限则拒绝、不改内存。
        let mut probe: serde_json::Map<String, Value> =
            inner.data.iter().map(|(k, v)| (k.clone(), v.clone())).collect();
        probe.insert(key.to_string(), value.clone());
        let encoded = serde_json::to_string(&Value::Object(probe)).unwrap();
        if encoded.len() > MAX_BYTES {
            return Err(format!(
                "插件 {} 存储超出 5MB 上限(尝试写入 {} 字节)",
                self.plugin_id,
                encoded.len()
            ));
        }
        inner.data.insert(key.to_string(), value);
        self.persist(&inner).await
    }

    pub async fn delete(&self, key: &str) -> Result<(), String> {
        let mut inner = self.inner.lock().await;
        self.ensure_loaded(&mut inner).await;
        if inner.data.remove(key).is_some() {
            self.persist(&inner).await?;
        }
        Ok(())
    }

    pub async fn clear(&self) -> Result<(), String> {
        let mut inner = self.inner.lock().await;
        inner.data.clear();
        inner.loaded = true;
        self.persist(&inner).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[tokio::test]
    async fn set_get_persist_roundtrip() {
        let dir = std::env::temp_dir().join(format!("lp_plugin_store_test_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let s = PluginStorage::new("com.test", dir.clone());
        s.set("name", json!("小明")).await.unwrap();
        assert_eq!(s.get("name").await, json!("小明"));
        // 新实例从磁盘读回。
        let s2 = PluginStorage::new("com.test", dir.clone());
        assert_eq!(s2.get("name").await, json!("小明"));
        assert_eq!(s2.keys().await, vec!["name".to_string()]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn rejects_over_quota() {
        let dir = std::env::temp_dir().join(format!("lp_plugin_quota_test_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let s = PluginStorage::new("com.test", dir.clone());
        let big = "x".repeat(MAX_BYTES + 10);
        assert!(s.set("k", json!(big)).await.is_err());
        assert_eq!(s.get("k").await, Value::Null); // 未写入
        let _ = std::fs::remove_dir_all(&dir);
    }
}
