#!/bin/sh
# 一点守护安装脚本：判断系统 → 下载最新版对应格式的包（opkg 用 ipk，apk 用 apk）→ 安装
#   cd /tmp && wget -O install.sh https://gitee.com/xautlx/doti-kids-router/raw/main/install.sh && sh install.sh
LATEST='https://doti-api.entdiy.xyz/doti_rt?dl=latest'
REPO='xautlx/doti-kids-router'
MIRRORS="${DOTI_MIRRORS:-https://gitee.com/$REPO/releases/download
https://gh-proxy.com/https://github.com/$REPO/releases/download
https://ghproxy.net/https://github.com/$REPO/releases/download
https://github.com/$REPO/releases/download}"
TMP=/tmp/doti-install

say() { echo "[一点守护] $*"; }
die() { echo "[一点守护] ✗ $*" >&2; rm -rf "$TMP"; exit 1; }

# 1 系统
[ "$(id -u)" = 0 ] || die "请用 root 账号执行"
[ -r /etc/openwrt_release ] || die "这台路由器不是 OpenWrt 系统，要先刷官方 OpenWrt（22.03 及以上），见 https://doti.entdiy.xyz/quick-start/"
. /etc/openwrt_release
v="$DISTRIB_RELEASE"; maj=${v%%.*}; rest=${v#*.}; min=${rest%%.*}
case "$maj$min" in
*[!0-9]*|"") say "系统版本：$v" ;;
*) if [ "$maj" -lt 22 ] || { [ "$maj" -eq 22 ] && [ "$min" -lt 3 ]; }; then
	die "需要 OpenWrt 22.03 及以上，这台是 $v。请先刷新版本的官方 OpenWrt，见 https://doti.entdiy.xyz/quick-start/"
   fi
   say "系统版本：OpenWrt $v" ;;
esac
if command -v opkg >/dev/null 2>&1; then PM=opkg
elif command -v apk >/dev/null 2>&1; then PM=apk
else die "没找到软件包管理器（opkg 或 apk），这个系统装不了"; fi
nft -v >/dev/null 2>&1 || command -v fw4 >/dev/null 2>&1 || die "这个系统没有 firewall4（nftables），一点守护需要官方 OpenWrt 22.03 及以上"
free=$(df -k /overlay 2>/dev/null | awk 'NR==2 {print $4}')
[ -n "$free" ] && [ "$free" -lt 400 ] && die "路由器剩余空间只有 ${free}KB，至少要 400KB"

# 2 刚开机时网络和防火墙还在初始化，这时下载容易失败
up=$(cut -d. -f1 /proc/uptime)
if [ "$up" -lt 120 ]; then say "路由器刚开机，等 $((120 - up)) 秒再开始……"; sleep $((120 - up)); fi

# 3 最新版本号：从首次安装地址的跳转里读出来
rm -rf "$TMP"; mkdir -p "$TMP"; cd "$TMP" || die "建不了临时目录 $TMP"
tag="${DOTI_TAG:-}"   # DOTI_TAG、DOTI_MIRRORS 测试用
for i in 1 2 3; do
	[ -n "$tag" ] && break
	tag=$(wget -T 30 -O /dev/null "$LATEST" 2>&1 | sed -n 's#.*/releases/download/\(v[0-9][0-9.]*\)/.*#\1#p' | head -1)
	[ -n "$tag" ] && break
	sleep 5
done
[ -n "$tag" ] || die "连不上一点守护的服务器，查不到最新版本。请检查路由器能不能上网，稍后再试"
ver=${tag#v}
if [ "$PM" = apk ]; then FILE="doti-$ver-r1.apk"; else FILE="doti_$ver-1_all.ipk"; fi
say "最新版本：$ver（$FILE）"

# 4 下载：几个下载源轮流试，大小对得上 SHA256SUMS 才算
get() {   # get 文件名 → 成功返回 0
	for m in $MIRRORS; do
		for i in 1 2; do
			rm -f "$1"
			wget -T 60 -O "$1" "$m/$tag/$1" >/dev/null 2>&1 && [ -s "$1" ] && return 0
			sleep 3
		done
	done
	return 1
}
get SHA256SUMS || die "下载失败：几个下载源都连不上。请检查路由器能不能上网，稍后再试"
want=$(awk -v f="$FILE" '$2 == f {print $1}' SHA256SUMS)
[ -n "$want" ] || die "这个版本还没有 $PM 用的安装包，请稍后再试"
ok=""
for m in 1 2; do
	get "$FILE" || break
	[ "$(sha256sum "$FILE" | cut -d' ' -f1)" = "$want" ] && { ok=1; break; }
	say "下载的文件校验不对，重新下载……"
done
[ -n "$ok" ] || die "下载失败或文件校验不对，请稍后再试"

# 5 安装：缺依赖就先更新软件源再装一次
# apk 装本地包也会先下载全部软件源索引，官方源在国内要一两分钟；依赖官方系统都自带，先不联网装，
# 缺依赖再联网，先试国内镜像（临时列表，只对这次安装生效，不改系统的软件源）
MIRROR=https://mirrors.tuna.tsinghua.edu.cn/openwrt
inst() {
	[ "$PM" = apk ] || { opkg install "$TMP/$FILE"; return; }
	if apk add --allow-untrusted --no-network "$TMP/$FILE" > "$TMP/log" 2>&1; then grep -v "^WARNING: opening from cache" "$TMP/log"; return 0; fi
	say "系统缺少依赖，联网安装（先试国内镜像）……"
	cat /etc/apk/repositories.d/*.list 2>/dev/null | sed "s#https*://downloads.openwrt.org#$MIRROR#" > "$TMP/repos"
	[ -s "$TMP/repos" ] && apk add --allow-untrusted --repositories-file "$TMP/repos" "$TMP/$FILE" && return 0
	apk add --allow-untrusted "$TMP/$FILE"
}
say "开始安装……"
if ! inst; then
	say "安装没成功，更新软件源后再试一次……"
	if [ "$PM" = apk ]; then apk update >/dev/null 2>&1; else opkg update >/dev/null 2>&1; fi || \
		die "软件源更新失败：路由器上不了网，或软件源地址连不上。国内网络可以先换清华镜像，见 https://doti.entdiy.xyz/quick-start/"
	inst || die "安装失败，请把上面的出错信息发给客服（小程序「一点守护」→「联系客服」）"
fi
rm -rf "$TMP"
say "✓ 安装完成（$ver）"
say "1–2 分钟后会出现不用密码的 WiFi「DOTI-TEMP-ADMIN」，手机连上它，打开微信小程序「一点守护」按提示绑定。"
say "这个 WiFi 只开 1 小时，超时后断电重开路由器会再开 1 小时。"
