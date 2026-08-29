//! 语法高亮（D82）：tree-sitter 解析 + grammar 内嵌 highlights 查询 → 语义 token span。
//!
//! 引擎只产出语义 span（字节偏移 + HighlightKind），颜色由 UI 决定（D7 语言中立）。
//! grammar crate 自带查询常量（命名不统一：HIGHLIGHTS_QUERY / HIGHLIGHT_QUERY），
//! 查询与 grammar 版本严格一致，无需 vendor 查询文件。
//! 所有入口静默降级：语言未知 / 内容超长 / 解析或查询失败 → 空 span，绝不报错。

use std::borrow::Cow;
use std::collections::HashMap;

use streaming_iterator::StreamingIterator;
use tree_sitter::{Language, Parser, Query, QueryCursor};
use tree_sitter_language::LanguageFn;

use crate::diff::FileDiff;

/// 全文高亮的上限（字节）：超出直接跳过，避免大文件卡顿。
const MAX_HIGHLIGHT_BYTES: usize = 1 << 20;

/// 语义 token 类别（capture 名按 `.` 前缀映射；variable/punctuation 等噪音不映射）。
#[derive(uniffi::Enum, Clone, Copy, PartialEq, Eq, Debug)]
pub enum HighlightKind {
    Keyword,
    String,
    Comment,
    Function,
    Type,
    Number,
    Constant,
    Operator,
}

/// 一个高亮 span（字节偏移）。`highlight_code` 返回全文偏移；
/// DiffLine/BlameLine 中为行内局部偏移（按行截断后）。
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct HighlightSpan {
    pub start: u32,
    pub end: u32,
    pub kind: HighlightKind,
}

/// 扩展名 → (LanguageFn, 查询源码)。
/// ts/tsx 叠加 JS 查询（TS grammar 是 JS 的超集方言，官方编辑器同款做法；
/// TS 仓库的 highlights.scm 只含方言增量规则）。
pub(crate) fn spec_for_path(path: &str) -> Option<(LanguageFn, Cow<'static, str>)> {
    let ext = path.rsplit('.').next()?.to_ascii_lowercase();
    match ext.as_str() {
        "swift" => Some((
            tree_sitter_swift::LANGUAGE,
            Cow::Borrowed(tree_sitter_swift::HIGHLIGHTS_QUERY),
        )),
        "rs" => Some((
            tree_sitter_rust::LANGUAGE,
            Cow::Borrowed(tree_sitter_rust::HIGHLIGHTS_QUERY),
        )),
        "py" => Some((
            tree_sitter_python::LANGUAGE,
            Cow::Borrowed(tree_sitter_python::HIGHLIGHTS_QUERY),
        )),
        "js" | "jsx" | "mjs" | "cjs" => Some((
            tree_sitter_javascript::LANGUAGE,
            Cow::Borrowed(tree_sitter_javascript::HIGHLIGHT_QUERY),
        )),
        "ts" | "tsx" => {
            let lang = if ext == "tsx" {
                tree_sitter_typescript::LANGUAGE_TSX
            } else {
                tree_sitter_typescript::LANGUAGE_TYPESCRIPT
            };
            let query = format!(
                "{}\n{}",
                tree_sitter_javascript::HIGHLIGHT_QUERY,
                tree_sitter_typescript::HIGHLIGHTS_QUERY
            );
            Some((lang, Cow::Owned(query)))
        }
        "c" | "h" => Some((
            tree_sitter_c::LANGUAGE,
            Cow::Borrowed(tree_sitter_c::HIGHLIGHT_QUERY),
        )),
        "cc" | "cpp" | "cxx" | "hpp" | "hh" => Some((
            tree_sitter_cpp::LANGUAGE,
            Cow::Borrowed(tree_sitter_cpp::HIGHLIGHT_QUERY),
        )),
        "java" => Some((
            tree_sitter_java::LANGUAGE,
            Cow::Borrowed(tree_sitter_java::HIGHLIGHTS_QUERY),
        )),
        "go" => Some((
            tree_sitter_go::LANGUAGE,
            Cow::Borrowed(tree_sitter_go::HIGHLIGHTS_QUERY),
        )),
        "json" => Some((
            tree_sitter_json::LANGUAGE,
            Cow::Borrowed(tree_sitter_json::HIGHLIGHTS_QUERY),
        )),
        "sh" | "bash" | "zsh" => Some((
            tree_sitter_bash::LANGUAGE,
            Cow::Borrowed(tree_sitter_bash::HIGHLIGHT_QUERY),
        )),
        _ => None,
    }
}

/// capture 名（如 `keyword.conditional`、`string.special`）→ 类别。
/// `keyword.operator` 是 Swift 的运算符 capture，归为 Operator；
/// 其余按首个 `.` 段映射；无映射的（variable/punctuation/property 等噪音）不高亮。
fn kind_for_capture(name: &str) -> Option<HighlightKind> {
    if name == "keyword.operator" {
        return Some(HighlightKind::Operator);
    }
    match name.split('.').next() {
        Some("keyword") => Some(HighlightKind::Keyword),
        Some("string" | "character" | "escape") => Some(HighlightKind::String),
        Some("comment") => Some(HighlightKind::Comment),
        Some("function" | "method" | "constructor") => Some(HighlightKind::Function),
        Some("type" | "class" | "interface" | "enum" | "struct") => Some(HighlightKind::Type),
        Some("number" | "float" | "integer") => Some(HighlightKind::Number),
        Some("constant" | "boolean" | "bool") => Some(HighlightKind::Constant),
        Some("operator") => Some(HighlightKind::Operator),
        _ => None,
    }
}

/// 全文高亮：解析 + 查询 → 排序去重后的 span（全文字节偏移）。
/// 任一步失败都返回空（高亮是锦上添花，绝不阻塞 diff）。
pub(crate) fn highlight_content(
    content: &[u8],
    language: &Language,
    query_src: &str,
) -> Vec<HighlightSpan> {
    if content.is_empty() || content.len() > MAX_HIGHLIGHT_BYTES {
        return Vec::new();
    }
    let mut parser = Parser::new();
    if parser.set_language(language).is_err() {
        return Vec::new();
    }
    let Some(tree) = parser.parse(content, None) else {
        return Vec::new();
    };
    let Ok(query) = Query::new(language, query_src) else {
        return Vec::new();
    };

    let mut spans = Vec::new();
    let mut cursor = QueryCursor::new();
    let mut iter = cursor.captures(&query, tree.root_node(), content);
    while let Some((m, capture_idx)) = iter.next() {
        let capture = &m.captures[*capture_idx];
        let Some(kind) = query
            .capture_names()
            .get(capture.index as usize)
            .and_then(|name| kind_for_capture(name))
        else {
            continue;
        };
        let range = capture.node.byte_range();
        if range.end > range.start {
            spans.push(HighlightSpan {
                start: range.start as u32,
                end: range.end as u32,
                kind,
            });
        }
    }
    // 排序 + 重叠去重：同起点长 span 优先（注释/字符串内部的嵌套 token 不重复上色）。
    spans.sort_by(|a, b| a.start.cmp(&b.start).then(b.end.cmp(&a.end)));
    let mut out: Vec<HighlightSpan> = Vec::with_capacity(spans.len());
    let mut last_end = 0u32;
    for s in spans {
        if s.start >= last_end {
            last_end = s.end;
            out.push(s);
        }
    }
    out
}

/// 全文高亮结果按行切分 → 行号(1-based) → 行内局部 span。
/// 跨行 span（块注释等）逐行截断；行区间与 DiffLine.text 语义一致（仅不含 `\n`）。
pub(crate) fn line_spans_for_content(
    content: &[u8],
    language: &Language,
    query_src: &str,
) -> HashMap<u32, Vec<HighlightSpan>> {
    let mut map: HashMap<u32, Vec<HighlightSpan>> = HashMap::new();
    let spans = highlight_content(content, language, query_src);
    if spans.is_empty() {
        return map;
    }
    // 每行起点（字节偏移）：行 i（1-based）区间 = [starts[i-1], starts[i]-1)，末行到 len。
    let mut starts = vec![0u32];
    for (i, &b) in content.iter().enumerate() {
        if b == b'\n' {
            starts.push(i as u32 + 1);
        }
    }
    for s in spans {
        // start 所在行：恰为行起点时落在该行，否则在前一行内。
        let mut line_idx = match starts.binary_search(&s.start) {
            Ok(i) => i,
            Err(i) => i - 1,
        };
        let mut start = s.start;
        while start < s.end && line_idx < starts.len() {
            let line_no = (line_idx + 1) as u32;
            let line_start = starts[line_idx];
            let line_end = if line_idx + 1 < starts.len() {
                starts[line_idx + 1].saturating_sub(1)
            } else {
                content.len() as u32
            };
            let clamped_start = start.max(line_start);
            let clamped_end = s.end.min(line_end);
            if clamped_end > clamped_start {
                map.entry(line_no).or_default().push(HighlightSpan {
                    start: clamped_start - line_start,
                    end: clamped_end - line_start,
                    kind: s.kind,
                });
            }
            start = line_end.saturating_add(1);
            line_idx += 1;
        }
    }
    map
}

/// 给 FileDiff 填上逐行高亮（行内局部字节偏移）。语言未知 / 超长 / 失败 → 静默跳过。
pub(crate) fn attach_highlights(path: &str, old: &[u8], new: &[u8], diff: &mut FileDiff) {
    let Some((language, query_src)) = spec_for_path(path) else {
        return;
    };
    let language: Language = language.into();
    let old_lines = line_spans_for_content(old, &language, &query_src);
    let new_lines = line_spans_for_content(new, &language, &query_src);
    if old_lines.is_empty() && new_lines.is_empty() {
        return;
    }
    for hunk in &mut diff.hunks {
        for (i, line) in hunk.old_lines.iter_mut().enumerate() {
            let line_no = hunk.old_start + i as u32;
            line.highlights = old_lines.get(&line_no).cloned().unwrap_or_default();
        }
        for (i, line) in hunk.new_lines.iter_mut().enumerate() {
            let line_no = hunk.new_start + i as u32;
            line.highlights = new_lines.get(&line_no).cloned().unwrap_or_default();
        }
    }
}

/// 对给定路径语言的文本做全文语法高亮（对外原始能力：测试 + 未来独立代码查看器）。
#[uniffi::export]
pub fn highlight_code(content: String, path: String) -> Vec<HighlightSpan> {
    match spec_for_path(&path) {
        Some((language, query_src)) => {
            let language: Language = language.into();
            highlight_content(content.as_bytes(), &language, &query_src)
        }
        None => Vec::new(),
    }
}
