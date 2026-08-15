#!/usr/bin/env bash
# 在当前架构本地构建并验证 VoCat。不会提交或修改源码跟踪文件。
set -euo pipefail

usage() {
  printf '%s\n' "用法: $0 [--source <VoCat源码目录>] [--skip-tests]"
}

SOURCE_DIR="${VOCAT_SOURCE_DIR:-/home/codex/dev/go/VoCat}"
SKIP_TESTS=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source) SOURCE_DIR="$2"; shift 2 ;;
    --skip-tests) SKIP_TESTS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf '未知参数: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ ! -f "$SOURCE_DIR/go.mod" ] || [ ! -f "$SOURCE_DIR/web/package-lock.json" ]; then
  printf '不是有效的 VoCat 源码目录: %s\n' "$SOURCE_DIR" >&2
  exit 1
fi

resolve_go() {
  if command -v go >/dev/null 2>&1; then
    command -v go
  elif [ -x /usr/local/go/bin/go ]; then
    printf '%s\n' /usr/local/go/bin/go
  else
    printf '%s\n' '未找到 Go；请安装 Go 1.25 或更高版本。' >&2
    exit 1
  fi
}

GO_BIN="$(resolve_go)"
printf '使用 Go: %s\n' "$($GO_BIN version)"

(
  cd "$SOURCE_DIR/web"
  npm ci --ignore-scripts --no-audit --no-fund
  npm run build
)

if [ "$SKIP_TESTS" -eq 0 ]; then
  (
    cd "$SOURCE_DIR"
    "$GO_BIN" test ./... -count=1
    "$GO_BIN" vet ./...
  )
fi

(
  cd "$SOURCE_DIR"
  "$GO_BIN" build -trimpath -o vocat ./cmd/vocat
)

printf '本机构建完成: %s/vocat\n' "$SOURCE_DIR"

