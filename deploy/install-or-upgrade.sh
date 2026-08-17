#!/usr/bin/env bash
# 在 Linux systemd ARM 主机安装或升级由 build-cross.sh 生成的离线部署包。
set -euo pipefail

INSTALL_ROOT=/opt/vocat
BIN_DIR="$INSTALL_ROOT/bin"
DATA_DIR="$INSTALL_ROOT/data"
BIN_PATH="$BIN_DIR/vocat"
ENV_DIR=/etc/vocat
ENV_FILE="$ENV_DIR/env"
UNIT_PATH=/etc/systemd/system/vocat.service
BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LISTEN_ADDR=""
REPLACE_SERVICE=0

usage() {
  cat <<'EOF'
用法: ./install-or-upgrade.sh [选项]

选项:
  --listen <IP:端口>    首次安装时写入 VOCAT_ADDR；默认 0.0.0.0:7575
  --replace-service     用包内 vocat.service 覆盖现有 systemd 单元
  -h, --help            显示帮助
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --listen) LISTEN_ADDR="$2"; shift 2 ;;
    --replace-service) REPLACE_SERVICE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf '未知参数: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { printf '请以 root 身份运行。\n' >&2; exit 1; }
command -v systemctl >/dev/null 2>&1 || { printf '此脚本仅支持 systemd 主机。\n' >&2; exit 1; }
[ -d /run/systemd/system ] || { printf '当前系统未运行 systemd。\n' >&2; exit 1; }
[ -x "$BUNDLE_DIR/vocat" ] || { printf '包内缺少可执行文件: %s/vocat\n' "$BUNDLE_DIR" >&2; exit 1; }
[ -f "$BUNDLE_DIR/vocat.service" ] || { printf '包内缺少 vocat.service。\n' >&2; exit 1; }
[ -f "$BUNDLE_DIR/SHA256SUMS" ] || { printf '包内缺少 SHA256SUMS。\n' >&2; exit 1; }

(
  cd "$BUNDLE_DIR"
  sha256sum -c SHA256SUMS
)
"$BUNDLE_DIR/vocat" version

install_runtime_dependencies() {
  local missing=""
  command -v ip >/dev/null 2>&1 || missing="$missing iproute2"
  command -v qmi-network >/dev/null 2>&1 || missing="$missing libqmi-utils"
  if ! command -v busybox >/dev/null 2>&1 && ! command -v udhcpc >/dev/null 2>&1; then
    missing="$missing busybox"
  fi
  [ -n "$missing" ] || return 0

  printf '正在安装运行依赖:%s\n' "$missing"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y $missing
  elif command -v dnf >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    dnf install -y $missing
  elif command -v yum >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    yum install -y $missing
  elif command -v pacman >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    pacman -Sy --noconfirm $missing
  elif command -v apk >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    apk add --no-cache $missing
  elif command -v opkg >/dev/null 2>&1; then
    opkg update >/dev/null 2>&1 || true
    # shellcheck disable=SC2086
    opkg install $missing
  else
    printf '无法自动安装依赖，请手动安装:%s\n' "$missing" >&2
    exit 1
  fi
}

if [ -n "$LISTEN_ADDR" ]; then
  case "$LISTEN_ADDR" in
    *:*) ;;
    *) printf '监听地址必须是 IP:端口，例如 192.168.1.10:7575。\n' >&2; exit 2 ;;
  esac
fi

NEW_DATABASE=0
if [ ! -f "$DATA_DIR/vocat.db" ]; then
  NEW_DATABASE=1
fi

install_runtime_dependencies
systemctl stop vocat 2>/dev/null || true

install -d -m 0755 "$BIN_DIR"
install -d -m 0750 "$DATA_DIR"
install -d -m 0755 "$ENV_DIR"

# 用候选二进制预先打开并迁移数据库。已有管理员时随机输入不会覆盖凭据；
# 首次安装时由操作者设置密码，密码只通过 stdin 传入。
if [ "$NEW_DATABASE" -eq 1 ]; then
  printf '首次安装：请设置 VoCat 管理员密码。\n' >&2
  read -r -s -p '管理员密码: ' BOOTSTRAP_PASSWORD
  printf '\n' >&2
  [ -n "$BOOTSTRAP_PASSWORD" ] || { printf '密码不能为空。\n' >&2; exit 1; }
else
  BOOTSTRAP_PASSWORD="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
fi
printf '%s\n' "$BOOTSTRAP_PASSWORD" | "$BUNDLE_DIR/vocat" bootstrap-admin \
  --database "$DATA_DIR/vocat.db" --username admin >/dev/null
unset BOOTSTRAP_PASSWORD

if [ -f "$BIN_PATH" ]; then
  cp -a "$BIN_PATH" "$BIN_PATH.previous"
fi
install -m 0755 "$BUNDLE_DIR/vocat" "$BIN_PATH.new"
mv -f "$BIN_PATH.new" "$BIN_PATH"
ln -sfn "$BIN_PATH" /usr/local/bin/vocat

if [ ! -f "$ENV_FILE" ]; then
  : "${LISTEN_ADDR:=0.0.0.0:7575}"
  printf 'VOCAT_ADDR=%s\nVOCAT_DATABASE_PATH=%s\nVOCAT_SECURE_COOKIES=false\n' \
    "$LISTEN_ADDR" "$DATA_DIR/vocat.db" > "$ENV_FILE"
  chmod 0600 "$ENV_FILE"
elif [ -n "$LISTEN_ADDR" ]; then
  printf '%s\n' "检测到现有 $ENV_FILE；为避免覆盖配置，未修改监听地址。请手动更新 VOCAT_ADDR。" >&2
fi

if [ ! -f "$UNIT_PATH" ] || [ "$REPLACE_SERVICE" -eq 1 ]; then
  if [ -f "$UNIT_PATH" ]; then
    cp -a "$UNIT_PATH" "$UNIT_PATH.previous"
  fi
  install -m 0644 "$BUNDLE_DIR/vocat.service" "$UNIT_PATH"
fi

systemctl daemon-reload
systemctl enable vocat >/dev/null
if systemctl restart vocat && systemctl is-active --quiet vocat; then
  rm -f "$BIN_PATH.previous"
  printf 'VoCat 已安装/升级并启动。\n'
  printf '状态: systemctl status vocat\n'
  printf '配置: %s\n' "$ENV_FILE"
  exit 0
fi

printf '新版本启动失败。' >&2
if [ -f "$BIN_PATH.previous" ]; then
  printf '正在恢复上一个二进制。\n' >&2
  cp -a "$BIN_PATH.previous" "$BIN_PATH"
  systemctl restart vocat || true
fi
printf '请查看日志: journalctl -u vocat -n 100 --no-pager\n' >&2
exit 1
