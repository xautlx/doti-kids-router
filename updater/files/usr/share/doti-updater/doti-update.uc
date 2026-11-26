// 一点守护升级程序
//   doti-update daemon | checkin | install | selftest | version
'use strict';
import * as fs from 'fs';

const VERSION = '2.0.3';
const PKG = 'doti-kids-router', UPKG = 'doti-kids-router-updater';
const cfg = {
	dir: getenv('DOTI_UPD_DIR') || '/etc/doti-updater',
	share: getenv('DOTI_UPD_SHARE') || '/usr/share/doti-updater',
	etc: getenv('DOTI_ETC') || '/etc/doti',
	run: getenv('DOTI_RUN') || '/tmp/doti',
	tmp: getenv('DOTI_UPD_TMP') || '/tmp',
	fetch: getenv('DOTI_FETCH') || 'uclient-fetch',
	opkg: getenv('DOTI_OPKG') || 'opkg',
	apk: getenv('DOTI_APK') || 'apk',
	pm: getenv('DOTI_PM'),
	usign: getenv('DOTI_USIGN') || 'usign',
	ucode: getenv('DOTI_UCODE') || 'ucode',
	ubus: getenv('DOTI_UBUS') || 'ubus',
	main: getenv('DOTI_MAIN') || '/usr/sbin/doti',
	initd: getenv('DOTI_INITD') || '/etc/init.d/doti',
	nft: getenv('DOTI_NFT') || 'nft',
	overlay: getenv('DOTI_OVERLAY') || '/overlay',
	sys: getenv('DOTI_SYSROOT') || '',
	wait: +(getenv('DOTI_UPD_WAIT') || 600),
	step: +(getenv('DOTI_UPD_STEP') || 5000)
};
const F = n => cfg.dir + '/' + n;
const RETRY = [300, 900, 2700], CLOCK_FIX = 120, LOCK_STALE = 1800;
// 下载源
const REPO = 'xautlx/doti-kids-router';
const MIRRORS = [
	'https://gitee.com/' + REPO + '/releases/download/{tag}/{file}',
	'https://gh-proxy.com/https://github.com/' + REPO + '/releases/download/{tag}/{file}',
	'https://ghproxy.net/https://github.com/' + REPO + '/releases/download/{tag}/{file}',
	'https://github.com/' + REPO + '/releases/download/{tag}/{file}',
	'https://ghfast.top/https://github.com/' + REPO + '/releases/download/{tag}/{file}'
];
// 下载失败后的重试间隔
const DL_RETRY = [1800, 3600];

// ---------- 小工具 ----------
function now() { return getenv('DOTI_NOW') ? +getenv('DOTI_NOW') : time(); }
function shq(s) { return "'" + replace('' + s, "'", "'\\''") + "'"; }
function log(msg) {
	system('logger -t doti-update ' + shq(msg) + ' 2>/dev/null');
	if (getenv('DOTI_UPD_LOG')) { const f = fs.open(getenv('DOTI_UPD_LOG'), 'a'); if (f) { f.write(msg + '\n'); f.close(); } }
}
function sh(cmd) { const p = fs.popen(cmd, 'r'); if (!p) return ''; const s = p.read('all'); p.close(); return trim(s ?? ''); }
function readJson(f, d) { const s = fs.readfile(f); if (s == null) return d; try { return json(s); } catch (e) { return d; } }
function writeJson(f, o) { fs.writefile(f + '.tmp', sprintf('%J', o)); fs.rename(f + '.tmp', f); }
function rnd() { const f = fs.open('/dev/urandom', 'r'), b = f.read(2); f.close(); return (ord(b, 0) * 256 + ord(b, 1)) / 65535.0; }
function mtime(f) { const s = fs.stat(f); return s ? s.mtime : 0; }
// 云端主地址和备用地址：主地址网络不通（没有 JSON 回包）时用备用
function cloudUrls() {
	const a = getenv('DOTI_CLOUD') || trim(fs.readfile('/usr/share/doti/cloud') ?? '');
	const b = getenv('DOTI_CLOUD_BACKUP') ?? trim(fs.readfile('/usr/share/doti/cloud-backup') ?? '');
	return filter([a, b], (u, i) => u && (i == 0 || u != a));
}

// 版本比较
function vcmp(a, b) {
	const x = map(split(a ?? '0', '.'), n => +n), y = map(split(b ?? '0', '.'), n => +n);
	for (let i = 0; i < max(length(x), length(y)); i++) {
		const p = x[i] ?? 0, q = y[i] ?? 0;
		if (p != q) return p < q ? -1 : 1;
	}
	return 0;
}

// ---------- SHA-256 / HMAC ----------
const K = [
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
];
const M32 = 0xffffffff;
function rotr(x, n) { return ((x >> n) | (x << (32 - n))) & M32; }
function sha256raw(msg) {
	const L = length(msg);
	let bytes = [];
	for (let i = 0; i < L; i++) push(bytes, ord(msg, i));
	push(bytes, 0x80);
	while (length(bytes) % 64 != 56) push(bytes, 0);
	const bits = L * 8;
	for (let i = 7; i >= 0; i--) push(bytes, (bits >> (i * 8)) & 0xff);
	let h = [ 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 ];
	for (let off = 0; off < length(bytes); off += 64) {
		const w = [];
		for (let i = 0; i < 16; i++)
			w[i] = (bytes[off + i * 4] << 24) | (bytes[off + i * 4 + 1] << 16) | (bytes[off + i * 4 + 2] << 8) | bytes[off + i * 4 + 3];
		for (let i = 16; i < 64; i++) {
			const s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
			const s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
			w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & M32;
		}
		let a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
		for (let i = 0; i < 64; i++) {
			const S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
			const ch = (e & f) ^ ((e ^ M32) & g);
			const t1 = (hh + S1 + ch + K[i] + w[i]) & M32;
			const S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
			const maj = (a & b) ^ (a & c) ^ (b & c);
			const t2 = (S0 + maj) & M32;
			hh = g; g = f; f = e; e = (d + t1) & M32; d = c; c = b; b = a; a = (t1 + t2) & M32;
		}
		h = [ (h[0] + a) & M32, (h[1] + b) & M32, (h[2] + c) & M32, (h[3] + d) & M32, (h[4] + e) & M32, (h[5] + f) & M32, (h[6] + g) & M32, (h[7] + hh) & M32 ];
	}
	let out = '';
	for (let x in h) out += chr((x >> 24) & 0xff, (x >> 16) & 0xff, (x >> 8) & 0xff, x & 0xff);
	return out;
}
function hex(raw) { let s = ''; for (let i = 0; i < length(raw); i++) s += sprintf('%02x', ord(raw, i)); return s; }
function hmacSha256(key, msg) {
	if (length(key) > 64) key = sha256raw(key);
	let ipad = '', opad = '';
	for (let i = 0; i < 64; i++) {
		const k = i < length(key) ? ord(key, i) : 0;
		ipad += chr(k ^ 0x36);
		opad += chr(k ^ 0x5c);
	}
	return hex(sha256raw(opad + sha256raw(ipad + msg)));
}

// ---------- 包管理器 ----------
// OpenWrt 25.x 起用 apk，以前用 opkg；本地包、下载的文件、校验值都按格式分
function pm() {
	if (!cfg.pm) cfg.pm = fs.stat('/bin/opkg') || fs.stat('/usr/bin/opkg') ? 'opkg' : fs.stat('/usr/bin/apk') ? 'apk' : 'opkg';
	return cfg.pm;
}
function ext() { return pm() == 'apk' ? 'apk' : 'ipk'; }
// 这次要用的包：{ file, sha256, size }；apk 系统只认签名信息里的 apk 那组，没有就不升级
function pkgOf(o) {
	if (pm() == 'apk') return o.apk ? { file: o.apk.file ?? PKG + '-' + o.version + '-r1.apk', sha256: o.apk.sha256, size: o.apk.size } : null;
	return { file: o.file ?? (o.pkg == UPKG ? UPKG + '_' + o.version + '.uc' : PKG + '_' + o.version + '-1_all.ipk'), sha256: o.sha256, size: o.size, urls: [ ...(o.urls ?? []), ...(o.url ? [ o.url ] : []) ] };
}
// 本地包：current 是装着的版本（回滚用），prev 是再上一个
function cur() { return F('current.' + ext()); }
function newFile() { return cfg.tmp + '/doti-new.' + ext(); }
function keepNew(f, v) { fs.rename(cur(), F('prev.' + ext())); fs.writefile(cur(), fs.readfile(f)); writeJson(F('current.json'), { version: v }); }
// apk 装本地包也会先下载全部软件源索引（官方源在国内要一两分钟），先不联网装，缺依赖再联网
// opkg 装本地包要的依赖本机没有（新版本加了依赖，路由器上又没有软件源列表）会装不上：更新软件源列表再装，
// 官方源在国内偶尔下载失败，最多再试两次
function pkgInstall(f) {
	if (pm() != 'apk') {
		const cmd = sprintf('%s install --force-reinstall --force-downgrade %s >/dev/null 2>&1', cfg.opkg, shq(f));
		if (system(cmd) == 0) return true;
		for (let i = 1; i <= 2; i++) {
			log(sprintf('装不上（可能缺依赖），更新软件源列表后再装（第 %d 次）', i));
			system(cfg.opkg + ' update >/dev/null 2>&1');
			if (system(cmd) == 0) return true;
		}
		return false;
	}
	return system(sprintf('%s add --allow-untrusted --no-network %s >/dev/null 2>&1', cfg.apk, shq(f))) == 0 ||
		system(sprintf('%s add --allow-untrusted %s >/dev/null 2>&1', cfg.apk, shq(f))) == 0;
}

// ---------- 主程序的状态 ----------
function identity() { return readJson(cfg.etc + '/identity.json', {}); }
function mainVersion() { const v = match(fs.readfile(cfg.main) ?? '', /const VERSION = '([^']+)'/); return v ? v[1] : ''; }
function installed() {
	const m = pm() == 'apk'
		? match(sh(cfg.apk + ' list -I ' + PKG + ' 2>/dev/null'), regexp('(^|\n)' + PKG + '-([0-9][0-9A-Za-z.~+_]*)-r[0-9]+ '))
		: match(sh(cfg.opkg + ' status ' + PKG + ' 2>/dev/null'), /Version: ([0-9A-Za-z.~+-]+)/);
	return m ? replace(m[length(m) - 1], /-[0-9]+$/, '') : mainVersion();
}

// ---------- 云端 ----------
function post(op, body) {
	const us = cloudUrls(), id = identity();
	if (!length(us) || !id.id || !id.key) return null;
	const ts = now(), b = sprintf('%J', body ?? {});
	const f = cfg.tmp + '/doti-update-req.json';
	fs.writefile(f, sprintf('%J', { op, id: id.id, ts, body: b, sig: hmacSha256(id.key, 'doti1|req|' + op + '|' + ts + '|' + b) }));
	fs.chmod(f, 0600);
	let r = null;
	for (let u in us) {
		const out = sh(sprintf('%s -q -T 30 -O - --post-file=%s %s 2>/dev/null', cfg.fetch, shq(f), shq(u)));
		try { r = json(out); } catch (e) { r = null; }
		if (type(r) == 'object') break;
		r = null;
		if (u != us[length(us) - 1]) log('云端主地址不通，换备用地址');
	}
	fs.unlink(f);
	return r;
}
function clockFix(cloudNow) {
	if (type(cloudNow) != 'int' || getenv('DOTI_NOW')) return;
	if (cloudNow - time() > CLOCK_FIX || time() - cloudNow > CLOCK_FIX) { system(['date', '-s', '@' + cloudNow]); log('用云端时间校时'); }
	fs.mkdir(cfg.run, 0700);
	writeJson(cfg.run + '/clock', { src: 'cloud', at: cloudNow });
}

// ---------- 验签、下载 ----------
function pubkey() { return getenv('DOTI_UPD_PUB') || cfg.share + '/doti-release.pub'; }
// 签名的信息 { info: "<JSON 文本>", sig: "<usign 签名文件内容>" } → 解开的对象
function signed(x) {
	if (type(x?.info) != 'string' || type(x?.sig) != 'string' || length(x.info) > 4096 || length(x.sig) > 512) return null;
	const m = cfg.tmp + '/doti-update-info', s = m + '.sig';
	fs.writefile(m, x.info); fs.writefile(s, x.sig);
	const ok = system(sprintf('%s -V -q -m %s -x %s -p %s >/dev/null 2>&1', cfg.usign, shq(m), shq(s), shq(pubkey()))) == 0;
	fs.unlink(m); fs.unlink(s);
	if (!ok) { log('升级信息验签不对，丢弃'); return null; }
	let o = null;
	try { o = json(x.info); } catch (e) { return null; }
	const okUrl = u => type(u) == 'string' && length(u) <= 512 && !!match(u, /^https:\/\/[^ '"]+$/);
	if (type(o) != 'object' || !match(o.version ?? '', /^[0-9]+(\.[0-9]+){1,3}$/) || (o.url != null && !okUrl(o.url)) ||
		(o.urls != null && (type(o.urls) != 'array' || length(o.urls) > 8 || length(filter(o.urls, u => !okUrl(u))))) ||
		(o.tag != null && !match('' + o.tag, /^[A-Za-z0-9._-]{1,32}$/)) || (o.file != null && !match('' + o.file, /^[A-Za-z0-9._-]{1,96}$/)) ||
		!match(o.sha256 ?? '', /^[0-9a-f]{64}$/) || type(o.size) != 'int' || o.size <= 0 || o.size > 4 * 1024 * 1024) return null;
	if (o.apk != null && (type(o.apk) != 'object' || (o.apk.file != null && !match('' + o.apk.file, /^[A-Za-z0-9._-]{1,96}$/)) ||
		!match(o.apk.sha256 ?? '', /^[0-9a-f]{64}$/) || type(o.apk.size) != 'int' || o.apk.size <= 0 || o.apk.size > 4 * 1024 * 1024)) return null;
	return o;
}
function sha256file(f) { const m = match(sh('sha256sum ' + shq(f) + ' 2>/dev/null'), /^([0-9a-f]{64})/); return m ? m[1] : ''; }
// 下载地址按顺序
function sources(o, p) {
	const out = [];
	for (let u in p.urls ?? []) if (index(out, u) < 0) push(out, u);
	const file = p.file;
	const tag = o.tag ?? (o.pkg == UPKG ? null : 'v' + o.version);
	if (tag) for (let m in MIRRORS) push(out, replace(replace(m, '{tag}', tag), '{file}', file));
	return out;
}
// 逐个源下载，大小和 sha256 都对才算
// 升级程序副本不分格式（p 不给时按 ipk 那组）
function download(o, f, p) {
	if (!p) p = { file: o.file ?? UPKG + '_' + o.version + '.uc', sha256: o.sha256, size: o.size, urls: [ ...(o.urls ?? []), ...(o.url ? [ o.url ] : []) ] };
	for (let u in sources(o, p)) {
		fs.unlink(f);
		system(sprintf('%s -q -T 60 -O %s %s >/dev/null 2>&1', cfg.fetch, shq(f), shq(u)));
		const s = fs.stat(f);
		if (s && s.size == p.size && sha256file(f) == p.sha256) return true;
		log('下载源不可用或校验不对，换下一个：' + u);
	}
	fs.unlink(f);
	return false;
}
function freeKB() { const m = match(sh('df -k ' + shq(cfg.overlay) + ' 2>/dev/null | tail -1'), /[ \t]([0-9]+)[ \t]+[0-9]+%/); return m ? +m[1] : 1e9; }

// ---------- 锁 ----------
// held：这个进程拿着锁（出异常时据此放掉）
let held = false;
function lock() {
	const l = cfg.tmp + '/doti-updater.lock', st = fs.stat(l);
	if (st && time() - st.mtime > LOCK_STALE) { fs.rmdir(l); log('清掉残留的锁'); }
	held = fs.mkdir(l) != null;
	return held;
}
function unlock() { fs.rmdir(cfg.tmp + '/doti-updater.lock'); held = false; }

// ---------- 放开网络 ----------
// 停管控、删掉一点守护的全部规则表（限速、屏蔽、统计），孩子网络全部放开。管控程序坏到停不下来也照样删表。
// 宁可短时间不管，也不能卡在限速、全家没法上网
const TABLES = ['doti', 'doti_limit', 'doti_dns'];
function failOpen() {
	system(sprintf('%s stop >/dev/null 2>&1', shq(cfg.initd)));
	for (let t in TABLES) system(sprintf('%s delete table inet %s >/dev/null 2>&1', cfg.nft, t));
}
function mainStart() { system(sprintf('%s start >/dev/null 2>&1', shq(cfg.initd))); }
function rulesOn() { return system(sprintf('%s list table inet doti_limit >/dev/null 2>&1', cfg.nft)) == 0; }
function uptime() { const u = fs.readfile(getenv('DOTI_UPTIME') || '/proc/uptime'); return u != null ? +split(u, ' ')[0] : 0; }

// ---------- 体检、回滚 ----------
function radiosUp() {
	let w = null;
	try { w = json(sh(cfg.ubus + ' call network.wireless status 2>/dev/null')); } catch (e) { return true; }
	if (type(w) != 'object') return true;
	for (let k in keys(w)) if (w[k]?.disabled !== true && w[k]?.up === false) return false;
	return true;
}
// 通过返回 ''，否则返回原因
function health(ver, t0) {
	const end = time() + cfg.wait, seen = [];
	let why = '';
	while (true) {
		why = '';
		if (installed() != ver || mainVersion() != ver) why = '装上的版本不对';
		else if (trim(fs.readfile(cfg.run + '/confirm') ?? '') != ver) why = '新版本没有自检通过';
		else {
			const m = mtime(cfg.run + '/status.json');
			if (m >= t0 && index(seen, m) < 0) push(seen, m);
			if (length(seen) < 2) why = '常驻程序状态没在更新';
			else if (!radiosUp()) why = 'WiFi 没起来';
		}
		if (!why || time() >= end) return why;
		sleep(cfg.step);
	}
}
function result(prev, to, res, reason) {
	writeJson(F('last.json'), { prev, to, result: res, reason: reason ?? '', at: now(), sent: false });
	log(sprintf('升级 %s → %s：%s%s', prev, to, res, reason ? '（' + reason + '）' : ''));
}
function bad() { const b = readJson(F('bad.json'), []); return type(b) == 'array' ? b : []; }
function markBad(v) { const b = bad(); if (index(b, v) < 0) push(b, v); writeJson(F('bad.json'), b); }
function rollback(prev, to, why) {
	markBad(to);
	if (!fs.stat(cur())) { failOpen(); result(prev, to, 'fail', why + '；没有本地旧包，没法回滚，已放开网络'); return; }
	const t0 = now();
	fs.unlink(cfg.run + '/confirm');
	failOpen();
	pkgInstall(cur());
	mainStart();
	const w = health(prev, t0);
	if (w) failOpen();   // 回滚了还不正常：保持放开，等报到报上去
	result(prev, to, w ? 'fail' : 'rollback', why + (w ? '；回滚后仍不正常：' + w + '，已放开网络' : ''));
}

// ---------- 安装 ----------
function haveCurrent() { return !!fs.stat(cur()) && readJson(F('current.json'), null)?.version == installed(); }
function install(o) {
	const prev = installed(), p = pkgOf(o);
	if (o.version == prev) return;
	if (!p) { log('这个版本没有 ' + ext() + ' 包，先不升级'); return; }
	if (freeKB() < 3 * p.size / 1024 + 64) { result(prev, o.version, 'fail', '闪存空间不够'); return; }
	if (!haveCurrent()) { log('本地没有当前版本的包，先不升级（升了没法回滚），等下次报到取回'); return; }
	const f = newFile();
	if (!download(o, f, p)) {
		const d = readJson(F('dlfail.json'), {}), n = (d.ver == o.version ? d.n ?? 0 : 0) + 1;
		if (n <= length(DL_RETRY)) { writeJson(F('dlfail.json'), { ver: o.version, n, next: now() + int(DL_RETRY[n - 1] * (0.7 + rnd() * 0.6)) }); log(sprintf('所有下载源都失败（第 %d 次），稍后再试', n)); return 'retry'; }
		fs.unlink(F('dlfail.json'));
		result(prev, o.version, 'fail', '所有下载源都失败或校验不对'); return;
	}
	fs.unlink(F('dlfail.json'));
	const t0 = now();
	writeJson(F('state.json'), { prev, to: o.version, at: t0 });
	fs.unlink(cfg.run + '/confirm');
	log(sprintf('开始升级 %s → %s（先停管控、放开网络）', prev, o.version));
	failOpen();
	pkgInstall(f);
	mainStart();
	const why = health(o.version, t0);
	if (why) rollback(prev, o.version, why);
	else { keepNew(f, o.version); result(prev, o.version, 'ok'); }
	fs.unlink(f);
	fs.unlink(F('state.json'));
}
// 断电收尾
function finishPending() {
	const st = readJson(F('state.json'), null);
	if (!st) return;
	log(sprintf('上次升级 %s → %s 没收尾，先体检', st.prev, st.to));
	const why = health(st.to, st.at);
	if (why) rollback(st.prev, st.to, '上次没装完：' + why);
	else {
		if (fs.stat(newFile())) keepNew(newFile(), st.to);
		result(st.prev, st.to, 'ok');
	}
	fs.unlink(F('state.json'));
}
function inWindow() { const lt = localtime(now()); return lt.hour >= 2 && lt.hour < 6; }
// 处理云端给的目标版本
function plan(target) {
	const o = signed(target);
	if (!o || o.pkg != PKG) return;
	const floor = fs.readfile(F('floor')) ?? '0';
	if (o.minVersion && vcmp(o.minVersion, floor) > 0) fs.writefile(F('floor'), o.minVersion);
	if (o.version == installed() || index(bad(), o.version) >= 0 || vcmp(o.version, fs.readfile(F('floor')) ?? '0') < 0) { fs.unlink(F('pending.json')); return; }
	writeJson(F('pending.json'), target);
	if (o.urgent === true || inWindow()) { if (install(o) != 'retry') fs.unlink(F('pending.json')); }
}
// 取回当前版本的包（回滚用）
function keepCurrent(c) {
	const o = signed(c), p = o ? pkgOf(o) : null;
	if (!o || !p || o.version != installed() || haveCurrent()) return;
	const f = cfg.tmp + '/doti-cur.' + ext();
	if (!download(o, f, p)) { log('取当前版本的包失败'); return; }
	fs.writefile(cur(), fs.readfile(f)); fs.unlink(f);
	writeJson(F('current.json'), { version: o.version });
	log('已取回当前版本的包（回滚用）');
}

// ---------- 自己的两份副本 ----------
function slotDir(s) { return F('slot-' + s); }
function selfUpdate(u) {
	const o = signed(u);
	if (!o || o.pkg != UPKG || o.version == VERSION) return false;
	const act = trim(fs.readfile(F('active')) ?? ''), other = act == 'a' ? 'b' : 'a';
	fs.mkdir(slotDir(other), 0700);
	const f = slotDir(other) + '/doti-update.uc';
	if (!download(o, f)) { log('取升级程序新副本失败'); return false; }
	if (system(sprintf('%s -S %s selftest >/dev/null 2>&1', cfg.ucode, shq(f))) != 0) { fs.unlink(f); log('升级程序新副本自检不过，不用'); return false; }
	fs.writefile(F('active.tmp'), other); fs.rename(F('active.tmp'), F('active'));
	// 换副本的结果下次报到时报（新副本起来了就是成功；起不来被启动器换回旧副本，旧副本报失败）
	writeJson(F('selfup.json'), { 'from': VERSION, to: o.version, at: now(), sent: false });
	log(sprintf('升级程序 %s → %s，重启生效', VERSION, o.version));
	return true;
}
// 上次换副本的结果（还没报过的）：现在跑的就是新版本算成功，否则是新副本起不来、换回来了
function selfResult() {
	const x = readJson(F('selfup.json'), null);
	if (type(x) != 'object' || x.sent || !x.to) return null;
	const ok = x.to == VERSION;
	return { 'from': x.from, to: x.to, result: ok ? 'ok' : 'fail', reason: ok ? '' : '新副本起不来，换回 ' + VERSION, at: x.at };
}

// ---------- 每日报到 ----------
function slot(id) {
	let h = 0x811c9dc5;
	for (let i = 0; i < length(id); i++) { h ^= ord(id, i); h = (h * 0x01000193) & M32; }
	return 7200 + (h % 240) * 60 + ((h >> 8) % 60);
}
function today(t) { const lt = localtime(t); return sprintf('%04d-%02d-%02d', lt.year, lt.mon, lt.mday); }
function claimed() { return length(readJson(cfg.etc + '/parents.json', {})?.parents ?? []) > 0; }
function kidNets() { let n = 0; for (let x in (readJson(cfg.run + '/status.json', {})?.networks ?? [])) if (x.wifiOn) n++; return n; }

// 交给主程序的部分写进收件箱
function inbox(r) {
	const x = { now: r.now };
	for (let k in ['member', 'joins', 'removes', 'wipe', 'noBackup', 'remote']) if (r[k] != null) x[k] = r[k];
	// 远程管理总开关（remote）只在变了时交：省得天天写收件箱、天天让主程序重读配置
	if (r.remote != null && (readJson(cfg.etc + '/remote.json', null)?.on === true) == !!r.remote) delete x.remote;
	if (length(keys(x)) == 1) return;
	fs.mkdir(cfg.run, 0700); fs.mkdir(cfg.run + '/inbox', 0700);
	writeJson(cfg.run + '/inbox/checkin-' + r.now + '.json', x);
	const g = +(fs.readfile(cfg.run + '/gen') ?? 0) + 1;
	fs.writefile(cfg.run + '/gen.tmp', '' + g); fs.rename(cfg.run + '/gen.tmp', cfg.run + '/gen');
}

// CPU / SoC 描述（ubus call system board 的 system 字段）；读不到回空串
function chip() {
	let b = null;
	try { b = json(sh(cfg.ubus + ' -t 3 call system board 2>/dev/null') || 'null'); } catch (e) { b = null; }
	return type(b?.system) == 'string' ? substr(trim(b.system), 0, 64) : '';
}
// 报到带的环境信息（给统计分析：发行版和系统版本、平台、芯片、存储内存、开机时长、无线频段数、家里各类设备数量）；取不到的项不带
function envInfo() {
	const e = {}, r = fs.readfile(cfg.sys + '/etc/openwrt_release') ?? '', K = { ID: 'id', RELEASE: 'os', REVISION: 'rev', TARGET: 'target', ARCH: 'arch' };
	for (let k in K) {
		const m = match(r, regexp("DISTRIB_" + k + "='([^']*)'"));
		if (m && m[1] != '') e[K[k]] = substr(m[1], 0, 40);
	}
	const board = trim(fs.readfile(cfg.sys + '/tmp/sysinfo/board_name') ?? ''), model = trim(fs.readfile(cfg.sys + '/tmp/sysinfo/model') ?? '');
	if (board) e.board = substr(board, 0, 64);
	if (model) e.model = substr(model, 0, 64);
	const c = chip();
	if (c) e.chip = c;
	e.pm = pm();
	const df = match(sh('df -k ' + shq(cfg.overlay) + ' 2>/dev/null | tail -1'), /[ \t]([0-9]+)[ \t]+[0-9]+[ \t]+([0-9]+)[ \t]+[0-9]+%/);
	if (df) { e.flashKB = +df[1]; e.flashFreeKB = +df[2]; }
	const mi = fs.readfile(cfg.sys + '/proc/meminfo') ?? '', mt = match(mi, /MemTotal:[ \t]+([0-9]+)/), ma = match(mi, /MemAvailable:[ \t]+([0-9]+)/);
	if (mt) e.memKB = +mt[1];
	if (ma) e.memFreeKB = +ma[1];
	const up = fs.readfile(getenv('DOTI_UPTIME') || '/proc/uptime');
	if (up != null) e.uptime = int(+split(up, ' ')[0]);
	const ph = fs.lsdir(cfg.sys + '/sys/class/ieee80211');
	if (ph) e.radios = length(ph);
	const devs = readJson(cfg.etc + '/baseline.json', null)?.devs;
	if (type(devs) == 'object') { const n = {}; for (let mac in devs) { const t = devs[mac]?.type ?? 'other'; n[t] = (n[t] ?? 0) + 1; } e.devs = n; }
	return e;
}
// 采集出任何错都只是不带 env，不影响报到（DOTI_ENV_FAIL 是测试用的，设了就让采集出异常）
function envSafe() {
	try {
		if (getenv('DOTI_ENV_FAIL')) die('DOTI_ENV_FAIL');
		return envInfo();
	} catch (e) {
		log('采集环境信息出错，这次报到不带：' + e);
		return null;
	}
}
// 绑定前诊断（主程序没绑定时写 /tmp/doti/prebind.json）：只有计数和状态；读不到、不像样就不带
function prebind() {
	if (claimed()) return null;
	const p = readJson(cfg.run + '/prebind.json', null);
	return type(p) == 'object' ? p : null;
}
// 上次报到云端回的错误（LIMIT：两次报到不到 60 秒，云端不收）
let lastErr = null;
function checkin() {
	const id = identity();
	lastErr = null;
	if (!id.registered) return null;
	const last = readJson(F('last.json'), null), m = readJson(cfg.etc + '/member.json', null), env = envSafe();
	let pb = null, ac = null;
	try { pb = prebind(); } catch (e) { pb = null; }
	// 最近几天路由器自动执行的计数（主程序记的 autocount.json）：没绑定、服务期外的也能看出用得多不多；读不到、不像样就不带
	try { ac = readJson(cfg.etc + '/autocount.json', null); if (type(ac) != 'object') ac = null; } catch (e) { ac = null; }
	const su = selfResult();
	const r = post('checkin', { version: installed(), updater: VERSION, lastUpgrade: last && !last.sent ? { 'from': last.prev, to: last.to, result: last.result, reason: last.reason, at: last.at } : null,
		...(su ? { lastUpgradeSelf: su } : {}),
		claimed: claimed(), kidNets: kidNets(), memberUntil: m?.x ?? 0, haveCurrent: haveCurrent(), ...(env ? { env } : {}), ...(pb ? { prebind: pb } : {}), ...(ac ? { auto: ac } : {}) });
	lastErr = r?.error ?? null;
	if (r?.error == 'LIMIT') log('报到太勤：离上次报到不到 60 秒，云端这次不收，过一分钟再报');
	if (r?.error == 'CLOCK') { clockFix(r.now); return null; }
	if (r?.error == 'NOT_REGISTERED') { fs.mkdir(cfg.run, 0700); fs.writefile(cfg.run + '/unregistered.now', '' + now()); log('云端没有这台的记录，通知主程序重新登记'); return null; }
	if (!r?.ok) return null;
	clockFix(r.now);
	writeJson(F('checkin.json'), { at: now(), day: today(now()), ok: true });
	if (last && !last.sent) { last.sent = true; writeJson(F('last.json'), last); }
	if (su) { const x = readJson(F('selfup.json'), {}); x.sent = true; writeJson(F('selfup.json'), x); }
	inbox(r);
	log('每日报到成功');
	return r;
}

// 报到并处理回包
function checkinAndAct() {
	if (!lock()) return null;
	fs.mkdir(cfg.dir, 0700);
	finishPending();
	const r = checkin();
	if (r) {
		if (r.current) keepCurrent(r.current);
		if (r.target) plan(r.target); else fs.unlink(F('pending.json'));
	}
	unlock();
	return r;
}

// 常驻进程
// 看门狗：限速规则还在、管控程序的状态 10 分钟（按开机时长算，不怕校时跳变）没更新 → 卡住了：放开网络，再重启管控（一天最多 3 次，
// 再卡就一直放开，等报到报上去、发新版本修）。记录放内存（/tmp/doti/watchdog.json），重启路由器就清零
const WD_STALE = 600, WD_RESTARTS = 3;
function watchdog() {
	const f = cfg.run + '/watchdog.json', r0 = readJson(f, null), w = type(r0) == 'object' ? r0 : {}, up = uptime(), m = mtime(cfg.run + '/status.json'), day = today(now());
	if (w.day != day) { w.day = day; w.n = 0; }
	if (!m || !rulesOn()) { w.m = m; w.since = up; writeJson(f, w); return; }
	if (m != w.m) { w.m = m; w.since = up; writeJson(f, w); return; }
	if (up - (w.since ?? up) < WD_STALE) { writeJson(f, w); return; }
	failOpen();
	log(sprintf('管控程序 %d 分钟没动静，已停管控、放开网络', int((up - w.since) / 60)));
	if (w.n < WD_RESTARTS) { w.n++; mainStart(); log(sprintf('重启管控（今天第 %d 次）', w.n)); }
	w.since = up;
	writeJson(f, w);
}

// 马上检查升级（云端经门铃让主程序写 upd.now，内容是管理员发起的时间）：没处理过的就马上报到，拿到新版本立即装（不等凌晨窗口）；
// 报到成功才算处理过（记 updnow.json），失败照常退避重试
const nowFlag = () => trim(fs.readfile(cfg.run + '/upd.now') ?? '');
const nowSeen = () => '' + (readJson(F('updnow.json'), null)?.v ?? '');
const nowWanted = () => { const v = nowFlag(); return v != '' && v != nowSeen(); };
function installPending() {
	const p = readJson(F('pending.json'), null);
	if (!p || !lock()) return;
	const o = signed(p);
	if (!o || install(o) != 'retry') fs.unlink(F('pending.json'));
	unlock();
}

// 装好后的报到节奏（按装好多久）：5、15、30 分钟各一次；第 1 天每小时；第 2–7 天每 2 小时；第 2 周每 6 小时；
// 之后只有每天凌晨那次（另算，一直都在）。间隔加 ±10% 随机。装好的时间记在 installed-at（{ id, at }），身份变了（重装、解除绑定）从头算；
// 第一次记时用设备身份文件的时间（主程序登记成功时写的；老设备升级上来不会从头加报）。
// 时钟没对过（早于 2024 年）时：新装的按开机时长算，以前记过的这段时间不加报（只靠每天那次和开机补报）
const RAMP_FIRST = [300, 900, 1800], CLOCK_MIN = 1704067200;
function rampGap(a) { return a < 86400 ? 3600 : a < 7 * 86400 ? 7200 : a < 14 * 86400 ? 21600 : 0; }
let ramp = { id: null, up0: null, last: null, jit: 1 };
// 装好多久（秒）；算不出来回 null
function installAge(id) {
	if (!id) return null;
	const t = now(), clockOk = t >= CLOCK_MIN, up = uptime();
	let f = readJson(F('installed-at'), null);
	if (ramp.id != id) {
		ramp = { id, up0: null, last: null, jit: 1 };
		const ck = readJson(F('checkin.json'), null);
		if (f?.id == id && f.at && clockOk && ck?.at >= f.at) ramp.last = ck.at - f.at;   // 重启后接着上次的节奏
	}
	if (f?.id != id) {
		const im = mtime(cfg.etc + '/identity.json');
		f = { id, at: clockOk ? (im >= CLOCK_MIN && im < t ? im : t) : 0 };
		writeJson(F('installed-at'), f);
		if (!clockOk) ramp.up0 = up;
	}
	if (clockOk) {
		if (!f.at || f.at > t) {
			f.at = t - (ramp.up0 != null ? up - ramp.up0 : 0);
			writeJson(F('installed-at'), f);
		}
		return t - f.at;
	}
	return ramp.up0 != null ? up - ramp.up0 : null;
}
// 这时候该不该按节奏加报一次（a：装好多久）
function rampDue(a) {
	if (a == null || a >= 14 * 86400) return false;
	for (let x in RAMP_FIRST) if (a >= x && (ramp.last == null || ramp.last < x)) return true;
	const g = rampGap(a);
	return a >= 1800 && g > 0 && (ramp.last == null || a - ramp.last >= g * ramp.jit);
}
// 一圈里的每一步单独兜住：出任何错只记日志（同样的错 10 分钟一次），放掉锁，常驻进程不退出，下一圈照常
let stepErr = '', stepErrAt = 0;
function guard(name, fn) {
	try { return fn(); }
	catch (e) {
		if (held) unlock();
		// 装到一半出的错：照断电收尾那样体检、不行就回滚
		if (fs.stat(F('state.json')) && lock()) { try { finishPending(); } catch (x) { failOpen(); } unlock(); }
		const s = name + '：' + e;
		if (s != stepErr || time() - stepErrAt >= 600) { stepErr = s; stepErrAt = time(); log('出错了（' + s + '），下一圈再试'); }
		return null;
	}
}

function daemon() {
	fs.mkdir(cfg.dir, 0700);
	if (lock()) { finishPending(); unlock(); }
	const ck = readJson(F('checkin.json'), null);
	let fails = 0, retryAt = 0, okDay = '';
	// 开机补报：一天没报到过；或者刚开机（开机 15 分钟内）、又不在服务期内——服务期外不连门铃，
	// 家长不在家续了费，断电重开路由器也能让它 5–30 分钟内取到新凭证
	const up = fs.readfile(getenv('DOTI_UPTIME') || '/proc/uptime'), boot = up != null && +split(up, ' ')[0] < 900;
	const svc = readJson(cfg.etc + '/remote.json', null)?.on === true && (readJson(cfg.etc + '/member.json', null)?.x ?? 0) > now();
	let catchUp = !ck?.at || now() - ck.at > 86400 || (boot && !svc) ? now() + 300 + int(rnd() * 1500) : 0;
	if (getenv('DOTI_UPD_ONCE')) catchUp = catchUp ? now() : 0;
	while (true) {
		const t = now(), id = identity(), lt = localtime(t), sec = lt.hour * 3600 + lt.min * 60 + lt.sec;
		const c = readJson(F('checkin.json'), null);
		const want = nowWanted(), flag = want ? nowFlag() : '';
		const age = guard('装好时间', () => installAge(id.id ?? ''));
		const daily = c?.day != today(t) && okDay != today(t) && sec >= slot(id.id ?? '') && sec < 6 * 3600;
		const due = id.registered && ((catchUp && t >= catchUp) || (retryAt && t >= retryAt) || (want && !retryAt) || (!retryAt && (daily || rampDue(age))));
		if (due) {
			const r = guard('报到', checkinAndAct);
			if (r) {
				fails = 0; retryAt = 0; catchUp = 0; okDay = today(t);
				ramp.last = age; ramp.jit = 0.9 + rnd() * 0.2;
				// 马上检查升级时升级程序和主程序都有新版：先换升级程序副本、退出由 procd 拉起，这次「马上」先不记成处理过，
				// 新副本起来后照「马上」再报到一次（撞 60 秒限制就 65 秒后再报），再装主程序。同一次「马上」只换一次副本：
				// 新副本起不来、被换回旧副本时，旧副本不再换，直接装主程序（不然会反复下载、反复重启）
				const tried = want && readJson(F('updnow-self.json'), null)?.v == flag;
				const self = r.updater && !tried ? guard('升级程序自更新', () => selfUpdate(r.updater)) : false;
				if (self) {
					if (want) { writeJson(F('updnow-self.json'), { v: flag, at: t }); log('马上检查升级：先换升级程序新副本，重启后接着装主程序'); }
					return 0;
				}
				if (want) { writeJson(F('updnow.json'), { v: flag, at: t }); log('马上检查升级：已报到' + (r.target || r.updater ? '，有新版本，马上装' : '，没有新版本')); }
				if (want && fs.stat(F('pending.json'))) guard('安装', installPending);
			}
			// 报得太勤（刚报过不到 60 秒，比如马上检查升级时刚换了升级程序）：65 秒后再报，不算失败、不退避
			else if (lastErr == 'LIMIT') retryAt = t + 65;
			else {
				log('报到没成功：' + (lastErr ?? '连不上云端或回包不对') + (fails < length(RETRY) ? '，稍后再试' : '，今天先不试了，等下一次'));
				if (++fails <= length(RETRY)) retryAt = t + int(RETRY[fails - 1] * (0.7 + rnd() * 0.6));
				else { fails = 0; retryAt = 0; catchUp = 0; ramp.last = age; }   // 这一轮放弃：按节奏等下一次，不连着重试
			}
		}
		else if (fs.stat(F('pending.json')) && t >= (readJson(F('dlfail.json'), null)?.next ?? 0)) guard('安装', () => {
			const p = readJson(F('pending.json'), null);
			let urgent = false;
			try { urgent = json(p?.info ?? '{}')?.urgent === true; } catch (e) {}
			if ((urgent || inWindow()) && lock()) {
				const o = signed(p);
				if (!o || install(o) != 'retry') fs.unlink(F('pending.json'));
				unlock();
			}
		});
		if (!fs.stat(cfg.tmp + '/doti-updater.lock')) guard('看门狗', watchdog);   // 升级、回滚时不看（那时本来就停着）
		if (getenv('DOTI_UPD_ONCE')) break;
		// 每分钟一圈；中间每 5 秒看一眼要不要马上检查升级，有就提前进下一圈
		for (let i = 0; i < 12 && !nowWanted(); i++) sleep(5000);
	}
	return 0;
}

// 自检
function selftest() {
	if (hmacSha256('key', 'The quick brown fox jumps over the lazy dog') != 'f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8') return 1;
	if (!fs.stat(pubkey())) return 1;
	return 0;
}

const cmd = ARGV[0];
if (cmd == 'daemon') exit(daemon());
else if (cmd == 'checkin') exit(checkinAndAct() ? 0 : 1);
else if (cmd == 'install') { const o = signed(readJson(F('pending.json'), null)); if (o && lock()) { if (install(o) != 'retry') fs.unlink(F('pending.json')); unlock(); } exit(0); }
else if (cmd == 'selftest') exit(selftest());
else if (cmd == 'version') { print(VERSION + '\n'); exit(0); }
else { warn('用法：doti-update daemon | checkin | install | selftest | version\n'); exit(2); }
