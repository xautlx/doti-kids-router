#!/bin/sh
# 一点守护安装脚本：判断系统 → 下载最新版对应格式的包（opkg 用 ipk，apk 用 apk）→ 安装
#   cd /tmp && wget -O install.sh https://gitee.com/xautlx/doti-kids-router/raw/main/install.sh && sh install.sh
#   出厂预装：DOTI_PREINSTALL=1 DOTI_ROOTPW=<出厂默认 root 密码> sh install.sh
LATEST='https://kids-router-api.doti.top/doti_rt?dl=latest'
REPO='xautlx/doti-kids-router'
MIRRORS="${DOTI_MIRRORS:-https://gitee.com/$REPO/releases/download
https://gh-proxy.com/https://github.com/$REPO/releases/download
https://ghproxy.net/https://github.com/$REPO/releases/download
https://github.com/$REPO/releases/download}"
TMP=/tmp/doti-install

ETCD=${DOTI_ETC:-/etc/doti}; SHARE=${DOTI_SHARE:-/usr/share/doti}; UPD_BIN=${DOTI_UPDATER:-/usr/sbin/doti-update}   # 测试用

say() { echo "[一点守护] $*"; }
die() { echo "[一点守护] ✗ $*" >&2; rm -rf "$TMP"; exit 1; }

# 升级程序（每日报到、在线升级）：主程序包里带着，装完主程序接着装（缺依赖时和主程序一样联网补；已装的同版本不动，旧的升级到包里这一版）。
# 装不上不算安装失败：管控程序照常工作、自己每天报到，之后每 6 小时在后台再试着补装
upd_step() {
	if [ "$PM" = apk ]; then UF=$SHARE/doti-updater.apk; else UF=$SHARE/doti-updater.ipk; fi
	if [ -f "$UF" ]; then
		if [ -x "$UPD_BIN" ]; then say "更新升级程序……"; else say "安装升级程序（每日报到、在线升级）……"; fi
		cp "$UF" "$TMP/${UF##*/}" && inst "$TMP/${UF##*/}" >/dev/null 2>&1
	fi
	if [ -x "$UPD_BIN" ]; then say "✓ 升级程序已装好"; return 0; fi
	say "⚠ 升级程序没装上（常见原因：缺依赖 usign、软件源连不上或空间不够）。一点守护照常工作，会自己每天报到，并在之后自动再试安装。"
	if [ "$PM" = apk ]; then say "  也可以手工补装：apk add --allow-untrusted $UF"
	else say "  也可以手工补装：opkg update && opkg install $UF"; fi
}

# 结尾说明：新装 / 更新 / 同版本重装；已绑定的只说设置和绑定都还在，没绑定的交代家长 WiFi 和临时 root 密码
done_msg() {   # done_msg 原来的版本（新装为空） 这次的版本
	bound=""; grep -q '"o"' "$ETCD/parents.json" 2>/dev/null && bound=1
	if [ -z "$1" ]; then say "✓ 安装完成（$2）"
	elif [ "$1" = "$2" ]; then say "✓ 已经是最新版 $2${bound:+，设置和绑定都还在，照常使用即可}"
	else say "✓ 已更新到 $2（原来是 $1）${bound:+，设置和绑定都还在，照常使用即可}"; fi
	[ -n "$bound" ] && return 0
	code=$(sed -n 's/.*"code": *"\([0-9A-Z]*\)".*/\1/p' "$ETCD/identity.json" 2>/dev/null)
	say "1–2 分钟后会出现不用密码的 WiFi「DOTI-${code:-XXXX}-ADMIN」，手机连上它，打开微信小程序「一点守护」按提示绑定。"
	say "这个 WiFi 只开 30 分钟，超时后断电重开路由器会再开 30 分钟。"
	# 自己装的、root 没设密码（或已经被主程序设成临时默认密码）：交代家长 WiFi 开放期间的临时 root 密码
	pre=$(cat "$ETCD/preinstall" 2>/dev/null)
	if [ ${#pre} -lt 8 ]; then
		rh=$(awk -F: '$1 == "root" { print $2 }' "${DOTI_SHADOW:-/etc/shadow}" 2>/dev/null)
		if [ -z "$rh" ] || grep -q ' temp$' "$ETCD/rootpw" 2>/dev/null; then
			echo ""
			say "★ 注意：家长 WiFi 开放的这 30 分钟里，路由器后台（LuCI / SSH）的 root 临时加了默认密码 Passwd4Doti，"
			say "  家长 WiFi 关闭后恢复原样（空密码）；绑定后换成家长 WiFi 密码。"
			say "  想用自己的密码可以执行 passwd 修改，自己改过的我们不会动。"
		fi
	fi
}
# 只要函数（测试用）
[ "${DOTI_INSTALL_LIB:-}" = 1 ] && return 0 2>/dev/null

# 1 系统
[ "$(id -u)" = 0 ] || die "请用 root 账号执行"
[ -r /etc/openwrt_release ] || die "这台路由器不是 OpenWrt 系统，要先刷官方 OpenWrt（22.03 及以上），见 https://doti.top/quick-start.html"
. /etc/openwrt_release
v="$DISTRIB_RELEASE"; maj=${v%%.*}; rest=${v#*.}; min=${rest%%.*}
case "$maj$min" in
*[!0-9]*|"") say "系统版本：$v" ;;
*) if [ "$maj" -lt 22 ] || { [ "$maj" -eq 22 ] && [ "$min" -lt 3 ]; }; then
	die "需要 OpenWrt 22.03 及以上，这台是 $v。请先刷新版本的官方 OpenWrt，见 https://doti.top/quick-start.html"
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
# 国内镜像按顺序试：清华（新版本全）、阿里云（还留着 22.03.x，清华等已经下架）。哪个能更新索引就用哪个
MIRRORS_CN="https://mirrors.tuna.tsinghua.edu.cn/openwrt https://mirrors.aliyun.com/openwrt"
MIRROR=""
VIA=""
# 限时执行：软件源连不上时 opkg update / apk 可能卡很久
# 计时的子进程不接输出：不然它里面的 sleep 一直占着输出管道，用 | tee、ssh 远程执行时要多等完整个限时才返回
lim() { s=$1; shift; "$@" & p=$!; ( sleep "$s"; kill "$p" 2>/dev/null ) </dev/null >/dev/null 2>&1 & w=$!; wait "$p"; r=$?; kill "$w" 2>/dev/null; return $r; }
# opkg 的临时配置：软件源换成镜像（OPKG_CONF_DIR 让它不读系统的 /etc/opkg/*.conf），索引放临时目录
mkopkg() {   # mkopkg 镜像地址
	rm -rf "$TMP/feeds" "$TMP/lists"; mkdir -p "$TMP/feeds" "$TMP/lists"
	for f in /etc/opkg/*.conf; do [ -f "$f" ] && sed "s#https*://downloads.openwrt.org#$1#" "$f" > "$TMP/feeds/${f##*/}"; done
	sed "s#^lists_dir .*#lists_dir ext $TMP/lists#" /etc/opkg.conf > "$TMP/opkg.conf"
	grep -q '^lists_dir' "$TMP/opkg.conf" || echo "lists_dir ext $TMP/lists" >> "$TMP/opkg.conf"
}
mo() { OPKG_CONF_DIR="$TMP/feeds" opkg -f "$TMP/opkg.conf" "$@"; }
# inst 包文件：装一个本地包（主程序、升级程序共用）
inst() {
	if [ "$PM" = opkg ]; then
		# 临时配置的索引目录是空的：这一步不联网，系统已有的官方源索引也不会被用来下载（那样在国内很慢）
		mkopkg "${MIRRORS_CN%% *}"
		mo install "$1" > "$TMP/log" 2>&1 && { cat "$TMP/log"; return 0; }
		say "系统缺少依赖，联网安装（先用国内镜像）……"
		for m in $MIRRORS_CN; do
			mkopkg "$m"
			if lim 90 mo update >/dev/null 2>&1 && mo install "$1"; then VIA=mirror; MIRROR=$m; return 0; fi
		done
		say "国内镜像不通，改用系统的软件源……"
		lim 180 opkg update >/dev/null 2>&1 || return 2
		opkg install "$1"; return
	fi
	if apk add --allow-untrusted --no-network "$1" > "$TMP/log" 2>&1; then grep -v "^WARNING: opening from cache" "$TMP/log"; return 0; fi
	say "系统缺少依赖，联网安装（先用国内镜像）……"
	for m in $MIRRORS_CN; do
		cat /etc/apk/repositories.d/*.list 2>/dev/null | sed "s#https*://downloads.openwrt.org#$m#" > "$TMP/repos"
		if [ -s "$TMP/repos" ] && lim 120 apk add --allow-untrusted --repositories-file "$TMP/repos" "$1"; then VIA=mirror; MIRROR=$m; return 0; fi
	done
	say "国内镜像不通，改用系统的软件源……"
	lim 240 apk add --allow-untrusted "$1"
}
# 1.2.0 以前的包叫 doti、doti-updater：先卸掉旧包再装（设置、绑定在 /etc/doti，不在包里，卸载不删）
prev=$(cat "$SHARE/version" 2>/dev/null)   # 原来装着的版本（新装为空；旧包名的也有这个文件）
old=""
if [ "$PM" = apk ]; then for p in doti-updater doti; do apk info -e "$p" >/dev/null 2>&1 && old="$old $p"; done
else for p in doti-updater doti; do opkg status "$p" 2>/dev/null | grep -q '^Status:.* installed' && old="$old $p"; done; fi
if [ -n "$old" ]; then
	say "换成新的软件包名，先卸掉旧包（设置和绑定保留）：$old"
	if [ "$PM" = apk ]; then apk del $old >/dev/null 2>&1; else opkg remove $old >/dev/null 2>&1; fi
fi
# 预装（出厂时我们自己装）：DOTI_PREINSTALL=1 先放预装标记，第一次安装就按预装处理——主 LAN 换成 10.x 网段；
# 再给 DOTI_ROOTPW（出厂默认 root 密码，8 位以上）时写进标记（只有 root 能读），没人绑定时 root 用它，绑定后换成家长 WiFi 密码。
# 标记只让本机更严，不带任何服务期等权益（权益只认云端登记）
if [ "${DOTI_PREINSTALL:-}" = 1 ]; then
	mkdir -p /etc/doti && (umask 077; printf '%s\n' "${DOTI_ROOTPW:-}" > /etc/doti/preinstall) && chmod 600 /etc/doti/preinstall && say "预装模式：已放预装标记"
fi
say "开始安装……"
inst "$TMP/$FILE"; r=$?
[ $r = 2 ] && die "软件源连不上：国内镜像和系统的软件源都连不上，请检查路由器能不能上网，稍后再试"
[ $r = 0 ] || die "安装失败：常见原因是这台路由器的软件源里没有门铃组件 mosquitto-client-nossl，或空间不够（最低 16MB 闪存、64MB 内存，这样的路由器暂不支持）。请把上面的出错信息发给客服（小程序「一点守护」→「联系客服」）"
# 6 升级程序
upd_step
rm -rf "$TMP"
if [ "$VIA" = mirror ]; then
	say "这次是用国内镜像（$MIRROR）补装的依赖，系统的软件源没改。平时也想用国内镜像的话，可以运行："
	if [ "$PM" = apk ]; then say "  sed -i 's#https*://downloads.openwrt.org#$MIRROR#' /etc/apk/repositories.d/distfeeds.list"
	else say "  sed -i 's#https*://downloads.openwrt.org#$MIRROR#' /etc/opkg/distfeeds.conf"; fi
fi
done_msg "$prev" "$ver"
