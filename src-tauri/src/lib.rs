mod hotkey;
mod panel;
mod settings;
mod win;

use tauri::{AppHandle, Manager};

use hotkey::HotkeyState;
use panel::PanelState;
use settings::{Settings, SettingsView};

#[tauri::command]
fn load_settings(app: AppHandle) -> SettingsView {
    let stored = settings::load(&app);
    let state = app.state::<HotkeyState>();
    SettingsView {
        hotkey: stored.hotkey,
        hotkey_registered: state.is_registered(),
        hotkey_error: state.error(),
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
        .manage(PanelState::default())
        .manage(HotkeyState::default())
        .invoke_handler(tauri::generate_handler![
            load_settings,
            save_settings,
            hide_panel
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
