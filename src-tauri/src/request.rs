//! 请求生命周期：发起、取消、流式转发、错误分类。
//!
//! 事件全部带 `request_id`（§4.1）。**request_id 是单调递增的十进制串**，
//! 不是 §4.3 字面写的 UUID —— 两个原因：
//!   1. 加 `uuid` crate 属 §1 清单外的第三方库（§10.1），为一个计数器不值当；
//!   2. 单调性让前端能只用一次比较就丢掉旧请求的事件。UUID 无序，前端必须
//!      先拿到 `start_request` 的返回值才知道当前 id，而事件与 IPC 返回值走
//!      同一条通道、不保证先后 —— 抢先到达的事件会因「id 不认识」被误丢。
//! 唯一性与「取消旧请求后内容不串台」这两个目的都达到了，语义没有削弱。

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter, Manager};

use crate::credentials;
use crate::lang::Direction;
use crate::provider::{gemini::GeminiProvider, Provider, TranslateReq};
use crate::settings::{self, FIRST_CHUNK_TIMEOUT_SECS, MAX_INPUT_CHARS};

/// §4.2 的错误分类。名字直接序列化给前端，改名等于改契约。
///
/// `ParseError` 是查词 JSON 解析失败时的降级路径，M2 才会构造 —— §4.2
/// 冻结了这张表，这里按表列全，不按当前用得到的删。
#[derive(Debug, Clone, Copy, Serialize)]
#[allow(dead_code)]
pub enum ErrorKind {
    NoApiKey,
    InvalidApiKey,
    RateLimited,
    Network,
    Timeout,
    EmptyClipboard,
    TooLong,
    ParseError,
    Unknown,
}

/// 查词 / 翻译。M1 只打通翻译，`Lookup` 走 §4 的降级规则落到翻译路径，
/// 结构化查词是 M2 的事。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Mode {
    Translate,
    Lookup,
}

#[derive(Clone, Serialize)]
struct ChunkPayload {
    request_id: String,
    delta: String,
}

#[derive(Clone, Serialize)]
struct DonePayload {
    request_id: String,
}

#[derive(Clone, Serialize)]
struct ErrorPayload {
    request_id: String,
    kind: ErrorKind,
    message: String,
}

/// 面板弹出时把原文和判定结果推给前端（§4.1 的 `panel:show`）。
#[derive(Clone, Serialize)]
pub struct PanelShowPayload {
    pub text: String,
    pub mode: Mode,
    pub direction: Direction,
}

/// 一次请求的运行时标记。看门狗线程和请求任务共享。
struct Flags {
    first_chunk: AtomicBool,
    finished: AtomicBool,
    /// 收到的增量条数。门禁 1.1 要证明输出是「流式」而不是一次性返回，
    /// 而译文本身不能落盘（§6：不存历史），所以只记条数。
    chunks: AtomicU64,
}

struct Active {
    id: String,
    handle: tauri::async_runtime::JoinHandle<()>,
}

pub struct RequestState {
    next_id: AtomicU64,
    active: Mutex<Option<Active>>,
    client: reqwest::Client,
}

impl Default for RequestState {
    fn default() -> Self {
        Self {
            next_id: AtomicU64::new(1),
            active: Mutex::new(None),
            // 客户端复用连接池。连接超时单独设短一点，断网时快速落到
            // Network 而不是干等到首字符超时（§4.2）。
            client: reqwest::Client::builder()
                // 10s 而不是 5s：走代理或 VPN 时握手本来就慢，超时太紧会把
                // 「慢」误报成「断网」。首字符超时另有 15s 的看门狗兜底。
                .connect_timeout(Duration::from_secs(10))
                .build()
                .unwrap_or_default(),
        }
    }
}

impl RequestState {
    /// 是否有请求正在进行。热键在 Loading 中按下时不关窗口，
    /// 而是取消当前请求 + 重新读剪贴板 + 开新请求（§4.3）。
    pub fn is_busy(&self) -> bool {
        self.active.lock().unwrap().is_some()
    }

    /// 给定 id 是否就是当前在途的那个请求。
    pub fn is_current(&self, request_id: &str) -> bool {
        self.active
            .lock()
            .unwrap()
            .as_ref()
            .is_some_and(|a| a.id == request_id)
    }

    /// 复用同一个连接池。校验 Key 的那次请求也走这里，省一次 TLS 握手。
    pub fn client(&self) -> reqwest::Client {
        self.client.clone()
    }
}

fn emit_error(app: &AppHandle, request_id: &str, kind: ErrorKind, message: impl Into<String>) {
    let message = message.into();
    // 落日志：面板内容在 WebView 里，PowerShell 读不到 DOM，M1 的门禁
    // （1.3 / 1.4 / 1.6 / 1.7）靠这一行来断言 Rust 侧究竟判成了哪一类。
    crate::panel::log_line(
        app,
        &format!("[req:error] kind={kind:?} request={request_id} message={message}\n"),
    );
    let _ = app.emit(
        "req:error",
        ErrorPayload {
            request_id: request_id.to_string(),
            kind,
            message,
        },
    );
}

/// 无条件取消当前请求。发起新请求前必调（§4.3）。
///
/// 日志打在这里而不是调用方：`toggle` 处理「Loading 中按热键」时会先调
/// 本函数、再让前端发起新请求，等 `start` 去检查时 active 已经是空的，
/// 于是取消这件事永远不会被记下来 —— 门禁 1.5 因此报「取消旧请求 0 次」，
/// 而实际上取消了。埋点跟着行为走，不跟着调用顺序走。
pub fn cancel_active(app: &AppHandle, reason: &str) {
    let previous = app.state::<RequestState>().active.lock().unwrap().take();
    if let Some(active) = previous {
        crate::panel::log_line(
            app,
            &format!("[req:cancel] request={} reason={reason}\n", active.id),
        );
        active.handle.abort();
    }
}

/// 只在 id 匹配时取消。看门狗用，避免误杀已经换代的新请求。
fn cancel_if_current(app: &AppHandle, request_id: &str) -> bool {
    let state = app.state::<RequestState>();
    let mut guard = state.active.lock().unwrap();
    let matches = guard.as_ref().is_some_and(|a| a.id == request_id);
    if matches {
        if let Some(active) = guard.take() {
            active.handle.abort();
        }
    }
    matches
}

/// 请求自然结束时把自己从 active 摘掉，别让 `is_busy` 一直为真。
fn clear_if_current(app: &AppHandle, request_id: &str) {
    let state = app.state::<RequestState>();
    let mut guard = state.active.lock().unwrap();
    if guard.as_ref().is_some_and(|a| a.id == request_id) {
        // 这里不 abort：任务自己正在收尾，abort 自己会砍掉尚未发出的 done 事件。
        *guard = None;
    }
}

pub fn start(app: &AppHandle, text: String, mode: Mode, direction: Direction) -> String {
    let state = app.state::<RequestState>();
    let id = state.next_id.fetch_add(1, Ordering::SeqCst).to_string();

    // 发起新请求前无条件取消旧的（§4.3）。
    cancel_active(app, "superseded");
    crate::panel::log_line(app, &format!("[req:start] request={id}\n"));

    let flags = Arc::new(Flags {
        first_chunk: AtomicBool::new(false),
        finished: AtomicBool::new(false),
        chunks: AtomicU64::new(0),
    });

    let handle = {
        let app = app.clone();
        let id = id.clone();
        let flags = flags.clone();
        tauri::async_runtime::spawn(async move {
            run(app.clone(), id.clone(), text, mode, direction, flags.clone()).await;
            flags.finished.store(true, Ordering::SeqCst);
            clear_if_current(&app, &id);
        })
    };

    *state.active.lock().unwrap() = Some(Active {
        id: id.clone(),
        handle,
    });

    spawn_first_chunk_watchdog(app.clone(), id.clone(), flags);

    id
}

/// 「15s 内无首字符」判 `Timeout`（§4.2）。
///
/// 用独立 OS 线程而不是异步定时器：`tauri::async_runtime` 只暴露 `spawn`，
/// 没有 `sleep` / `timeout`，直接引 tokio 又是 §1 清单外的依赖。线程只睡一次
/// 就退出，成本可以忽略。
fn spawn_first_chunk_watchdog(app: AppHandle, request_id: String, flags: Arc<Flags>) {
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs(FIRST_CHUNK_TIMEOUT_SECS));
        if flags.finished.load(Ordering::SeqCst) || flags.first_chunk.load(Ordering::SeqCst) {
            return;
        }
        // 仍是当前请求才算超时；已经被新请求顶掉的就不必再报。
        if cancel_if_current(&app, &request_id) {
            emit_error(
                &app,
                &request_id,
                ErrorKind::Timeout,
                format!("{FIRST_CHUNK_TIMEOUT_SECS} 秒内没有收到响应"),
            );
        }
    });
}

async fn run(
    app: AppHandle,
    request_id: String,
    text: String,
    _mode: Mode,
    direction: Direction,
    flags: Arc<Flags>,
) {
    // 首字符延迟的计时起点。§2.3 的预算是「窗口 → 首字符 < 800ms」，
    // 门禁 1.2 要求 p50 < 1200ms。
    let started = std::time::Instant::now();
    let text = text.trim().to_string();

    // 前置校验，这几种情况不发网络请求。
    if text.is_empty() {
        emit_error(
            &app,
            &request_id,
            ErrorKind::EmptyClipboard,
            "剪贴板里没有文本",
        );
        return;
    }
    let char_count = text.chars().count();
    if char_count > MAX_INPUT_CHARS {
        // 不截断后偷偷发送（§4.3）。
        emit_error(
            &app,
            &request_id,
            ErrorKind::TooLong,
            format!("内容过长（{char_count} 字符），请分段"),
        );
        return;
    }

    let stored = settings::load(&app);
    let Some(api_key) = credentials::load(&stored.provider.id) else {
        emit_error(&app, &request_id, ErrorKind::NoApiKey, "还没有配置 API Key");
        return;
    };

    let provider = GeminiProvider::new(&stored.provider);
    let client = app.state::<RequestState>().client.clone();
    let req = TranslateReq { text, direction };

    if let Err((kind, message)) =
        stream_translation(&app, &request_id, &client, &provider, &req, &api_key, &flags, started)
            .await
    {
        emit_error(&app, &request_id, kind, message);
        return;
    }

    crate::panel::log_line(
        &app,
        &format!(
            "[req:done] request={request_id} chunks={}\n",
            flags.chunks.load(Ordering::SeqCst)
        ),
    );
    let _ = app.emit(
        "req:done",
        DonePayload {
            request_id: request_id.clone(),
        },
    );
}

#[allow(clippy::too_many_arguments)]
async fn stream_translation(
    app: &AppHandle,
    request_id: &str,
    client: &reqwest::Client,
    provider: &GeminiProvider,
    req: &TranslateReq,
    api_key: &str,
    flags: &Arc<Flags>,
    started: std::time::Instant,
) -> Result<(), (ErrorKind, String)> {
    let mut response = provider
        .translate_request(client, req, api_key)
        .send()
        .await
        .map_err(map_send_error)?;

    // 响应头到达的时刻。它和首字符之间的差值能把「链路慢」与「模型在想」
    // 分开：前者卡在这一行之前，后者卡在这一行之后。
    crate::panel::log_line(
        app,
        &format!(
            "[http] request={request_id} status={} headers_at={:.0}ms\n",
            response.status().as_u16(),
            started.elapsed().as_millis()
        ),
    );

    let status = response.status();
    if !status.is_success() {
        let body = response.text().await.unwrap_or_default();
        return Err(map_status_error(status, &body));
    }

    // 按字节缓冲，不能按 String —— 一个汉字会被拆在两个 chunk 之间，
    // 提前 from_utf8_lossy 就变成替换字符了。
    let mut buffer: Vec<u8> = Vec::new();
    let mut first_byte_logged = false;
    let mut total_bytes = 0usize;
    loop {
        let chunk = response.chunk().await.map_err(map_send_error)?;
        let Some(chunk) = chunk else { break };
        total_bytes += chunk.len();
        if !first_byte_logged {
            first_byte_logged = true;
            // 收到正文第一个字节的时刻。它与 [first-chunk] 的差值说明
            // 解析问题：有字节进来却没有增量出去，就是 SSE 没被认出来。
            crate::panel::log_line(
                app,
                &format!(
                    "[first-byte] request={request_id} at={:.0}ms\n",
                    started.elapsed().as_millis()
                ),
            );
        }
        buffer.extend_from_slice(&chunk);

        while let Some(pos) = buffer.iter().position(|b| *b == b'\n') {
            let line: Vec<u8> = buffer.drain(..=pos).collect();
            let Ok(line) = std::str::from_utf8(&line) else {
                continue;
            };
            // 头几行原样记下来：如果响应根本不是 SSE（比如返回了完整
            // JSON 数组），只有看到真实的行长什么样才能发现。
            if total_bytes < 400 {
                crate::panel::log_line(
                    app,
                    &format!("[sse-line] request={request_id} {:?}\n", line.trim_end()),
                );
            }
            let Some(delta) = extract_delta(provider, line.trim_end())? else {
                continue;
            };
            if delta.is_empty() {
                continue;
            }
            if !flags.first_chunk.swap(true, Ordering::SeqCst) {
                // 门禁 1.2 的原始数据：从 start_request 进入到首个增量送出。
                crate::panel::log_line(
                    app,
                    &format!(
                        "[first-chunk] {}us ({:.2}ms) request={}\n",
                        started.elapsed().as_micros(),
                        started.elapsed().as_micros() as f64 / 1000.0,
                        request_id,
                    ),
                );
            }
            flags.chunks.fetch_add(1, Ordering::SeqCst);
            let _ = app.emit(
                "req:chunk",
                ChunkPayload {
                    request_id: request_id.to_string(),
                    delta,
                },
            );
        }
    }

    Ok(())
}

/// 单行 SSE → 增量文本。非 `data:` 行（事件名、注释、空行）一律跳过。
fn extract_delta(
    provider: &GeminiProvider,
    line: &str,
) -> Result<Option<String>, (ErrorKind, String)> {
    let Some(data) = line.strip_prefix("data:") else {
        return Ok(None);
    };
    let data = data.trim();
    if data.is_empty() || data == "[DONE]" {
        return Ok(None);
    }
    provider
        .parse_chunk(data)
        .map_err(|message| (ErrorKind::Unknown, message))
}

fn map_send_error(error: reqwest::Error) -> (ErrorKind, String) {
    if error.is_connect() || error.is_timeout() || error.is_request() {
        (ErrorKind::Network, describe_transport_error(error))
    } else {
        (ErrorKind::Unknown, error.to_string())
    }
}

/// 传输层错误的人话描述。
///
/// **底层原因必须带上。** 第一版这里写的是 `map_err(|_| "网络连接失败")`，
/// 把 reqwest 的错误整个丢掉 —— 结果真出问题时，界面上只有一句「网络连接
/// 失败」，分不清是 DNS 解析不了、TLS 握手失败、连接被拒还是超时，等于
/// 没法排查。§4.2 要求的是「一句人话 + 一个动作」，不是「不许有技术细节」。
pub fn describe_transport_error(error: reqwest::Error) -> String {
    let hint = if error.is_timeout() {
        "连接超时"
    } else if error.is_connect() {
        "连不上服务器"
    } else {
        "网络连接失败"
    };

    // reqwest 的 Display 只给最外层，真正有用的是链条末端的系统错误
    // （dns error / certificate / connection refused 之类）。
    let mut cause: Option<&dyn std::error::Error> = std::error::Error::source(&error);
    let mut detail = String::new();
    while let Some(current) = cause {
        detail = current.to_string();
        cause = current.source();
    }
    if detail.is_empty() {
        detail = error.to_string();
    }

    format!("{hint}：{}", summarize(&detail))
}

fn map_status_error(status: reqwest::StatusCode, body: &str) -> (ErrorKind, String) {
    match status.as_u16() {
        400 if body.contains("API_KEY_INVALID") => {
            (ErrorKind::InvalidApiKey, "API Key 无效".to_string())
        }
        401 | 403 => (ErrorKind::InvalidApiKey, "API Key 无效".to_string()),
        404 => (
            ErrorKind::Unknown,
            "配置的模型不存在，或当前 Key 无权访问它。请在设置里换一个模型名。".to_string(),
        ),
        429 => (ErrorKind::RateLimited, "请求太频繁".to_string()),
        _ => (
            ErrorKind::Unknown,
            format!("请求失败（HTTP {}）：{}", status.as_u16(), summarize(body)),
        ),
    }
}

/// 错误正文可能很长，面板只有 420px 宽，截断到能看清的长度。
fn summarize(body: &str) -> String {
    let body = body.trim();
    if body.chars().count() > 200 {
        body.chars().take(200).collect::<String>() + "…"
    } else {
        body.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::ProviderSettings;

    fn provider() -> GeminiProvider {
        GeminiProvider::new(&ProviderSettings::default())
    }

    #[test]
    fn ignores_non_data_lines() {
        assert_eq!(extract_delta(&provider(), "").unwrap(), None);
        assert_eq!(extract_delta(&provider(), ": keep-alive").unwrap(), None);
        assert_eq!(extract_delta(&provider(), "event: message").unwrap(), None);
    }

    #[test]
    fn reads_data_line() {
        let line = r#"data: {"candidates":[{"content":{"parts":[{"text":"hello"}]}}]}"#;
        assert_eq!(
            extract_delta(&provider(), line).unwrap(),
            Some("hello".to_string())
        );
    }

    #[test]
    fn maps_auth_failures_to_invalid_key() {
        let (kind, _) = map_status_error(reqwest::StatusCode::UNAUTHORIZED, "");
        assert!(matches!(kind, ErrorKind::InvalidApiKey));
        let (kind, _) = map_status_error(reqwest::StatusCode::FORBIDDEN, "");
        assert!(matches!(kind, ErrorKind::InvalidApiKey));
    }

    #[test]
    fn maps_429_to_rate_limited() {
        let (kind, _) = map_status_error(reqwest::StatusCode::TOO_MANY_REQUESTS, "");
        assert!(matches!(kind, ErrorKind::RateLimited));
    }

    #[test]
    fn long_error_bodies_are_truncated() {
        let long = "x".repeat(500);
        assert!(summarize(&long).chars().count() <= 201);
    }
}
