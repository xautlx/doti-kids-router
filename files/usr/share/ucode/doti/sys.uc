// 进程级小工具（只给顶层程序 doti、cgi 用；模块之间不能互相 import，模块里要用的由调用方传进去）：
// 跑命令取输出、日志、随机数、IPv4 地址换算
'use strict';
import * as fs from 'fs';

// 跑一条 shell 命令，取输出（去掉首尾空白）；起不来回空串
export function sh(cmd) {
	const p = fs.popen(cmd, 'r');
	if (!p) return '';
	const s = p.read('all');
	p.close();
	return trim(s ?? '');
};

// 日志：logger(标签) → 写日志的函数。设了 DOTI_LOGFILE（测试）就写文件，否则交给系统日志
export function logger(tag) {
	return msg => {
		const f = getenv('DOTI_LOGFILE');
		if (f) { const h = fs.open(f, 'a'); h.write(msg + '\n'); h.close(); return; }
		system(['logger', '-t', tag, msg]);
	};
};

// n 字节随机数的十六进制
export function hexRand(n) {
	const f = fs.open('/dev/urandom', 'r');
	const b = f.read(n);
	f.close();
	let s = '';
	for (let i = 0; i < length(b); i++) s += sprintf('%02x', ord(b, i));
	return s;
};

// ---------- IPv4 ----------
// 点分地址 → 整数，不合法回 null
export function ip4(s) {
	const m = match(s ?? '', /^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$/);
	if (!m) return null;
	let n = 0;
	for (let i = 1; i <= 4; i++) { if (+m[i] > 255) return null; n = n * 256 + +m[i]; }
	return n;
};
// a 在不在 ip/prefix 这个网段里
export function inNet(a, ip, prefix) {
	const x = ip4(a), y = ip4(ip);
	if (x == null || y == null) return false;
	const span = 1 << (32 - prefix);
	return int(x / span) == int(y / span);
};
// 子网掩码 → 前缀长度（从高位数连续的 1）；读不出来按 24
export function maskLen(mask) {
	const n = ip4(mask);
	if (n == null) return 24;
	let c = 0;
	for (let i = 31; i >= 0; i--) { if (int(n / (1 << i)) % 2) c++; else break; }
	return c;
};
// uci 的 network.lan.ipaddr（可能是 CIDR 写法或空格隔开的列表）+ netmask → { ip, prefix }
export function lanAddr(ipaddr, mask) {
	const p = split(split(trim(ipaddr ?? ''), ' ')[0], '/');
	return { ip: p[0], prefix: p[1] != null && match(p[1], /^[0-9]+$/) ? +p[1] : maskLen(mask) };
};
