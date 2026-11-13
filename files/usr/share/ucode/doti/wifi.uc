// 孩子 WiFi 和家长 WiFi
'use strict';
import * as fs from 'fs';

export function bins() {
	return { uci: getenv('DOTI_UCI') || 'uci', ubus: getenv('DOTI_UBUS') || 'ubus', wifi: getenv('DOTI_WIFI') || 'wifi' };
};
function sh(cmd) {
	const p = fs.popen(cmd, 'r');
	if (!p) return '';
	const s = p.read('all');
	p.close();
	return s ?? '';
}
// 没认领时家长 WiFi 用固定临时名，第一次设密码时改成带编号的名字
export function adminSsid(code) { return 'DOTI-' + code + '-ADMIN'; };
export function shq(s) { return "'" + replace(s, "'", "'\\''") + "'"; };
export function kidNet(key) { return 'doti' + substr(key, 1); };

// `uci show wireless` → { 节名: { 选项: 值 } }
export function parseShow(text) {
	const o = {};
	for (let line in split(text ?? '', '\n')) {
		const m = match(line, /^wireless\.([^.=]+)\.([A-Za-z0-9_]+)=(.*)$/);
		if (!m) continue;
		let v = m[3];
		if (length(v) >= 2 && substr(v, 0, 1) == "'" && substr(v, -1) == "'") v = replace(substr(v, 1, length(v) - 2), "'\\''", "'");
		if (!o[m[1]]) o[m[1]] = {};
		o[m[1]][m[2]] = v;
	}
	return o;
};

function iface(o, k) {
	const s = o[k];
	return { sec: k, ssid: s.ssid ?? '', key: s.key ?? '', enc: s.encryption ?? '', mode: s.mode ?? '', disabled: s.disabled ?? '0', device: s.device ?? '' };
}
function isOpen(f) { return f.enc == '' || f.enc == 'none'; }

// 某个网络的热点
export function ifacesOf(o, net) {
	return map(filter(sort(keys(o)), k => o[k].network == net), k => iface(o, k));
};

// 主网络上的热点，标出哪个是我们的家长 WiFi
export function parentIfaces(o, code) {
	return map(filter(ifacesOf(o, 'lan'), f => f.mode == 'ap'), f => ({ ...f, ours: f.ssid == adminSsid(code) }));
};

// 设家长密码的目标
export function parentTargets(o, code) {
	const all = parentIfaces(o, code);
	if (!length(filter(all, f => f.ours))) return [];
	return filter(all, f => f.ours || isOpen(f));
};

// 主网络上开着的热点都有密码
export function parentHasPassword(o, code) {
	return !length(filter(parentIfaces(o, code), f => f.disabled != '1' && isOpen(f)));
};

// `ubus call network.wireless status` → { k1: 开着吗 }
export function actualOn(text, ks) {
	let st = null;
	try { st = json(text); } catch (e) { return null; }
	if (type(st) != 'object') return null;
	const out = {};
	for (let k in ks) out[k] = false;
	for (let radio in keys(st))
		for (let i in st[radio]?.interfaces ?? [])
			for (let k in ks)
				if (index(i?.section ?? '', kidNet(k) + '_') == 0 && i?.ifname) out[k] = true;
	return out;
};

export function validPassword(pw) { return type(pw) == 'string' && !!match(pw, /^[ -~]{8,63}$/); };

export function randDigits(n) {
	const f = fs.open('/dev/urandom', 'r');
	const b = f.read(n);
	f.close();
	let s = '';
	for (let i = 0; i < n; i++) s += chr(48 + ord(b, i) % 10);
	return s;
};

export function cmdsDisabled(ifs, on) {
	return map(filter(ifs, f => f.disabled != (on ? '0' : '1')), f => 'set wireless.' + f.sec + '.disabled=' + (on ? '0' : '1'));
};
export function cmdsKey(ifs, pw) {
	const out = [];
	for (let f in ifs) {
		if (isOpen(f)) push(out, 'set wireless.' + f.sec + '.encryption=psk2');
		push(out, 'set wireless.' + f.sec + '.key=' + shq(pw));
	}
	return out;
};
// 设家长密码：家长 WiFi 一开始就叫 DOTI-XXXX-ADMIN（不加密），首次设密码只加密码、不改名——
// 手机看到同名网络从不加密变成加密，会当成新网络弹出输密码框（华为、iPhone 实测），不用先忘记网络
export function cmdsParent(ifs, pw, code) { return cmdsKey(ifs, pw); };

// ---------- 读写 ----------
export function load(b) { return parseShow(sh(b.uci + ' show wireless 2>/dev/null')); };
export function state(b, ks) { return actualOn(sh(b.ubus + ' call network.wireless status 2>/dev/null'), ks); };

// 执行 uci 命令、提交，后台 2 秒后重载 WiFi
export function apply(b, cmds) {
	if (!length(cmds)) return false;
	for (let c in cmds) system(b.uci + ' ' + c);
	system(b.uci + ' commit wireless');
	system('(sleep 2; ' + b.wifi + ' reload) >/dev/null 2>&1 &');
	return true;
};
