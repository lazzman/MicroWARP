---
name: microwarp-rebase-upstream
description: 安全地将 MicroWARP 当前分支变基到作者仓库 upstream/main，同时保留本地提交、恢复未提交改动，并验证结果。用于同步 ccbkkb/MicroWARP 作者仓库。
---

# MicroWARP 作者仓库同步

本项目固定使用下列远程拓扑：

```text
upstream = https://github.com/ccbkkb/MicroWARP  # 作者仓库；默认拉取与变基基线
origin   = https://github.com/lazzman/MicroWARP # 个人仓库；默认推送目标
```

当前分支的 `branch.<name>.remote` 必须指向 `upstream`，而 `branch.<name>.pushRemote` 必须指向 `origin`。这样：

```bash
git pull      # 从作者仓库拉取
git push      # 推送到个人仓库
```

## 不可违反的规则

- 必须先执行 `git fetch --prune upstream`，再开始 rebase。
- 禁止使用 `git reset --hard`、`git clean -fd`、`git rebase --skip`、普通 `--force` 或丢弃本地提交。
- 若工作树不干净，必须使用 `git stash push --include-untracked`；成功后恢复 stash。
- rebase 冲突中 `--ours` 是 `upstream/main` 基线，`--theirs` 是正在重放的本地提交。先分析三方内容和提交意图，不能机械选择任意一侧。
- 发生冲突时保留现场，不得删除 stash 或中断后静默回退。

## 执行入口

在仓库根目录执行：

```bash
bash .agents/skills/microwarp-rebase-upstream/scripts/rebase_upstream.sh
```

可显式传入作者远程跟踪引用，但必须是 `upstream/*`：

```bash
bash .agents/skills/microwarp-rebase-upstream/scripts/rebase_upstream.sh upstream/main
```

脚本输出 `UPSTREAM`、`ORIGINAL_HEAD`、`STASH_REF` 和 `RESULT`：

- `RESULT=SUCCESS`：rebase 与 stash 恢复都成功；
- `RESULT=CONFLICT`：以退出码 `20` 保留 rebase 冲突现场；
- `RESULT=STASH_CONFLICT`：rebase 已成功，但恢复未提交改动时冲突，以退出码 `21` 保留现场。

## 冲突处理循环

```bash
git status --short
git diff --name-only --diff-filter=U
git diff --check
```

针对每个冲突文件，读取三方内容及正在重放的提交：

```bash
git show :1:path/to/file  # 共同祖先
git show :2:path/to/file  # 作者仓库基线（ours）
git show :3:path/to/file  # 本地正在重放提交（theirs）
git show --stat --oneline REBASE_HEAD
git show REBASE_HEAD -- path/to/file
```

合并双方有效且互不冲突的改动，删除全部冲突标记后：

```bash
git diff --check
git add path/to/resolved-file
GIT_EDITOR=true git rebase --continue
```

完成 rebase 后，如果脚本输出了 `STASH_REF` 但未自动恢复，执行：

```bash
git stash pop "$STASH_REF"
```

若 stash 恢复冲突，按相同三方流程解决，保留恢复后的未提交修改，不要为了工作树干净而强制提交。

## 完成验证与推送

```bash
git status --short
git diff --check
git log --oneline upstream/main..HEAD
git fsck --no-reflogs --no-progress
```

运行与改动相关的测试、静态检查或镜像构建。只有确认测试通过后才推送：

```bash
git push
```

若同步后的已发布分支必须重写个人远程历史，只能使用：

```bash
git push --force-with-lease
```
