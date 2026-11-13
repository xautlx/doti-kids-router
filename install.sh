#!/bin/sh
# 一点守护安装脚本：判断系统 → 下载最新版对应格式的包（opkg 用 ipk，apk 用 apk）→ 安装
#   cd /tmp && wget -O install.sh https://gitee.com/xautlx/doti-kids-router/raw/main/install.sh && sh install.sh
LATEST='https://kids-router-api.doti.top/doti_rt?dl=latest'
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
[ -r /etc/openwrt_release ] || die "这台路由器不是 OpenWrt 系统，要先刷官方 OpenWrt（22.03 及以上），见 https://doti.top/quick-start/"
. /etc/openwrt_release
v="$DISTRIB_RELEASE"; maj=${v%%.*}; rest=${v#*.}; min=${rest%%.*}
case "$maj$min" in
*[!0-9]*|"") say "系统版本：$v" ;;
*) if [ "$maj" -lt 22 ] || { [ "$maj" -eq 22 ] && [ "$min" -lt 3 ]; }; then
	die "需要 OpenWrt 22.03 及以上，这台是 $v。请先刷新版本的官方 OpenWrt，见 https://doti.top/quick-start/"
   fi
   say "系统版本：OpenWrt $v" ;;
esac
if command -v opkg >/dev/null 2>&1; then PM=opkg
elif command -v apk >/dev/null 2>&1; then PM=apk
else die "没找到软件包管理器（opkg 或 apk），这个系统装不了"; fi
nft -v >/dev/null 2>&1 || command -v fw4 >/dev/null 2>&1 || die "这个系统没有 firewall4（nftables），一点守护需要官方 OpenWrt 22.03 及以上"
free=$(df -k /overlay 2>/dev/null | awk 'NR==2 {print $4}')
[ -n "$free" ] && [ "$free" -lt 800 ] && die "路由器剩余空间只有 ${free}KB，至少要 800KB（一点守护和它要的门铃组件 mosquitto-client-nossl；最低配置 16MB 闪存、64MB 内存）"

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
if [ "$PM" = apk ]; then FILE="doti-kids-router-$ver-r1.apk"; else FILE="doti-kids-router_$ver-1_all.ipk"; fi
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

# 5 安装：先不联网装（依赖系统都自带时最快）；缺依赖（一般只缺门铃组件）再联网补。
# 联网先试国内镜像，用临时配置（只对这次安装生效，不改系统的软件源），限时；不通再用系统原来的软件源。
# 不按地域判断：路由器不知道自己在哪，按实际连不连得上来选，海外用户镜像不通就自动退回官方源
MIRROR=https://mirrors.tuna.tsinghua.edu.cn/openwrt
VIA=""
# 限时执行：软件源连不上时 opkg update / apk 可能卡很久
lim() { s=$1; shift; "$@" & p=$!; ( sleep "$s"; kill "$p" 2>/dev/null ) & w=$!; wait "$p"; r=$?; kill "$w" 2>/dev/null; return $r; }
# opkg 的临时配置：软件源换成镜像（OPKG_CONF_DIR 让它不读系统的 /etc/opkg/*.conf），索引放临时目录
mkopkg() {
	mkdir -p "$TMP/feeds" "$TMP/lists"
	for f in /etc/opkg/*.conf; do [ -f "$f" ] && sed "s#https*://downloads.openwrt.org#$MIRROR#" "$f" > "$TMP/feeds/${f##*/}"; done
	sed "s#^lists_dir .*#lists_dir ext $TMP/lists#" /etc/opkg.conf > "$TMP/opkg.conf"
	grep -q '^lists_dir' "$TMP/opkg.conf" || echo "lists_dir ext $TMP/lists" >> "$TMP/opkg.conf"
}
mo() { OPKG_CONF_DIR="$TMP/feeds" opkg -f "$TMP/opkg.conf" "$@"; }
inst() {
	if [ "$PM" = opkg ]; then
		# 临时配置的索引目录是空的：这一步不联网，系统已有的官方源索引也不会被用来下载（那样在国内很慢）
		mkopkg
		mo install "$TMP/$FILE" > "$TMP/log" 2>&1 && { cat "$TMP/log"; return 0; }
		say "系统缺少依赖，联网安装（先用国内镜像）……"
		if lim 90 mo update >/dev/null 2>&1 && mo install "$TMP/$FILE"; then VIA=mirror; return 0; fi
		say "国内镜像不通，改用系统的软件源……"
		lim 180 opkg update >/dev/null 2>&1 || return 2
		opkg install "$TMP/$FILE"; return
	fi
	if apk add --allow-untrusted --no-network "$TMP/$FILE" > "$TMP/log" 2>&1; then grep -v "^WARNING: opening from cache" "$TMP/log"; return 0; fi
	say "系统缺少依赖，联网安装（先用国内镜像）……"
	cat /etc/apk/repositories.d/*.list 2>/dev/null | sed "s#https*://downloads.openwrt.org#$MIRROR#" > "$TMP/repos"
	if [ -s "$TMP/repos" ] && lim 120 apk add --allow-untrusted --repositories-file "$TMP/repos" "$TMP/$FILE"; then VIA=mirror; return 0; fi
	say "国内镜像不通，改用系统的软件源……"
	lim 240 apk add --allow-untrusted "$TMP/$FILE"
}
# 1.2.0 以前的包叫 doti、doti-updater：先卸掉旧包再装（设置、绑定在 /etc/doti，不在包里，卸载不删）
old=""
if [ "$PM" = apk ]; then for p in doti-updater doti; do apk info -e "$p" >/dev/null 2>&1 && old="$old $p"; done
else for p in doti-updater doti; do opkg status "$p" 2>/dev/null | grep -q '^Status:.* installed' && old="$old $p"; done; fi
if [ -n "$old" ]; then
	say "换成新的软件包名，先卸掉旧包（设置和绑定保留）：$old"
	if [ "$PM" = apk ]; then apk del $old >/dev/null 2>&1; else opkg remove $old >/dev/null 2>&1; fi
fi
say "开始安装……"
inst; r=$?
[ $r = 2 ] && die "软件源连不上：国内镜像和系统的软件源都连不上，请检查路由器能不能上网，稍后再试"
[ $r = 0 ] || die "安装失败：常见原因是这台路由器的软件源里没有门铃组件 mosquitto-client-nossl，或空间不够（最低 16MB 闪存、64MB 内存，这样的路由器暂不支持）。请把上面的出错信息发给客服（小程序「一点守护」→「联系客服」）"
rm -rf "$TMP"
say "✓ 安装完成（$ver）"
if [ "$VIA" = mirror ]; then
	say "这次是用国内镜像（清华）补装的依赖，系统的软件源没改。平时也想用国内镜像的话，可以运行："
	if [ "$PM" = apk ]; then say "  sed -i 's#https*://downloads.openwrt.org#$MIRROR#' /etc/apk/repositories.d/distfeeds.list"
	else say "  sed -i 's#https*://downloads.openwrt.org#$MIRROR#' /etc/opkg/distfeeds.conf"; fi
fi
if [ -n "$old" ]; then say "原来的设置和绑定都还在，照常使用即可。"; exit 0; fi
code=$(sed -n 's/.*"code": *"\([0-9A-Z]*\)".*/\1/p' /etc/doti/identity.json 2>/dev/null)
say "1–2 分钟后会出现不用密码的 WiFi「DOTI-${code:-编号}-ADMIN」，手机连上它，打开微信小程序「一点守护」按提示绑定。"
say "这个 WiFi 只开 30 分钟，超时后断电重开路由器会再开 30 分钟。"
