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
