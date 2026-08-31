//! 配置读写。`%APPDATA%/glim/settings.json`，不含 API Key（§4.3）。
//! M0 只有热键一项；语言对、开机启动等属 M3。

use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Manager};

pub const DEFAULT_HOTKEY: &str = "Ctrl+Alt+D";

/// 持久化到 settings.json 的内容。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Settings {
    pub hotkey: String,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            hotkey: DEFAULT_HOTKEY.to_string(),
        }
    }
}

/// `load_settings` 的返回值：持久化内容 + 热键注册的运行时状态。
/// 前端靠 `hotkey_registered` 判断是否要显示冲突提示（§8 门禁 0.1a）。
#[derive(Debug, Clone, Serialize)]
pub struct SettingsView {
    pub hotkey: String,
    pub hotkey_registered: bool,
    pub hotkey_error: Option<String>,
}

pub fn config_dir(app: &AppHandle) -> Option<PathBuf> {
    app.path().config_dir().ok().map(|dir| dir.join("glim"))
}

pub fn settings_path(app: &AppHandle) -> Option<PathBuf> {
    config_dir(app).map(|dir| dir.join("settings.json"))
}

/// 读不到或解析失败一律返回默认值，不报错、不阻塞启动。
pub fn load(app: &AppHandle) -> Settings {
    let Some(path) = settings_path(app) else {
        return Settings::default();
    };
    let Ok(raw) = std::fs::read_to_string(&path) else {
        return Settings::default();
    };
    serde_json::from_str(&raw).unwrap_or_default()
}

pub fn save(app: &AppHandle, settings: &Settings) -> Result<(), String> {
    let dir = config_dir(app).ok_or_else(|| "无法定位配置目录".to_string())?;
    std::fs::create_dir_all(&dir).map_err(|e| format!("创建配置目录失败：{e}"))?;
    let raw = serde_json::to_string_pretty(settings)
        .map_err(|e| format!("序列化配置失败：{e}"))?;
    std::fs::write(dir.join("settings.json"), raw).map_err(|e| format!("写入配置失败：{e}"))
}
