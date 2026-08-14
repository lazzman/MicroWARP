#!/usr/bin/env bash
# 将当前分支安全重放到 MicroWARP 作者仓库的最新提交。
set -euo pipefail

readonly AUTHOR_REMOTE="upstream"
readonly DEFAULT_UPSTREAM="upstream/main"
readonly PERSONAL_REMOTE="origin"

usage() {
    cat <<'USAGE'
用法: rebase_upstream.sh [upstream/<branch>]

默认目标为 upstream/main。脚本会保护未提交和未跟踪改动，先抓取作者仓库，
再开始 rebase。发生冲突时保留现场并以退出码 20 返回。
USAGE
}

result() { printf 'RESULT=%s\n' "$1"; }

fail() {
    printf 'ERROR=%s\n' "$1" >&2
    result "FAILED"
    exit 1
}

in_git_dir() {
    test -e "$(git rev-parse --git-path "$1")"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if [[ $# -gt 1 ]]; then
    usage >&2
    exit 64
fi

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "当前目录不是 Git 工作树"

branch="$(git branch --show-current)"
[[ -n "$branch" ]] || fail "当前处于 detached HEAD，无法安全重放本地分支提交"

if in_git_dir rebase-merge || in_git_dir rebase-apply || in_git_dir MERGE_HEAD || in_git_dir CHERRY_PICK_HEAD; then
    fail "仓库已有未完成的 rebase、merge 或 cherry-pick；请先解决现有操作"
fi

git remote get-url "$AUTHOR_REMOTE" >/dev/null 2>&1 || fail "缺少作者远程仓库: ${AUTHOR_REMOTE}"
git remote get-url "$PERSONAL_REMOTE" >/dev/null 2>&1 || fail "缺少个人推送远程仓库: ${PERSONAL_REMOTE}"

upstream="${1:-$DEFAULT_UPSTREAM}"
[[ "$upstream" == "${AUTHOR_REMOTE}/"* ]] || fail "项目同步只能基于 ${AUTHOR_REMOTE}/*，收到: ${upstream}"

# 安全 rebase 的前置条件：绝不依赖过期的远程跟踪引用。
printf 'FETCH_REMOTE=%s\n' "$AUTHOR_REMOTE"
git fetch --prune "$AUTHOR_REMOTE"
git rev-parse --verify --quiet "${upstream}^{commit}" >/dev/null || fail "无法解析目标上游: ${upstream}"

original_head="$(git rev-parse HEAD)"
stash_ref=""
stash_commit=""
if [[ -n "$(git status --porcelain)" ]]; then
    stash_label="microwarp-rebase-upstream-${branch}-$(date +%Y%m%d%H%M%S)"
    git stash push --include-untracked --message "$stash_label" >/dev/null
    stash_ref="stash@{0}"
    stash_commit="$(git rev-parse --verify refs/stash)"
fi

git config rerere.enabled true

printf 'BRANCH=%s\n' "$branch"
printf 'UPSTREAM=%s\n' "$upstream"
printf 'PUSH_REMOTE=%s\n' "$PERSONAL_REMOTE"
printf 'ORIGINAL_HEAD=%s\n' "$original_head"
printf 'STASH_REF=%s\n' "${stash_ref:-none}"
printf 'STASH_COMMIT=%s\n' "${stash_commit:-none}"

if ! git rebase "$upstream"; then
    if in_git_dir rebase-merge || in_git_dir rebase-apply; then
        printf 'CONFLICT_FILES=\n'
        git diff --name-only --diff-filter=U
        result "CONFLICT"
        exit 20
    fi
    fail "git rebase 执行失败，但未进入可解决的冲突状态"
fi

if [[ -n "$stash_ref" ]]; then
    if ! git stash pop "$stash_ref"; then
        printf 'CONFLICT_FILES=\n'
        git diff --name-only --diff-filter=U
        result "STASH_CONFLICT"
        exit 21
    fi
fi

printf 'REBASED_HEAD=%s\n' "$(git rev-parse HEAD)"
result "SUCCESS"
