// 不良网站屏蔽
'use strict';

export const OPTIONAL = [ 'game', 'short-video-live', 'movie-tv-vod' ];
export const RENAMED = { shortvideo: 'short-video-live', film: 'movie-tv-vod' };   // 旧版本存的分类代号 → 现在的
export const DOH_IPS = [ '8.8.8.8', '8.8.4.4', '1.1.1.1', '1.0.0.1', '9.9.9.9', '149.112.112.112', '208.67.222.222', '208.67.220.220',
	'223.5.5.5', '223.6.6.6', '119.29.29.29', '1.12.12.12', '120.53.53.53', '180.76.76.76', '94.140.14.14', '94.140.15.15' ];

// 用哪份名单
export function pickDir(etcDir, etcManifest, shareDir, shareManifest) {
	return (etcManifest?.ver ?? 0) > (shareManifest?.ver ?? 0) ? [etcDir, etcManifest] : [shareDir, shareManifest];
};

// 生成一个孩子网络（每个孩子网络一个屏蔽 DNS）的 dnsmasq 主配置。custom：自己加的网站（所有网络共用）；nb：这个网络的网站屏蔽（开着的分类、关掉的自己加的网站）
export function mainConf(dir, manifest, custom, nb) {
	let s = '';
	const on = filter(map(nb?.categories ?? [], x => RENAMED[x] ?? x), x => index(OPTIONAL, x) >= 0);
	for (let c in ['base', 'always', ...on])
		if (manifest?.files?.[c]) s += 'conf-file=' + dir + '/' + c + '.conf\n';
	for (let d in custom ?? []) if (index(nb?.off ?? [], d) < 0) s += sprintf('address=/%s/192.0.2.1\naddress=/%s/::\n', d, d);
	return s;
};

// 状态里的条数：custom 是自己加的网站总数
export function counts(manifest, custom) {
	const n = { custom: length(custom ?? []) };
	for (let c in keys(manifest?.files ?? {})) n[c] = manifest.files[c].n;
	return n;
};
