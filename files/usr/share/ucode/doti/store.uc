// 路径、原子写 JSON、锁、通知常驻程序
'use strict';
import * as fs from 'fs';

export function etc(name) { return (getenv('DOTI_ETC') || '/etc/doti') + (name ? '/' + name : ''); };
export function tmp(name) { return (getenv('DOTI_RUN') || '/tmp/doti') + (name ? '/' + name : ''); };

export function readJson(path, dflt) {
	const s = fs.readfile(path);
	if (s == null) return dflt;
	try { return json(s); } catch (e) { return dflt; }
};

// mode：改名之前先设好权限（改名后的文件是新文件，权限不会沿用原来的）
export function writeText(path, text, mode) {
	const t = path + '.tmp';
	if (fs.writefile(t, text) == null) return false;
	if (mode) fs.chmod(t, mode);
	return !!fs.rename(t, path);
};

export function writeJson(path, obj) { return writeText(path, sprintf('%J', obj)); };
// 带密钥的文件（设备身份）：只有 root 能读
export function writeSecret(path, obj) { return writeText(path, sprintf('%J', obj), 0600); };

export function ensureDirs() {
	for (let d in [etc(), etc('usage'), tmp()]) fs.mkdir(d);
};

// 读-改-写都在锁里
export function withLock(fn, now) {
	const dir = tmp('lock');
	let got = false;
	for (let i = 0; i < 60; i++) {
		if (fs.mkdir(dir)) { got = true; break; }
		const st = fs.stat(dir);
		if (st && (now ?? time()) - st.mtime > 10) { fs.rmdir(dir); continue; }
		sleep(50);
	}
	if (!got) return [null, 'BUSY'];
	let r = null, err = null;
	try { r = fn(); } catch (e) { err = e; }
	fs.rmdir(dir);
	if (err) die(err);
	return [r, null];
};

// 通知常驻程序重读配置
export function bumpGen() {
	const g = +(fs.readfile(tmp('gen')) ?? 0) + 1;
	writeText(tmp('gen'), '' + g);
	return g;
};
export function gen() { return +(fs.readfile(tmp('gen')) ?? 0); };
export function applied() { return +(fs.readfile(tmp('applied')) ?? 0); };
export function setApplied(g) { writeText(tmp('applied'), '' + g); };

// 等常驻程序生效
export function waitApplied(g, now) {
	const st = fs.stat(tmp('status.json'));
	if (!st || (now ?? time()) - st.mtime > 30) return false;
	for (let i = 0; i < 30; i++) {
		if (applied() >= g) return true;
		sleep(100);
	}
	return applied() >= g;
};

// 让常驻程序去做需要联网的事
export function mark(name) { writeText(tmp(name + '.now'), '' + time()); };
export function takeMark(name) {
	const p = tmp(name + '.now');
	if (!fs.stat(p)) return false;
	fs.unlink(p);
	return true;
};
