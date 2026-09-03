//! API Key 存取。存 Windows 凭据管理器，**不落 settings.json**（§4.3、§6）。
//! service 名固定为 `glim/provider/<provider_id>`。

/// 凭据条目的 service 名。§4.3 写死的格式，改动会让老用户的 Key 丢失。
fn service_name(provider_id: &str) -> String {
    format!("glim/provider/{provider_id}")
}

/// 凭据管理器要求 (service, user) 二元组。这里没有多账号概念，
/// user 固定用 provider_id，保证同一 provider 只有一条。
fn entry(provider_id: &str) -> Result<keyring::Entry, String> {
    keyring::Entry::new(&service_name(provider_id), provider_id)
        .map_err(|e| format!("无法访问凭据管理器：{e}"))
}

/// 读不到就是没配。区分不了「没配」和「读失败」时一律当没配，
/// 由上层返回 `NoApiKey` 走引导，不弹技术错误（§4.2）。
pub fn load(provider_id: &str) -> Option<String> {
    let entry = entry(provider_id).ok()?;
    let key = entry.get_password().ok()?;
    let key = key.trim().to_string();
    if key.is_empty() {
        None
    } else {
        Some(key)
    }
}

pub fn save(provider_id: &str, key: &str) -> Result<(), String> {
    entry(provider_id)?
        .set_password(key.trim())
        .map_err(|e| format!("写入凭据管理器失败：{e}"))
}

pub fn has_key(provider_id: &str) -> bool {
    load(provider_id).is_some()
}
