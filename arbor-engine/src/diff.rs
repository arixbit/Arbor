//! 单文件 line-level diff（side-by-side 数据模型）。
//!
//! 纯字节路径：InternedInput + imara-diff，不经 Platform/resource-cache
//! （省去 .gitattributes 过滤器/diff driver 配置开销，FFI 场景足够）。
//! 行切分用 ByteLinesWithoutTerminator（去尾随换行，避免 EOF 无换行伪影）。

use gix::bstr::{BStr, ByteSlice};

use crate::error::EngineError;
use crate::highlight::HighlightSpan;

/// diff 的维度：工作区↔索引（未暂存）、索引↔HEAD（已暂存）、
/// 工作区↔HEAD（三层模型的直接比较）。
#[derive(uniffi::Enum, Clone, Copy, Debug)]
pub enum DiffMode {
    WorktreeToIndex,
    /// Reverse presentation of the staged/local comparison: old=worktree,
    /// new=index. This is read-only and must not be used for line staging.
    IndexToWorktree,
    IndexToHead,
    WorktreeToHead,
}

/// 一行的变更种类。
#[derive(uniffi::Enum, Clone, Copy, PartialEq, Eq, Debug)]
pub enum DiffLineKind {
    Context,
    Addition,
    Deletion,
}

/// 一行中需要高亮的字节区间（word-level diff 结果；对未配对的整行 = 全行）。
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct WordSpan {
    pub start: u32,
    pub end: u32,
}

/// 一行 diff：kind + 1-based 行号（不适用侧为 0）+ 文本（无尾随换行）+ 词级高亮区间。
/// `highlights` 为语法高亮行内局部 span（repo 层 attach_highlights 填充；本模块恒为空）。
#[derive(uniffi::Record, Clone, Debug)]
pub struct DiffLine {
    pub kind: DiffLineKind,
    pub old_line: u32,
    pub new_line: u32,
    pub text: String,
    pub spans: Vec<WordSpan>,
    pub highlights: Vec<HighlightSpan>,
}

/// DIFF-001：diff 行为设置（whitespace/word/CRLF）。
#[derive(uniffi::Record, Clone, Copy, Debug)]
pub struct DiffSettings {
    /// 忽略行尾空白差异（-w 的轻量版）。
    pub ignore_whitespace_at_eol: bool,
    /// 忽略所有空白差异（等价 git diff -w）。
    pub ignore_all_space: bool,
    /// word-level 高亮（DiffLine.spans 填充）。
    pub word_diff: bool,
    /// CRLF 敏感：false 时比较前归一化 CRLF（attributes 建议的跨平台 diff）。
    pub crlf_sensitive: bool,
    /// 显式允许 Git diff driver 的 textconv。仅用于 Diff 预览；不会启用
    /// diff.<driver>.command 这类任意外部 diff helper。
    pub use_external_textconv: bool,
}

impl Default for DiffSettings {
    fn default() -> Self {
        DiffSettings {
            ignore_whitespace_at_eol: false,
            ignore_all_space: false,
            word_diff: false,
            crlf_sensitive: true,
            use_external_textconv: false,
        }
    }
}

/// 一个 hunk：旧侧起点 + 新侧起点 + 两侧行序列。
/// old_lines = 上下文+删除；new_lines = 上下文+新增（side-by-side 直接可用，unified 可反推）。
#[derive(uniffi::Record, Clone, Debug)]
pub struct DiffHunk {
    pub old_start: u32,
    pub new_start: u32,
    pub old_lines: Vec<DiffLine>,
    pub new_lines: Vec<DiffLine>,
}

/// 单文件 diff 结果。
#[derive(uniffi::Record, Clone, Debug)]
pub struct FileDiff {
    pub path: String,
    pub binary: bool,
    pub hunks: Vec<DiffHunk>,
}

/// Read an object only when it is actually a blob.
///
/// Tree diffs can legitimately expose directory objects for file/directory
/// type changes. Keeping this check in one place prevents gix's low-level
/// "expected blob, got tree" conversion error from leaking through FFI.
pub(crate) fn blob_bytes(
    repo: &gix::Repository,
    id: gix::hash::ObjectId,
    context: &str,
) -> Result<Vec<u8>, EngineError> {
    let object = repo.find_object(id).map_err(EngineError::from_gix)?;
    if !object.kind.is_blob() {
        return Err(EngineError::GitOperation {
            message: format!(
                "{context}: object {id} is {:?}, but a blob was required",
                object.kind
            ),
        });
    }
    Ok(object.data.clone())
}

/// A file diff treats a directory/submodule entry as an empty file side.
/// This is important for a file↔directory type change: there is no blob
/// content on the directory side, but the diff itself remains meaningful.
pub(crate) fn blob_bytes_or_empty(
    repo: &gix::Repository,
    id: gix::hash::ObjectId,
) -> Result<Vec<u8>, EngineError> {
    let object = repo.find_object(id).map_err(EngineError::from_gix)?;
    if object.kind.is_blob() {
        Ok(object.data.clone())
    } else {
        Ok(Vec::new())
    }
}

/// 索引侧 blob 字节；路径不在索引（未跟踪）-> 空。
pub(crate) fn index_bytes(repo: &gix::Repository, path: &str) -> Result<Vec<u8>, EngineError> {
    let index = repo.index().map_err(EngineError::from_gix)?;
    let path_bstr = path.as_bytes().as_bstr();
    match index.entry_by_path(path_bstr) {
        Some(entry) => blob_bytes_or_empty(repo, entry.id),
        None => Ok(Vec::new()),
    }
}

/// 任意 rev（分支名/提交 id/tag）下指定路径的 blob 字节；路径缺失 -> 空。
pub(crate) fn rev_blob_bytes(
    repo: &gix::Repository,
    rev: &str,
    path: &str,
) -> Result<Vec<u8>, EngineError> {
    let spec = format!("{rev}:{path}");
    match repo.rev_parse_single(BStr::new(spec.as_bytes())) {
        Ok(id) => blob_bytes_or_empty(repo, id.detach()),
        Err(_) => Ok(Vec::new()),
    }
}

/// Read a revision path as diff content, including a gitlink (submodule).
///
/// A gitlink points at a commit object rather than a blob. Treating it as an
/// empty side makes a changed submodule appear as a no-op in the Changes
/// Browser. IntelliJ presents the two gitlink ids as the meaningful diff, so
/// expose a small textual representation while keeping ordinary directories
/// as empty sides.
pub(crate) fn rev_content_bytes(
    repo: &gix::Repository,
    rev: &str,
    path: &str,
) -> Result<Vec<u8>, EngineError> {
    let tree_spec = format!("{rev}^{{tree}}");
    let tree_id = repo
        .rev_parse_single(BStr::new(tree_spec.as_bytes()))
        .map_err(EngineError::from_gix)?
        .detach();
    let tree = repo.find_tree(tree_id).map_err(EngineError::from_gix)?;
    let Some(entry) = tree
        .lookup_entry(path.split('/'))
        .map_err(EngineError::from_gix)?
    else {
        return Ok(Vec::new());
    };
    if entry.mode().is_commit() {
        return Ok(format!("Submodule commit {}\n", entry.object_id()).into_bytes());
    }
    if entry.mode().is_blob_or_symlink() {
        return blob_bytes(repo, entry.object_id(), "read revision content");
    }
    Ok(Vec::new())
}

/// HEAD 侧 blob 字节；路径不在 HEAD -> 空（新增文件场景）。
pub(crate) fn head_bytes(repo: &gix::Repository, path: &str) -> Result<Vec<u8>, EngineError> {
    rev_blob_bytes(repo, "HEAD", path)
}

/// 工作区文件字节；不存在 -> 空（删除文件场景）。
pub(crate) fn worktree_bytes(repo: &gix::Repository, path: &str) -> Vec<u8> {
    match repo.workdir() {
        Some(wd) => std::fs::read(wd.join(path)).unwrap_or_default(),
        None => Vec::new(),
    }
}

/// 二进制检测：前 8000 字节含 NUL（git 惯例）。
pub(crate) fn is_binary(bytes: &[u8]) -> bool {
    bytes.iter().take(8000).any(|&b| b == 0)
}

/// 计算两个字符串的词级差异，返回 (删除侧 spans, 新增侧 spans)。
/// spans 为字节区间（与输入字符串一致）。用 gix-imara-diff 的 words tokenizer
/// （字母数字序列/空格序列/单字符分词），不做 slider 启发式（行级语义）。
pub(crate) fn word_spans(old: &str, new: &str) -> (Vec<WordSpan>, Vec<WordSpan>) {
    use gix::diff::blob::sources;
    use gix::diff::blob::{Algorithm, Diff, InternedInput};
    let input = InternedInput::new(sources::words(old), sources::words(new));
    let diff = Diff::compute(Algorithm::Histogram, &input);
    let mut old_spans = Vec::new();
    let mut offset = 0u32;
    for (i, token_idx) in input.before.iter().enumerate() {
        let token: &str = &input.interner[*token_idx];
        let len = token.len() as u32;
        if diff.is_removed(i as u32) {
            old_spans.push(WordSpan {
                start: offset,
                end: offset + len,
            });
        }
        offset += len;
    }
    let mut new_spans = Vec::new();
    let mut offset = 0u32;
    for (i, token_idx) in input.after.iter().enumerate() {
        let token: &str = &input.interner[*token_idx];
        let len = token.len() as u32;
        if diff.is_added(i as u32) {
            new_spans.push(WordSpan {
                start: offset,
                end: offset + len,
            });
        }
        offset += len;
    }
    (old_spans, new_spans)
}

/// Parse the unified patch emitted by `git diff --textconv` into the same
/// side-by-side model used by the native byte diff.
///
/// Git owns the text conversion and emits the patch framing, so this parser
/// intentionally accepts only hunk lines and the standard binary markers. A
/// successful command with no hunks is a real no-diff result.
pub(crate) fn parse_external_unified_diff(
    output: &str,
    path: &str,
) -> Result<FileDiff, EngineError> {
    let mut hunks = Vec::new();
    let mut current: Option<DiffHunk> = None;
    let mut pending_deletions: std::collections::VecDeque<(u32, String)> =
        std::collections::VecDeque::new();
    let mut old_cursor = 0;
    let mut new_cursor = 0;
    let mut saw_hunk = false;

    let finish_pending_deletions =
        |hunk: &mut DiffHunk, pending: &mut std::collections::VecDeque<(u32, String)>| {
            while let Some((old_line, text)) = pending.pop_front() {
                hunk.old_lines.push(DiffLine {
                    kind: DiffLineKind::Deletion,
                    old_line,
                    new_line: 0,
                    text: text.clone(),
                    spans: vec![WordSpan {
                        start: 0,
                        end: text.len() as u32,
                    }],
                    highlights: Vec::new(),
                });
            }
        };

    for raw_line in output.lines() {
        if raw_line.starts_with("@@ ") {
            if let Some(mut hunk) = current.take() {
                finish_pending_deletions(&mut hunk, &mut pending_deletions);
                hunks.push(hunk);
            }
            let (old_start, new_start) =
                parse_hunk_header(raw_line).ok_or_else(|| EngineError::GitOperation {
                    message: format!("textconv diff: invalid hunk header '{raw_line}'"),
                })?;
            old_cursor = old_start;
            new_cursor = new_start;
            current = Some(DiffHunk {
                old_start,
                new_start,
                old_lines: Vec::new(),
                new_lines: Vec::new(),
            });
            saw_hunk = true;
            continue;
        }

        let Some(hunk) = current.as_mut() else {
            continue;
        };
        if raw_line == r"\ No newline at end of file" || raw_line.is_empty() {
            continue;
        }
        let Some(&kind_byte) = raw_line.as_bytes().first() else {
            continue;
        };
        if !kind_byte.is_ascii() {
            continue;
        }
        let kind = kind_byte as char;
        let text = &raw_line[1..];
        match kind {
            ' ' => {
                finish_pending_deletions(hunk, &mut pending_deletions);
                let old_line = old_cursor;
                let new_line = new_cursor;
                old_cursor += 1;
                new_cursor += 1;
                hunk.old_lines.push(DiffLine {
                    kind: DiffLineKind::Context,
                    old_line,
                    new_line,
                    text: text.to_string(),
                    spans: Vec::new(),
                    highlights: Vec::new(),
                });
                hunk.new_lines.push(DiffLine {
                    kind: DiffLineKind::Context,
                    old_line,
                    new_line,
                    text: text.to_string(),
                    spans: Vec::new(),
                    highlights: Vec::new(),
                });
            }
            '-' => {
                pending_deletions.push_back((old_cursor, text.to_string()));
                old_cursor += 1;
            }
            '+' => {
                let new_line = new_cursor;
                new_cursor += 1;
                if let Some((old_line, old_text)) = pending_deletions.pop_front() {
                    let (old_spans, new_spans) = word_spans(&old_text, text);
                    hunk.old_lines.push(DiffLine {
                        kind: DiffLineKind::Deletion,
                        old_line,
                        new_line: 0,
                        text: old_text,
                        spans: old_spans,
                        highlights: Vec::new(),
                    });
                    hunk.new_lines.push(DiffLine {
                        kind: DiffLineKind::Addition,
                        old_line: 0,
                        new_line,
                        text: text.to_string(),
                        spans: new_spans,
                        highlights: Vec::new(),
                    });
                } else {
                    hunk.new_lines.push(DiffLine {
                        kind: DiffLineKind::Addition,
                        old_line: 0,
                        new_line,
                        text: text.to_string(),
                        spans: vec![WordSpan {
                            start: 0,
                            end: text.len() as u32,
                        }],
                        highlights: Vec::new(),
                    });
                }
            }
            _ => {}
        }
    }

    if let Some(mut hunk) = current {
        finish_pending_deletions(&mut hunk, &mut pending_deletions);
        hunks.push(hunk);
    }

    if saw_hunk {
        return Ok(FileDiff {
            path: path.to_string(),
            binary: false,
            hunks,
        });
    }

    let lower = output.to_ascii_lowercase();
    Ok(FileDiff {
        path: path.to_string(),
        binary: lower.contains("binary files") || lower.contains("git binary patch"),
        hunks: Vec::new(),
    })
}

fn parse_hunk_header(line: &str) -> Option<(u32, u32)> {
    let body = line.strip_prefix("@@ ")?.split(" @@").next()?;
    let mut ranges = body.split_whitespace();
    let old = ranges.next()?.strip_prefix('-')?;
    let new = ranges.next()?.strip_prefix('+')?;
    Some((parse_hunk_start(old)?, parse_hunk_start(new)?))
}

fn parse_hunk_start(range: &str) -> Option<u32> {
    range.split(',').next()?.parse().ok()
}

/// Reverse an already parsed side-by-side diff without recomputing textconv.
/// This is used for the read-only IndexToWorktree presentation.
pub(crate) fn reverse_file_diff(diff: FileDiff) -> FileDiff {
    let hunks = diff
        .hunks
        .into_iter()
        .map(|hunk| DiffHunk {
            old_start: hunk.new_start,
            new_start: hunk.old_start,
            old_lines: hunk
                .new_lines
                .into_iter()
                .map(|line| match line.kind {
                    DiffLineKind::Context => DiffLine {
                        kind: DiffLineKind::Context,
                        old_line: line.new_line,
                        new_line: line.old_line,
                        ..line
                    },
                    DiffLineKind::Addition => DiffLine {
                        kind: DiffLineKind::Deletion,
                        old_line: line.new_line,
                        new_line: 0,
                        ..line
                    },
                    DiffLineKind::Deletion => DiffLine {
                        kind: DiffLineKind::Deletion,
                        old_line: line.new_line,
                        new_line: 0,
                        ..line
                    },
                })
                .collect(),
            new_lines: hunk
                .old_lines
                .into_iter()
                .map(|line| match line.kind {
                    DiffLineKind::Context => DiffLine {
                        kind: DiffLineKind::Context,
                        old_line: line.new_line,
                        new_line: line.old_line,
                        ..line
                    },
                    DiffLineKind::Deletion => DiffLine {
                        kind: DiffLineKind::Addition,
                        old_line: 0,
                        new_line: line.old_line,
                        ..line
                    },
                    DiffLineKind::Addition => DiffLine {
                        kind: DiffLineKind::Addition,
                        old_line: 0,
                        new_line: line.old_line,
                        ..line
                    },
                })
                .collect(),
        })
        .collect();
    FileDiff {
        path: diff.path,
        binary: diff.binary,
        hunks,
    }
}

/// 计算两个字节序列的 hunks；`ignore_whitespace=true` 时按 git `-w` 语义忽略行内空白：
/// 两侧按行去空白后跑管线（行数不变、行号一一对应），再按行号回填原始文本；
/// 词级 spans 清空（-w 模式下无意义，v1 接受）。
pub(crate) fn compute_hunks_with(old: &[u8], new: &[u8], ignore_whitespace: bool) -> Vec<DiffHunk> {
    compute_hunks_with_settings(
        old,
        new,
        &DiffSettings {
            ignore_all_space: ignore_whitespace,
            ..DiffSettings::default()
        },
    )
}

/// DIFF-001：带设置的 diff 计算。规范化仅用于匹配，输出保留原文行；
/// word_diff 时保留 spans 供 UI 做词级高亮。
pub(crate) fn compute_hunks_with_settings(
    old: &[u8],
    new: &[u8],
    settings: &DiffSettings,
) -> Vec<DiffHunk> {
    let need_normalize =
        settings.ignore_all_space || settings.ignore_whitespace_at_eol || !settings.crlf_sensitive;
    // gix 的行切分默认剥离行尾 \r(CRLF 与 LF 视为等价)。
    // crlf_sensitive=true 时若输入含 \r,必须主动标记差异:
    // 把 \r 替换为可见占位字符参与比较,输出行仍映射回原文。
    let has_cr = old.contains(&b'\r') || new.contains(&b'\r');
    if !need_normalize && !has_cr {
        return compute_hunks_inner(old, new);
    }
    let (old_norm, old_lines) = normalize_lines(old, settings);
    let (new_norm, new_lines) = normalize_lines(new, settings);
    let mut hunks = compute_hunks_inner(&old_norm, &new_norm);
    for hunk in &mut hunks {
        for line in &mut hunk.old_lines {
            if line.old_line > 0 {
                if let Some(text) = old_lines.get(line.old_line as usize - 1) {
                    line.text = text.clone();
                }
            }
            line.spans.clear();
        }
        for line in &mut hunk.new_lines {
            if line.new_line > 0 {
                if let Some(text) = new_lines.get(line.new_line as usize - 1) {
                    line.text = text.clone();
                }
            }
            line.spans.clear();
        }
    }
    hunks
}

/// 按设置归一化行内容（保留行结构），返回 (归一化字节, 原始行文本[无尾换行])。
fn normalize_lines(bytes: &[u8], settings: &DiffSettings) -> (Vec<u8>, Vec<String>) {
    let text = String::from_utf8_lossy(bytes);
    let mut norm = Vec::new();
    let mut lines = Vec::new();
    for line in text.split_inclusive('\n') {
        let mut original = line.trim_end_matches('\n').to_string();
        if !settings.crlf_sensitive {
            // 非敏感:行尾 \r 也剥掉(CRLF 与 LF 等价)
            original = original.trim_end_matches('\r').to_string();
        }
        let normalized: String = if settings.ignore_all_space {
            original.chars().filter(|c| !c.is_whitespace()).collect()
        } else if settings.ignore_whitespace_at_eol {
            original.trim_end().to_string()
        } else if settings.crlf_sensitive {
            // 敏感模式:把 \r 标记为可见占位,让 diff 引擎看到 CRLF 差异
            original.replace('\r', "\u{240D}")
        } else {
            original.clone()
        };
        lines.push(original);
        norm.extend_from_slice(normalized.as_bytes());
        norm.push(b'\n');
    }
    (norm, lines)
}

fn compute_hunks_inner(old: &[u8], new: &[u8]) -> Vec<DiffHunk> {
    use gix::diff::blob::unified_diff::DiffLineKind as GixKind;
    use gix::diff::blob::unified_diff::{ConsumeHunk, ContextSize, HunkHeader};
    use gix::diff::blob::{Algorithm, Diff, InternedInput, UnifiedDiff};

    struct Collector {
        hunks: Vec<DiffHunk>,
    }
    impl ConsumeHunk for Collector {
        type Out = Vec<DiffHunk>;
        fn consume_hunk(
            &mut self,
            header: HunkHeader,
            lines: &[(GixKind, &[u8])],
        ) -> std::io::Result<()> {
            let mut hunk = DiffHunk {
                old_start: header.before_hunk_start,
                new_start: header.after_hunk_start,
                old_lines: Vec::new(),
                new_lines: Vec::new(),
            };
            let mut old_no = header.before_hunk_start;
            let mut new_no = header.after_hunk_start;
            // 变更组 = [删除..., 新增...]：缓冲删除行，遇新增按 FIFO 配对计算词级 spans。
            let mut pending_dels: std::collections::VecDeque<(u32, String)> =
                std::collections::VecDeque::new();
            for (kind, bytes) in lines {
                let text = String::from_utf8_lossy(bytes).into_owned();
                match kind {
                    GixKind::Context => {
                        // 组结束：残留删除行整行高亮
                        while let Some((del_old_no, del_text)) = pending_dels.pop_front() {
                            let full = vec![WordSpan {
                                start: 0,
                                end: del_text.len() as u32,
                            }];
                            hunk.old_lines.push(DiffLine {
                                kind: DiffLineKind::Deletion,
                                old_line: del_old_no,
                                new_line: 0,
                                text: del_text,
                                spans: full,
                                highlights: Vec::new(),
                            });
                        }
                        hunk.old_lines.push(DiffLine {
                            kind: DiffLineKind::Context,
                            old_line: old_no,
                            new_line: new_no,
                            text: text.clone(),
                            spans: Vec::new(),
                            highlights: Vec::new(),
                        });
                        hunk.new_lines.push(DiffLine {
                            kind: DiffLineKind::Context,
                            old_line: old_no,
                            new_line: new_no,
                            text,
                            spans: Vec::new(),
                            highlights: Vec::new(),
                        });
                        old_no += 1;
                        new_no += 1;
                    }
                    GixKind::Remove => {
                        pending_dels.push_back((old_no, text));
                        old_no += 1;
                    }
                    GixKind::Add => {
                        if let Some((del_old_no, del_text)) = pending_dels.pop_front() {
                            // 配对修改：词级 spans
                            let (del_spans, add_spans) = word_spans(&del_text, &text);
                            hunk.old_lines.push(DiffLine {
                                kind: DiffLineKind::Deletion,
                                old_line: del_old_no,
                                new_line: 0,
                                text: del_text,
                                spans: del_spans,
                                highlights: Vec::new(),
                            });
                            hunk.new_lines.push(DiffLine {
                                kind: DiffLineKind::Addition,
                                old_line: 0,
                                new_line: new_no,
                                text,
                                spans: add_spans,
                                highlights: Vec::new(),
                            });
                        } else {
                            // 纯新增行：整行高亮
                            let full = vec![WordSpan {
                                start: 0,
                                end: text.len() as u32,
                            }];
                            hunk.new_lines.push(DiffLine {
                                kind: DiffLineKind::Addition,
                                old_line: 0,
                                new_line: new_no,
                                text,
                                spans: full,
                                highlights: Vec::new(),
                            });
                        }
                        new_no += 1;
                    }
                }
            }
            // 收尾：残留删除行整行高亮
            while let Some((del_old_no, del_text)) = pending_dels.pop_front() {
                let full = vec![WordSpan {
                    start: 0,
                    end: del_text.len() as u32,
                }];
                hunk.old_lines.push(DiffLine {
                    kind: DiffLineKind::Deletion,
                    old_line: del_old_no,
                    new_line: 0,
                    text: del_text,
                    spans: full,
                    highlights: Vec::new(),
                });
            }
            self.hunks.push(hunk);
            Ok(())
        }
        fn finish(self) -> Self::Out {
            self.hunks
        }
    }

    let input = InternedInput::new(
        gix::diff::blob::platform::resource::ByteLinesWithoutTerminator::new(old),
        gix::diff::blob::platform::resource::ByteLinesWithoutTerminator::new(new),
    );
    let mut diff = Diff::compute(Algorithm::Histogram, &input);
    diff.postprocess_lines(&input);
    UnifiedDiff::new(
        &diff,
        &input,
        Collector { hunks: Vec::new() },
        ContextSize::symmetrical(3),
    )
    .consume()
    .expect("hunk collector never errors")
}
