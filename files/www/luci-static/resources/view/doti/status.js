'use strict';
'require view';
'require fs';
'require poll';
'require ui';

// 一点守护状态页：服务状态，加上绑定到微信小程序的两步引导（没绑定时）或打开小程序的码（已绑定时）；管理都在微信小程序「一点守护」里
// 二维码在浏览器里现场画（doti/qrcode.js，MIT），不请求任何外部服务：
//   家长 WiFi：标准 WiFi 二维码，手机相机扫一下就连；小程序：普通链接二维码，微信扫了直接打开小程序的绑定页
var MINI_URL = 'https://doti.top/b/?c=';
var qrLoad = null;

function loadQr() {
	if (window.qrcode) return Promise.resolve();
	if (!qrLoad) qrLoad = new Promise(function(ok) {
		var s = document.createElement('script');
		s.src = L.resource('doti/qrcode.js');
		s.onload = ok; s.onerror = ok;   // 加载不了就不画码，只显示文字
		document.head.appendChild(s);
	});
	return qrLoad;
}

// 颜色都走 CSS 变量，跟着 LuCI 主题的明亮 / 暗黑走；二维码底色始终是白的（暗底上扫不出来）
var CSS = [
	'.dt{--dt-card:#fbfaff;--dt-line:#e3dcff;--dt-ink:#1e1442;--dt-text:#555;--dt-brand:#5b3cf5;--dt-sub:#b9a8ff;',
	'--dt-warn-bg:#fff8e1;--dt-warn-line:#f3dfa2;--dt-warn-ink:#7a5b00;--dt-red:#d6336c;--dt-orange:#d97706;--dt-closed-bg:#fff7f7;--dt-closed-line:#e0b4b4}',
	'.dt.dt-dark{--dt-card:#211d33;--dt-line:#3d3566;--dt-ink:#ece8ff;--dt-text:#bcb6d3;--dt-brand:#a594ff;--dt-sub:#6f5fe0;',
	'--dt-warn-bg:#352b10;--dt-warn-line:#6a5520;--dt-warn-ink:#f0d68f;--dt-red:#ff7aa5;--dt-orange:#f5a524;--dt-closed-bg:#3a2026;--dt-closed-line:#7d3c47}',
	'.dt-warn{background:var(--dt-warn-bg);border:1px solid var(--dt-warn-line);color:var(--dt-warn-ink);border-radius:6px;padding:10px 14px;margin-bottom:14px;line-height:1.9}',
	'.dt-warn-t{font-weight:700;font-size:15px;margin-bottom:4px;color:var(--dt-red)}',
	'.dt .dt-red{color:var(--dt-red)}.dt .dt-orange{color:var(--dt-orange)}.dt .dt-muted{color:var(--dt-text)}',
	'.dt-steps{display:flex;flex-wrap:wrap;align-items:stretch;gap:14px}',
	'.dt-card{flex:1 1 260px;max-width:560px;border:1px solid var(--dt-line);border-radius:10px;padding:12px 16px;background:var(--dt-card);color:var(--dt-ink)}',
	'.dt-card.dt-dim{opacity:.45}',
	'.dt-title{font-weight:700}',
	'.dt-badge{display:inline-block;width:22px;height:22px;line-height:22px;text-align:center;border-radius:50%;background:#5b3cf5;color:#fff;font-size:12px;margin-right:6px}',
	'.dt-row{display:flex;flex-direction:column;align-items:stretch;gap:10px}',
	'.dt-left{flex:0 0 auto;text-align:center}',
	'.dt-tips{font-size:12px;line-height:1.85;color:var(--dt-text);border-top:1px dashed var(--dt-line);padding-top:8px}',
	'.dt-tips b{color:var(--dt-ink)}',
	'.dt-th{display:flex;align-items:center;gap:6px;font-weight:700;color:var(--dt-ink);margin-bottom:2px}',
	'.dt-qi{display:inline-block;width:16px;height:16px;line-height:16px;border-radius:50%;background:var(--dt-ink);color:var(--dt-card);font-size:11px;font-weight:800;text-align:center}',
	'.dt-sh{font-weight:700;color:var(--dt-ink);margin-top:6px;padding-left:6px;border-left:3px solid var(--dt-sub);line-height:1.4}',
	'.dt-lbl{font-size:12px;color:var(--dt-text);white-space:nowrap}.dt-lbl b{color:var(--dt-brand)}.dt-mono{font-family:monospace}',
	'.dt-arrow{flex:0 0 auto;display:flex;align-items:center;font-size:28px;font-weight:800;color:var(--dt-brand)}',
	'.dt-closed{border:1px dashed var(--dt-closed-line);background:var(--dt-closed-bg);border-radius:8px;padding:12px;margin:8px auto;width:180px;height:180px;box-sizing:border-box;display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center}',
	'.dt-qr{margin:8px auto;padding:0;background:#fff;border-radius:8px;box-sizing:content-box;line-height:0}',
	// 窄屏（手机上开后台）两张卡片上下排，箭头转成朝下
	'@media (max-width:640px){.dt-card{flex-basis:100%;max-width:none}.dt-arrow{flex-basis:100%;justify-content:center;transform:rotate(90deg);height:28px}}'
].join('');

function addCss() {
	if (document.getElementById('doti-css')) return;
	document.head.appendChild(E('style', { 'id': 'doti-css' }, CSS));
}

// 主题是不是暗色：bootstrap 主题在 <html> 上标 data-darkmode；别的主题看页面实际背景色的亮度
function isDark() {
	var m = document.documentElement.getAttribute('data-darkmode');
	if (m == 'true') return true;
	if (m == 'false') return false;
	var els = [ document.getElementById('maincontent'), document.body, document.documentElement ];
	for (var i = 0; i < els.length; i++) {
		if (!els[i]) continue;
		var c = (getComputedStyle(els[i]).backgroundColor || '').match(/[\d.]+/g);
		if (!c || (c.length > 3 && +c[3] == 0)) continue;
		return (0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]) < 128;
	}
	return false;
}

// 画成 SVG（放大不糊）；库没加载上就空着
function qr(text, size) {
	var box = E('div', { 'class': 'dt-qr', 'style': 'width:' + size + 'px;height:' + size + 'px' });
	if (window.qrcode) {
		try {
			var q = window.qrcode(0, 'M');
			q.addData(text); q.make();
			// 四周留 4 格白边（二维码标准要求），白边太窄有些手机扫不出来
			var cell = Math.max(2, Math.floor(size / (q.getModuleCount() + 8)));
			box.innerHTML = q.createSvgTag(cell, cell * 4);
			var svg = box.firstChild;
			if (svg) { svg.setAttribute('width', size); svg.setAttribute('height', size); }
		} catch (e) { box.style.display = 'none'; }
	}
	else box.style.display = 'none';
	return box;
}

// WiFi 二维码按安卓系统「分享 WiFi」生成的格式写（S 在前、带空的 P），各家相机、相册扫码都认；特殊字符要转义
function wifiEsc(s) { return String(s).replace(/([\\;,:"])/g, '\\$1'); }

function good(ok, yes, no) { return E('span', { 'style': 'color:' + (ok ? '#2e9e6b' : '#d6336c') + ';font-weight:600' }, ok ? yes : no); }
function row(k, v) { return E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td left', 'width': '33%' }, k), E('td', { 'class': 'td left' }, v) ]); }
function table(rows) { return E('table', { 'class': 'table' }, rows); }

// 二维码下面的说明：「家长 WiFi：DOTI-xxxx-ADMIN」「微信小程序：一点守护」
function qrLabel(k, v, mono) {
	return E('div', { 'class': 'dt-lbl' }, [ k, E('b', mono ? { 'class': 'dt-mono' } : {}, v) ]);
}
// 小提示的标题：前面一个圆圈问号小图标
function tipHead() {
	return E('div', { 'class': 'dt-th' }, [
		E('span', { 'class': 'dt-qi' }, '?'),
		'小提示'
	]);
}
// 小提示里的分段小标题
function subHead(t) { return E('div', { 'class': 'dt-sh' }, t); }

// 一步一张卡片：标题在上，中间二维码（或重新开放），下面小提示
function step(n, title, left, tips, dim) {
	return E('div', { 'class': 'dt-card' + (dim ? ' dt-dim' : '') }, [
		E('div', { 'class': 'dt-title' }, [ E('span', { 'class': 'dt-badge' }, '' + n), title ]),
		E('div', { 'class': 'dt-row' }, [
			E('div', { 'class': 'dt-left' }, left),
			E('div', { 'class': 'dt-tips' }, tips)
		])
	]);
}

return view.extend({
	load: function() {
		return Promise.all([ fs.exec_direct('/usr/sbin/doti', [ 'info' ], 'json').catch(function() { return null; }), loadQr() ]).then(function(r) { return r[0]; });
	},

	reopen: function() {
		var self = this;
		return fs.exec('/usr/sbin/doti', [ 'reopen' ]).then(function(r) {
			if (r.code != 0) ui.addNotification(null, E('p', {}, '没能重新开放：' + ((r.stdout || '') + (r.stderr || '')).trim()));
			return self.load().then(function(x) { self.box.replaceChildren(self.body(x)); });
		});
	},

	// 绑定到微信小程序：没绑定时两步（家长 WiFi 开着时第 1 步给 WiFi 码，关了给「重新开放」）；绑定后只留打开小程序的码
	bind: function(d) {
		var mini = MINI_URL + encodeURIComponent(d.code || '');
		if (d.parents)
			return E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, '用小程序管理'),
				E('div', { 'style': 'display:flex;align-items:center;flex-wrap:wrap;gap:16px' }, [
					E('div', { 'style': 'flex:0 0 auto;text-align:center' }, [ qr(mini, 160), qrLabel('微信小程序：', '一点守护') ]),
					E('div', { 'style': 'line-height:2' }, [
						E('div', {}, '用微信扫码打开「一点守护」'),
						E('div', {}, '在家直接管，出门在外也能管；要再加家人，在小程序「家人」里邀请'),
						E('div', { 'class': 'dt-muted' }, '扫不了码也可以在微信里搜索小程序「一点守护」')
					])
				])
			]);
		var left = d.claimLeft || 0, open = left > 0, name = d.parentWifi || '家长 WiFi';
		var tip = function(t) { return E('div', {}, t); };
		var first = open
			? step(1, '手机连上家长 WiFi', [
				qr('WIFI:S:' + wifiEsc(d.parentWifi || '') + ';T:nopass;P:;;', 180),
				qrLabel('家长 WiFi：', name, true)
			], [
				tipHead(),
				subHead('两种连接方式'),
				tip('1. 苹果手机可直接使用相机扫上方二维码；安卓手机可尝试用下滑弹出的「控制中心」里的「扫一扫」'),
				tip('2. 在手机「设置 → WLAN」里找到 ' + name + ' 热点，无需密码，点一下就能连'),
				subHead('开放剩余时间'),
				tip([ '还剩 ', E('b', { 'class': 'dt-orange' }, Math.ceil(left / 60) + ' 分钟'), ' 自动关闭，没绑定时只开 30 分钟' ])
			])
			: step(1, '手机连上家长 WiFi', [
				E('div', { 'class': 'dt-closed' }, [
					E('div', { 'style': 'font-weight:600' }, '家长 WiFi 已关闭'),
					E('button', { 'class': 'cbi-button cbi-button-action', 'style': 'margin-top:10px', 'click': ui.createHandlerFn(this, 'reopen') }, '重新开放 30 分钟')
				]),
				qrLabel('家长 WiFi：', name, true)
			], [
				tipHead(),
				tip('· 没绑定时家长 WiFi 只开 30 分钟，免得被别人连上'),
				tip('· 点上方按钮再开 30 分钟；断电重开路由器也一样')
			]);
		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, '还差一步：绑定到微信小程序'),
			E('div', { 'class': 'dt-steps' }, [
				first,
				E('div', { 'class': 'dt-arrow' }, '→'),
				step(2, '用微信扫码绑定当前设备', [ qr(mini, 180), qrLabel('微信小程序：', '一点守护') ], open ? [
					tipHead(),
					subHead('扫码快捷操作'),
					tip([ '· 手机先连上家长 WiFi ' + name + ' 热点后，用', E('b', {}, '微信「扫一扫」'), '上方二维码' ]),
					tip('· 微信扫码会自动打开「一点守护」小程序，确认家长 WiFi 新密码，一键绑定当前路由器'),
					subHead('手工搜索操作'),
					tip('也可以直接在微信里搜索小程序「一点守护」，按照指引操作设备绑定')
				] : [ tipHead(), tip('· 先完成第 1 步') ], !open)
			])
		]);
	},

	body: function(d) {
		if (!d)
			return E('div', { 'class': 'cbi-section' }, E('p', {}, '读不到一点守护的状态，请确认软件包已经装好。'));
		var wifi = d.parentWifi || '—';
		if (!d.parents && d.parentWifi) wifi += (d.claimLeft > 0 ? '（开放中，不用密码）' : '（已关闭，没绑定时只开 30 分钟）');
		return E('div', {}, [
			// root 临时密码放在最上面，进后台第一眼就能看到
			d.rootTemp ? E('div', { 'class': 'dt-warn' }, [
				E('div', { 'class': 'dt-warn-t' }, '关于 root 密码的安全设置'),
				E('div', {}, [ '为了便于接下来操作设备绑定，会临时无密码开放 30 分钟的「一点守护」家长 WiFi 热点。「一点守护」程序检测到当前 OpenWrt 系统为默认 root 空密码，为了防止他人连接热点后 SSH 访问管理端进行操作，无密码家长 WiFi 热点开放期间会临时把 root 密码设置为 ', E('b', { 'class': 'dt-red' }, d.rootTemp), '。30 分钟未完成绑定，家长 WiFi 热点会自动关闭，root 密码自动恢复默认空密码；完成设备绑定后，root 密码会自动同步设置为家长 WiFi 热点新密码，确保安全的同时也方便你统一登录管理。建议尽快按照如下步骤完成设备绑定，减少无密码家长 WiFi 热点开放时间，避免被他人连接蹭网。' ])
			]) : '',
			d.code ? this.bind(d) : '',
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, '服务状态'),
				table([
					row('一点守护服务', good(d.running, '运行中', '没在运行')),
					row('主程序版本', d.version ? d.version + (d.released ? '（' + d.released + '）' : '') : '—'),
					row('路由器编号', d.code || '—'),
					row('家长 WiFi', wifi),
					row('绑定', d.parents ? good(true, '已绑定，' + d.parents + ' 位家人', '') : '还没绑定')
				])
			])
		]);
	},

	render: function(d) {
		var self = this;
		addCss();
		this.box = E('div', { 'class': 'dt' }, this.body(d));
		// 主题样式加载完才看得出明暗：页面挂上后判断一次，之后每次刷新再对一次（切换主题、跟随系统）
		var theme = function() { self.box.classList.toggle('dt-dark', isDark()); };
		requestAnimationFrame(theme);
		// bootstrap 主题跟随系统时会改 <html data-darkmode>，跟着变
		if (window.MutationObserver) new MutationObserver(theme).observe(document.documentElement, { attributes: true, attributeFilter: [ 'data-darkmode' ] });
		// 30 秒刷新一次：剩余分钟、绑定好了以后换成已绑定的样子
		poll.add(function() {
			return self.load().then(function(x) { self.box.replaceChildren(self.body(x)); theme(); });
		}, 30);
		return E('div', {}, [
			E('h2', {}, '一点守护'),
			E('div', { 'class': 'cbi-map-descr' }, '孩子上网时间管理：孩子网络用一会儿、慢一会儿，到点只限速不断网。上网规则、家人、上网记录都在微信小程序「一点守护」里管理。'),
			this.box
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
