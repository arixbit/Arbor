#!/usr/bin/env bash
# Build a deterministic Git repository used by Arbor's UI smoke tests.
#
# The fixture must be identical on every run so an "observable change"
# assertion means something: fixed commit messages, fixed timestamps, fixed
# branch names, and a fixed working-tree state (staged + unstaged + untracked
# + ignored + stash entry).
#
# usage: make-ui-fixture.sh TARGET_DIR
set -euo pipefail

target="${1:?usage: make-ui-fixture.sh TARGET_DIR}"
if [[ -z "${target// }" ]]; then
  echo "target directory must not be empty" >&2
  exit 2
fi

rm -rf -- "$target"
mkdir -p -- "$target"
cd -- "$target"

git init --quiet --initial-branch main
git config user.name "Arbor UI Fixture"
git config user.email "fixture@arbor.invalid"
git config commit.gpgsign false
git config core.autocrlf false

export GIT_AUTHOR_NAME="Arbor UI Fixture"
export GIT_AUTHOR_EMAIL="fixture@arbor.invalid"
export GIT_COMMITTER_NAME="Arbor UI Fixture"
export GIT_COMMITTER_EMAIL="fixture@arbor.invalid"

commit_at() {
  local iso="$1"
  local message="$2"
  export GIT_AUTHOR_DATE="$iso"
  export GIT_COMMITTER_DATE="$iso"
  git add --all
  git commit --quiet --message "$message"
}

printf 'build/\n*.log\n' > .gitignore
mkdir -p src/Core docs

cat > README.md <<'MARKDOWN'
# Arbor UI Fixture

Deterministic repository used by the Arbor UI smoke suite.
MARKDOWN

cat > src/App.swift <<'SWIFT'
struct App {
    let name = "fixture"
}
SWIFT

commit_at "2024-01-01T09:00:00+00:00" "Initial commit"

cat > src/Core/Engine.swift <<'SWIFT'
struct Engine {
    var revision = 1
}
SWIFT

commit_at "2024-01-02T09:00:00+00:00" "Add engine core"

git tag v1.0.0 HEAD

mkdir -p build
printf 'fixture output\n' > build/output.txt
printf 'ignored log line\n' > debug.log

cat > docs/README.md <<'MARKDOWN'
Fixture documentation.
MARKDOWN

commit_at "2024-01-03T09:00:00+00:00" "Document the fixture"

git switch --quiet --create feature/alpha
cat > src/Feature.swift <<'SWIFT'
struct Feature {
    var enabled = true
}
SWIFT

commit_at "2024-01-04T09:00:00+00:00" "Add feature alpha"

git switch --quiet main
git switch --quiet --create bugfix/beta
cat > src/Fix.swift <<'SWIFT'
struct Fix {
    var applied = true
}
SWIFT

commit_at "2024-01-05T09:00:00+00:00" "Fix beta behaviour"

git switch --quiet main

# A stash entry so the Stash / Shelf screen is not empty.
printf 'stashed change\n' >> README.md
git stash push --quiet --message "Fixture stash"
git stash list >/dev/null

# Working-tree state for the Changes screen: one staged, one unstaged,
# one untracked file, and one ignored file.
cat > src/Core/Engine.swift <<'SWIFT'
struct Engine {
    var revision = 2
    var staged = true
}
SWIFT
git add src/Core/Engine.swift

cat > src/App.swift <<'SWIFT'
struct App {
    let name = "fixture"
    let modified = true
}
SWIFT

cat > src/Untracked.swift <<'SWIFT'
struct Untracked {}
SWIFT

printf 'ignored log line\n' > debug.log

# Keep stress-test commits unreachable until the row-layout test moves main
# to their tip, so the regular visual fixture retains its original history.
python3 - <<'PY'
import json
import os
import pathlib
import subprocess

def git(*args, **kwargs):
    return subprocess.check_output(['git', *args], text=True, **kwargs).strip()

parent = git('rev-parse', 'HEAD')
tree = git('rev-parse', 'HEAD^{tree}')
subjects = [
    'UI row 1 short before',
    'UI row 2 long words ' + 'a long commit message that must stay in its own row ' * 12,
    'UI row 3 short middle',
    'UI row 4 中文与表情 ' + '修复日志列表的长提交信息排版 🛠️ ' * 20,
    'UI row 5 line separators first\u2028second\u2029third',
    'UI row 6 short after',
]
commits = []
for index, subject in enumerate(subjects):
    subject = subject.rstrip()
    timestamp = f'2024-01-{index + 6:02d}T09:00:00+00:00'
    environment = dict(os.environ, GIT_AUTHOR_DATE=timestamp, GIT_COMMITTER_DATE=timestamp)
    parent = git('commit-tree', tree, '-p', parent, input=subject + '\n\nFull commit body.\n', env=environment)
    commits.append({'id': parent, 'subject': subject})
pathlib.Path('.git/arbor-ui-log-rows.json').write_text(json.dumps(commits, ensure_ascii=False))
PY

git status --short >/dev/null
echo "fixture ready at $target"
