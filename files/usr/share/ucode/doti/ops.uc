// 家长操作，局域网接口和远程命令共用
'use strict';

export const ACTIONS = ['open', 'openAll', 'limitAll', 'auto'];

export function make(d) {
	const S = d.settings, F = d.store, W = d.wifi;
	const etc = F.etc, readJson = F.readJson, withLock = F.withLock, writeJson = F.writeJson;

	function netKeys() { return map(readJson(etc('nets.json'), []), n => n.key); }
	function settingsNow(code) { return readJson(etc('settings.json'), null) ?? S.defaults(netKeys(), code); }

	// at：远程命令的发出时间（云端时间）。开放 N 分钟从发出时算，送晚了只给剩下的，过了就 LATE（作废）
	function today(b, byIdx, now, at) {
		const act = b?.action;
		if (index(netKeys(), b?.key) < 0 || index(ACTIONS, act) < 0) return [null, 'BAD_REQUEST'];
		if (act == 'open' && index([15, 30, 45, 60, 90, 120, 240, 360], b.minutes) < 0) return [null, 'BAD_REQUEST'];
		const until = act == 'open' ? (at ?? now) + b.minutes * 60 : null;
		if (until != null && until <= now) return [null, 'LATE'];
		const lt = localtime(now), date = sprintf('%04d-%02d-%02d', lt.year, lt.mon, lt.mday);
		const r = withLock(() => {
			const t = readJson(etc('today.json'), null) ?? { seq: 0, plans: {} };
			const old = t.plans[b.key];
			if (at != null && old && old.date == date && (old.at ?? 0) > at) return 'STALE';
			if (act == 'auto') { delete t.plans[b.key]; t.cancel ??= {}; t.cancel[b.key] = { by: byIdx, at: now }; }
			else {
				t.seq++;
				t.plans[b.key] = { seq: t.seq, date, action: act, at: at ?? now, by: byIdx,
					...(act == 'open' ? { minutes: b.minutes, until } : {}) };
			}
			writeJson(etc('today.json'), t);
			return true;
		}, now);
		if (r[1]) return [null, 'INTERNAL'];
		return r[0] === true ? [true, null] : [null, r[0]];
	}

	function saveSettings(code, body, now) {
		const r = withLock(() => {
			const m = S.merge(settingsNow(code), body, netKeys(), code);
			if (!m.err) writeJson(etc('settings.json'), m.settings);
			return m;
		}, now);
		return r[1] ? { err: 'INTERNAL' } : r[0];
	}

	function wifiToggle(key, on) {
		const keys = netKeys();
		if (index(keys, key) < 0 || type(on) != 'bool') return 'BAD_REQUEST';
		const b = W.bins(), o = W.load(b), ifs = W.ifacesOf(o, W.kidNet(key));
		if (!length(ifs)) return 'NO_WIFI';
		if (!on) {
			// 读不到实际状态（ubus 不可用）时不拦
			const st = W.state(b, keys);
			if (st && !length(filter(keys, k => k != key && st[k]))) return 'KEEP_ONE';
		}
		W.apply(b, W.cmdsDisabled(ifs, on));
		return null;
	}

	// 各 WiFi 现在的密码：孩子网络按 key，家长 WiFi 是 admin（家长手机的恢复备份用，只走局域网）
	function wifiKeys(code) {
		const o = W.load(W.bins()), out = {};
		for (let k in netKeys()) { const f = W.ifacesOf(o, W.kidNet(k))[0]; if (f?.key) out[k] = f.key; }
		const p = filter(W.parentIfaces(o, code), x => x.ours && x.key)[0];
		if (p) out.admin = p.key;
		return out;
	}

	// 各 WiFi 密码最后改动的时间 { k1: t, admin: t }：本机按密码摘要比对（摘要只存路由器上），变了就记下当时时间；
	// 第一次记（没有记录文件）一律记 0（不知道什么时候改的）。上报云端的只有时间，家长手机据此判断自己记的密码是不是旧的
	function pwStamp(code, now) {
		const cur = wifiKeys(code);
		const r = withLock(() => {
			const old = readJson(etc('pwat.json'), null), first = old == null, rec = old ?? {}, out = {};
			let dirty = first;
			for (let k in keys(cur)) {
				const h = substr(d.sha(cur[k]), 0, 16);
				if (rec[k]?.h != h) { rec[k] = { h, at: first ? 0 : now }; dirty = true; }
				out[k] = rec[k].at;
			}
			for (let k in keys(rec)) if (cur[k] == null) { delete rec[k]; dirty = true; }
			if (dirty) writeJson(etc('pwat.json'), rec);
			return out;
		}, now);
		return r[0] ?? {};
	}
	function pwAtOf() {
		const rec = readJson(etc('pwat.json'), null) ?? {}, out = {};
		for (let k in keys(rec)) out[k] = rec[k]?.at ?? 0;
		return out;
	}

	// 设 WiFi 密码（局域网和远程共用）：key 是孩子网络或 'admin'（家长 WiFi，root 密码跟着换）；返回 [WiFi 名, 错误]
	function setPassword(key, pw, code) {
		if (!W.validPassword(pw)) return [null, 'PASSWORD'];
		const b = W.bins(), o = W.load(b);
		if (key == 'admin') {
			const ifs = W.parentTargets(o, code);
			if (!length(ifs)) return [null, 'NO_WIFI'];
			W.apply(b, W.cmdsParent(ifs, pw, code));
			if (d.root) d.root(pw);
			if (d.sha) pwStamp(code, d.now ? d.now() : time());
			return [W.adminSsid(code), null];
		}
		if (index(netKeys(), key) < 0) return [null, 'BAD_REQUEST'];
		const ifs = W.ifacesOf(o, W.kidNet(key));
		if (!length(ifs)) return [null, 'NO_WIFI'];
		W.apply(b, W.cmdsKey(ifs, pw));
		if (d.sha) pwStamp(code, d.now ? d.now() : time());
		return [ifs[0].ssid, null];
	}

	return { netKeys, settingsNow, today, saveSettings, wifiToggle, setPassword, wifiKeys, pwStamp, pwAtOf };
};
