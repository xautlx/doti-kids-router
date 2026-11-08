// 按设备的用网判定
'use strict';

export const P = {
	dn_kbs: 10,        // 规则 1
	udp_pps: 10,       // 规则 2
	new_over: 5,       // 规则 3
	kbs_over: 3,       // 且流量比底噪多
	win: 3, need: 2,   // 平滑
	hold_min: 60, hold_max: 300,   // 延续秒数
	video_kbs: 125,    // 估算播放时长用的码率
	burst_max: 120,    // 一阵下载不超过这么多秒才当作缓冲、按下载量延续
	pre_sec: 20, pre_min: 1024, pre_max: 20480,   // 预缓存
	audio_kbs: 20,     // 预缓存按这个码率估算能播多久
	long_n: 18,        // 长窗口
	long_margin: 0.1,  // 长窗口门槛 = 底噪 95% 分位 × (1 + m) + m
	sample_every: 60,  // 学习时多久取一个 3 分钟样本
	quiet_for: 180,    // 最近这么多秒没命中任何规则才取样本
	res_pps_max: 20, res_kbs_max: 5,   // 底噪样本绝对上限
	sess_max: 30,      // 一段学习最多攒多少样本就入档
	res_max: 300,      // 每台设备最多留多少底噪样本
	learn_min: 20,     // 样本够这么多才用自己的底噪
	keep_days: 30,     // 多久没出现的设备删掉档案
};
// 没学到底噪时的默认值
const DEFAULT = { phone: { pps95: 1.0, kbs: 0.3, new: 1 }, other: { pps95: null, kbs: 1, new: 3 } };

function hex(s) { const n = +('0x' + s); return n == n ? n : null; }
// 设备类型粗分
export function devType(host, mac) {
	const h = lc(host ?? '');
	if (match(h, /tv|osca|box|projector|电视/)) return 'tv';
	if (match(h, /iphone|ipad|android|huawei|honor|xiaomi|redmi|oppo|vivo|oneplus|realme|galaxy|^[a-z]{3}-[a-z]{2}[0-9]{2}/)) return 'phone';
	if (match(h, /mac|imac|pc|desktop|laptop|windows|thinkpad|surface/)) return 'pc';
	const b = hex(substr(mac ?? '00', 0, 2));
	if (b != null && (b & 2)) return 'phone';
	return 'other';
};

function quietRes(r) { return r[0] <= P.res_pps_max && r[1] <= P.res_kbs_max; }
function q(arr, p) { if (!length(arr)) return 0; const a = sort(map(arr, x => x), (x, y) => x - y); return a[min(length(a) - 1, int(length(a) * p))]; }
function keep(arr, x, n) { push(arr, x); while (length(arr) > n) shift(arr); }

// 这台设备当前用的底噪
export function baseOf(b, type) {
	const res = b?.res ?? [];
	if (length(res) >= P.learn_min)
		return { pps95: q(map(res, r => r[0]), 0.95), kbs: q(map(res, r => r[1]), 0.5), new: q(map(res, r => r[2]), 0.5), learned: true };
	const d = DEFAULT[type == 'phone' ? 'phone' : 'other'];
	return { pps95: d.pps95, kbs: d.kbs, new: d.new, learned: false };
};

export function create(saved) {
	const S = { devs: {}, base: {}, dirty: false };
	for (let mac, b in (saved?.devs ?? {})) {
		const res = filter(b.res ?? [], quietRes);
		if (length(res) != length(b.res ?? [])) S.dirty = true;
		S.base[mac] = { host: b.host ?? '', type: b.type ?? 'other', res, seen: b.seen ?? 0 };
	}
	return S;
};

export function save(S, now) {
	const out = { ver: 1, devs: {} };
	for (let mac, b in S.base) if (now - b.seen < P.keep_days * 86400) out.devs[mac] = b;
	return out;
};

// MAC 变了但主机名相同
function baseFor(S, mac, host, now) {
	if (S.base[mac]) return S.base[mac];
	if (host) for (let m, b in S.base) {
		if (b.host == host && !S.devs[m]) { S.base[mac] = b; delete S.base[m]; S.dirty = true; return b; }
	}
	return S.base[mac] = { host, type: devType(host, mac), res: [], seen: now };
}

function udpPps(f, dt) {
	let best = 0;
	for (let x in (f.top ?? [])) if (x.p == 'udp' && x.up_p > 0 && x.dn_p / dt > best) best = x.dn_p / dt;
	return best;
}

// 处理一个 10 秒窗口
export function step(S, devs, dt, now, ctx) {
	dt = max(1, dt) + 0.0;   // ucode 里整数相除会取整，按浮点数算
	const groups = {}, out = {};
	const seen = {};
	for (let ip, f in devs) {
		if (!f.mac) continue;
		seen[f.mac] = f;
	}
	for (let mac, D in S.devs) if (!seen[mac] && now - D.last < 600) seen[mac] = { mac, host: D.host, net: D.net, up_b: 0, dn_b: 0, up_p: 0, dn_p: 0, new_conn: 0, top: [] };
	for (let mac, f in seen) {
		const D = S.devs[mac] ??= { host: f.host ?? '', net: f.net, pps: [], kbs: [], nw: [], raw: [], burstT: 0, burstB: 0.0, hold: 0, hitT: -1e9, sess: [], nextSample: 0, learning: false, last: now };
		if (f.dn_p + f.up_p > 0 || f.new_conn > 0) D.last = now;
		if (f.host) D.host = f.host;
		if (f.net) D.net = f.net;
		const B = baseFor(S, mac, D.host, now);
		// 先看到设备、后拿到名字（DHCP 晚报主机名）：补上名字，按名字重新分类型
		if (D.host && B.host != D.host) { B.host = D.host; B.type = devType(D.host, mac); S.dirty = true; }
		B.seen = now;
		const base = baseOf(B, B.type);
		const kbs = (f.dn_b + f.up_b) / dt / 1024, dn = f.dn_b / dt / 1024, pps = (f.dn_p + f.up_p) / dt, nw = f.new_conn * 10 / dt;
		keep(D.pps, pps, P.long_n); keep(D.kbs, kbs, P.long_n); keep(D.nw, nw, P.long_n);
		let pre = false;
		if (B.type != 'tv' && D.burstIso && dn < P.dn_kbs && D.burstT > 0 && D.burstT <= P.pre_sec && D.burstB >= P.pre_min * 1024 && D.burstB <= P.pre_max * 1024) {
			const h = now + min(P.hold_max, max(P.hold_min, D.burstB / (P.audio_kbs * 1024)));
			if (h > D.hold) { D.hold = h; D.holdPre = true; }
			D.hitT = now; pre = true;
		}
		if (dn >= P.dn_kbs && !D.burstT) D.burstIso = !length(filter(D.raw, x => x)) && (!D.lastWhy || D.lastWhy == 'prefetch');
		if (dn >= P.dn_kbs) { D.burstT += dt; D.burstB += f.dn_b; } else { D.burstT = 0; D.burstB = 0.0; }

		let why = '';
		if (dn >= P.dn_kbs) why = 'down';
		else if (udpPps(f, dt) >= P.udp_pps) why = 'udp';
		else if (nw >= base.new + P.new_over && kbs >= base.kbs + P.kbs_over) why = 'conn';
		if (why) D.hitT = now;
		keep(D.raw, why != '', P.win);
		let on = length(filter(D.raw, x => x)) >= P.need;
		if (!on && base.pps95 != null && length(D.pps) >= P.long_n && q(D.pps, 0.5) > base.pps95 * (1 + P.long_margin) + P.long_margin) { on = true; why = 'long'; }
		if (on) {
			const hold = D.burstT > 0 && D.burstT <= P.burst_max ? min(P.hold_max, max(P.hold_min, D.burstB / (P.video_kbs * 1024))) : P.hold_min;
			if (now + hold > D.hold) { D.hold = now + hold; D.holdPre = false; }
		}
		const use = on || now < D.hold;

		const learn = !!ctx?.learn?.[D.net];
		const quiet = now - D.hitT >= P.quiet_for && !(base.learned && why == 'long');
		if (learn && quiet && length(D.pps) >= P.long_n && now >= D.nextSample) {
			const r = [q(D.pps, 0.5), q(D.kbs, 0.5), q(D.nw, 0.5)];
			if (quietRes(r)) push(D.sess, r);
			D.nextSample = now + P.sample_every;
		}
		if ((!learn && length(D.sess)) || length(D.sess) >= P.sess_max) {
			const s = sort(D.sess, (a, b) => a[0] - b[0]);
			for (let i = 0; i < int((length(s) + 1) / 2); i++) keep(B.res, map(s[i], x => int(x * 100) / 100.0), P.res_max);
			D.sess = [];
			S.dirty = true;
		}
		D.learning = learn;

		const shown = use ? (why || (pre || D.holdPre ? 'prefetch' : 'hold')) : '';
		D.lastWhy = shown;
		out[mac] = { on: use, why: shown, net: D.net, type: B.type, learned: base.learned };
		if (use && D.net) groups[D.net] = true;
	}
	return { groups, devs: out };
};
