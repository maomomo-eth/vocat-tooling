#!/usr/bin/env bash
# 从 vocat-tooling GitHub Releases 下载并安装最新 VoCat 部署包。
set -euo pipefail

REPO="${VOCAT_TOOLING_REPO:-maomomo-eth/vocat-tooling}"
TAG=""
LISTEN_ADDR=""
REPLACE_SERVICE=0

usage() {
  cat <<'EOF'
用法: install-latest.sh [选项]

选项:
  --repo <owner/repo>      GitHub 仓库（默认 maomomo-eth/vocat-tooling）
  --tag <release标签>     安装指定 release；默认安装 latest
  --listen <IP:端口>      传给安装脚本，仅首次安装时写入 VOCAT_ADDR
  --replace-service       用包内 vocat.service 覆盖现有 systemd 单元
  -h, --help              显示帮助

环境变量:
  VOCAT_TOOLING_REPO      覆盖默认 GitHub 仓库
  GITHUB_TOKEN            可选，用于提高 GitHub API 访问额度
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    --listen) LISTEN_ADDR="$2"; shift 2 ;;
    --replace-service) REPLACE_SERVICE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf '未知参数: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { printf '请以 root 身份运行，例如：sudo bash install-latest.sh\n' >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { printf '未找到 tar。\n' >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { printf '未找到 sha256sum。\n' >&2; exit 1; }

case "$(uname -m)" in
  x86_64|amd64)
    PLATFORM=amd64
    ;;
  aarch64|arm64)
    PLATFORM=arm64
    ;;
  armv7l|armv7*|armhf)
    PLATFORM=armv7
    ;;
  *)
    printf '不支持的系统架构: %s（支持 x86_64、aarch64、armv7）\n' "$(uname -m)" >&2
    exit 1
    ;;
esac

fetch_stdout() {
  url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl_args=(-fsSL)
    if [ -n "${GITHUB_TOKEN:-}" ]; then
      curl_args+=(-H "Authorization: Bearer $GITHUB_TOKEN")
    fi
    curl "${curl_args[@]}" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget_args=(-qO-)
    if [ -n "${GITHUB_TOKEN:-}" ]; then
      wget_args+=(--header="Authorization: Bearer $GITHUB_TOKEN")
    fi
    wget "${wget_args[@]}" "$url"
  else
    printf '未找到 curl 或 wget。\n' >&2
    exit 1
  fi
}

download_file() {
  url="$1"
  output="$2"
  if command -v curl >/dev/null 2>&1; then
    curl_args=(-fL)
    if [ -n "${GITHUB_TOKEN:-}" ]; then
      curl_args+=(-H "Authorization: Bearer $GITHUB_TOKEN")
    fi
    curl "${curl_args[@]}" -o "$output" "$url"
  else
    wget_args=()
    if [ -n "${GITHUB_TOKEN:-}" ]; then
      wget_args+=(--header="Authorization: Bearer $GITHUB_TOKEN")
    fi
    wget "${wget_args[@]}" -O "$output" "$url"
  fi
}

API_URL="https://api.github.com/repos/$REPO/releases/latest"
if [ -n "$TAG" ]; then
  API_URL="https://api.github.com/repos/$REPO/releases/tags/$TAG"
fi

RELEASE_JSON="$(fetch_stdout "$API_URL")"
ARCHIVE_URL="$(printf '%s\n' "$RELEASE_JSON" | sed -nE "s/.*\"browser_download_url\": \"([^\"]*vocat-linux-${PLATFORM}-[^\"]*\\.tar\\.gz)\".*/\\1/p" | head -n 1)"
CHECKSUM_URL="$(printf '%s\n' "$RELEASE_JSON" | sed -nE 's/.*"browser_download_url": "([^"]*SHA256SUMS\.txt)".*/\1/p' | head -n 1)"

if [ -z "$ARCHIVE_URL" ]; then
  printf 'latest release 中没有适用于 linux/%s 的部署包。\n' "$PLATFORM" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

ARCHIVE_PATH="$TMP_DIR/$(basename "$ARCHIVE_URL")"
printf '下载: %s\n' "$ARCHIVE_URL"
download_file "$ARCHIVE_URL" "$ARCHIVE_PATH"

if [ -n "$CHECKSUM_URL" ]; then
  CHECKSUM_PATH="$TMP_DIR/SHA256SUMS.txt"
  download_file "$CHECKSUM_URL" "$CHECKSUM_PATH"
  ARCHIVE_NAME="$(basename "$ARCHIVE_PATH")"
  if grep -F "  $ARCHIVE_NAME" "$CHECKSUM_PATH" > "$TMP_DIR/SHA256SUMS.selected"; then
    (cd "$TMP_DIR" && sha256sum -c SHA256SUMS.selected)
  else
    printf 'SHA256SUMS.txt 中没有 %s，跳过外层包校验。\n' "$ARCHIVE_NAME" >&2
  fi
else
  printf 'release 未提供 SHA256SUMS.txt，跳过外层包校验。\n' >&2
fi

BUNDLE_NAME="$(tar -tzf "$ARCHIVE_PATH" | sed -n '1s#/.*##p')"
[ -n "$BUNDLE_NAME" ] || { printf '无法识别部署包目录。\n' >&2; exit 1; }
tar -xzf "$ARCHIVE_PATH" -C "$TMP_DIR"

INSTALLER="$TMP_DIR/$BUNDLE_NAME/install-or-upgrade.sh"
[ -x "$INSTALLER" ] || { printf '部署包内缺少可执行安装脚本。\n' >&2; exit 1; }

INSTALL_ARGS=()
if [ -n "$LISTEN_ADDR" ]; then
  INSTALL_ARGS+=(--listen "$LISTEN_ADDR")
fi
if [ "$REPLACE_SERVICE" -eq 1 ]; then
  INSTALL_ARGS+=(--replace-service)
fi

"$INSTALLER" "${INSTALL_ARGS[@]}"
