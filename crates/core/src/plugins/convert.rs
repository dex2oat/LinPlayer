//! JS 值 <-> serde_json 互转。descriptor 里的函数被抽出交给 `on_fn`(存进引擎 handler 表),
//! 原位替换成 `{"__handler__": id}` 标记——这样描述对象能作为纯 JSON 过到前端渲染。

use rquickjs::{Array, Ctx, Function, Object, Value};
use serde_json::{json, Map, Value as Json};

/// JS -> JSON。遇到函数时调 `on_fn` 取一个 handler id,嵌入 `{"__handler__": id}`。
/// 纯转换(不期望函数)传一个返回空串的闭包即可。
pub fn js_to_json<'js>(v: &Value<'js>, on_fn: &mut dyn FnMut(Function<'js>) -> String) -> Json {
    if v.is_null() || v.is_undefined() {
        return Json::Null;
    }
    if let Some(b) = v.as_bool() {
        return json!(b);
    }
    if let Some(i) = v.as_int() {
        return json!(i);
    }
    if let Some(f) = v.as_float() {
        return json!(f);
    }
    if let Some(s) = v.as_string() {
        return json!(s.to_string().unwrap_or_default());
    }
    if v.is_function() {
        let id = on_fn(v.as_function().unwrap().clone());
        return json!({ "__handler__": id });
    }
    if let Some(arr) = v.as_array() {
        let mut out = Vec::with_capacity(arr.len());
        for item in arr.iter::<Value>() {
            match item {
                Ok(val) => out.push(js_to_json(&val, on_fn)),
                Err(_) => out.push(Json::Null),
            }
        }
        return Json::Array(out);
    }
    if let Some(obj) = v.as_object() {
        let mut map = Map::new();
        for pair in obj.props::<String, Value>() {
            if let Ok((k, val)) = pair {
                map.insert(k, js_to_json(&val, on_fn));
            }
        }
        return Json::Object(map);
    }
    Json::Null
}

/// 纯 JS -> JSON(函数丢成 Null)。
pub fn js_value_to_json(v: &Value) -> Json {
    js_to_json(v, &mut |_| String::new())
}

/// JSON -> JS。用于把 handler 参数 / ctx.plugin 元信息喂回 JS。
pub fn json_to_js<'js>(ctx: &Ctx<'js>, v: &Json) -> rquickjs::Result<Value<'js>> {
    Ok(match v {
        Json::Null => Value::new_null(ctx.clone()),
        Json::Bool(b) => Value::new_bool(ctx.clone(), *b),
        Json::Number(n) => {
            if let Some(i) = n.as_i64() {
                if let Ok(i32v) = i32::try_from(i) {
                    Value::new_int(ctx.clone(), i32v)
                } else {
                    Value::new_float(ctx.clone(), i as f64)
                }
            } else {
                Value::new_float(ctx.clone(), n.as_f64().unwrap_or(0.0))
            }
        }
        Json::String(s) => rquickjs::String::from_str(ctx.clone(), s)?.into_value(),
        Json::Array(a) => {
            let arr = Array::new(ctx.clone())?;
            for (i, item) in a.iter().enumerate() {
                arr.set(i, json_to_js(ctx, item)?)?;
            }
            arr.into_value()
        }
        Json::Object(m) => {
            let obj = Object::new(ctx.clone())?;
            for (k, item) in m {
                obj.set(k.as_str(), json_to_js(ctx, item)?)?;
            }
            obj.into_value()
        }
    })
}
