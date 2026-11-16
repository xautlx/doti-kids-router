// 远程同步的纯逻辑：关键状态、要不要立即上报、上报内容、命令执行记录。
'use strict';

export const CMD_KEEP = 100;

// 关键状态：只放变得慢的（剩余秒数、已用分钟、网速不算）
// pwAt：各 WiFi 密码最后改动的时间，变了（改了密码）立即报
export function keyState(status, settings, day, pwAt) {
	const vers = { global: settings?.globalVer ?? 0 };
	for (let n in (settings?.networks ?? [])) vers[n.key] = n.ver;
	return { day, router: { wan: status?.router?.wan ?? null, ...(pwAt ? { pwAt } : {}) },
		networks: map(status?.networks ?? [], n => [n.key, n.period, n.periodName ?? '', n.since ?? 0,
			n.period == 'smartOpen' ? 0 : (n.next ?? 0), !!n.want, n.plan?.seq ?? 0, n.wifiOn]),
		vers };
};

// 只是时段到点切换（各家同一时刻发生）→ 错开再报；其他变化（要网起落、设置、临时安排、热点、外网）立即报
export function urgent(prev, cur) {
	if (!prev) return true;
	if (sprintf('%J', prev.router) != sprintf('%J', cur.router) || sprintf('%J', prev.vers) != sprintf('%J', cur.vers)) return true;
	if (length(prev.networks) != length(cur.networks)) return true;
	for (let i = 0; i < length(cur.networks); i++) {
		const a = prev.networks[i], b = cur.networks[i];
		if (a[0] != b[0] || a[5] != b[5] || a[6] != b[6] || a[7] != b[7]) return true;
	}
	return false;
};

// 同步时带的状态：网络状态去掉网速；settings 只在设置版本变了时带（传 null 就不带，云端沿用上次存的）
// pwAt 放进 router 一起报（只有时间，没有密码）
export function reportBody(status, settings, pwAt) {
	return { router: pwAt ? { ...status.router, pwAt } : status.router, networks: map(status.networks ?? [], n => { const x = { ...n }; delete x.speed; return x; }), ...(settings ? { settings } : {}) };
};

// 执行记录：{ list: [{ i, state, result }] }，只留最近 CMD_KEEP 条
export function doneOf(rec, i) { for (let x in (rec?.list ?? [])) if (x.i == i) return x; return null; };
export function remember(rec, item) {
	const list = filter(rec?.list ?? [], x => x.i != item.i);
	push(list, item);
	while (length(list) > CMD_KEEP) shift(list);
	return { list };
};

// ---------- 路由器快照（三端同一份结构，ICD §2.9）：在家局域网 GET /doti/snapshot、远程同步上报、小程序缓存都是它 ----------
// { v, at, tags, router, networks, settings, wifi, parents }：五段各一个摘要 tags，摘要相同就是没变；只放路由器说了算的事，不放任何密码
export const SNAP_V = 1;
export const SNAP_PARTS = ['router', 'networks', 'settings', 'wifi', 'parents'];
// 32 位 FNV-1a，十六进制 8 位（只用来比较变没变）
export function fnv(s) {
	let h = 0x811c9dc5;
	for (let i = 0; i < length(s); i++) { h = h ^ ord(s, i); h = (h * 0x01000193) & 0xffffffff; }
	return sprintf('%08x', h);
};
// status：常驻程序这一圈的状态 { at, router, networks }；ks：keyState（网络段的摘要按它算，剩余秒数、已用分钟、网速这些每圈都变的不算）
// wifi：{ kids: [{ key, ssid, on }], parent: { ssid, set } }；parents：家长名单的公开部分（toPublic，不带 me）
export function snapshotOf(status, settings, wifi, parents, ks) {
	const J = x => sprintf('%J', x);
	return { v: SNAP_V, at: status.at, router: status.router, networks: status.networks, settings, wifi, parents,
		tags: { router: fnv(J(status.router)), networks: fnv(J([ks?.networks, ks?.router])), settings: fnv(J(ks?.vers)), wifi: fnv(J(wifi)), parents: fnv(J(parents)) } };
};
// 对方手里有的摘要 have（{ 段: 摘要 }）→ 只回变了的段；全都一样回 { same: true }
export function snapshotDiff(snap, have) {
	const out = { v: snap.v, at: snap.at, tags: snap.tags };
	let changed = false;
	for (let p in SNAP_PARTS) if (type(have) != 'object' || have[p] != snap.tags[p]) { out[p] = snap[p]; changed = true; }
	if (!changed) out.same = true;
	return out;
};
// 上报给云端用的：网络段去掉网速（每圈都变、远程看没意义）
export function snapshotReport(snap, have) {
	const d = snapshotDiff(snap, have);
	if (d.networks) d.networks = map(d.networks, n => { const x = { ...n }; delete x.speed; return x; });
	return d;
};
