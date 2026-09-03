//! Provider 抽象（§4）。前端完全不知道背后是谁，只发 `{ text, mode }`。
//!
//! §4 里 trait 写的是 `async fn translate(&self, req) -> Result<TextStream>`。
//! 这里拆成「构造请求」+「解析增量」两个同步方法，把 await 循环留在
//! `request.rs`：Rust 的 async trait 要么上 `async-trait`（§1 清单外的第三方库，
//! 不能加），要么用 RPITIT 再手写 Send 边界。拆开之后抽象边界没变 ——
//! M2 接 OpenAICompat 时照样只实现这两个方法。

pub mod gemini;

use serde::Serialize;

use crate::lang::Direction;

/// §4 的 `Capabilities`。传统翻译 API 的 `supports_lookup` 为 false，
/// 届时查词请求自动降级走翻译路径（§4 降级规则）。
///
/// M1 只有 Gemini 一个 Provider、只走翻译，没有需要判断能力的分支，
/// 所以暂时无人调用。§4 明确要求「这条现在就要写进去，否则二期接
/// Apple 翻译框架要返工」，因此保留而不是等到 M2 再补。
#[allow(dead_code)]
#[derive(Debug, Clone, Copy, Serialize)]
pub struct Capabilities {
    pub supports_lookup: bool,
    pub supports_stream: bool,
}

/// 一次翻译请求的入参。
pub struct TranslateReq {
    pub text: String,
    pub direction: Direction,
}

pub trait Provider: Send + Sync {
    #[allow(dead_code)]
    fn capabilities(&self) -> Capabilities;

    /// 构造好但尚未发送的 HTTP 请求。鉴权头在这里加。
    fn translate_request(
        &self,
        client: &reqwest::Client,
        req: &TranslateReq,
        api_key: &str,
    ) -> reqwest::RequestBuilder;

    /// 从一条 SSE `data:` 负载里取出增量文本。
    /// 返回 `Ok(None)` 表示这条负载不含正文（心跳、元数据），跳过即可。
    fn parse_chunk(&self, data: &str) -> Result<Option<String>, String>;
}
