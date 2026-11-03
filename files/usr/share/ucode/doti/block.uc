// 不良网站屏蔽
'use strict';

export const OPTIONAL = [ 'game', 'shortvideo', 'video' ];
export const DOH_IPS = [ '8.8.8.8', '8.8.4.4', '1.1.1.1', '1.0.0.1', '9.9.9.9', '149.112.112.112', '208.67.222.222', '208.67.220.220',
	'223.5.5.5', '223.6.6.6', '119.29.29.29', '1.12.12.12', '120.53.53.53', '180.76.76.76', '94.140.14.14', '94.140.15.15' ];

// 用哪份名单
export function pickDir(etcDir, etcManifest, shareDir, shareManifest) {
	return (etcManifest?.ver ?? 0) > (shareManifest?.ver ?? 0) ? [etcDir, etcManifest] : [shareDir, shareManifest];
};

// 生成 dnsmasq 主配置
export function mainConf(dir, manifest, blk) {
	let s = '';
	for (let c in ['base', 'always', ...filter(blk?.categories ?? [], x => index(OPTIONAL, x) >= 0)])
		if (manifest?.files?.[c]) s += 'conf-file=' + dir + '/' + c + '.conf\n';
	for (let d in blk?.custom ?? []) if (index(blk?.paused ?? [], d) < 0) s += sprintf('address=/%s/192.0.2.1\naddress=/%s/::\n', d, d);
	return s;
};

// 状态里的条数
export function counts(manifest, blk) {
	const n = { custom: length(filter(blk?.custom ?? [], d => index(blk?.paused ?? [], d) < 0)) };
	for (let c in keys(manifest?.files ?? {})) n[c] = manifest.files[c].n;
	return n;
};
