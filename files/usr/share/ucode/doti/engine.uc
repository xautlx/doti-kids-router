// 管控状态机
'use strict';

// ---------- 时段 ----------
function bit(wday) { return (wday + 6) % 7; }
function mins(s) { return int(substr(s, 0, 2)) * 60 + int(substr(s, 3, 2)); }
function midnightOf(lt, now) { return now - (lt.hour * 3600 + lt.min * 60 + lt.sec); }

export function inWindow(w, lt, now) {
	const cur = lt.hour * 60 + lt.min, f = mins(w.from), t = mins(w.to);
	const d = bit(lt.wday), prev = (d + 6) % 7, m0 = midnightOf(lt, now);
	if (f < t)
		return ((w.days & (1 << d)) && cur >= f && cur < t) ? m0 + t * 60 : null;
	if ((w.days & (1 << d)) && cur >= f) return m0 + 86400 + t * 60;
	if ((w.days & (1 << prev)) && cur < t) return m0 + t * 60;
	return null;
};

export function find(list, lt, now) {
	for (let w in (list || [])) {
		const u = inWindow(w, lt, now);
		if (u != null) return { win: w, until: u };
	}
	return null;
};

// 设置里的网络 → 引擎用的形式
export function toEngine(net) {
	const out = { key: net.key, surf: (net.surfMin ?? 30) * 60, lim: (net.limitMin ?? 45) * 60,
		dailyMax: (net.dailyMaxMin ?? 0) * 60, open: [], limit: [] };
	for (let w in (net.windows || [])) {
		let mask = 0;
		for (let d in w.days) mask |= 1 << (d - 1);
		push(w.kind == 'open' ? out.open : out.limit, { days: mask, from: w.start, to: w.end, name: w.name || '' });
	}
	return out;
};

export function today(lt) { return sprintf('%04d-%02d-%02d', lt.year, lt.mon, lt.mday); };

function fresh(n, day) { return { day, mode: 'open', remain: n.surf, used: 0, surf: n.surf }; }

// 算一步：返回 [新进度, 输出]
export function step(n, st, plan, ctx) {
	if (!st || st.day != ctx.today) st = fresh(n, ctx.today);
	if (st.mode == 'open') {
		if (n.surf > st.surf) st.remain += n.surf - st.surf;
		if (st.remain > n.surf) st.remain = n.surf;
	}
	else if (st.remain > n.lim) st.remain = n.lim;
	st.surf = n.surf;

	const tomorrow = midnightOf(ctx.lt, ctx.now) + 86400;
	const out = { key: n.key, period: '', periodName: '', limited: false, remainSec: 0, until: 0, usedSec: int(st.used) };
	function set(period, limited, until, name) {
		out.period = period; out.limited = limited; out.until = until; out.periodName = name || '';
		return [st, out];
	}

	if (plan && plan.date == ctx.today) {
		if (plan.action == 'open' && ctx.now < plan.until) return set('tempOpen', false, plan.until);
		if (plan.action == 'openAll') return set('allOpen', false, tomorrow);
		if (plan.action == 'limitAll') return set('allLimit', true, tomorrow);
	}
	let hit = find(n.open, ctx.lt, ctx.now);
	if (hit) return set('fixedOpen', false, hit.until, hit.win.name);
	hit = find(n.limit, ctx.lt, ctx.now);
	if (hit) return set('fixedLimit', true, hit.until, hit.win.name);
	if (n.surf == 0) return set('smartLimit', true, 0);
	if (n.dailyMax > 0 && st.used >= n.dailyMax) return set('quotaDone', true, tomorrow);

	if (st.mode == 'open') {
		if (ctx.inUse) { st.remain -= ctx.dt; st.used += ctx.dt; st.idle = 0; }
		else {
			// 连续不用网满一个限速时长，当作休息过了，这一轮补满（中途断断续续的不补）
			st.idle = (st.idle ?? 0) + ctx.dt;
			if (n.lim > 0 && st.idle >= n.lim && st.remain < n.surf) { st.remain = n.surf; st.idle = 0; }
		}
		if (st.remain <= 0) { st.mode = 'limit'; st.remain = n.lim; st.idle = 0; }
	}
	else {
		st.remain -= ctx.dt;
		if (st.remain <= 0) { st.mode = 'open'; st.remain = n.surf; st.idle = 0; }
	}
	out.period = st.mode == 'open' ? 'smartOpen' : 'smartLimit';
	out.limited = st.mode == 'limit';
	out.remainSec = int(st.remain);
	out.usedSec = int(st.used);
	return [st, out];
};

// 下次预计切换时刻
export function nextOf(out, now, inUse) {
	const p = out.period;
	if (p == 'tempOpen' || p == 'fixedOpen' || p == 'fixedLimit' || p == 'allOpen' || p == 'allLimit' || p == 'quotaDone')
		return out.until || null;
	if (p == 'smartLimit') return out.remainSec > 0 ? now + out.remainSec : null;
	if (p == 'smartOpen') return inUse ? now + out.remainSec : null;
	return null;
};

// 同一段
export function segOf(out) { return out.period + '|' + out.periodName + '|' + out.until; };

export const SPEED_KBS = 100;
export const PPS = 10;

// 没有按设备数据时的退路
export function classify(bytes, pkts, dt) {
	if (dt <= 0) return 'idle';
	if (bytes / 1024 / dt > SPEED_KBS) return 'over';
	if (pkts / dt > PPS) return 'active';
	return 'idle';
};
