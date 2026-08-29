//! 逐行/逐 hunk 部分暂存（partial staging）。
//!
//! 数据流（stage_lines）：old=索引 blob，new=工作区 blob，diff 给出变更组。
//! 选中某些 old 侧行号 -> 命中变更组 -> 整组应用到索引（变更组不可拆分，同 git 语义）。
//! unstage_lines 反向：old=HEAD，new=索引，选中 -> 回退到 HEAD。
//!
//! 实现：把 hunk 的 old_lines/new_lines 合并回 unified 顺序 -> 按上下文切组成
//! Context / Change{deletions, additions} -> 单趟遍历构建目标内容（选中组取对应侧，
//! 未选中组取另一侧），不依赖 gix apply。

use std::collections::HashSet;

use crate::diff::{compute_hunks_with, DiffHunk, DiffLineKind};
use crate::error::EngineError;

/// 一次行选择：某个 hunk 内两侧的绝对行号集合（1-based）。
/// 删除行使用 `old_lines`，新增行使用 `new_lines`；两者都为空表示选中
/// 该 hunk 全部变更组（hunk 级）。只要命中变更组任一侧，整组都会被应用，
/// 保持 Git/IntelliJ 的修改组不可拆分语义。
#[derive(uniffi::Record, Clone, Debug)]
pub struct LineSelection {
    pub hunk_index: u32,
    pub old_lines: Vec<u32>,
    pub new_lines: Vec<u32>,
}

/// unified 顺序的一个组：上下文块或变更块。
enum Group {
    Context(Vec<String>),
    Change {
        deletions: Vec<(u32, String)>, // (old_line 1-based, text)
        additions: Vec<(u32, String)>, // (new_line 1-based, text)
    },
}

/// 把 hunk 的 old_lines（context+deletion）与 new_lines（context+addition）合并回
/// unified 顺序，并按上下文切成 Context / Change 组。删除先于新增（unified 惯例）。
fn hunk_groups(hunk: &DiffHunk) -> Vec<Group> {
    let mut groups: Vec<Group> = Vec::new();
    let mut i = 0usize;
    let mut j = 0usize;
    let mut cur_ctx: Vec<String> = Vec::new();
    let mut cur_del: Vec<(u32, String)> = Vec::new();
    let mut cur_add: Vec<(u32, String)> = Vec::new();

    let flush_ctx = |cur: &mut Vec<String>, groups: &mut Vec<Group>| {
        if !cur.is_empty() {
            groups.push(Group::Context(std::mem::take(cur)));
        }
    };
    let flush_change = |cur_del: &mut Vec<(u32, String)>,
                        cur_add: &mut Vec<(u32, String)>,
                        groups: &mut Vec<Group>| {
        if !cur_del.is_empty() || !cur_add.is_empty() {
            groups.push(Group::Change {
                deletions: std::mem::take(cur_del),
                additions: std::mem::take(cur_add),
            });
        }
    };

    while i < hunk.old_lines.len() || j < hunk.new_lines.len() {
        let old_ctx = i < hunk.old_lines.len() && hunk.old_lines[i].kind == DiffLineKind::Context;
        let new_ctx = j < hunk.new_lines.len() && hunk.new_lines[j].kind == DiffLineKind::Context;
        let old_del = i < hunk.old_lines.len() && hunk.old_lines[i].kind == DiffLineKind::Deletion;
        let new_add = j < hunk.new_lines.len() && hunk.new_lines[j].kind == DiffLineKind::Addition;

        // 两侧都是上下文且 old_line 一致 -> 同步上下文（变更组结束）
        if old_ctx && new_ctx && hunk.old_lines[i].old_line == hunk.new_lines[j].old_line {
            flush_change(&mut cur_del, &mut cur_add, &mut groups);
            cur_ctx.push(hunk.old_lines[i].text.clone());
            i += 1;
            j += 1;
        } else if old_del {
            flush_ctx(&mut cur_ctx, &mut groups);
            cur_del.push((hunk.old_lines[i].old_line, hunk.old_lines[i].text.clone()));
            i += 1;
        } else if new_add {
            flush_ctx(&mut cur_ctx, &mut groups);
            cur_add.push((hunk.new_lines[j].new_line, hunk.new_lines[j].text.clone()));
            j += 1;
        } else {
            // 不应发生（diff 一致性破坏）；中止避免死循环/损坏
            break;
        }
    }
    flush_ctx(&mut cur_ctx, &mut groups);
    flush_change(&mut cur_del, &mut cur_add, &mut groups);
    groups
}

/// 单趟构建部分暂存后的内容。
/// - `old`/`new`：两侧字节（stage: old=索引,new=工作区；unstage: old=HEAD,new=索引）
/// - `reverse=false`（stage）：选中组取 new 侧（应用变更），未选中取 old 侧（保持）
/// - `reverse=true`（unstage）：选中组取 old 侧（回退），未选中取 new 侧（保持已暂存）
pub(crate) fn apply_partial(
    old: &[u8],
    new: &[u8],
    selections: &[LineSelection],
    reverse: bool,
) -> Result<String, EngineError> {
    let hunks = compute_hunks_with(old, new, false);
    let old_text = String::from_utf8_lossy(old);
    let old_lines: Vec<&str> = old_text.lines().collect();
    let mut result: Vec<String> = Vec::new();
    let mut old_pos = 0usize; // 0-based，下一个待复制的 old 行

    let sel_by_hunk: std::collections::HashMap<u32, &LineSelection> =
        selections.iter().map(|s| (s.hunk_index, s)).collect();

    for (hi, hunk) in hunks.iter().enumerate() {
        // hunk 之前的未变更 old 行原样复制
        let hunk_start = (hunk.old_start as usize).saturating_sub(1);
        while old_pos < hunk_start && old_pos < old_lines.len() {
            result.push(old_lines[old_pos].to_string());
            old_pos += 1;
        }
        let sel = sel_by_hunk.get(&(hi as u32));
        let sel_old_lines: HashSet<u32> = sel
            .map(|s| s.old_lines.iter().copied().collect())
            .unwrap_or_default();
        let sel_new_lines: HashSet<u32> = sel
            .map(|s| s.new_lines.iter().copied().collect())
            .unwrap_or_default();
        let whole_hunk = sel
            .map(|s| s.old_lines.is_empty() && s.new_lines.is_empty())
            .unwrap_or(false);

        for g in hunk_groups(hunk) {
            match g {
                Group::Context(lines) => {
                    for t in lines {
                        result.push(t);
                        old_pos += 1;
                    }
                }
                Group::Change {
                    deletions,
                    additions,
                } => {
                    // 命中：hunk 级，或删除/新增侧任一行在选择集。
                    // 纯插入变更没有 old line，必须由 new_lines 命中。
                    let hit = whole_hunk
                        || deletions.iter().any(|(ol, _)| sel_old_lines.contains(ol))
                        || additions.iter().any(|(nl, _)| sel_new_lines.contains(nl));
                    // take_new = hit XOR reverse
                    //   stage(reverse=false): hit->取new, !hit->取old
                    //   unstage(reverse=true): hit->取old, !hit->取new
                    let take_new = hit ^ reverse;
                    if take_new {
                        // 应用变更：跳过 old 删除行，加入 new 新增行
                        for _ in &deletions {
                            old_pos += 1;
                        }
                        for (_, a) in additions {
                            result.push(a);
                        }
                    } else {
                        // 保持：保留 old 删除行，丢弃 new 新增行
                        for (_, t) in &deletions {
                            result.push(t.clone());
                            old_pos += 1;
                        }
                    }
                }
            }
        }
    }
    // 末尾未变更 old 行
    while old_pos < old_lines.len() {
        result.push(old_lines[old_pos].to_string());
        old_pos += 1;
    }
    let trailing = if old_text.ends_with('\n') { "\n" } else { "" };
    Ok(result.join("\n") + trailing)
}
