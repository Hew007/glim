mod credentials;
mod hotkey;
mod lang;
mod panel;
mod provider;
mod request;
mod settings;
mod win;

use tauri::{AppHandle, Manager};
use tauri_plugin_clipboard_manager::ClipboardExt;

use hotkey::HotkeyState;
use lang::Direction;
use panel::PanelState;
use provider::gemini::GeminiProvider;
use request::{Mode, RequestState};
use settings::{Settings, SettingsView};

#[tauri::command]
fn load_settings(app: AppHandle) -> SettingsView {
    let stored = settings::load(&app);
    let state = app.state::<HotkeyState>();
    SettingsView {
        hotkey: stored.hotkey,
        hotkey_registered: state.is_registered(),
        hotkey_error: state.error(),
        has_api_key: credentials::has_key(&stored.provider.id),
        provider: stored.provider,
        languages: stored.languages,
    }
}

/// 写盘 + 立即重新注册热键（门禁 0.1b）。注册失败时返回错误文案，
/// 由前端显示，不静默失败（§2.1 规则 4）。
#[tauri::command]
fn save_settings(app: AppHandle, settings: Settings) -> Result<(), String> {
    settings::save(&app, &settings)?;
    match hotkey::register(&app, &settings.hotkey) {
        Ok(()) => Ok(()),
        Err(message) => {
            hotkey::set_error(&app, Some(message.clone()));
            Err(message)
        }
    }
}

#[tauri::command]
fn hide_panel(app: AppHandle) {
    panel::hide(&app, "ipc:hide_panel");
}

/// §4.1 的 `read_clipboard_text`。剪贴板是图片或文件时返回 `None`，
/// 不尝试解析（§4.3）。
#[tauri::command]
fn read_clipboard_text(app: AppHandle) -> Option<String> {
    let text = app.clipboard().read_text().ok()?;
    if text.trim().is_empty() {
        None
    } else {
        Some(text)
    }
}

#[tauri::command]
fn start_request(app: AppHandle, text: String, mode: Mode, direction: Direction) -> String {
    request::start(&app, text, mode, direction)
}

#[tauri::command]
fn cancel_request(app: AppHandle, request_id: String) {
    // §4.1 的入参是 request_id。当前实现同时只允许一个在途请求，
    // 传进来的 id 不是当前那个就说明它早已被顶替，无需再取消。
    let state = app.state::<RequestState>();
    if state.is_current(&request_id) {
        request::cancel_active(&app);
    }
}

/// §4.1 的 `validate_api_key`。发一次最小的真实请求判断 Key 是否可用。
///
/// **校验通过后顺手把 Key 写进凭据管理器。** §4.1 冻结了命令名与入参，
/// 没有单独的「保存 Key」命令，而 §5.1 的引导流程要求「粘贴 → 自动验证 →
/// 成功即进入主界面」——验证与保存本就是同一个动作。Key 只进凭据管理器，
/// 不进 settings.json（§4.3、§6）。
#[tauri::command]
async fn validate_api_key(
    app: AppHandle,
    provider: String,
    key: String,
    model: String,
) -> Result<(), String> {
    let key = key.trim().to_string();
    if key.is_empty() {
        return Err("API Key 不能为空".to_string());
    }

    let mut config = settings::load(&app).provider;
    config.id = provider;
    config.model = model;

    let client = app.state::<RequestState>().client();
    let url = GeminiProvider::new(&config).validate_url();
    let body = serde_json::json!({
        "contents": [{ "role": "user", "parts": [{ "text": "ping" }] }],
        "generationConfig": { "maxOutputTokens": 1 }
    });

    let response = client
        .post(url)
        .header("x-goog-api-key", &key)
        .json(&body)
        .send()
        .await
        .map_err(request::describe_transport_error)?;

    let status = response.status().as_u16();
    if status == 200 {
        return credentials::save(&config.id, &key);
    }

    let body = response.text().await.unwrap_or_default();
    Err(describe_validation_failure(&app, &config, status, &body))
}

/// 校验失败的人话。**不能只甩一个 HTTP 状态码** —— §4.2 要求每个错误都有
/// 一句看得懂的话加一个能做的动作，「验证失败（HTTP 404）」两样都不占。
fn describe_validation_failure(
    app: &AppHandle,
    config: &settings::ProviderSettings,
    status: u16,
    body: &str,
) -> String {
    let config_hint = settings::settings_path(app)
        .map(|path| format!("配置文件在 {}", path.display()))
        .unwrap_or_else(|| "请修改配置文件".to_string());

    match status {
        // Key 格式不对时 Gemini 返回 400 而不是 401，正文里带 API_KEY_INVALID。
        400 if body.contains("API_KEY_INVALID") => {
            "API Key 无效。确认复制的是完整的一串，中间没有断行或空格。".to_string()
        }
        401 | 403 => "API Key 无效，或这个 Key 没有访问该模型的权限。".to_string(),
        404 => format!(
            "模型「{}」不存在，或当前 Key 无权访问它。\
             把它改成一个可用的模型名再试 —— {}。",
            config.model, config_hint
        ),
        429 => "请求太频繁，请稍后再试。".to_string(),
        _ => format!("验证失败（HTTP {status}）：{}", summarize_body(body)),
    }
}

/// 面板只有 420px 宽，错误正文截断到能看清的长度。
fn summarize_body(body: &str) -> String {
    let body = body.trim();
    if body.chars().count() > 200 {
        body.chars().take(200).collect::<String>() + "…"
    } else {
        body.to_string()
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        // 单实例：第二次启动触发已有实例弹窗，不起新进程（§4.3）
        .plugin(tauri_plugin_single_instance::init(|app, _argv, _cwd| {
            let handle = app.clone();
            let _ = app.run_on_main_thread(move || {
                panel::show(&handle, None);
            });
        }))
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .plugin(tauri_plugin_clipboard_manager::init())
        .manage(PanelState::default())
        .manage(HotkeyState::default())
        .manage(RequestState::default())
        .invoke_handler(tauri::generate_handler![
            load_settings,
            save_settings,
            hide_panel,
            read_clipboard_text,
            start_request,
            cancel_request,
            validate_api_key
        ])
        .setup(|app| {
            let handle = app.handle().clone();

            // 窗口在配置里以 visible: false 预创建，这里只补 Win32 扩展样式。
            panel::apply_ex_styles(&handle);

            hotkey::spawn_escape_worker(handle.clone());

            let stored = settings::load(&handle);
            if let Err(message) = hotkey::register(&handle, &stored.hotkey) {
                hotkey::set_error(&handle, Some(message));
                // 热键被占用时启动即提示，不静默失败（§2.1 规则 4 / 门禁 0.1a）
                panel::show_focused(&handle);
            }

            panel::spawn_outside_click_watcher(handle);
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
