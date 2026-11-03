// 状态变化记录：每个孩子网络每天一份，按发生顺序；比较这一步和上一步，有变化才记
'use strict';

export const MAX_PER_DAY = 300;
const RULE_FIELDS = ['surfMin', 'limitMin', 'dailyMaxMin', 'limitKbps'];

function winKey(ws) { return join(';', map(ws ?? [], w => join(',', [w.kind, w.name, join('', w.days ?? []), w.start, w.end]))); }
function who(w, t) { return w && t - (w.at ?? 0) <= 120 ? w.by : null; }

// mem：这个网络上一步记下的 { p, n, seq, on, wifi, ver, rules, pend }（null 表示这一天 / 这次开机第一次）
// x：这一步 { period, periodName, remainSec, next, plan, planOn, inUse, wifiOn, ver, rules, who, cancel, boot }
// 返回 [新的 mem, 要记的事件]
export function step(mem, x, t) {
	const ev = [], add = (o) => push(ev, { t, ...o });
	const rules = {};
	for (let f in RULE_FIELDS) rules[f] = x.rules?.[f];
	rules.w = winKey(x.rules?.windows);
	const pl = x.plan, seq = pl?.seq ?? 0;
	const pe = (d) => ({ e: 'p', p: x.period, ...(x.periodName ? { n: x.periodName } : {}), ...(x.remainSec != null ? { r: x.remainSec } : {}),
		...(x.next ? { x: x.next } : {}), ...(d ? { d: 1 } : {}) });
	if (!mem) {
		// boot：reboot 路由器刚开机，restart 只是管控程序重新启动（升级、重启服务）
		if (x.boot) add({ e: 'b', ...(x.boot == 'restart' ? { k: 1 } : {}) });
		add(pe(true));
		return [{ p: x.period, n: x.periodName ?? '', seq, on: !!x.planOn, wifi: x.wifiOn, ver: x.ver, rules, pend: x.period == 'smartOpen' && !x.inUse }, ev];
	}
	const m = { ...mem };
	// WiFi 开关
	if (x.wifiOn != null && m.wifi != null && x.wifiOn != m.wifi) add({ e: 'w', o: x.wifiOn, ...(who(x.who?.w, t) ? { b: who(x.who.w, t) } : {}) });
	if (x.wifiOn != null) m.wifi = x.wifiOn;
	// 规则改了：只记和计时相关的几项，固定时段只记改没改
	if (x.ver != null && m.ver != null && x.ver != m.ver) {
		const f = {};
		for (let k in RULE_FIELDS) if (rules[k] != m.rules?.[k]) f[k] = [m.rules?.[k], rules[k]];
		if (rules.w != m.rules?.w) f.windows = 1;
		add({ e: 'r', ...(length(keys(f)) ? { f } : {}), ...(who(x.who?.r, t) ? { b: who(x.who.r, t) } : {}) });
	}
	if (x.ver != null) { m.ver = x.ver; m.rules = rules; }
	// 临时安排：新设、取消、到点结束
	if (seq && seq != m.seq) add({ e: 's', a: pl.action, ...(pl.minutes ? { m: pl.minutes, u: pl.until } : {}), ...(pl.by ? { b: pl.by } : {}) });
	else if (!seq && m.seq) add({ e: 'c', ...(x.cancel?.by && t - (x.cancel.at ?? 0) <= 120 ? { b: x.cancel.by } : {}) });
	else if (seq && m.on && !x.planOn) add({ e: 'x' });
	m.seq = seq; m.on = !!x.planOn;
	// 时段变了（WiFi 关着时不记时段）
	if ((x.period != m.p || (x.periodName ?? '') != m.n) && x.period != 'wifiOff') {
		add(pe(false));
		m.pend = x.period == 'smartOpen';
	}
	m.p = x.period; m.n = x.periodName ?? '';
	// 智能开放的这一轮第一次有人在用：开始计时
	if (m.pend && x.period == 'smartOpen' && x.inUse) { add({ e: 'u', ...(x.remainSec != null ? { r: x.remainSec } : {}) }); m.pend = false; }
	if (x.period != 'smartOpen') m.pend = false;
	return [m, ev];
};

// 记到当天的文件里：day._ev = { k1: [...] }，每个网络最多 MAX_PER_DAY 条（多了丢最早的）
export function append(day, key, ev) {
	if (!length(ev)) return day;
	day._ev ??= {};
	const a = day._ev[key] ??= [];
	// 几分钟内接连重启（比如安装时服务重启两次）：只留最后一次
	const n = length(a);
	if (ev[0].e == 'b' && n >= 2 && a[n - 2].e == 'b' && a[n - 1].d && ev[0].t - a[n - 1].t < 180) { pop(a); pop(a); }
	for (let e in ev) push(a, e);
	while (length(a) > MAX_PER_DAY) shift(a);
	return day;
};
