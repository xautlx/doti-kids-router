// 家长操作，局域网接口用
'use strict';

export const ACTIONS = ['open', 'openAll', 'limitAll', 'auto'];

export function make(d) {
	const S = d.settings, F = d.store, W = d.wifi;
	const etc = F.etc, readJson = F.readJson, withLock = F.withLock, writeJson = F.writeJson;

	function netKeys() { return map(readJson(etc('nets.json'), []), n => n.key); }
	function settingsNow(code) { return readJson(etc('settings.json'), null) ?? S.defaults(netKeys(), code); }

	function today(b, byIdx, now) {
		const act = b?.action;
		if (index(netKeys(), b?.key) < 0 || index(ACTIONS, act) < 0) return [null, 'BAD_REQUEST'];
		if (act == 'open' && index([15, 30, 45, 60, 90, 120, 240, 360], b.minutes) < 0) return [null, 'BAD_REQUEST'];
		const lt = localtime(now), date = sprintf('%04d-%02d-%02d', lt.year, lt.mon, lt.mday);
		const r = withLock(() => {
			const t = readJson(etc('today.json'), null) ?? { seq: 0, plans: {} };
			if (act == 'auto') delete t.plans[b.key];
			else {
				t.seq++;
				t.plans[b.key] = { seq: t.seq, date, action: act, at: now, by: byIdx,
					...(act == 'open' ? { minutes: b.minutes, until: now + b.minutes * 60 } : {}) };
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

	return { netKeys, settingsNow, today, saveSettings, wifiToggle };
};
