//! 全局热键。走 `tauri-plugin-global-shortcut`（底层 `RegisterHotKey`），
//! 不安装任何键盘钩子（§1、§2.1 规则 1）。

use std::sync::mpsc::{channel, Sender};
use std::sync::Mutex;
use std::time::Instant;

use tauri::{AppHandle, Manager};
use tauri_plugin_global_shortcut::{GlobalShortcutExt, Shortcut, ShortcutState};

use crate::panel;

/// 面板可见期间临时占用，用于 Esc 关闭。
const ESCAPE_ACCELERATOR: &str = "Escape";

/// Esc 快捷键的注册/注销请求。必须走独立线程，原因见 `spawn_escape_worker`。
enum EscapeCommand {
    Register,
    Unregister,
}

#[derive(Default)]
pub struct HotkeyState {
    current: Mutex<Option<Shortcut>>,
    /// 注册失败的原因。`None` 表示注册成功。
    error: Mutex<Option<String>>,
    escape_tx: Mutex<Option<Sender<EscapeCommand>>>,
}

impl HotkeyState {
    pub fn is_registered(&self) -> bool {
        self.error.lock().unwrap().is_none()
    }

    pub fn error(&self) -> Option<String> {
        self.error.lock().unwrap().clone()
    }
}

pub fn set_error(app: &AppHandle, error: Option<String>) {
    *app.state::<HotkeyState>().error.lock().unwrap() = error;
}

fn parse(accelerator: &str) -> Result<Shortcut, String> {
    accelerator
        .parse::<Shortcut>()
        .map_err(|_| format!("无法解析热键「{accelerator}」"))
}

/// 注册主热键。改键时直接再调一次即可立即生效，无需重启（门禁 0.1b）。
pub fn register(app: &AppHandle, accelerator: &str) -> Result<(), String> {
    let shortcut = parse(accelerator)?;
    unregister_current(app);

    app.global_shortcut()
        .on_shortcut(shortcut, move |app, _shortcut, event| {
            // t0 必须是回调里的第一件事，测量口径见 §8 门禁 0.1
            let t0 = Instant::now();
            if event.state == ShortcutState::Pressed {
                // 不在快捷键回调里直接操作窗口：show/hide 会注册或注销 Esc
                // 快捷键，回到主线程再做，既避开插件内部的锁，也省掉一次
                // 跨线程的窗口调用。
                let handle = app.clone();
                let _ = app.run_on_main_thread(move || {
                    panel::toggle(&handle, t0);
                });
            }
        })
        .map_err(|e| format!("热键「{accelerator}」注册失败：{e}"))?;

    *app.state::<HotkeyState>().current.lock().unwrap() = Some(shortcut);
    set_error(app, None);
    Ok(())
}

pub fn unregister_current(app: &AppHandle) {
    let previous = app.state::<HotkeyState>().current.lock().unwrap().take();
    if let Some(shortcut) = previous {
        let _ = app.global_shortcut().unregister(shortcut);
    }
}

/// Esc 的注册/注销**必须**在独立线程上做，不能在主线程直接调用。
///
/// `global-hotkey` 在主线程建隐藏窗口收 `WM_HOTKEY`，插件的事件分发是
/// 「持着 `shortcuts` 互斥锁同步调用 handler」，而 `register` / `unregister`
/// 内部也要拿同一把锁。热键回调跑在主线程上，在回调链里直接注册 Esc
/// 就是同一线程重入非重入锁 —— 主线程当场死锁，表现为第一次弹窗之后
/// 热键彻底失灵。工作线程会阻塞到 handler 返回再拿锁，不会死锁。
pub fn spawn_escape_worker(app: AppHandle) {
    let (tx, rx) = channel::<EscapeCommand>();
    *app.state::<HotkeyState>().escape_tx.lock().unwrap() = Some(tx);

    std::thread::spawn(move || {
        while let Ok(command) = rx.recv() {
            let Ok(shortcut) = parse(ESCAPE_ACCELERATOR) else {
                continue;
            };
            match command {
                EscapeCommand::Register => {
                    let _ = app.global_shortcut().on_shortcut(
                        shortcut,
                        move |app, _shortcut, event| {
                            if event.state == ShortcutState::Pressed {
                                let handle = app.clone();
                                let _ = app.run_on_main_thread(move || {
                                    panel::hide(&handle, "escape");
                                });
                            }
                        },
                    );
                }
                EscapeCommand::Unregister => {
                    let _ = app.global_shortcut().unregister(shortcut);
                }
            }
        }
    });
}

/// 面板可见期间临时占用 Esc，hide 时立即归还。
pub fn register_escape(app: &AppHandle) {
    send_escape(app, EscapeCommand::Register);
}

pub fn unregister_escape(app: &AppHandle) {
    send_escape(app, EscapeCommand::Unregister);
}

fn send_escape(app: &AppHandle, command: EscapeCommand) {
    let tx = app.state::<HotkeyState>().escape_tx.lock().unwrap().clone();
    if let Some(tx) = tx {
        let _ = tx.send(command);
    }
}
