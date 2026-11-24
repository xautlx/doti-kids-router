// 登记时带的系统信息（给兼容性统计）：发行版和版本、平台、型号、芯片、包管理器、闪存和内存；取不到的项不带。
// 字段和升级程序报到带的 env 对齐（升级程序另有开机时长、无线频段数、设备类型数量，这里不带）。
// 不含家里设备的任何信息。依赖由调用方传入：o = { sys: 系统根目录前缀（测试用）, sh: 跑命令取输出, ubus, overlay, pm }
'use strict';
import * as fs from 'fs';

function shq(s) { return "'" + replace('' + s, "'", "'\\''") + "'"; }

// 包管理器：opkg（22.03 / 23.05 / 24.10）或 apk（25.x）
export function pm(sys) {
	return fs.stat(sys + '/bin/opkg') || fs.stat(sys + '/usr/bin/opkg') ? 'opkg' : fs.stat(sys + '/usr/bin/apk') ? 'apk' : 'opkg';
};

// ubus call system board 的 system 字段（CPU / SoC 描述）；读不到回空串
export function chip(sh, ubus) {
	let b = null;
	try { b = json(sh(ubus + ' -t 3 call system board 2>/dev/null') || 'null'); } catch (e) { b = null; }
	return type(b?.system) == 'string' ? substr(trim(b.system), 0, 64) : '';
};

export function collect(o) {
	const sys = o.sys ?? '', e = {}, r = fs.readfile(sys + '/etc/openwrt_release') ?? '';
	const K = { ID: 'id', RELEASE: 'os', REVISION: 'rev', TARGET: 'target', ARCH: 'arch' };
	for (let k in K) {
		const m = match(r, regexp("DISTRIB_" + k + "='([^']*)'"));
		if (m && m[1] != '') e[K[k]] = substr(m[1], 0, 40);
	}
	const board = trim(fs.readfile(sys + '/tmp/sysinfo/board_name') ?? ''), model = trim(fs.readfile(sys + '/tmp/sysinfo/model') ?? '');
	if (board) e.board = substr(board, 0, 64);
	if (model) e.model = substr(model, 0, 64);
	const c = chip(o.sh, o.ubus);
	if (c) e.chip = c;
	e.pm = o.pm || pm(sys);
	const df = match(o.sh('df -k ' + shq(o.overlay) + ' 2>/dev/null | tail -1'), /[ \t]([0-9]+)[ \t]+[0-9]+[ \t]+([0-9]+)[ \t]+[0-9]+%/);
	if (df) { e.flashKB = +df[1]; e.flashFreeKB = +df[2]; }
	const mi = fs.readfile(sys + '/proc/meminfo') ?? '', mt = match(mi, /MemTotal:[ \t]+([0-9]+)/), ma = match(mi, /MemAvailable:[ \t]+([0-9]+)/);
	if (mt) e.memKB = +mt[1];
	if (ma) e.memFreeKB = +ma[1];
	return e;
};
