// nftables 规则
'use strict';
import * as fs from 'fs';

// 家里的内网地址（打开「家里局域网不计时、不限速」的网络，访问这些不计、不限）
export const PRIVATE = '{ 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 }';

// 不计时、不限速的目标地址：lanFree 的网络加内网，再加不限速地址 free（云端给的 IP 列表：云端自己等）
function freeDst(lanFree, free) {
	const a = lanFree ? ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16'] : [];
	for (let ip in (free ?? [])) push(a, ip);
	return a;
}

// 统计表；lanFree 的网络只统计和内网以外的流量；不限速地址 free 的流量都不统计
export function baseRuleset(groups, free) {
	let s = 'table inet doti\ndelete table inet doti\ntable inet doti {\n';
	for (let i = 0; i < length(groups); i++)
		s += sprintf('\tset up%d { type ipv4_addr; flags dynamic; counter; timeout 1h; }\n\tset dn%d { type ipv4_addr; flags dynamic; counter; timeout 1h; }\n', i, i);
	s += '\tchain stat {\n\t\ttype filter hook forward priority 0; policy accept;\n';
	for (let i = 0; i < length(groups); i++) {
		const g = groups[i], f = freeDst(g.lanFree, free), fs = length(f) ? '{ ' + join(', ', f) + ' }' : '';
		const up = fs ? ' ip daddr != ' + fs : '', dn = fs ? ' ip saddr != ' + fs : '';
		s += sprintf('\t\tiifname "%s"%s counter comment "%s_up"\n\t\toifname "%s"%s counter comment "%s_down"\n', g.dev, up, g.key, g.dev, dn, g.key);
		s += sprintf('\t\tiifname "%s"%s update @up%d { ip saddr }\n\t\toifname "%s"%s update @dn%d { ip daddr }\n', g.dev, up, i, g.dev, dn, i);
	}
	return s + '\t}\n}\n';
};

// 限速表：nets 是正在限速的网络 { key, dev, kbps, lanFree }；kbps 为 0 就断网；lanFree 的网络访问内网照常放行；
// 不限速地址 free（云端给的 IP 列表）的 HTTPS 一律放行：限速、断网时孩子也能找家长要时间、拍照上传、看家长的回应
export function limitRuleset(nets, free) {
	let s = 'table inet doti_limit\ndelete table inet doti_limit\n';
	if (!length(nets)) return s;
	s += 'table inet doti_limit {\n\tchain kidcap {\n\t\ttype filter hook forward priority -200; policy accept;\n';
	for (let n in nets) {
		if (n.lanFree) s += sprintf('\t\tiifname "%s" ip daddr %s accept\n\t\toifname "%s" ip saddr %s accept\n', n.dev, PRIVATE, n.dev, PRIVATE);
		if (length(free ?? [])) {
			const set = '{ ' + join(', ', free) + ' }';
			s += sprintf('\t\tiifname "%s" ip daddr %s tcp dport 443 accept\n\t\toifname "%s" ip saddr %s tcp sport 443 accept\n', n.dev, set, n.dev, set);
		}
		const kb = max(1, int(n.kbps / 8)), burst = kb * 10;
		for (let dir in ['iifname', 'oifname'])
			s += n.kbps > 0 ? sprintf('\t\t%s "%s" limit rate over %d kbytes/second burst %d kbytes counter drop comment "%s_drop"\n', dir, n.dev, kb, burst, n.key)
				: sprintf('\t\t%s "%s" counter drop comment "%s_drop"\n', dir, n.dev, n.key);
	}
	return s + '\t}\n}\n';
};

// 内网地址（和 PRIVATE 一致）
export function isPrivate(ip) {
	const m = match(ip ?? '', /^([0-9]+)\.([0-9]+)\./);
	if (!m) return false;
	const a = +m[1], b = +m[2];
	return a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168);
};

// 一个不限速地址：只认公网 IPv4，内网、回环、格式不对的返回 null
export function publicIp(ip) {
	const m = match(type(ip) == 'string' ? ip : '', /^([0-9]+)[.]([0-9]+)[.]([0-9]+)[.]([0-9]+)$/);
	if (!m || +m[1] > 255 || +m[2] > 255 || +m[3] > 255 || +m[4] > 255 || +m[1] == 0 || +m[1] == 127 || +m[1] >= 224 || isPrivate(ip)) return null;
	return ip;
};

// 云端回包里的不限速地址 freeIps：只留合格的、去重，最多 8 个，排好序（好比较）
export function freeIpList(r) {
	const src = type(r?.freeIps) == 'array' ? r.freeIps : [];
	const out = [];
	for (let v in src) { const ip = publicIp(v); if (ip && index(out, ip) < 0 && length(out) < 8) push(out, ip); }
	return sort(out);
};

// DNS 转发表：devs 的 DNS 都转到屏蔽名单；guard 是其中还要拦加密 DNS（853 端口、常见加密 DNS 服务器的 443）的网络，
// 家长关了加密 DNS 拦截的网络不在里面（没传 guard 就是全拦）
export function dnsRuleset(devs, port, dohIps, guard) {
	// port：数字（都转到同一个），或 { 网卡: 端口 }（每个孩子网络一个屏蔽 DNS）
	let s = 'table inet doti_dns\ndelete table inet doti_dns\n';
	if (!length(devs)) return s;
	s += 'table inet doti_dns {\n';
	if (length(dohIps)) s += sprintf('\tset doh { type ipv4_addr; elements = { %s } }\n', join(', ', dohIps));
	s += '\tchain redir {\n\t\ttype nat hook prerouting priority dstnat - 1; policy accept;\n';
	const byPort = {};
	for (let d in devs) {
		const p = type(port) == 'object' ? port[d] : port;
		if (!p) continue;
		if (!byPort[p]) byPort[p] = [];
		push(byPort[p], d);
	}
	for (let p in sort(keys(byPort))) {
		const set = join(', ', map(byPort[p], d => '"' + d + '"'));
		s += sprintf('\t\tiifname { %s } udp dport 53 redirect to :%s\n\t\tiifname { %s } tcp dport 53 redirect to :%s\n', set, p, set, p);
	}
	s += '\t}\n\tchain nodoh {\n\t\ttype filter hook forward priority -5; policy accept;\n';
	guard ??= devs;
	if (length(guard)) {
		const gs = join(', ', map(guard, d => '"' + d + '"'));
		s += sprintf('\t\tiifname { %s } tcp dport 853 reject with tcp reset\n\t\tiifname { %s } udp dport 853 drop\n', gs, gs);
		if (length(dohIps)) s += sprintf('\t\tiifname { %s } ip daddr @doh tcp dport 443 reject with tcp reset\n\t\tiifname { %s } ip daddr @doh udp dport 443 drop\n', gs, gs);
	}
	return s + '\t}\n}\n';
};

export const removeAll = 'table inet doti\ndelete table inet doti\ntable inet doti_limit\ndelete table inet doti_limit\ntable inet doti_dns\ndelete table inet doti_dns\n';

// `nft -j list table inet doti` 的输出 → { k1: { bytes, pkts, up, dn } }
export function parseCounters(text) {
	const out = {};
	let j;
	try { j = json(text); } catch (e) { return out; }
	for (let o in (j?.nftables || [])) {
		const r = o.rule;
		if (!r?.comment) continue;
		const m = match(r.comment, /^(.+)_(up|down)$/);
		if (!m) continue;
		for (let e in r.expr) if (e.counter) {
			out[m[1]] ??= { bytes: 0, pkts: 0, up: 0, dn: 0 };
			out[m[1]].bytes += e.counter.bytes;
			out[m[1]].pkts += e.counter.packets;
			out[m[1]][m[2] == 'up' ? 'up' : 'dn'] += e.counter.bytes;
		}
	}
	return out;
};

// `nft -j list table inet doti_limit` 的输出 → 各网络超速丢掉的包数 { k1: 12 }
export function parseDrops(text) {
	const out = {};
	let j;
	try { j = json(text); } catch (e) { return out; }
	for (let o in (j?.nftables || [])) {
		const m = match(o.rule?.comment ?? '', /^(.+)_drop$/);
		if (m) for (let e in o.rule.expr) if (e.counter) out[m[1]] = (out[m[1]] ?? 0) + e.counter.packets;
	}
	return out;
};

// 执行一段规则
export function apply(bin, tmp, text) {
	fs.writefile(tmp, text);
	return system(sprintf('%s -f %s >/dev/null 2>&1', bin, tmp));
};

// `nft -j list table inet <表>` 的原文
export function listJSON(bin, table) {
	const p = fs.popen(sprintf('%s -j list table inet %s 2>/dev/null', bin, table ?? 'doti'), 'r');
	if (!p) return '';
	const t = p.read('all');
	p.close();
	return t ?? '';
};

export function counters(bin) { return parseCounters(listJSON(bin)); };
