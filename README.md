# doti-kids-router · 一点守护（路由器端）

> 用心一点，给孩子成长守护多一点。

[English](README_en.md)

一点守护是装在家里 OpenWrt 路由器上的孩子上网时间管理：孩子的网**用一会儿、慢一会儿**自动轮换，不用等固定时段；到点只限速、不断网，消息、查资料照常能用。家长在微信小程序「一点守护」里管理，孩子设备上什么都不用装。

这个仓库是路由器端程序（软件包 `doti-kids-router` 和升级程序 `doti-kids-router-updater`），全部开源。

## 了解和安装

产品介绍、系统要求、安装和绑定步骤、核对安装包，都在项目主页和 快速开始 里：

| | 国内访问更快 | GitHub Pages |
|---|---|---|
| 项目主页 | [doti.top](https://doti.top/) | [xautlx.github.io/doti-kids-router](https://xautlx.github.io/doti-kids-router/) |
| 快速开始 | [doti.top/quick-start](https://doti.top/quick-start/) | [xautlx.github.io/doti-kids-router/quick-start](https://xautlx.github.io/doti-kids-router/quick-start/) |

安装包在 [Releases](../../releases)（国内也可以到 gitee 同名仓库的发行版下载）。

## 自行打包

```sh
python3 build.py         # → dist/doti-kids-router_<版本>-1_all.ipk、dist/doti-kids-router-updater_<版本>-1_all.ipk
python3 build.py --apk   # 再打 dist/doti-kids-router-<版本>-r1.apk、dist/doti-kids-router-updater-<版本>-r1.apk（要 apk-tools 3，比如在 Alpine 3.24 里）
```

打包是可复现的：同一份代码在哪打出来都是同一个文件，可以和 Releases 的 `SHA256SUMS` 比对。打 `v<版本>` 标签时 GitHub Actions 自动打包并发布到 Releases；路由器在线升级从这里下载，按签名过的 sha256 核对。

## 目录

| 路径 | 内容 |
|---|---|
| `files/` | 软件包 `doti` 装到路由器上的文件 |
| `updater/` | 升级程序 `doti-kids-router-updater` |
| `build.py` | 打包脚本 |
| `install.sh` | 安装脚本（判断系统、下载对应格式的包、校验、安装） |

## 许可证

[GPL-3.0](LICENSE)。

始终屏蔽名单（`blocklist/always.txt`）的成人、赌博类域名取自 [StevenBlack/hosts](https://github.com/StevenBlack/hosts)（MIT）。
