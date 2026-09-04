//! 配置读写。`%APPDATA%/glim/settings.json`，不含 API Key（§4.3）。
//! M0 只有热键一项；语言对、开机启动等属 M3。

use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Manager};

pub const DEFAULT_HOTKEY: &str = "Ctrl+Alt+D";

/// 输入长度上限（字符）。超过直接返回 `TooLong`，不截断后偷偷发送（§4.3）。
pub const MAX_INPUT_CHARS: usize = 5000;

/// 首字符超时。§4.2 规定 15s 内无首字符即 `Timeout`。
pub const FIRST_CHUNK_TIMEOUT_SECS: u64 = 15;

/// 持久化到 settings.json 的内容。**不含 API Key** —— Key 单独存
/// Windows 凭据管理器（§4.3、§6），见 `credentials.rs`。
///
/// 新增字段一律带 `#[serde(default)]`：M0 落盘的 settings.json 只有 `hotkey`，
/// 少一个默认值就会让老配置整个解析失败、静默退回默认热键。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Settings {
    pub hotkey: String,
    #[serde(default)]
    pub provider: ProviderSettings,
    #[serde(default)]
    pub languages: LanguagePair,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            hotkey: DEFAULT_HOTKEY.to_string(),
            provider: ProviderSettings::default(),
            languages: LanguagePair::default(),
        }
    }
}

/// Provider 配置。**模型串与端点写在配置里，不硬编码在业务逻辑**（§4.3）——
/// 模型命名变动频繁，写死等于每次改名都要重新发版。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderSettings {
    /// 凭据条目的 key，见 `credentials::service_name`。
    pub id: String,
    pub model: String,
    pub endpoint: String,
    /// 「获取免费 API Key」按钮的落地页。§5.1 要求这个 URL 写在配置里
    /// 而不是硬编码：AI Studio 改版路径不是小概率事件，链接失效比没有链接更糟。
    pub api_key_url: String,
}

impl Default for ProviderSettings {
    fn default() -> Self {
        Self {
            id: "gemini".to_string(),
            // 用 `-latest` 别名而不是钉死版本号：模型改名频繁，实测
            // gemini-2.5-flash-lite 已经返回 404。别名会自动跟着走，
            // 想要行为绝对稳定再在配置里换成带版本号的具体型号。
            model: "gemini-flash-lite-latest".to_string(),
            endpoint: "https://generativelanguage.googleapis.com/v1beta".to_string(),
            api_key_url: "https://aistudio.google.com/apikey".to_string(),
        }
    }
}

/// 语言对：母语 + 外语（§3.0、§5）。不是「目标语言」——
/// 方向由源语言与这一对的关系推出来，用户永远不用手动切。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LanguagePair {
    pub native: String,
    pub foreign: String,
}

impl Default for LanguagePair {
    fn default() -> Self {
        Self {
            native: "zh".to_string(),
            foreign: "en".to_string(),
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
    pub provider: ProviderSettings,
    pub languages: LanguagePair,
    /// 凭据管理器里有没有 Key。只报有无，**绝不把 Key 本身送给前端**。
    pub has_api_key: bool,
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

/// 文件不存在时把默认配置落盘。
///
/// §4.3 规定模型串与端点写在配置里、由用户按需调整 —— 但 `load` 读不到
/// 就静默返回默认值、从不写回，结果是文件在首次改热键之前根本不存在，
/// 「去 settings.json 里换个模型」变成一句空话。启动时补这一次写入。
pub fn ensure_exists(app: &AppHandle) {
    let Some(path) = settings_path(app) else {
        return;
    };
    if path.exists() {
        return;
    }
    let _ = save(app, &load(app));
}

pub fn save(app: &AppHandle, settings: &Settings) -> Result<(), String> {
    let dir = config_dir(app).ok_or_else(|| "无法定位配置目录".to_string())?;
    std::fs::create_dir_all(&dir).map_err(|e| format!("创建配置目录失败：{e}"))?;
    let raw = serde_json::to_string_pretty(settings)
        .map_err(|e| format!("序列化配置失败：{e}"))?;
    std::fs::write(dir.join("settings.json"), raw).map_err(|e| format!("写入配置失败：{e}"))
}
