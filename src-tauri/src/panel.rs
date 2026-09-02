//! 面板窗口：预创建后 hide，触发时只做 show + 定位（§2.3 铁律）。
//! 窗口从不销毁，Hidden ↔ Showing 之间切换。

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use tauri::{AppHandle, Manager, WebviewWindow};
use windows::Win32::Foundation::HWND;

use crate::hotkey;
use crate::settings;
use crate::win;

pub const PANEL_LABEL: &str = "panel";

/// 光标右下偏移量，逻辑像素（§4.3）。
const CURSOR_OFFSET_LOGICAL: f64 = 12.0;
/// 「点击外部」检测的轮询间隔。只在窗口可见时真正做检测。
const POLL_INTERVAL_MS: u64 = 40;

#[derive(Default)]
pub struct PanelState {
    visible: AtomicBool,
    /// 「热键 → 窗口可见」的实测耗时，微秒。门禁 0.1 的原始数据。
    timings: Mutex<Vec<u64>>,
}

impl PanelState {
    pub fn is_visible(&self) -> bool {
        self.visible.load(Ordering::SeqCst)
    }
}

fn window(app: &AppHandle) -> Option<WebviewWindow> {
    app.get_webview_window(PANEL_LABEL)
}

fn panel_hwnd(app: &AppHandle) -> Option<HWND> {
    let raw = window(app)?.hwnd().ok()?;
    Some(win::hwnd_from_raw(raw.0))
}

/// 给窗口打上 `WS_EX_NOACTIVATE` / `WS_EX_TOOLWINDOW`（§2.4）。启动时调用一次。
/// 因为显示/隐藏走的是 Win32 而不是 tao，这套样式不会再被覆写。
pub fn apply_ex_styles(app: &AppHandle) {
    if let Some(hwnd) = panel_hwnd(app) {
        win::apply_panel_ex_styles(hwnd);
    }
}

/// 显示面板。`t0` 由热键回调在第一行取，测的是「按下热键 → 窗口可见」
/// 的完整耗时（门禁 0.1）；非热键路径（启动提示、单实例二次启动）传 `None`，
/// 不写入采样，避免污染门禁数据。
pub fn show(app: &AppHandle, t0: Option<Instant>) {
    let Some(hwnd) = panel_hwnd(app) else { return };
    if t0.is_none() {
        log_line(app, "[show] non-hotkey\n");
    }
    let Some(placement) = compute_placement(app, hwnd) else { return };

    win::show_at_no_activate(hwnd, placement.x, placement.y);

    let elapsed = t0.map(|t0| t0.elapsed());
    app.state::<PanelState>().visible.store(true, Ordering::SeqCst);
    if let Some(elapsed) = elapsed {
        record_timing(app, elapsed, &placement);
    }

    // Esc 关闭：NOACTIVATE 的窗口拿不到键盘事件，只能在可见期间临时占用
    // Esc 全局快捷键，hide 时立刻注销。注册必须走工作线程，原因见 hotkey.rs。
    hotkey::register_escape(app);
}

/// 启动时的热键冲突提示：这一路径要让用户当场把新热键敲进输入框，
/// 所以临时摘掉 `WS_EX_NOACTIVATE` 并主动激活；隐藏时由 `hide` 还原。
/// 热键正常路径不走这里，始终不夺焦点（门禁 0.3）。
pub fn show_focused(app: &AppHandle) {
    let Some(hwnd) = panel_hwnd(app) else { return };
    log_line(app, "[show] hotkey-conflict-prompt\n");
    let Some(placement) = compute_placement(app, hwnd) else { return };

    win::set_noactivate(hwnd, false);
    win::show_at_activated(hwnd, placement.x, placement.y);

    app.state::<PanelState>().visible.store(true, Ordering::SeqCst);
    hotkey::register_escape(app);
}

/// `reason` 只用于日志，方便门禁复现时看清是谁关的窗口。
pub fn hide(app: &AppHandle, reason: &str) {
    let Some(hwnd) = panel_hwnd(app) else { return };
    log_line(app, &format!("[hide] {reason}\n"));
    win::hide_window(hwnd);
    // 冲突提示可能临时摘掉过 NOACTIVATE，这里无条件还原。
    win::set_noactivate(hwnd, true);
    app.state::<PanelState>().visible.store(false, Ordering::SeqCst);
    hotkey::unregister_escape(app);
}

/// 热键再次按下 = toggle（§2.1 规则 6）。
pub fn toggle(app: &AppHandle, t0: Instant) {
    if app.state::<PanelState>().is_visible() {
        hide(app, "hotkey-toggle");
    } else {
        show(app, Some(t0));
    }
}

struct Placement {
    x: i32,
    y: i32,
    cursor: (i32, i32),
    size: (i32, i32),
    work: (i32, i32, i32, i32),
    flipped_x: bool,
    flipped_y: bool,
}

/// 光标右下偏移 12px；右溢出翻到光标左侧，下溢出翻到上方；
/// 用光标所在显示器的 work area（已排除任务栏）。§4.3
fn compute_placement(app: &AppHandle, hwnd: HWND) -> Option<Placement> {
    let (cx, cy) = win::cursor_pos()?;
    let rect = win::window_rect(hwnd)?;
    let (w, h) = (rect.right - rect.left, rect.bottom - rect.top);

    let scale = window(app)
        .and_then(|window| {
            window
                .monitor_from_point(cx as f64, cy as f64)
                .ok()
                .flatten()
                .map(|monitor| monitor.scale_factor())
                .or_else(|| window.scale_factor().ok())
        })
        .unwrap_or(1.0);
    let offset = (CURSOR_OFFSET_LOGICAL * scale).round() as i32;

    let mut x = cx + offset;
    let mut y = cy + offset;
    let mut flipped_x = false;
    let mut flipped_y = false;

    let work = win::work_area_at(cx, cy);
    if let Some(work) = work {
        if x + w > work.right {
            x = cx - offset - w;
            flipped_x = true;
        }
        if y + h > work.bottom {
            y = cy - offset - h;
            flipped_y = true;
        }
        // 翻转后仍越界（窗口比工作区还大、或光标贴边）时夹紧到工作区内。
        x = x.clamp(work.left, (work.right - w).max(work.left));
        y = y.clamp(work.top, (work.bottom - h).max(work.top));
    }

    Some(Placement {
        x,
        y,
        cursor: (cx, cy),
        size: (w, h),
        work: work.map_or((0, 0, 0, 0), |r| (r.left, r.top, r.right, r.bottom)),
        flipped_x,
        flipped_y,
    })
}

fn record_timing(app: &AppHandle, elapsed: Duration, placement: &Placement) {
    let micros = elapsed.as_micros() as u64;
    let index = {
        let state = app.state::<PanelState>();
        let mut timings = state.timings.lock().unwrap();
        timings.push(micros);
        timings.len()
    };

    let line = format!(
        "#{index} {micros}us ({:.2}ms) cursor=({},{}) size={}x{} work=({},{},{},{}) pos=({},{}) flip={}/{}\n",
        micros as f64 / 1000.0,
        placement.cursor.0,
        placement.cursor.1,
        placement.size.0,
        placement.size.1,
        placement.work.0,
        placement.work.1,
        placement.work.2,
        placement.work.3,
        placement.x,
        placement.y,
        placement.flipped_x,
        placement.flipped_y,
    );

    log_line(app, &line);
}

fn log_line(app: &AppHandle, line: &str) {
    let Some(dir) = settings::config_dir(app) else {
        return;
    };
    let _ = std::fs::create_dir_all(&dir);
    if let Ok(mut file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join("hotkey-timing.log"))
    {
        use std::io::Write;
        let _ = file.write_all(line.as_bytes());
    }
}

/// 「点击外部关闭」：NOACTIVATE 的窗口收不到失焦事件，改为轮询鼠标左键的
/// 按下沿 + 光标是否落在窗口矩形外。不装任何钩子（§1）。
///
/// 只在面板可见时才真正判定关闭，但按键状态**始终**跟踪 —— 否则
/// 「按下沿」会把面板出现那一刻就已按住的左键算作一次新点击。
pub fn spawn_outside_click_watcher(app: AppHandle) {
    std::thread::spawn(move || {
        let mut was_down = false;
        loop {
            std::thread::sleep(Duration::from_millis(POLL_INTERVAL_MS));

            // 隐藏期间必须继续跟踪左键的真实状态，不能清零：清零会让
            // 「面板出现时左键正按着」在下一次轮询里被当成一次新的按下沿，
            // 面板一闪即消失（按住左键拖选、不松手直接按热键就会触发）。
            if !app.state::<PanelState>().is_visible() {
                was_down = win::is_left_button_down();
                continue;
            }

            let down = win::is_left_button_down();
            if down && !was_down {
                let rect = panel_hwnd(&app).and_then(win::window_rect);
                if let (Some((cx, cy)), Some(rect)) = (win::cursor_pos(), rect) {
                    if !win::point_in_rect(&rect, cx, cy) {
                        let handle = app.clone();
                        let _ = app.run_on_main_thread(move || hide(&handle, "outside-click"));
                    }
                }
            }
            was_down = down;
        }
    });
}
