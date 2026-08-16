#!/usr/bin/env bash
# 构建可离线上传到 Linux 主机的 VoCat 部署包。
set -euo pipefail

usage() {
  cat <<'EOF'
用法: build-cross.sh <amd64|x86_64|arm64|armv7> [选项]

选项:
  --source <目录>     VoCat 源码目录（默认 /home/codex/dev/go/VoCat）
  --skip-tests        跳过 Go 测试与 vet（不建议）
  --output <目录>     部署包输出目录（默认本仓库 dist/）
EOF
}

[ "$#" -ge 1 ] || { usage >&2; exit 2; }
case "$1" in
  -h|--help) usage; exit 0 ;;
esac
TARGET="$1"
shift

SOURCE_DIR="${VOCAT_SOURCE_DIR:-/home/codex/dev/go/VoCat}"
OUTPUT_DIR=""
SKIP_TESTS=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source) SOURCE_DIR="$2"; shift 2 ;;
    --output) OUTPUT_DIR="$2"; shift 2 ;;
    --skip-tests) SKIP_TESTS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf '未知参数: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$TARGET" in
  amd64|x86_64)
    GOARCH=amd64
    GOARM=""
    PLATFORM=amd64
    ;;
  arm64|aarch64)
    GOARCH=arm64
    GOARM=""
    PLATFORM=arm64
    ;;
  armv7)
    GOARCH=arm
    GOARM=7
    PLATFORM=armv7
    ;;
  *)
    printf '不支持的目标: %s（支持 amd64、x86_64、arm64、armv7）\n' "$TARGET" >&2
    exit 2
    ;;
esac

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
TOOL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$TOOL_ROOT/dist}"
mkdir -p "$OUTPUT_DIR"

VERSION="$(git -C "$SOURCE_DIR" describe --tags --always --dirty)"
VERSION="${VERSION#v}"
BUILD_TIME="$(git -C "$SOURCE_DIR" show -s --format=%cI HEAD)"
COMMIT="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
BUNDLE_NAME="vocat-linux-${PLATFORM}-${VERSION}"
BUNDLE_DIR="$OUTPUT_DIR/$BUNDLE_NAME"
ARCHIVE="$OUTPUT_DIR/$BUNDLE_NAME.tar.gz"

if [ -e "$BUNDLE_DIR" ] || [ -e "$ARCHIVE" ]; then
  printf '输出已存在，拒绝覆盖: %s\n' "$BUNDLE_NAME" >&2
  exit 1
fi

printf '源码提交: %s\n目标平台: linux/%s\n使用 Go: %s\n' "$COMMIT" "$PLATFORM" "$($GO_BIN version)"

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

mkdir -p "$BUNDLE_DIR"
(
  cd "$SOURCE_DIR"
  CGO_ENABLED=0 GOOS=linux GOARCH="$GOARCH" GOARM="$GOARM" "$GO_BIN" build \
    -trimpath \
    -ldflags "-s -w -X vocat/internal/buildinfo.Version=$VERSION -X vocat/internal/buildinfo.BuildTime=$BUILD_TIME" \
    -o "$BUNDLE_DIR/vocat" \
    ./cmd/vocat
)

install -m 0755 "$TOOL_ROOT/deploy/install-or-upgrade.sh" "$BUNDLE_DIR/install-or-upgrade.sh"
install -m 0644 "$TOOL_ROOT/deploy/vocat.service" "$BUNDLE_DIR/vocat.service"
printf 'source_commit=%s\nsource_version=%s\nbuild_time=%s\ntarget=linux/%s\ngo_version=%s\n' \
  "$COMMIT" "$VERSION" "$BUILD_TIME" "$PLATFORM" "$($GO_BIN version)" > "$BUNDLE_DIR/BUILD-METADATA.txt"
(
  cd "$BUNDLE_DIR"
  sha256sum vocat install-or-upgrade.sh vocat.service BUILD-METADATA.txt > SHA256SUMS
)
tar -C "$OUTPUT_DIR" -czf "$ARCHIVE" "$BUNDLE_NAME"

printf '部署包已生成:\n  %s\nSHA-256:\n  %s\n' "$ARCHIVE" "$(sha256sum "$ARCHIVE" | awk '{print $1}')"
