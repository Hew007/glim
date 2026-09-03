//! 语言方向判定（§3.0）。设置项是「语言对」（母语 + 外语），不是目标语言：
//!
//! ```text
//! 源 == 母语   → 译成外语
//! 源 == 外语   → 译成母语
//! 源 == 其他   → 译成母语
//! ```
//!
//! 这样「复制中文出英文、复制英文出中文」自然成立，用户永远不用手动切方向。

use serde::{Deserialize, Serialize};

use crate::settings::LanguagePair;

/// CJK 占比超过这个比例判为中文。§3.0 定的 30%。
///
/// 分母是**非空白字符数**，不是总长度。附录 A 用例 20
/// 「这个 API 的 rate limit 是多少」= 6 个汉字 / 18 个非空白字符 = 33%，
/// 刚好落在阈值上方判为中文 —— 这条用例正是拿来卡这个分母口径的。
const CJK_RATIO_THRESHOLD: f64 = 0.30;

/// 一次请求的翻译方向。`from` / `to` 存语言码，UI 的「中 → EN」标签由此渲染。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Direction {
    pub from: String,
    pub to: String,
}

/// 粗判源语言，只区分「中文」和「其他」——§3.0 明确不引入语言检测库。
fn is_chinese(text: &str) -> bool {
    let mut cjk = 0usize;
    let mut total = 0usize;
    for ch in text.chars() {
        if ch.is_whitespace() {
            continue;
        }
        total += 1;
        if is_cjk(ch) {
            cjk += 1;
        }
    }
    if total == 0 {
        return false;
    }
    (cjk as f64) / (total as f64) > CJK_RATIO_THRESHOLD
}

/// 汉字区间。只覆盖表意文字本身，不含中文标点 —— 标点算进分子会让
/// 「他说：「明天见。」」这类句子的占比虚高，但那本来就是中文，
/// 真正的风险在中英混排：把全角标点算进分子会把英文长句里的一个句号
/// 也算成中文特征。分母含标点、分子不含，是偏保守的一侧。
fn is_cjk(ch: char) -> bool {
    matches!(ch as u32,
        0x4E00..=0x9FFF     // CJK 统一表意文字
        | 0x3400..=0x4DBF   // 扩展 A
        | 0xF900..=0xFAFF   // 兼容表意文字
    )
}

/// 按语言对决定这次要译成什么。源语言不是这对里的任何一个时译成母语。
pub fn detect(text: &str, pair: &LanguagePair) -> Direction {
    let source_is_native = if pair.native == "zh" {
        is_chinese(text)
    } else {
        // v1 的主场景语言对是中 ↔ 英。母语不是中文时无从粗判，
        // 一律按「源 == 外语」处理，即译成母语，与 §3.0 的兜底一致。
        false
    };

    if source_is_native {
        Direction {
            from: pair.native.clone(),
            to: pair.foreign.clone(),
        }
    } else {
        Direction {
            from: pair.foreign.clone(),
            to: pair.native.clone(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn zh_en() -> LanguagePair {
        LanguagePair {
            native: "zh".into(),
            foreign: "en".into(),
        }
    }

    #[test]
    fn english_goes_to_chinese() {
        let d = detect("The quick brown fox jumps over the lazy dog.", &zh_en());
        assert_eq!(d.from, "en");
        assert_eq!(d.to, "zh");
    }

    #[test]
    fn chinese_goes_to_english() {
        let d = detect("我觉得这个方案还需要再讨论一下", &zh_en());
        assert_eq!(d.from, "zh");
        assert_eq!(d.to, "en");
    }

    /// 附录 A 用例 20，最容易翻车的三条之一。
    #[test]
    fn mixed_script_counts_as_chinese() {
        let d = detect("这个 API 的 rate limit 是多少", &zh_en());
        assert_eq!(d.from, "zh", "CJK 占比 6/18 = 33% 应判为中文");
    }

    /// 反向：英文句子里夹一两个汉字不该被判成中文。
    #[test]
    fn mostly_english_stays_english() {
        let d = detect("I think we should reconsider the 方案", &zh_en());
        assert_eq!(d.from, "en");
    }

    #[test]
    fn empty_is_not_chinese() {
        assert!(!is_chinese(""));
        assert!(!is_chinese("   \n\t "));
    }
}
