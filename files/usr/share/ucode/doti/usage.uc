// 上网记录：路由器上只给今天的；前几天的服务期内交给云端（历史统计），交上去就删，交不上最多留 KEEP_DAYS 天
'use strict';

export const KEEP_DAYS = 7;

// devs：这一步每台设备 { <MAC>: { on, d, u } }（d / u 是字节），没有按设备的判断时不传
export function add(day, key, hour, limited, inUseSec, downKB, upKB, devs) {
	if (!day[key]) day[key] = {};
	if (!day[key]['' + hour]) day[key]['' + hour] = { a: 0, l: 0, d: 0, u: 0 };
	const h = day[key]['' + hour];
	if (limited) h.l += inUseSec;
	else h.a += inUseSec;
	h.d += downKB;
	h.u += upKB;
	for (let mac, v in (devs ?? {})) {
		const sec = v.on ? int(inUseSec + 0.5) : 0, d = int(v.d ?? 0), u = int(v.u ?? 0);
		if (!sec && !d && !u) continue;
		h.m ??= {};
		const x = h.m[mac] ??= { a: 0, l: 0, d: 0, u: 0 };
		if (limited) x.l += sec;
		else x.a += sec;
		x.d += d;
		x.u += u;
	}
	return day;
};

// 一天的文件内容 → 上网记录接口的 networks
export function toApi(day) {
	const out = [];
	for (let key in sort(keys(day ?? {}))) {
		if (substr(key, 0, 1) == '_') continue;   // _ev 是状态变化记录
		const hours = [];
		for (let h in sort(map(keys(day[key]), x => +x), (x, y) => x - y)) {
			const v = day[key]['' + h];
			const openMin = int(v.a / 60.0 + 0.5), limitMin = int(v.l / 60.0 + 0.5);
			const down = int(v.d * 1024), up = int(v.u * 1024), bytes = down + up;
			if (!openMin && !limitMin && !bytes) continue;
			const devs = [];
			for (let mac in sort(keys(v.m ?? {}))) {
				const x = v.m[mac], o = int(x.a / 60.0 + 0.5), l = int(x.l / 60.0 + 0.5);
				if (o || l || x.d + x.u) push(devs, { mac, openMin: o, limitMin: l, down: x.d, up: x.u });
			}
			push(hours, { h, openMin, limitMin, bytes, down, up, ...(length(devs) ? { devs } : {}) });
		}
		if (length(hours)) push(out, { key, hours });
	}
	return out;
};

// 一个网络今天开放时总共在用多少分钟（规则开放、临时开放、固定开放都算，限速时段不算；按小时取整后相加，和上网记录页当天合计一样）
export function onlineMin(day, key) {
	let m = 0;
	for (let h, v in (day?.[key] ?? {})) m += int(v.a / 60.0 + 0.5);
	return m;
};

// 最近网速：每个网络留最近 n 个点 [下行, 上行]（字节/秒）
export function trendPush(tr, key, down, up, n) {
	const a = tr[key] ??= [];
	push(a, [down, up]);
	while (length(a) > n) shift(a);
	return tr;
};

// 公历日期和天数互换
function toDays(y, m, d) {
	y -= m <= 2 ? 1 : 0;
	const era = int((y >= 0 ? y : y - 399) / 400), yoe = y - era * 400;
	const doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1;
	return era * 146097 + yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy - 719468;
}
function fromDays(z) {
	z += 719468;
	const era = int((z >= 0 ? z : z - 146096) / 146097), doe = z - era * 146097;
	const yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365);
	const doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100)), mp = int((5 * doy + 2) / 153);
	const d = doy - int((153 * mp + 2) / 5) + 1, m = mp < 10 ? mp + 3 : mp - 9;
	return sprintf('%04d-%02d-%02d', yoe + era * 400 + (m <= 2 ? 1 : 0), m, d);
}

// 要删掉的文件
export function expired(files, today) {
	const keepFrom = fromDays(toDays(+substr(today, 0, 4), +substr(today, 5, 2), +substr(today, 8, 2)) - (KEEP_DAYS - 1));
	return filter(files, f => match(f, /^[0-9]{4}-[0-9]{2}-[0-9]{2}\.json$/) && substr(f, 0, 10) < keepFrom);
};

// 还没交给云端的日子：usage/ 里今天以前的文件名，从早到晚
export function pending(files, today) {
	return sort(filter(files ?? [], f => match(f, /^[0-9]{4}-[0-9]{2}-[0-9]{2}\.json$/) && substr(f, 0, 10) < today));
};

// 设备档案：主机名、类型（常驻程序记的）和家长起的名字；名字按 MAC 找，找不到再按主机名找（换了随机 MAC 的同一台）
// base / cur：baseline.json 的 devs、devices.json；names：devnames.json
export function devInfo(base, cur, names) {
	return (mac) => {
		const host = cur?.[mac]?.host || base?.[mac]?.host || '', type = cur?.[mac]?.type ?? base?.[mac]?.type ?? 'other';
		let name = names?.[mac]?.name ?? '';
		if (!name && host) for (let m, n in (names ?? {})) if (n.host == host && n.name) { name = n.name; break; }
		return { name, host, type };
	};
};

// 一天的计数（报到带上，看路由器替家长干了多少活；口径和云端每日摘要的 ev 一样）：各孩子网络加起来
//   nets 几个网络, open / limit 开放 / 限速时在用分钟（按小时取整再加）, round 智能降速轮数, fixed 限速时段触发, quota 用满每天最多的网络数,
//   temp 临时安排次数, tempMin 临时开放分钟, rule 改规则次数, start 智能开放开始计时次数（开机时的初始状态不算）
export function counts(day) {
	const c = { nets: 0, open: 0, limit: 0, round: 0, fixed: 0, quota: 0, temp: 0, tempMin: 0, rule: 0, start: 0 }, ks = {};
	for (let key in keys(day ?? {})) {
		if (substr(key, 0, 1) == '_' || type(day[key]) != 'object') continue;
		ks[key] = true;
		for (let h in keys(day[key])) { const v = day[key][h]; c.open += int((v?.a ?? 0) / 60.0 + 0.5); c.limit += int((v?.l ?? 0) / 60.0 + 0.5); }
	}
	for (let key in keys(day?._ev ?? {})) {
		ks[key] = true;
		let quota = false;
		for (let e in (day._ev[key] ?? [])) {
			if (e.e == 'p' && !e.d && e.p == 'smartLimit' && e.x) c.round++;
			else if (e.e == 'p' && e.p == 'quotaDone') quota = true;
			else if (e.e == 's') { c.temp++; if (e.a == 'open') c.tempMin += e.m ?? 0; }
			else if (e.e == 'r') c.rule++;
			if (e.e == 'p' && !e.d && e.p == 'fixedLimit') c.fixed++;
			else if (e.e == 'u') c.start++;
		}
		if (quota) c.quota++;
	}
	c.nets = length(keys(ks));
	return c;
};

// 最近几天的计数（autocount.json）：记上这一天，只留最近 n 天
export function countsKeep(all, date, c, n) {
	const out = { ...(type(all) == 'object' ? all : {}) };
	out[date] = c;
	const ds = sort(filter(keys(out), d => match(d, /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/)));
	const first = length(ds) - n;   // 22.03 的 ucode 没有 slice
	for (let d in keys(out)) if (index(ds, d) < first) delete out[d];
	return out;
};
