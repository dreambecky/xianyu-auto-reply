#!/usr/bin/env bash
# 服务器端：应用代码更新 -> 重建容器 -> 健康检查 -> 失败自动回滚
#
# 用法（在服务器项目目录下执行）：
#   ./git-update.sh --bundle /tmp/xianyu-sync.bundle   # 从开发机推来的 bundle 更新（日常，无需 GitHub）
#   ./git-update.sh --pull                             # 从 origin git pull（GitHub 已有内容时）
#   ./git-update.sh --rollback                         # 回退到上一次成功运行的版本
#   ./git-update.sh --bundle xxx --force               # 无新提交也强制重建镜像
#
# 注意：.env.prod / data / logs / backups 已被 .gitignore 排除，git reset --hard 不会动它们。
#       但服务器上「已跟踪文件」的手工改动会被覆盖，改代码请在开发机提交后同步。
set -euo pipefail

# 本脚本自身可能被 git reset --hard 覆盖，先复制一份到 /tmp 再执行
if [ "${GIT_UPDATE_RELOADED:-0}" != "1" ]; then
    PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
    TMP_SCRIPT="$(mktemp /tmp/xianyu-git-update.XXXXXX)"
    cp "$0" "$TMP_SCRIPT"
    chmod 700 "$TMP_SCRIPT"
    export GIT_UPDATE_RELOADED=1 PROJECT_DIR TMP_SCRIPT
    exec bash "$TMP_SCRIPT" "$@"
fi
trap 'rm -f "${TMP_SCRIPT:-}"' EXIT
cd "$PROJECT_DIR"

log()  { printf '\n\033[0;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\n\033[0;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\n\033[0;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
用法: ./git-update.sh [--bundle PATH | --pull | --rollback] [--force]
  --bundle PATH   从开发机 git bundle 同步（推荐，不依赖 GitHub）
  --pull          从 origin git pull --ff-only（需先在开发机 push 到远程仓库）
  --rollback      回退到 backups/last-good-commit 记录的版本
  --force         即使没有新提交也强制重建镜像
EOF
}

MODE="pull"
BUNDLE=""
FORCE=false
while [ $# -gt 0 ]; do
  case "$1" in
    --bundle)   MODE=bundle; BUNDLE="${2:-}"; shift 2 ;;
    --pull)     MODE=pull; shift ;;
    --rollback) MODE=rollback; shift ;;
    --force)    FORCE=true; shift ;;
    --help|-h)  usage; exit 0 ;;
    *)          die "未知参数: $1（用 --help 查看用法）" ;;
  esac
done
[ "$MODE" != bundle ] || [ -n "$BUNDLE" ] || die "--bundle 需要指定 bundle 文件路径"

[ -d .git ]          || die "当前目录不是 git 仓库。请先在开发机执行: ./remote-deploy.sh <目标> --git-init"
[ -f deploy-prod.sh ] || die "缺少 deploy-prod.sh，请确认在项目根目录运行"
mkdir -p backups
GOOD_FILE="backups/last-good-commit"

# 拒绝覆盖服务器上对已跟踪文件的手工改动（未跟踪/被忽略的数据文件不受影响）
DIRTY="$(git status --porcelain --untracked-files=no)"
[ -z "$DIRTY" ] || die "服务器上有未提交的已跟踪文件改动，更新会覆盖它们。请先处理：\n$DIRTY"

OLD="$(git rev-parse HEAD)"
OLD_MSG="$(git log -1 --format='%h %s')"
log "当前版本: $OLD_MSG"

# ── 1. 取得目标版本 ───────────────────────────────────────
case "$MODE" in
  bundle)
    [ -f "$BUNDLE" ] || die "找不到 bundle 文件: $BUNDLE"
    # 带 + 强制更新远端跟踪引用：开发机若做过 rebase / reset 也能同步
    git fetch -q "$BUNDLE" "+main:refs/remotes/sync/main" \
      || die "bundle 读取失败（文件损坏或不含 main 分支）"
    TARGET="$(git rev-parse refs/remotes/sync/main)"
    ;;
  pull)
    if ! git pull --ff-only origin main 2>&1; then
      die "git pull 失败。若远程仓库还是空的，请先在开发机 git push -u origin main；或改用 --bundle 方式同步。"
    fi
    TARGET="$(git rev-parse HEAD)"
    ;;
  rollback)
    [ -f "$GOOD_FILE" ] || die "没有 $GOOD_FILE，无法回退"
    TARGET="$(cat "$GOOD_FILE")"
    git cat-file -e "$TARGET^{commit}" 2>/dev/null || die "$GOOD_FILE 记录的版本不存在: $TARGET"
    ;;
esac

if [ "$TARGET" = "$OLD" ] && [ "$FORCE" != true ]; then
  log "没有新提交（$TARGET），无需更新。加 --force 可强制重建镜像。"
  exit 0
fi

# ── 2. 切换工作区 ─────────────────────────────────────────
if [ "$MODE" != pull ]; then
  git reset --hard -q "$TARGET"
fi
NEW_MSG="$(git log -1 --format='%h %s')"
log "切换到: $NEW_MSG"

# ── 3. 更新前备份数据库（粗略快照，容器运行中） ───────────
if [ -f data/xianyu_data.db ]; then
  DB_BACKUP="backups/xianyu_data-$(date +%Y%m%d-%H%M%S).db"
  cp -a data/xianyu_data.db "$DB_BACKUP"
  log "数据库已备份: $DB_BACKUP"
fi

# ── 4. 重建并健康检查 ─────────────────────────────────────
if ./deploy-prod.sh --rebuild; then
  printf '%s\n' "$TARGET" > "$GOOD_FILE"
  log "更新完成：$OLD_MSG  →  $NEW_MSG"
  printf '  回滚命令: ./git-update.sh --rollback\n'
  printf '  查看变更: git log --oneline %s..%s\n' "${OLD:0:8}" "${TARGET:0:8}"
  exit 0
fi

# ── 5. 失败自动回滚 ───────────────────────────────────────
warn "新版本未通过健康检查，开始回滚到 $OLD_MSG ..."
if [ "$OLD" != "$TARGET" ]; then
  git reset --hard -q "$OLD"
fi
if ./deploy-prod.sh --rebuild; then
  printf '%s\n' "$OLD" > "$GOOD_FILE"
  die "更新失败，但已成功回滚到 $OLD_MSG。请查看上方构建/启动日志排查原因。"
fi
die "更新失败且回滚也失败！当前工作区为 $OLD_MSG，请立即人工介入：./deploy-prod.sh --rebuild"
