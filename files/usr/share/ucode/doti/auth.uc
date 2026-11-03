// 签名对象和家长名单
'use strict';

export const MAX_PARENTS = 10;
const MAX_JOINED = 50;
const OFFLINE_GRACE = 7 * 86400;

export function b64u(s) {
	return replace(replace(replace(b64enc(s), /\+/g, '-'), /\//g, '_'), /=+$/, '');
};
export function unb64u(s) {
	if (type(s) != 'string' || !match(s, /^[A-Za-z0-9_-]*$/)) return null;
	s = replace(replace(s, /-/g, '+'), /_/g, '/');
	while (length(s) % 4) s += '=';
	return b64dec(s);
};

// 恒定时间比较
export function ctEq(a, b) {
	if (type(a) != 'string' || type(b) != 'string' || length(a) != length(b)) return false;
	let d = 0;
	for (let i = 0; i < length(a); i++) d |= ord(a, i) ^ ord(b, i);
	return d == 0;
};

function mac(hmac, key, t, payload) { return hmac(key, 'doti1|' + t + '|' + payload); }

// body 必带 t、d、e
export function sign(hmac, key, body) {
	const p = b64u(sprintf('%J', body));
	return p + '.' + mac(hmac, key, body.t, p);
};

// 校验签名对象
export function verify(hmac, key, obj, t, devId, opt) {
	if (type(obj) != 'string') return [null, 'format'];
	const i = index(obj, '.');
	if (i < 1) return [null, 'format'];
	const p = substr(obj, 0, i), sig = substr(obj, i + 1);
	if (!ctEq(mac(hmac, key, t, p), sig)) return [null, 'sig'];
	const raw = unb64u(p);
	let body = null;
	try { body = json(raw); } catch (e) { return [null, 'format']; }
	if (type(body) != 'object' || body.t !== t) return [null, 'type'];
	if (body.d !== devId) return [null, 'device'];
	if (opt?.clockOk !== false && type(body.e) == 'int') {
		const grace = opt?.offline ? OFFLINE_GRACE : 0;
		if (opt.now > body.e + grace) return [null, 'expired'];
	}
	return [body, null];
};

// ---------- 家长名单 { parents: [{ o, nick, avatar, at, by }], joined: [], ver } ----------

export function emptyList() { return { parents: [], joined: [], ver: 0 }; };

export function indexOf(list, o) {
	for (let i = 0; i < length(list.parents); i++) if (list.parents[i].o === o) return i;
	return -1;
};
export function isParent(list, o) { return type(o) == 'string' && indexOf(list, o) >= 0; };

function bump(list) { list.ver++; return list; }

export function claim(list, o, nick, avatar, now) {
	if (length(list.parents)) return [list, 'CLAIMED'];
	push(list.parents, { o, nick: nick || '', avatar: avatar || '', at: now, by: '' });
	return [bump(list), null];
};

// 加入凭证正文 { j, o, n, by }
export function join(list, cred, avatar, now) {
	for (let j in list.joined) if (j === cred.j) return [list, 'USED'];
	if (!isParent(list, cred.by)) return [list, 'INVITER_GONE'];
	if (isParent(list, cred.o)) return [list, null];
	if (length(list.parents) >= MAX_PARENTS) return [list, 'FULL'];
	push(list.parents, { o: cred.o, nick: cred.n || '', avatar: avatar || '', at: now, by: cred.by });
	push(list.joined, cred.j);
	while (length(list.joined) > MAX_JOINED) shift(list.joined);
	return [bump(list), null];
};

export function remove(list, o) {
	const i = indexOf(list, o);
	if (i < 0) return [list, 'NOT_FOUND'];
	splice(list.parents, i, 1);
	return [bump(list), null];
};

export function setProfile(list, o, nick, avatar) {
	const i = indexOf(list, o);
	if (i < 0) return [list, 'NOT_FOUND'];
	if (nick != null) list.parents[i].nick = nick;
	if (avatar != null) list.parents[i].avatar = avatar;
	return [bump(list), null];
};

// 返回给小程序
export function toPublic(list, me) {
	return map(list.parents, (p, i) => {
		const b = p.by ? indexOf(list, p.by) : -1;
		return { idx: i + 1, nick: p.nick, avatar: p.avatar, me: p.o === me, by: b >= 0 ? b + 1 : 0, at: p.at };
	});
};
