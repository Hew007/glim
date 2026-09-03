//! Gemini Provider。v1 的默认实现，走 free tier（§4）。

use serde_json::{json, Value};

use super::{Capabilities, Provider, TranslateReq};
use crate::settings::ProviderSettings;

pub struct GeminiProvider {
    endpoint: String,
    model: String,
}

impl GeminiProvider {
    pub fn new(settings: &ProviderSettings) -> Self {
        Self {
            endpoint: settings.endpoint.trim_end_matches('/').to_string(),
            model: settings.model.clone(),
        }
    }

    /// `alt=sse` 才会逐块推送；不带这个参数返回的是一个完整 JSON 数组，
    /// 首字符延迟直接变成整段生成时间（§2.3 的 800ms 预算会当场失守）。
    fn stream_url(&self) -> String {
        format!(
            "{}/models/{}:streamGenerateContent?alt=sse",
            self.endpoint, self.model
        )
    }

    /// 校验 Key 用的最小请求：非流式、只要一个 token，够判断 401/403 即可。
    pub fn validate_url(&self) -> String {
        format!("{}/models/{}:generateContent", self.endpoint, self.model)
    }
}

/// 翻译提示词（§3.4）。要点：只输出译文，不加前缀、不加引号、不解释；
/// 中→英额外要求地道表达，这是中文母语者用翻译工具的主要不满来源。
fn system_prompt(direction: &crate::lang::Direction) -> String {
    let mut prompt = String::from(
        "You are a translation engine. Output ONLY the translation. \
         Do not add any prefix such as \"Translation:\", do not wrap the result in quotes, \
         do not explain, do not comment, do not repeat the source text.",
    );
    if direction.from == "zh" && direction.to == "en" {
        prompt.push_str(
            " Translate the Chinese input into natural, idiomatic English as a native speaker \
             would write it. Do not translate word by word.",
        );
    } else if direction.to == "zh" {
        prompt.push_str(" Translate the input into natural Simplified Chinese.");
    }
    prompt
}

impl Provider for GeminiProvider {
    fn capabilities(&self) -> Capabilities {
        Capabilities {
            supports_lookup: true,
            supports_stream: true,
        }
    }

    fn translate_request(
        &self,
        client: &reqwest::Client,
        req: &TranslateReq,
        api_key: &str,
    ) -> reqwest::RequestBuilder {
        let body = json!({
            "systemInstruction": {
                "parts": [{ "text": system_prompt(&req.direction) }]
            },
            "contents": [{
                "role": "user",
                "parts": [{ "text": req.text }]
            }],
            "generationConfig": {
                // 翻译要稳定复现，不要发挥。
                "temperature": 0.3
            }
        });

        client
            .post(self.stream_url())
            // Key 走请求头而不是 query 参数：URL 会进日志、进代理记录，
            // 请求头不会。
            .header("x-goog-api-key", api_key)
            .json(&body)
    }

    fn parse_chunk(&self, data: &str) -> Result<Option<String>, String> {
        let value: Value =
            serde_json::from_str(data).map_err(|e| format!("SSE 负载不是合法 JSON：{e}"))?;

        // 安全策略拦截时没有 candidates，只有 promptFeedback.blockReason。
        if let Some(reason) = value
            .pointer("/promptFeedback/blockReason")
            .and_then(Value::as_str)
        {
            return Err(format!("请求被模型安全策略拦截（{reason}）"));
        }

        let text = value
            .pointer("/candidates/0/content/parts/0/text")
            .and_then(Value::as_str);

        Ok(text.map(str::to_string))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lang::Direction;

    fn provider() -> GeminiProvider {
        GeminiProvider::new(&ProviderSettings::default())
    }

    #[test]
    fn stream_url_carries_sse_flag() {
        assert!(provider().stream_url().ends_with(":streamGenerateContent?alt=sse"));
    }

    #[test]
    fn extracts_delta_text() {
        let chunk = r#"{"candidates":[{"content":{"parts":[{"text":"敏捷的"}]}}]}"#;
        assert_eq!(provider().parse_chunk(chunk).unwrap(), Some("敏捷的".into()));
    }

    /// 元数据块（只有 usageMetadata、没有正文）必须被跳过而不是报错。
    #[test]
    fn skips_chunks_without_text() {
        let chunk = r#"{"usageMetadata":{"promptTokenCount":12}}"#;
        assert_eq!(provider().parse_chunk(chunk).unwrap(), None);
    }

    #[test]
    fn reports_safety_block() {
        let chunk = r#"{"promptFeedback":{"blockReason":"SAFETY"}}"#;
        assert!(provider().parse_chunk(chunk).is_err());
    }

    #[test]
    fn zh_to_en_prompt_asks_for_idiomatic_english() {
        let p = system_prompt(&Direction { from: "zh".into(), to: "en".into() });
        assert!(p.contains("idiomatic"));
    }
}
