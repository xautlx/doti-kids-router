// 系统 root 密码跟着家长 WiFi 密码走（管理后台 LuCI、SSH 用）：
// 绑定、改家长 WiFi 密码时，root 没设密码、或还是上次跟着设的那个，就一起改成新的家长 WiFi 密码；
// 解除绑定时，还是跟着设的那个就清空，回到刚安装的样子。自己在 LuCI、SSH 里另设过的不动。
// 系统只存加密后的 root 密码，路由器上没有工具拿明文去核对，所以每次设好记下 /etc/shadow 里那串的摘要：
// 摘要对得上，说明 root 密码就是上次的家长 WiFi 密码，没被另改过。
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
function ours(h, sha256) {
	const m = trim(fs.readfile(mark()) ?? '');
	return length(m) > 0 && m == sha256(h);
}

// 家长 WiFi 密码设成 pw 之后调：'set' 改了 / 'skip' 另设过不动 / 'none' 读不到 / 'fail' 没改成
export function follow(pw, sha256) {
	const h = hash();
	if (h == null) return 'none';
	if (h != '' && !ours(h, sha256)) return 'skip';
	system(sprintf("printf '%%s\\n%%s\\n' %s %s | %s root >/dev/null 2>&1", shq(pw), shq(pw), passwd()));
	const n = hash();
	if (!n || n == h) return 'fail';
	fs.writefile(mark(), sha256(n));
	return 'set';
};

// 解除绑定时调：还是跟着设的那个就清空
export function release(sha256) {
	const h = hash(), mine = !!h && ours(h, sha256);
	if (mine) system(passwd() + ' -d root >/dev/null 2>&1');
	fs.unlink(mark());
	return mine;
};
