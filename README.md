# Cloudflare IP 优选助手 - Linux 通用版

基于 [10000ge10000/cf-ip-speed-panel](https://github.com/10000ge10000/cf-ip-speed-panel) 项目，适配 Linux 通用环境（飞牛系统 fnOS、Debian、Ubuntu、CentOS、群晖等）。

## 功能

- ✅ 自动安装 `cfst` (CloudflareSpeedTest)
- ✅ 设备注册并上传测速结果到原项目服务器
- ✅ 自动检测代理/直连状态
- ✅ 支持 IPv4 / IPv6
- ✅ crontab 定时测速
- ✅ 参与众测 DNS 优选（省份+运营商聚合）

## 一键安装

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/你的仓库/main/install.sh)"
```

或者手动：

```bash
# 下载脚本
curl -fsSL -o install.sh https://raw.githubusercontent.com/你的仓库/main/install.sh
chmod +x install.sh

# 运行安装
./install.sh install
```

## 使用方法

```bash
# 查看帮助
./install.sh help

# 立即测速并上传
./install.sh run

# 查看状态
./install.sh status

# 查看日志
./install.sh logs

# 设置定时任务（默认每天凌晨3点）
./install.sh cron "0 3 * * *"

# 每天3点和15点测速
./install.sh cron "0 3,15 * * *"

# 移除定时任务
./install.sh cron-remove

# 编辑配置
./install.sh config

# 卸载
./install.sh uninstall
```

## 配置文件

安装后配置位于 `/opt/cf-ip-speed/config`：

```bash
# Cloudflare IP 优选助手配置
NICKNAME="你的昵称"
DEVICE_ID="xxx"
DEVICE_TOKEN="xxx"
IP_VERSION="v4"
CFST_ARGS="-n 60 -t 4 -dn 8 -dt 15 -tlr 0 -p 8"
UPLOAD_MAX_NODES="50"
```

## 适配说明

| 组件 | OpenWrt 原版 | Linux 通用版 |
|------|-------------|-------------|
| 测速工具 | cfst (opkg 包) | cfst (独立二进制) |
| 配置管理 | UCI (`uci set/get`) | Shell source 文件 |
| 定时任务 | cron | crontab |
| Web 界面 | LuCI | 命令行 |
| 代理检测 | 检测 OpenWrt 服务 | 检测 tun/wg 接口 |

## API 说明

本脚本使用原项目的公开 API：

- `POST /api/public/register` — 注册设备
- `POST /api/public/upload` — 上传测速结果

数据上传到 `https://cf.6610000.xyz`，参与众测 DNS 优选。

## 系统要求

- Linux（x86_64 / ARM64 / ARMv7 / MIPS）
- `curl` 或 `wget`
- `awk`、`grep`、`tar`
- 网络可访问 Cloudflare IP 段

## 注意事项

- 测速时建议暂停代理软件，否则可能被检测为"疑似代理出口"
- 疑似代理出口的数据不会参与 DNS 优选
- 建议选择凌晨或空闲时段测速，减少对正常使用的影响
