// 云端请求
'use strict';
import * as fs from 'fs';

// 云端地址：主地址和备用地址，主地址网络不通（没有 JSON 回包）时用备用
export function urls() {
	const a = getenv('DOTI_CLOUD') || trim(fs.readfile('/usr/share/doti/cloud') ?? '');
	const b = getenv('DOTI_CLOUD_BACKUP') ?? trim(fs.readfile('/usr/share/doti/cloud-backup') ?? '');
	return filter([a, b], (u, i) => u && (i == 0 || u != a));
};
export function url() { return urls()[0] ?? ''; };

export function envelope(hmac, id, op, ts, body) {
	const b = sprintf('%J', body ?? {});
	if (op == 'register') return { op, body: b };
	return { op, id: id.id, ts, body: b, sig: hmac(id.key, 'doti1|req|' + op + '|' + ts + '|' + b) };
};

export function post(hmac, id, op, ts, body, dir) {
	const us = urls();
	if (!length(us)) return null;
	const f = dir + '/req-' + op + '.json';
	fs.writefile(f, sprintf('%J', envelope(hmac, id, op, ts, body)));
	fs.chmod(f, 0600);
	let r = null;
	for (let u in us) {
		const p = fs.popen(sprintf("%s -q -T 10 -O - --post-file='%s' '%s' 2>/dev/null", getenv('DOTI_FETCH') || 'uclient-fetch', f, u), 'r');
		const out = p ? p.read('all') : null;
		if (p) p.close();
		try { r = json(out ?? ''); } catch (e) { r = null; }
		if (type(r) == 'object') break;
		r = null;
	}
	fs.unlink(f);
	return r;
};

// 失败重试的退避时间
export function backoff(fails, base, cap) {
	let g = base;
	for (let i = 1; i < fails && g < cap; i++) g *= 2;
	const f = fs.open('/dev/urandom', 'r'), b = f.read(1);
	f.close();
	return int(min(g, cap) * (0.5 + ord(b, 0) / 255.0));
};
