# VoCat 本地构建与 ARM 部署工具

这个仓库与 VoCat 主仓库分离，只提供可审计的本地构建、交叉编译和 systemd 部署脚本。

默认目标是 Linux ARM64（`aarch64` / `arm64`）主机。构建产物不含自动更新逻辑；是否升级完全由操作者决定。

## 目录

- `scripts/build-local.sh`：在本机构建并测试当前架构的 VoCat。
- `scripts/build-cross.sh`：构建 Linux `arm64` 或 `armv7` 离线部署包。
- `deploy/install-or-upgrade.sh`：在目标 Linux systemd 主机上安装或升级部署包。
- `deploy/vocat.service`：默认的 systemd 服务单元。

## 本机交叉编译 ARM64

先在 VoCat 源码仓库中固定并审查需要构建的提交，再执行：

```bash
cd /home/codex/dev/shell/vocat-tooling
./scripts/build-cross.sh arm64 --source /home/codex/dev/go/VoCat
```

脚本会：

1. 以 `npm ci --ignore-scripts` 安装锁定的前端依赖；
2. 构建嵌入式前端；
3. 运行 `go test ./...` 和 `go vet ./...`；
4. 以 `CGO_ENABLED=0` 交叉编译 Linux ARM 二进制；
5. 创建含二进制、校验和、服务单元和部署脚本的 `tar.gz` 包。

产物位于 `dist/`，示例：`dist/vocat-linux-arm64-<版本>.tar.gz`。

## 在 ARM 主机安装或升级

把部署包上传到 ARM 主机的 `/root`，然后以 root 执行：

```bash
cd /root
tar -xzf vocat-linux-arm64-<版本>.tar.gz
cd vocat-linux-arm64-<版本>
./install-or-upgrade.sh --listen 192.168.1.10:7575
```

首次安装会交互式要求设置管理员密码；升级会保留已有 SQLite 数据库、管理员账号和 `/etc/vocat/env` 中的配置。

默认监听地址为 `0.0.0.0:7575`，方便局域网设备直接访问。请不要配置公网端口转发或 UPnP，并在防火墙中仅放行可信内网来源。

部署脚本默认保留已有 service unit。需要同步本仓库提供的单元文件时，增加 `--replace-service`：

```bash
./install-or-upgrade.sh --replace-service
```

## 安全边界

- 仅构建你已固定提交并审查过的源码；不要以 `master` 最新状态直接上线。
- 部署脚本会验证包内 `SHA256SUMS`，这能发现传输损坏，但不能替代对构建机和源码提交的信任。
- 不启用 VoCat 的自动更新，也不要开启开发者模式或安装插件，除非已单独审计。
- 此脚本面向 systemd Linux，不支持 OpenWrt/procd。
