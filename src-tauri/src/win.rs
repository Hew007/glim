//! Win32 薄封装：窗口扩展样式、光标位置、显示器工作区、鼠标按键状态。
//! 只在 Windows 上编译；macOS 属二期，届时另写一份实现（§1）。

use windows::Win32::Foundation::{HWND, POINT, RECT};
use windows::Win32::Graphics::Gdi::{
    GetMonitorInfoW, MonitorFromPoint, MONITORINFO, MONITOR_DEFAULTTONEAREST,
};
use windows::Win32::UI::Input::KeyboardAndMouse::{GetAsyncKeyState, VK_LBUTTON};
use windows::Win32::UI::WindowsAndMessaging::{
    GetCursorPos, GetWindowLongPtrW, GetWindowRect, SetForegroundWindow, SetWindowLongPtrW,
    SetWindowPos, ShowWindow, GWL_EXSTYLE, HWND_TOPMOST, SWP_NOACTIVATE, SWP_NOSIZE,
    SWP_SHOWWINDOW, SW_HIDE, WS_EX_APPWINDOW, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW,
};

/// 给面板窗口加上 `WS_EX_NOACTIVATE`（不夺焦点）和 `WS_EX_TOOLWINDOW`
/// （不进 Alt+Tab / 任务栏）。见 §2.4。
///
/// 必须同时清掉 `WS_EX_APPWINDOW`：tao 建窗时默认带上它，而 Alt+Tab 的
/// 判定规则是「没有 TOOLWINDOW 或者有 APPWINDOW」，两个都在等于 TOOLWINDOW
/// 白加（门禁 0.2）。
pub fn apply_panel_ex_styles(hwnd: HWND) {
    unsafe {
        let current = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
        let wanted = (current | WS_EX_NOACTIVATE.0 as isize | WS_EX_TOOLWINDOW.0 as isize)
            & !(WS_EX_APPWINDOW.0 as isize);
        SetWindowLongPtrW(hwnd, GWL_EXSTYLE, wanted);
    }
}

/// 单独开关 `WS_EX_NOACTIVATE`。热键面板全程保持开启；只有启动时的
/// 热键冲突提示需要临时关掉，否则那个改键输入框收不到键盘（门禁 0.1a/0.1b）。
pub fn set_noactivate(hwnd: HWND, enabled: bool) {
    unsafe {
        let current = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
        let next = if enabled {
            current | WS_EX_NOACTIVATE.0 as isize
        } else {
            current & !(WS_EX_NOACTIVATE.0 as isize)
        };
        SetWindowLongPtrW(hwnd, GWL_EXSTYLE, next);
    }
}

/// 当前光标位置（物理像素，虚拟桌面坐标系）。
pub fn cursor_pos() -> Option<(i32, i32)> {
    let mut pt = POINT::default();
    unsafe { GetCursorPos(&mut pt).ok()? };
    Some((pt.x, pt.y))
}

/// 光标所在显示器的工作区（已排除任务栏）。多显示器按光标所在屏计算，见 §4.3。
pub fn work_area_at(x: i32, y: i32) -> Option<RECT> {
    unsafe {
        let monitor = MonitorFromPoint(POINT { x, y }, MONITOR_DEFAULTTONEAREST);
        let mut info = MONITORINFO {
            cbSize: std::mem::size_of::<MONITORINFO>() as u32,
            ..Default::default()
        };
        if GetMonitorInfoW(monitor, &mut info).as_bool() {
            Some(info.rcWork)
        } else {
            None
        }
    }
}

/// 定位 + 显示，一次 `SetWindowPos` 完成，且不激活窗口。
///
/// 不能用 tao / Tauri 的 `show()`：tao 在改变可见性时会拿它自己缓存的
/// `WindowFlags` 重写整个 ex-style，把我们加的 `WS_EX_TOOLWINDOW` /
/// `WS_EX_NOACTIVATE` 抹掉并把 `WS_EX_APPWINDOW` 加回来（实测 ex-style
/// 从 0x08000198 变成 0x00040118，门禁 0.2 直接失效）。
pub fn show_at_no_activate(hwnd: HWND, x: i32, y: i32) {
    unsafe {
        let _ = SetWindowPos(
            hwnd,
            Some(HWND_TOPMOST),
            x,
            y,
            0,
            0,
            SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW,
        );
    }
}

/// 定位 + 显示 + 主动激活。只给启动时的热键冲突提示用，那里需要键盘输入。
pub fn show_at_activated(hwnd: HWND, x: i32, y: i32) {
    unsafe {
        let _ = SetWindowPos(hwnd, Some(HWND_TOPMOST), x, y, 0, 0, SWP_NOSIZE | SWP_SHOWWINDOW);
        let _ = SetForegroundWindow(hwnd);
    }
}

pub fn hide_window(hwnd: HWND) {
    unsafe {
        let _ = ShowWindow(hwnd, SW_HIDE);
    }
}

/// 窗口外框矩形（物理像素）。
pub fn window_rect(hwnd: HWND) -> Option<RECT> {
    let mut rect = RECT::default();
    unsafe { GetWindowRect(hwnd, &mut rect).ok()? };
    Some(rect)
}

/// 鼠标左键当前是否按下。用于「点击外部关闭」的轮询检测，
/// 不安装任何鼠标/键盘钩子（§1）。
pub fn is_left_button_down() -> bool {
    unsafe { (GetAsyncKeyState(VK_LBUTTON.0 as i32) as u16 & 0x8000) != 0 }
}

pub fn point_in_rect(rect: &RECT, x: i32, y: i32) -> bool {
    x >= rect.left && x < rect.right && y >= rect.top && y < rect.bottom
}

/// 从 Tauri 给出的原始句柄指针重建 `HWND`，避免与 tauri 依赖的 `windows`
/// crate 版本耦合。
pub fn hwnd_from_raw(raw: *mut core::ffi::c_void) -> HWND {
    HWND(raw)
}
