// 设置：模板、默认值、校验、合并
'use strict';

export const SURF = [0, 15, 30, 45, 60, 75, 90, 120, 240, 1440];
export const LIMIT = [15, 30, 45, 60, 75, 90, 120, 240, 1440];
export const DAILY = [0, 30, 60, 90, 120, 180, 240, 480, 720, 960];
export const CATEGORIES = ['game', 'shortvideo', 'film'];   // 游戏、短视频和直播、影视
const NET_KEYS = ['k1', 'k2', 'k3'];
export const DEFAULT_NAMES = { k1: '大宝的网络', k2: '二宝的网络', k3: '三娃的网络' };
export function defaultRouterName(code) { return '一点守护路由器 ' + (code || ''); };
const MAX_WIN = 8, MAX_CUSTOM = 200;

function sleepWins(a, b) {
	if (!a) return [];
	return [ { id: 'w1', kind: 'limit', name: '睡觉', days: [7, 1, 2, 3, 4], start: a[0], end: a[1] },
		{ id: 'w2', kind: 'limit', name: '睡觉（周末）', days: [5, 6], start: b[0], end: b[1] } ];
}

export const TEMPLATES = {
	preschool: { surfMin: 30, limitMin: 75, dailyMaxMin: 60, sleep: [['20:00', '07:00'], ['21:00', '08:00']] },
	lower: { surfMin: 30, limitMin: 60, dailyMaxMin: 90, sleep: [['21:00', '07:00'], ['22:00', '08:00']] },
	upper: { surfMin: 30, limitMin: 45, dailyMaxMin: 120, sleep: [['21:30', '07:00'], ['22:30', '08:00']] },
	teen: { surfMin: 45, limitMin: 30, dailyMaxMin: 180, sleep: [['22:30', '06:30'], ['23:30', '07:30']] },
	onDemand: { surfMin: 0, limitMin: 1440, dailyMaxMin: 0, sleep: null }
};

// 按模板生成一个网络的整份设置
// 限速时网速（kbps）：0 断网、100 很慢（默认，能发文字）、500 慢（能看图）；不给更快的档，再快短视频就能放了
export const LIMIT_KBPS = [0, 100, 500], LIMIT_KBPS_DEFAULT = 100;
// 家里局域网不计时、不限速（lanFree）：默认是——打印机、NAS 照常用；孩子借家里开着代理的设备绕过管控时，家长关掉它（界面上叫「家里局域网也计时、限速」）
export const LAN_FREE_DEFAULT = true;
// 孩子网络状态显示：连着这个孩子 WiFi、又不是家长的手机打开小程序时看到什么。detail 详细（状态、还能用多久、今天用了多少、规则），simple 极简（只有开放还是限速）
export const KID_VIEWS = ['detail', 'simple'], KID_VIEW_DEFAULT = 'detail';
// 放行加密 DNS（allowDoh）：默认放行——代理软件、浏览器安全 DNS 照常能用；孩子自己改 DNS 绕过屏蔽名单时，家长关掉它（界面上叫「拦截加密 DNS」）
export const ALLOW_DOH_DEFAULT = true;

export function fromTemplate(tpl, key, name, ver) {
	const t = TEMPLATES[tpl];
	return { key, ver: ver ?? 1, name: name || DEFAULT_NAMES[key] || key, template: tpl,
		surfMin: t.surfMin, limitMin: t.limitMin, dailyMaxMin: t.dailyMaxMin,
		windows: t.sleep ? sleepWins(t.sleep[0], t.sleep[1]) : [], limitKbps: LIMIT_KBPS_DEFAULT, lanFree: LAN_FREE_DEFAULT, kidView: KID_VIEW_DEFAULT, allowDoh: ALLOW_DOH_DEFAULT };
};

export function defaults(keys, code) {
	return { globalVer: 1, routerName: defaultRouterName(code),
		block: { categories: [], except: {}, custom: [], paused: [], shareCustom: true },
		networks: map(keys, k => fromTemplate('lower', k)) };
};

// UTF-8 按字符计数、截断
function chars(s) {
	let n = 0;
	for (let i = 0; i < length(s); i++) if ((ord(s, i) & 0xC0) != 0x80) n++;
	return n;
}
export function cleanText(s, max) {
	if (type(s) != 'string') return '';
	let out = '', n = 0;
	for (let i = 0; i < length(s); i++) {
		const b = ord(s, i);
		if (b < 0x20 || b == 0x7f) continue;
		if ((b & 0xC0) != 0x80) { if (n == max) break; n++; }
		out += chr(b);
	}
	return trim(out);
};

// 域名校验
export function cleanDomain(d) {
	if (type(d) != 'string') return null;
	d = lc(trim(d));
	if (substr(d, 0, 2) == '*.') d = substr(d, 2);
	while (length(d) && substr(d, -1) == '.') d = substr(d, 0, length(d) - 1);
	if (length(d) < 3 || length(d) > 253 || !match(d, /^[a-z0-9-]+(\.[a-z0-9-]+)+$/)) return null;
	for (let p in split(d, '.'))
		if (length(p) < 1 || length(p) > 63 || substr(p, 0, 1) == '-' || substr(p, -1) == '-') return null;
	return d;
};

function inList(v, list) { for (let x in list) if (x === v) return true; return false; }
function isTime(s) { return type(s) == 'string' && !!match(s, /^([01][0-9]|2[0-3]):[0-5][0-9]$/); }

function checkWindows(ws) {
	if (type(ws) != 'array') return [null, 'windows'];
	const out = [], count = { open: 0, limit: 0 }, ids = {};
	for (let w in ws) {
		if (type(w) != 'object' || !inList(w.kind, ['open', 'limit'])) return [null, 'windows.kind'];
		if (++count[w.kind] > MAX_WIN) return [null, 'windows.count'];
		if (type(w.id) != 'string' || !match(w.id, /^[A-Za-z0-9]{1,8}$/) || ids[w.id]) return [null, 'windows.id'];
		ids[w.id] = true;
		if (type(w.days) != 'array' || !length(w.days)) return [null, 'windows.days'];
		const seen = {};
		for (let d in w.days) {
			if (type(d) != 'int' || d < 1 || d > 7 || seen[d]) return [null, 'windows.days'];
			seen[d] = true;
		}
		if (!isTime(w.start) || !isTime(w.end) || w.start == w.end) return [null, 'windows.time'];
		push(out, { id: w.id, kind: w.kind, name: cleanText(w.name, 10), days: sort(map(w.days, x => x)), start: w.start, end: w.end });
	}
	return [out, null];
}

// 校验一个网络的设置
export function checkNet(n) {
	if (type(n) != 'object') return [null, 'network'];
	if (!inList(n.surfMin, SURF)) return [null, 'surfMin'];
	if (!inList(n.limitMin, LIMIT)) return [null, 'limitMin'];
	if (!inList(n.dailyMaxMin, DAILY)) return [null, 'dailyMaxMin'];
	// 高级设置：限速时网速、家里局域网不计时不限速、孩子网络状态显示、关闭加密 DNS 拦截（没带就是默认）
	const kbps = n.limitKbps ?? LIMIT_KBPS_DEFAULT, lan = n.lanFree ?? LAN_FREE_DEFAULT, kv = n.kidView ?? KID_VIEW_DEFAULT, doh = n.allowDoh ?? ALLOW_DOH_DEFAULT;
	if (!inList(kbps, LIMIT_KBPS)) return [null, 'limitKbps'];
	if (type(lan) != 'bool') return [null, 'lanFree'];
	if (!inList(kv, KID_VIEWS)) return [null, 'kidView'];
	if (type(doh) != 'bool') return [null, 'allowDoh'];
	if (n.template != null && n.template != '' && !TEMPLATES[n.template]) return [null, 'template'];
	const w = checkWindows(n.windows ?? []);
	if (w[1]) return [null, w[1]];
	const name = cleanText(n.name, 10);
	return [{ key: n.key, ver: 0, name: name || DEFAULT_NAMES[n.key] || n.key, template: n.template || '',
		surfMin: n.surfMin, limitMin: n.limitMin, dailyMaxMin: n.surfMin == 1440 ? 0 : n.dailyMaxMin, windows: w[0], limitKbps: kbps, lanFree: lan, kidView: kv, allowDoh: doh }, null];
};

function checkBlock(b, old) {
	if (type(b) != 'object') return [null, 'block'];
	const cats = [];
	for (let c in (b.categories ?? [])) {
		if (!inList(c, CATEGORIES)) return [null, 'block.categories'];
		if (!inList(c, cats)) push(cats, c);
	}
	const custom = [];
	for (let d in (b.custom ?? [])) {
		const c = cleanDomain(d);
		if (c && !inList(c, custom)) push(custom, c);
	}
	if (length(custom) > MAX_CUSTOM) return [null, 'block.custom'];
	// 某个分类不挡哪几个孩子网络（UI-KID-09e）：只对开着的分类记，空的不记
	if (b.except != null && type(b.except) != 'object') return [null, 'block.except'];
	const except = {};
	for (let c, ks in (b.except ?? {})) {
		if (!inList(c, CATEGORIES) || type(ks) != 'array') return [null, 'block.except'];
		if (!inList(c, cats)) continue;
		const out = [];
		for (let k in ks) if (inList(k, NET_KEYS) && !inList(k, out)) push(out, k);
		if (length(out)) except[c] = out;
	}
	const paused = [];
	for (let d in (b.paused ?? [])) {
		const c = cleanDomain(d);
		if (c && inList(c, custom) && !inList(c, paused)) push(paused, c);
	}
	return [{ categories: cats, except, custom, paused, shareCustom: b.shareCustom ?? old?.shareCustom ?? true }, null];
}

// 旧路由器的名字还是默认的「一点守护路由器 <编号>」：编号换了，不带过来
function isDefaultName(n) {
	const p = defaultRouterName('');
	return index(n, p) == 0 && match(substr(n, length(p)), /^[0-9A-Za-z]*$/) != null;
}

// 从恢复包整份替换设置；路由器名只带家长改过的，默认名按 code（恢复旧编号时是旧编号）
export function restore(cur, s, keys, code) {
	const b = type(s?.block) == 'object' ? checkBlock(s.block, cur.block)[0] : null;
	const name = cleanText(s?.routerName, 12);
	return { ...cur, routerName: name && !isDefaultName(name) ? name : isDefaultName(cur.routerName) ? defaultRouterName(code) : cur.routerName, block: b ?? cur.block, globalVer: cur.globalVer + 1,
		networks: map(cur.networks, n => {
			for (let x in (s?.networks ?? [])) if (x?.key == n.key && index(keys, n.key) >= 0) {
				const c = checkNet(x);
				if (c[0]) return { ...c[0], ver: n.ver + 1 };
			}
			return n;
		}) };
};

// 保存设置
export function merge(cur, req, keys, code) {
	if (type(req) != 'object' || type(req.base) != 'object') return { err: 'base' };
	const next = json(sprintf('%J', cur)), conflicts = [];
	const wantGlobal = req.routerName != null || req.block != null;
	let gBlock = null;
	if (req.block != null) {
		const b = checkBlock(req.block, cur.block);
		if (b[1]) return { err: b[1] };
		gBlock = b[0];
	}
	const nets = [], seen = {};
	for (let n in (req.networks ?? [])) {
		if (type(n) != 'object' || !inList(n.key, keys) || seen[n.key]) return { err: 'networks.key' };
		seen[n.key] = true;
		const r = checkNet(n);
		if (r[1]) return { err: r[1] };
		push(nets, r[0]);
	}
	if (wantGlobal) {
		if (req.base.global !== cur.globalVer) push(conflicts, 'global');
		else {
			if (req.routerName != null) next.routerName = cleanText(req.routerName, 12) || defaultRouterName(code);
			if (gBlock) next.block = gBlock;
			next.globalVer = cur.globalVer + 1;
		}
	}
	for (let n in nets) {
		let idx = -1;
		for (let i = 0; i < length(next.networks); i++) if (next.networks[i].key == n.key) idx = i;
		const curVer = idx >= 0 ? next.networks[idx].ver : 0;
		if (req.base[n.key] !== curVer) { push(conflicts, n.key); continue; }
		n.ver = curVer + 1;
		if (idx >= 0) next.networks[idx] = n;
		else push(next.networks, n);
	}
	return { settings: next, conflicts, err: null };
};
