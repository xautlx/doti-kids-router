// 服务期凭证（member.json）和远程管理总开关（remote.json）：主程序（报到、同步回包）和局域网接口（在家开通时小程序交来）都写，
// 只经这里、在锁里写。make(d)：d = { store: { etc, readJson, writeJson, withLock }, verify, hmac, bumpGen, now, log }
'use strict';
import * as fs from 'fs';

export function make(d) {
	const F = d.store;
	const memberFile = () => F.etc('member.json'), remoteFile = () => F.etc('remote.json');
	const log = d.log ?? (() => {});

	// 服务期到期时间（凭证里的 x），没有为 null
	function memberUntil() { return F.readJson(memberFile(), null)?.x; }
	// 远程管理总开关：云端说开着才算开，没拿到过按关
	function remoteOn() { return F.readJson(remoteFile(), null)?.on === true; }

	// 收下会员凭证：验签（类型 member、给这台、按 opt 判断到期），到期时间变了才写、通知常驻程序重读。回 [到期时间, 错误]
	function memberSet(id, cred, opt) {
		if (!cred) return [null, 'missing'];
		const v = d.verify(d.hmac, id.key, cred, 'member', id.id, opt);
		if (!v[0]) return [null, v[1] ?? 'bad'];
		const r = F.withLock(() => {
			if (F.readJson(memberFile(), null)?.x == v[0].x) return false;
			F.writeJson(memberFile(), { x: v[0].x, cred, at: d.now() });
			return true;
		}, d.now());
		if (r[0] === true) { d.bumpGen(); log('会员到期时间更新：' + v[0].x); }
		return [v[0].x, null];
	}
	// 云端说没开通或已到期（NOT_MEMBER）：以云端为准，本地凭证作废
	function memberDrop() {
		const r = F.withLock(() => {
			if (!F.readJson(memberFile(), null)) return false;
			fs.unlink(memberFile());
			return true;
		}, d.now());
		if (r[0] === true) { d.bumpGen(); log('云端说远程管理没开通或已到期，本地会员作废'); }
	}
	// 总开关变了才写
	function remoteFlag(on) {
		if (remoteOn() == on) return false;
		F.writeJson(remoteFile(), { on, at: d.now() });
		log(on ? '远程管理已开放' : '远程管理暂停（总开关关了），停止同步');
		return true;
	}
	return { memberUntil, remoteOn, memberSet, memberDrop, remoteFlag };
};
