# VoCat 本地构建与 ARM 部署工具

这个仓库与 [VoCat 主仓库](https://github.com/MengMengCode/VoCat) 分离，只提供可审计的本地构建、交叉编译和 systemd 部署脚本。

默认目标是 Linux `amd64`、`arm64` 或 `armv7` 主机。构建产物不含自动更新逻辑；是否升级完全由操作者决定。

## 仓库地址

- 部署工具：<https://github.com/maomomo-eth/vocat-tooling>
- VoCat 主仓库：<https://github.com/MengMengCode/VoCat>

下面的流程将从这两个 GitHub 仓库开始。建议始终以固定的 VoCat 提交构建，而不是未经审查地部署 `master` 最新代码。

## 前置条件

构建机需要：

- Linux、macOS 或 WSL；
- Go 1.25 或更高版本；
- Node.js 20 或更高版本及 npm；
- Git、`tar`、`sha256sum`；
- 能以 SSH/SCP 连接 ARM 目标主机。

目标机需要运行 Linux 和 systemd，且安装操作须以 root 执行。本工具不支持 OpenWrt/procd。

## 目录

- `scripts/build-local.sh`：在本机构建并测试当前架构的 VoCat。
- `scripts/build-cross.sh`：构建 Linux `amd64`、`arm64` 或 `armv7` 离线部署包。
- `deploy/install-latest.sh`：从 GitHub Releases 拉取最新部署包并安装或升级。
- `deploy/install-or-upgrade.sh`：在目标 Linux systemd 主机上安装或升级部署包。
- `deploy/vocat.service`：默认的 systemd 服务单元。

## 从 GitHub 获取源码

在构建机上将两个仓库放在同一父目录：

```bash
mkdir -p ~/vocat-build
cd ~/vocat-build
git clone https://github.com/maomomo-eth/vocat-tooling.git
git clone https://github.com/MengMengCode/VoCat.git
```

首次构建前，查看并固定要使用的 VoCat 提交：

```bash
cd ~/vocat-build/VoCat
git log --oneline -20
git checkout <已审查的提交哈希>
```

需要评估新版时，不直接升级；先拉取、查看提交与差异：

```bash
git fetch origin
git log --oneline HEAD..origin/master
git diff --stat HEAD..origin/master
git diff HEAD..origin/master
```

确认后才执行 `git checkout <新的提交哈希>`。

## 构建 Linux 部署包

回到部署工具仓库，构建 x86_64/amd64 离线包：

```bash
cd ~/vocat-build/vocat-tooling
./scripts/build-cross.sh amd64 --source ~/vocat-build/VoCat
```

构建 ARM64 离线包：

```bash
./scripts/build-cross.sh arm64 --source ~/vocat-build/VoCat
```

脚本会：

1. 以 `npm ci --ignore-scripts` 安装锁定的前端依赖；
2. 构建嵌入式前端；
3. 运行 `go test ./...` 和 `go vet ./...`；
4. 以 `CGO_ENABLED=0` 交叉编译 Linux 二进制；
5. 创建含二进制、校验和、服务单元和部署脚本的 `tar.gz` 包。

产物位于 `dist/`，示例：`dist/vocat-linux-amd64-<版本>.tar.gz`、`dist/vocat-linux-arm64-<版本>.tar.gz`。

对于 32 位 ARMv7 目标，改为：

```bash
./scripts/build-cross.sh armv7 --source ~/vocat-build/VoCat
```

如需在构建机当前架构直接构建可运行二进制，可使用：

```bash
./scripts/build-local.sh --source ~/vocat-build/VoCat
```

## 从 GitHub Releases 一键安装或升级

在目标 Linux systemd 主机上以 root 执行：

```bash
curl -fsSL https://raw.githubusercontent.com/maomomo-eth/vocat-tooling/main/deploy/install-latest.sh | bash
```

或使用 `wget`：

```bash
wget -qO- https://raw.githubusercontent.com/maomomo-eth/vocat-tooling/main/deploy/install-latest.sh | bash
```

脚本会自动识别 `x86_64`、`aarch64` 或 `armv7`，下载最新 release 中匹配的 `vocat-linux-<平台>-<版本>.tar.gz`，如 release 提供 `SHA256SUMS.txt` 则先校验外层包，再执行包内安装脚本。

首次安装时可指定监听地址：

```bash
curl -fsSL https://raw.githubusercontent.com/maomomo-eth/vocat-tooling/main/deploy/install-latest.sh | bash -s -- --listen 192.168.1.10:7575
```

安装指定 release：

```bash
curl -fsSL https://raw.githubusercontent.com/maomomo-eth/vocat-tooling/main/deploy/install-latest.sh | bash -s -- --tag <release标签>
```

## 上传部署包到 ARM 主机

将刚生成的部署包上传到目标主机的 `/root`。将示例中的 IP 改为你的 ARM 主机地址：

```bash
cd ~/vocat-build/vocat-tooling
scp dist/vocat-linux-arm64-*.tar.gz root@192.168.1.10:/root/
```

上传完成后可比对本地和远端文件哈希：

```bash
sha256sum dist/vocat-linux-arm64-*.tar.gz
ssh root@192.168.1.10 'sha256sum /root/vocat-linux-arm64-*.tar.gz'
```

## 在 ARM 主机首次安装

登录 ARM 主机后解压并执行安装脚本：

```bash
cd /root
tar -xzf vocat-linux-arm64-<版本>.tar.gz
cd vocat-linux-arm64-<版本>
./install-or-upgrade.sh
```

首次安装会交互式要求设置管理员密码。程序默认监听 `0.0.0.0:7575`，安装完成后在局域网浏览器访问：

```text
http://<ARM主机内网IP>:7575
```

如果希望首次安装时指定其他监听地址：

```bash
./install-or-upgrade.sh --listen 192.168.1.10:7575
```

安装后检查服务与日志：

```bash
systemctl status vocat
journalctl -u vocat -n 100 --no-pager
```

## 手动升级

升级前重复“评估新版 → 固定提交 → 交叉编译 → 上传”的步骤。目标主机上执行新包内的同一个脚本即可：

```bash
cd /root
tar -xzf vocat-linux-arm64-<新版本>.tar.gz
cd vocat-linux-arm64-<新版本>
./install-or-upgrade.sh
```

升级会保留 `/opt/vocat/data/vocat.db`、管理员账号和 `/etc/vocat/env`。脚本会先验证包内 `SHA256SUMS`，并保留上一个二进制用于启动失败后的恢复。

如果要更改监听地址，编辑配置文件后重启服务：

```bash
sed -i 's/^VOCAT_ADDR=.*/VOCAT_ADDR=0.0.0.0:7575/' /etc/vocat/env
systemctl restart vocat
```

部署脚本默认保留已有 service unit。需要同步本仓库提供的单元文件时，增加 `--replace-service`：

```bash
./install-or-upgrade.sh --replace-service
```

## 安全边界

- 仅构建你已固定提交并审查过的源码；不要以 `master` 最新状态直接上线。
- 部署脚本会验证包内 `SHA256SUMS`，这能发现传输损坏，但不能替代对构建机和源码提交的信任。
- 不启用 VoCat 的自动更新，也不要开启开发者模式或安装插件，除非已单独审计。
- `0.0.0.0:7575` 适合局域网，不应配置公网端口转发或 UPnP；请用主机防火墙限制可信内网来源。
