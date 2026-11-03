// 用网采样
'use strict';

const UDP_LIVE_AGE = 60;   // 持续双向 UDP
const TOP = 5;
function prefixOf(ip) { const a = split(ip, '.'); return a[0] + '.' + a[1] + '.' + a[2] + '.'; }
export function prefixes(gs) { return map(gs, g => prefixOf(g.ip)); };

// ---------- nft 计数表 ----------
export function ruleset(gs) {
	let s = 'table inet doti_calib\ndelete table inet doti_calib\ntable inet doti_calib {\n';
	for (let i = 0; i < length(gs); i++) {
		s += sprintf('\tset up%d { type ipv4_addr; flags dynamic; counter; timeout 1h; }\n\tset dn%d { type ipv4_addr; flags dynamic; counter; timeout 1h; }\n', i, i);
	}
	s += '\tchain count {\n\t\ttype filter hook forward priority 5; policy accept;\n';
	for (let i = 0; i < length(gs); i++) {
		s += sprintf('\t\tiifname "%s" update @up%d { ip saddr }\n\t\toifname "%s" update @dn%d { ip daddr }\n', gs[i].dev, i, gs[i].dev, i);
	}
	return s + '\t}\n}\n';
};

// nft -j list table inet doti_calib → { ip: { up_b, up_p, dn_b, dn_p, net } }
export function parseSets(text, gs) {
	const out = {};
	let j;
	try { j = json(text); } catch (e) { return out; }
	for (let o in (j?.nftables ?? [])) {
		const st = o.set;
		if (!st?.elem) continue;
		const m = match(st.name, /^(up|dn)([0-9]+)$/);
		if (!m) continue;
		for (let e in st.elem) {
			const ip = e.elem?.val, c = e.elem?.counter;
			if (!ip || !c) continue;
			out[ip] ??= { up_b: 0, up_p: 0, dn_b: 0, dn_p: 0, net: gs[+m[2]]?.key ?? '' };
			out[ip][m[1] + '_b'] = c.bytes;
			out[ip][m[1] + '_p'] = c.packets;
		}
	}
	return out;
};

// /proc/net/nf_conntrack 里源地址在孩子网段的连接 → { 键: { p, src, dport, up_b, up_p, dn_b, dn_p } }
export function parseConntrack(text, prefixes) {
	const out = {};
	for (let line in split(text ?? '', '\n')) {
		const m = match(line, /^ipv4[[:space:]]+[0-9]+[[:space:]]+(tcp|udp)[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]+(.*)$/);
		if (!m) continue;
		const rest = m[2];
		const src = match(rest, /src=([0-9.]+)/)?.[1];
		if (!src || !length(filter(prefixes, p => index(src, p) == 0))) continue;
		const dst = match(rest, /dst=([0-9.]+)/)?.[1], sport = match(rest, /sport=([0-9]+)/)?.[1], dport = match(rest, /dport=([0-9]+)/)?.[1];
		const pk = [], by = [];
		let r = rest;
		for (let k = 0; k < 2; k++) {
			const a = match(r, /packets=([0-9]+) bytes=([0-9]+)/);
			if (!a) break;
			push(pk, +a[1]); push(by, +a[2]);
			r = substr(r, index(r, a[0]) + length(a[0]));
		}
		if (length(pk) < 2) continue;
		out[m[1] + ' ' + src + ':' + sport + '>' + dst + ':' + dport] = { p: m[1], src, dst, dport: +dport, up_p: pk[0], up_b: by[0], dn_p: pk[1], dn_b: by[1] };
	}
	return out;
};

// iw dev <接口> station dump → { mac: { idle_ms, rx_p, tx_p, signal } }
export function parseStations(text) {
	const out = {};
	let cur = null;
	for (let line in split(text ?? '', '\n')) {
		let m = match(line, /^Station ([0-9a-f:]{17})/);
		if (m) { cur = out[m[1]] = { idle_ms: 0, rx_p: 0, tx_p: 0, signal: 0 }; continue; }
		if (!cur) continue;
		if ((m = match(line, /inactive time:[[:space:]]*([0-9]+)/))) cur.idle_ms = +m[1];
		else if ((m = match(line, /rx packets:[[:space:]]*([0-9]+)/))) cur.rx_p = +m[1];
		else if ((m = match(line, /tx packets:[[:space:]]*([0-9]+)/))) cur.tx_p = +m[1];
		else if ((m = match(line, /^[[:space:]]*signal:[[:space:]]*(-?[0-9]+)/))) cur.signal = +m[1];
	}
	return out;
};

// /tmp/dhcp.leases → { ip: { mac, host } }
export function parseLeases(text) {
	const out = {};
	for (let line in split(text ?? '', '\n')) {
		const f = split(line, ' ');
		if (length(f) >= 4) out[f[2]] = { mac: lc(f[1]), host: f[3] == '*' ? '' : f[3] };
	}
	return out;
};

const d0 = (a, b) => (a != null && b != null && a >= b) ? a - b : 0;

// 算一个间隔内每台设备的特征
export function features(prev, cur, dt, now, state) {
	const dev = {};
	const D = ip => (dev[ip] ??= { mac: '', host: '', net: '', up_b: 0, dn_b: 0, up_p: 0, dn_p: 0,
		udp_live: 0, udp_pps: 0, new_conn: 0, act_conn: 0, tcp_dn_b: 0, quic_dn_b: 0, flows: [], wifi: null });
	for (let ip, c in cur.sets) {
		const p = prev.sets[ip] ?? {};
		const d = D(ip);
		d.net = c.net;
		d.up_b = d0(c.up_b, p.up_b ?? 0); d.up_p = d0(c.up_p, p.up_p ?? 0);
		d.dn_b = d0(c.dn_b, p.dn_b ?? 0); d.dn_p = d0(c.dn_p, p.dn_p ?? 0);
	}
	for (let k, f in cur.ct) {
		state.seen[k] ??= now;
		const p = prev.ct[k];
		const isNew = !p && prev.ready;
		const x = p ? { up_b: d0(f.up_b, p.up_b), up_p: d0(f.up_p, p.up_p), dn_b: d0(f.dn_b, p.dn_b), dn_p: d0(f.dn_p, p.dn_p) }
			: (prev.ready ? { up_b: f.up_b, up_p: f.up_p, dn_b: f.dn_b, dn_p: f.dn_p } : { up_b: 0, up_p: 0, dn_b: 0, dn_p: 0 });
		const age = now - state.seen[k];
		const d = D(f.src);
		if (isNew) d.new_conn++;
		if (x.up_p + x.dn_p > 0) d.act_conn++;
		if (f.p == 'tcp') d.tcp_dn_b += x.dn_b;
		if (f.p == 'udp' && f.dport == 443) d.quic_dn_b += x.dn_b;
		if (f.p == 'udp' && x.up_p > 0 && x.dn_p > 0 && age >= UDP_LIVE_AGE) { d.udp_live++; d.udp_pps += (x.up_p + x.dn_p) / dt; }
		if (x.up_b + x.dn_b > 0) push(d.flows, { p: f.p, dport: f.dport, up_b: x.up_b, dn_b: x.dn_b, up_p: x.up_p, dn_p: x.dn_p, age });
	}
	for (let k in keys(state.seen)) if (!cur.ct[k]) delete state.seen[k];
	for (let ip, d in dev) {
		const l = cur.leases[ip];
		if (l) { d.mac = l.mac; d.host = l.host; }
		const w = d.mac ? cur.sta[d.mac] : null, pw = d.mac ? prev.sta[d.mac] : null;
		if (w) d.wifi = { idle_ms: w.idle_ms, rx_p: pw ? d0(w.rx_p, pw.rx_p) : 0, tx_p: pw ? d0(w.tx_p, pw.tx_p) : 0, signal: w.signal };
		d.udp_pps = int(d.udp_pps * 10) / 10;
		const sorted = sort(d.flows, (a, b) => (b.up_b + b.dn_b) - (a.up_b + a.dn_b));
		d.top = [];
		for (let k = 0; k < length(sorted) && k < TOP; k++) push(d.top, sorted[k]);
		delete d.flows;
	}
	return dev;
};
