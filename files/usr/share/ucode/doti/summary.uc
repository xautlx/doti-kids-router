// 每日摘要：一天结束后把当天明细（usage/<日期>.json）压成每个网络几百字节，给长期趋势和以后的分析报告用；留多久看闪存剩多少（plan）
// 只有时长、次数和流量，不含任何上网内容
'use strict';

export const KEEP_DAYS = 366;          // 空间充裕时最多留一年（接口最多给这么多天）
export const KEEP_MONTHS_LOW = 2;      // 空间偏紧时只留最近几个月（含当月）
export const LOW_KB = 2048, CRIT_KB = 512;   // 闪存剩余低于 LOW_KB 算偏紧，低于 CRIT_KB 连当天的摘要也先不写

function hm(t) { const l = localtime(t); return sprintf('%02d:%02d', l.hour, l.min); }

// day：一天的明细（usage.uc 的格式，_ev 是状态变化）；返回 { <网络>: 摘要 }
// 摘要：o 开放时在用分钟、l 限速时仍在用分钟、d / u 下行 / 上行 MB、h 24 个小时各在用几分钟、
// dev { <MAC>: { m 当天分钟, h { <小时>: 分钟 }（只记用过的小时） } }、last 最晚在用的那个小时（-1 表示没用）、
// ev { round 用完几轮, quota 用满每天最多, temp 临时安排次数, tempMin 临时开放共几分钟, rule 改规则次数 }、
// acts 家长操作原样留下（临时安排 s、取消 c、改规则 r、WiFi 开关 w，时间改成 HH:MM），first / lastEv 第一条和最后一条状态变化的时刻
export function summarize(day) {
	const out = {};
	for (let key in keys(day ?? {})) {
		if (substr(key, 0, 1) == '_') continue;
		const s = { o: 0, l: 0, d: 0, u: 0, h: [], dev: {}, last: -1 };
		for (let i = 0; i < 24; i++) push(s.h, 0);
		for (let hk, v in day[key]) {
			const h = +hk, o = int(v.a / 60.0 + 0.5), l = int(v.l / 60.0 + 0.5);
			s.o += o; s.l += l; s.d += v.d / 1024.0; s.u += v.u / 1024.0;
			if (h >= 0 && h < 24) { s.h[h] += o; if (o > 0 && h > s.last) s.last = h; }
			for (let mac, x in (v.m ?? {})) {
				const m = int(x.a / 60.0 + 0.5);
				if (!m) continue;
				const dv = s.dev[mac] ??= { m: 0, h: {} };
				dv.m += m; dv.h['' + h] = (dv.h['' + h] ?? 0) + m;
			}
		}
		s.d = int(s.d * 10 + 0.5) / 10.0; s.u = int(s.u * 10 + 0.5) / 10.0;
		out[key] = s;
	}
	for (let key, evs in (day?._ev ?? {})) {
		const s = out[key] ??= { o: 0, l: 0, d: 0, u: 0, h: [], dev: {}, last: -1 };
		if (!length(s.h)) for (let i = 0; i < 24; i++) push(s.h, 0);
		const c = { round: 0, quota: 0, temp: 0, tempMin: 0, rule: 0 }, acts = [];
		for (let e in evs) {
			if (e.e == 'p' && !e.d && e.p == 'smartLimit' && e.x) c.round++;
			else if (e.e == 'p' && e.p == 'quotaDone') c.quota = 1;
			else if (e.e == 's') { c.temp++; if (e.a == 'open') c.tempMin += e.m ?? 0; }
			else if (e.e == 'r') c.rule++;
			if (index(['s', 'c', 'r', 'w'], e.e) >= 0) { const a = { ...e, t: hm(e.t) }; if (a.u) a.u = hm(a.u); push(acts, a); }
		}
		s.ev = c;
		if (length(acts)) s.acts = acts;
		if (length(evs)) { s.first = hm(evs[0].t); s.lastEv = hm(evs[length(evs) - 1].t); }
	}
	return out;
};

// 摘要文件按月存：summary/<YYYY-MM>.json = { "<YYYY-MM-DD>": { <网络>: 摘要 } }
export function monthOf(date) { return substr(date, 0, 7); };

// 按闪存剩余空间决定：availKB 剩余 KB（读不到传 null，按充裕算）
// 返回 { write: 今天要不要写新摘要, del: 要删的月份文件 }
//   充裕：删整个月都在 KEEP_DAYS 天以前的；偏紧：只留最近 KEEP_MONTHS_LOW 个月；很紧：同偏紧，而且先不写
export function plan(files, today, now, availKB) {
	const ms = sort(filter(files, f => match(f, /^[0-9]{4}-[0-9]{2}\.json$/)));
	let cut;
	if (availKB != null && availKB < LOW_KB) {
		const lt = localtime(now), y = lt.year, m = lt.mon - (KEEP_MONTHS_LOW - 1);
		cut = m >= 1 ? sprintf('%04d-%02d', y, m) : sprintf('%04d-%02d', y - 1, m + 12);
	}
	else { const lt = localtime(now - KEEP_DAYS * 86400); cut = sprintf('%04d-%02d', lt.year, lt.mon); }
	return { write: availKB == null || availKB >= CRIT_KB, del: filter(ms, f => substr(f, 0, 7) < cut) };
};
