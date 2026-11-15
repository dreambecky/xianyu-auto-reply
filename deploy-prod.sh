#!/usr/bin/env bash
# 生产部署脚本：构建镜像 -> 启动容器 -> 等待健康 -> 首次安全加固
# 用法：
#   chmod +x deploy-prod.sh && ./deploy-prod.sh          # 首次部署 / 常规重启
#   ./deploy-prod.sh --rebuild                          # 代码更新后强制重新构建镜像
#
# 首次生成 .env.prod 时可通过环境变量覆盖（仅首次生效）：
#   WEB_BIND=0.0.0.0 MEMORY_LIMIT=1024 CPU_LIMIT=1.0 ./deploy-prod.sh
set -euo pipefail

cd "$(dirname "$0")"
PROJECT_DIR="$(pwd)"
ENV_FILE="$PROJECT_DIR/.env.prod"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.prod.yml"
IMAGE="xianyu-auto-reply-fix:prod"

log()  { printf '\n\033[0;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\n\033[0;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\n\033[0;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# ── 1. 前置检查与 Docker 权限自适应 ──────────────────────
command -v docker >/dev/null 2>&1 || die "未安装 Docker，请先安装 Docker Engine 20.10+"
command -v python3 >/dev/null 2>&1 || die "需要 python3（用于生成密钥）"
[ -f "$COMPOSE_FILE" ] || die "缺少 $COMPOSE_FILE，请在项目根目录运行"
[ -f "Start.py" ] || die "当前目录不是项目根目录"

# 某些云主机（如 ubuntu 用户不在 docker 组）需要 sudo 才能访问 daemon
if docker info >/dev/null 2>&1; then
    DOCKER=(docker)
elif command -v sudo >/dev/null 2>&1 && sudo -n docker info >/dev/null 2>&1; then
    DOCKER=(sudo -n docker)
    log "当前用户无 docker 组权限，改用 sudo 调用 Docker"
else
    die "无法访问 Docker daemon。请把当前用户加入 docker 组，或配置免密 sudo。"
fi
DOCKER_DISPLAY="${DOCKER[*]}"
"${DOCKER[@]}" compose version >/dev/null 2>&1 || die "缺少 Docker Compose v2 插件"
compose() { "${DOCKER[@]}" compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"; }
echo "项目目录: $PROJECT_DIR   Docker: $DOCKER_DISPLAY"

# ── 2. 生成 / 复用配置 ────────────────────────────────────
# 先捕获外部传入的覆盖值（source .env.prod 会覆盖同名变量）
CFG_WEB_BIND="${WEB_BIND:-127.0.0.1}"
CFG_WEB_PORT="${WEB_PORT:-9000}"
CFG_MEM="${MEMORY_LIMIT:-2048}"
CFG_CPU="${CPU_LIMIT:-2.0}"

if [ ! -f "$ENV_FILE" ]; then
    FERNET_KEY="$(python3 -c 'import base64,os;print(base64.urlsafe_b64encode(os.urandom(32)).decode())')"
    ADMIN_PWD="$(python3 -c 'import secrets;print(secrets.token_urlsafe(24))')"
    cat > "$ENV_FILE" <<EOF
WEB_BIND=$CFG_WEB_BIND
WEB_PORT=$CFG_WEB_PORT
BUILD_DOCKERFILE=Dockerfile-cn
BASE_IMAGE=python:3.11-slim-bookworm
NODE_IMAGE=node:24.22.2-bookworm-slim
LOG_LEVEL=INFO
MEMORY_LIMIT=$CFG_MEM
CPU_LIMIT=$CFG_CPU
SECRET_ENCRYPTION_KEY=$FERNET_KEY
ADMIN_PASSWORD=$ADMIN_PWD
EOF
    chmod 600 "$ENV_FILE"
    log "已生成 .env.prod（监听 $CFG_WEB_BIND:$CFG_WEB_PORT，内存 ${CFG_MEM}M / CPU ${CFG_CPU} 核）"
else
    log "复用已有 .env.prod（不会覆盖现有密钥）"
fi

# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a
: "${SECRET_ENCRYPTION_KEY:?请在 .env.prod 中配置 SECRET_ENCRYPTION_KEY}"
: "${ADMIN_PASSWORD:?请在 .env.prod 中配置 ADMIN_PASSWORD}"
WEB_PORT="${WEB_PORT:-9000}"
WEB_BIND="${WEB_BIND:-127.0.0.1}"
DB_FILE="$PROJECT_DIR/data/xianyu_data.db"

# ── 3. 持久化目录 ─────────────────────────────────────────
mkdir -p data logs backups static/uploads/images
chmod 700 data backups
FIRST_RUN=false
[ -f "$DB_FILE" ] || FIRST_RUN=true
log "数据目录就绪（首次部署: $FIRST_RUN）"

# ── 4. 构建并启动 ─────────────────────────────────────────
if [ "${1:-}" = "--rebuild" ] || ! "${DOCKER[@]}" image inspect "$IMAGE" >/dev/null 2>&1; then
    log "构建镜像（首次构建需下载 Chromium 与系统依赖，约 5-15 分钟）"
    compose up -d --build
else
    log "复用已有镜像启动"
    compose up -d
fi

# ── 5. 等待健康检查 ──────────────────────────────────────
HEALTHY=false
for _ in $(seq 1 60); do
    if compose exec -T xianyu-app curl -fsS http://127.0.0.1:8090/health >/dev/null 2>&1; then
        HEALTHY=true
        break
    fi
    sleep 3
done
if [ "$HEALTHY" != true ]; then
    compose logs --tail=120 || true
    die "服务未通过健康检查，请查看上方日志"
fi
log "服务健康检查通过"

# ── 6. 首次部署安全加固 ──────────────────────────────────
# 本版本代码并未读取 ADMIN_PASSWORD / JWT_SECRET_KEY 环境变量，
# 管理员密码硬编码 admin123，注册开关也存在数据库 system_settings 表中。
# 加固在容器内以 root 执行 SQL，避免宿主机用户对 root 写入的 SQLite 文件无写权限。
if [ "$FIRST_RUN" = true ]; then
    PY_CODE='
import hashlib, os, sqlite3
db_path = os.getenv("DB_PATH", "/app/data/xianyu_data.db")
pwd = os.environ["NEW_ADMIN_PASSWORD"]
conn = sqlite3.connect(db_path, timeout=30)
cur = conn.cursor()
cur.execute("UPDATE users SET password_hash = ?, updated_at = CURRENT_TIMESTAMP WHERE username = ?",
            (hashlib.sha256(pwd.encode()).hexdigest(), "admin"))
for key, desc in (("registration_enabled", "是否开启用户注册"),
                  ("show_default_login_info", "是否显示默认登录信息")):
    cur.execute("INSERT OR IGNORE INTO system_settings (key, value, description) VALUES (?, ?, ?)",
                (key, "false", desc))
    cur.execute("UPDATE system_settings SET value = ? WHERE key = ?", ("false", key))
conn.commit()
conn.close()
print("hardened: admin password rotated, registration disabled, default login hint hidden")
'
    compose exec -T -e NEW_ADMIN_PASSWORD="$ADMIN_PASSWORD" xianyu-app python -c "$PY_CODE" \
        || die "首次安全加固失败，请勿在未改默认密码的情况下把服务暴露到公网"
    compose restart xianyu-app >/dev/null
    for _ in $(seq 1 40); do
        if compose exec -T xianyu-app curl -fsS http://127.0.0.1:8090/health >/dev/null 2>&1; then
            break
        fi
        sleep 3
    done
    log "首次加固完成：默认密码已替换、注册已关闭、登录页默认凭据提示已隐藏"
else
    warn "非首次部署，跳过密码重置（沿用 .env.prod 中记录的 ADMIN_PASSWORD）"
fi

# ── 7. 输出结果 ──────────────────────────────────────────
if [ "$WEB_BIND" = "127.0.0.1" ]; then
    ACCESS_HINT="仅回环，需宿主机 Nginx 反代或 SSH 隧道"
    NEXT_STEP="1) 配置 Nginx + HTTPS，或用 SSH 隧道访问"
else
    ACCESS_HINT="公网监听（HTTP 明文，请尽快限制来源 IP / 上 HTTPS）"
    NEXT_STEP="1) 在云控制台放行 ${WEB_PORT} 端口，并限制来源 IP 或改走 HTTPS"
fi
printf '\n'
printf '\033[0;36m════════════════════════════════════════════════════════════\033[0m\n'
printf '\033[0;36m  部署完成\033[0m\n'
printf '\033[0;36m════════════════════════════════════════════════════════════\033[0m\n'
printf '  监听地址     : %s:%s （%s）\n' "$WEB_BIND" "$WEB_PORT" "$ACCESS_HINT"
printf '  资源上限     : %sM 内存 / %s 核 CPU\n' "${MEMORY_LIMIT:-2048}" "${CPU_LIMIT:-2.0}"
printf '  管理员账号   : admin\n'
printf '  管理员密码   : %s\n' "$ADMIN_PASSWORD"
printf '  配置与密钥   : %s\n' "$ENV_FILE"
printf '  健康检查     : curl http://127.0.0.1:%s/health\n' "$WEB_PORT"
printf '\n'
printf '  下一步：\n'
printf '   %s\n' "$NEXT_STEP"
printf '   2) 浏览器登录后台，添加一个闲鱼测试账号，确认消息能收到\n'
printf '   3) 配置自动回复 / 发货规则，用小号先跑通再上正式账号\n'
printf '   4) 备份 .env.prod：SECRET_ENCRYPTION_KEY 丢失将无法解密已存 Cookie\n'
printf '   5) 若容器反复重启（OOM），把 .env.prod 的 MEMORY_LIMIT 调大后重新 up -d\n'
printf '\n'
printf '  常用命令：\n'
printf '   日志   %s compose --env-file .env.prod -f docker-compose.prod.yml logs -f\n' "$DOCKER_DISPLAY"
printf '   状态   %s compose --env-file .env.prod -f docker-compose.prod.yml ps\n' "$DOCKER_DISPLAY"
printf '   停止   %s compose --env-file .env.prod -f docker-compose.prod.yml down\n' "$DOCKER_DISPLAY"
printf '   升级   git pull && ./deploy-prod.sh --rebuild\n'
printf '\033[0;36m════════════════════════════════════════════════════════════\033[0m\n'
