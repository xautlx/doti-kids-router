// 系统 root 密码跟着家长 WiFi 密码走（管理后台 LuCI、SSH 用）：
// 绑定、改家长 WiFi 密码时，root 没设密码、或还是上次由我们设的那个，就一起改成新的家长 WiFi 密码；
// 解除绑定时，还是我们设的那个就清空，回到刚安装的样子。自己在 LuCI、SSH 里另设过的不动。
// 预装的路由器没人绑定时 root 不留空（不用密码的家长 WiFi 开着那 30 分钟，连上来的人能直接进 LuCI、SSH）：
// 用出厂预装时给的默认密码（存在 /etc/doti/preinstall 里，由调用方读出来传入；代码开源，密码不写在代码里）。
// 没绑定时设成它（init），绑定时 follow 认得是我们设的、换成家长 WiFi 密码，解除绑定时改回它。
// 自己装的没人绑定时，只在不用密码的家长 WiFi 开着那 30 分钟里给 root 临时加一个公开的固定默认密码（temp），
// 挡住随手试空密码进后台的人；关闭后还是我们设的那个就恢复为空（刷机的人习惯空密码登录），期间自己改过的不动。
// 系统只存加密后的 root 密码，路由器上没有工具拿明文去核对，所以每次设好记下 /etc/shadow 里那串的摘要：
// 摘要对得上，说明 root 密码就是我们上次设的，没被另改过。摘要后面带 ' temp' 的是临时默认密码，关闭时只清这种。
// 摘要函数由调用方传入（sha256）：模块之间不互相 import，兼容 OpenWrt 22.03 的 ucode。
'use strict';
import * as fs from 'fs';

function mark() { return (getenv('DOTI_ETC') || '/etc/doti') + '/rootpw'; }
function shadow() { return getenv('DOTI_SHADOW') || '/etc/shadow'; }
function passwd() { return getenv('DOTI_PASSWD') || 'passwd'; }
function shq(s) { return "'" + replace(s, "'", "'\\''") + "'"; }

// root 那一栏：'' 没设密码；null 读不到（不在路由器上、没有 root 这一行）
export function hash() {
	const m = match(fs.readfile(shadow()) ?? '', /(^|\n)root:([^:\n]*)/);
	return m ? m[2] : null;
};
// 标记文件一行：摘要，临时默认密码再跟一个 ' temp'
function marked() { return split(trim(fs.readfile(mark()) ?? ''), ' '); }
function ours(h, sha256) {
	const m = marked()[0];
	return length(m) > 0 && m == sha256(h);
}
// 把 root 设成 pw 并记下摘要（tmp：临时默认密码）；成了返回 true
function setTo(pw, sha256, tmp) {
	const h = hash();
	system(sprintf("printf '%%s\\n%%s\\n' %s %s | %s root >/dev/null 2>&1", shq(pw), shq(pw), passwd()));
	const n = hash();
	if (!n || n == h) return false;
	fs.writefile(mark(), sha256(n) + (tmp ? ' temp' : ''));
	return true;
}

// root 现在是什么：null 读不到 / 'empty' 没设密码 / 'temp' 我们设的临时默认密码 / 'ours' 我们设的别的密码 / 'other' 另设过的
export function kind(sha256) {
	const h = hash();
	if (h == null) return null;
	if (h == '') return 'empty';
	if (!ours(h, sha256)) return 'other';
	return marked()[1] == 'temp' ? 'temp' : 'ours';
};

// 自己装的、没人绑定时按家长 WiFi 是否开放（open）对齐，pw 是临时默认密码：
// 开放中、root 没设密码 → 设成 pw（'set'）；已关闭、还是我们设的临时默认密码 → 清空（'clear'）；
// 别的情况不动（'skip'）；'none' 读不到；'fail' 没设成
export function temp(open, pw, sha256) {
	const k = kind(sha256);
	if (k == null) return 'none';
	if (open && k == 'empty') return setTo(pw, sha256, true) ? 'set' : 'fail';
	if (open || k != 'temp') return 'skip';
	system(passwd() + ' -d root >/dev/null 2>&1');
	if (hash() !== '') return 'fail';
	fs.unlink(mark());
	return 'clear';
};

// 预装、没人绑定时调，pw 是出厂默认密码：root 没设密码就设成它。'set' 设了 / 'skip' 已有密码不动 / 'none' 读不到 / 'fail' 没设成
export function init(pw, sha256) {
	const h = hash();
	if (h == null) return 'none';
	if (h != '') return 'skip';
	return setTo(pw, sha256) ? 'set' : 'fail';
};

// 家长 WiFi 密码设成 pw 之后调：'set' 改了 / 'skip' 另设过不动 / 'none' 读不到 / 'fail' 没改成
export function follow(pw, sha256) {
	const h = hash();
	if (h == null) return 'none';
	if (h != '' && !ours(h, sha256)) return 'skip';
	return setTo(pw, sha256) ? 'set' : 'fail';
};

// 解除绑定时调：还是我们设的那个就清空；预装的（传了出厂默认密码 dflt）改回它
export function release(sha256, dflt) {
	const h = hash(), mine = !!h && ours(h, sha256);
	if (mine && dflt && setTo(dflt, sha256)) return true;
	if (mine) system(passwd() + ' -d root >/dev/null 2>&1');
	fs.unlink(mark());
	return mine;
};
