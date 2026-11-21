'use strict';
'require view';
'require fs';
'require poll';

// 一点守护状态页：只显示服务是否在运行、版本、编号等基本状态，管理都在微信小程序「一点守护」里
var CODE_IMG = L.resource('doti/miniapp.jpg');

function good(ok, yes, no) { return E('span', { 'style': 'color:' + (ok ? '#2e9e6b' : '#d6336c') + ';font-weight:600' }, ok ? yes : no); }
function row(k, v) { return E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td left', 'width': '33%' }, k), E('td', { 'class': 'td left' }, v) ]); }
function table(rows) { return E('table', { 'class': 'table' }, rows); }

return view.extend({
	load: function() {
		return fs.exec_direct('/usr/sbin/doti', [ 'info' ], 'json').catch(function() { return null; });
	},

	body: function(d) {
		if (!d)
			return E('div', { 'class': 'cbi-section' }, E('p', {}, '读不到一点守护的状态，请确认软件包已经装好。'));
		return E('div', {}, [
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, '服务状态'),
				table([
					row('一点守护服务', good(d.running, '运行中', '没在运行')),
					row('主程序版本', d.version ? d.version + (d.released ? '（' + d.released + '）' : '') : '—'),
					row('路由器编号', d.code || '—'),
					row('家长 WiFi', d.parentWifi || '—')
				])
			])
		]);
	},

	render: function(d) {
		var self = this, box = E('div', {}, this.body(d));
		poll.add(function() {
			return self.load().then(function(x) { box.replaceChildren(self.body(x)); });
		}, 30);
		// 小程序码是随软件包带的静态图片（不向微信请求）；没有图片时只提示搜索
		var scan = E('span', {}, '用微信扫左边的小程序码，或在微信里搜索「一点守护」');
		var img = E('img', { 'src': CODE_IMG, 'alt': '一点守护小程序码', 'style': 'width:160px;height:160px;background:#fff;padding:8px;border-radius:10px;margin:0 20px 10px 0' });
		img.onerror = function() { img.style.display = 'none'; scan.textContent = '在微信里搜索「一点守护」，打开小程序'; };
		return E('div', {}, [
			E('h2', {}, '一点守护'),
			E('div', { 'class': 'cbi-map-descr' }, '孩子上网时间管理：孩子网络用一会儿、慢一会儿，到点只限速不断网。这里只显示基本状态，上网规则、家人、上网记录都在微信小程序「一点守护」里管理。'),
			box,
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, '用小程序管理'),
				E('div', { 'style': 'display:flex;align-items:center;flex-wrap:wrap' }, [
					img,
					E('div', { 'style': 'line-height:2' }, [
						E('div', {}, '1. 手机连上家长 WiFi' + (d && d.parentWifi ? '「' + d.parentWifi + '」' : '')),
						E('div', {}, [ '2. ', scan ]),
						E('div', {}, '3. ' + (d && d.parents ? '在小程序里查看和修改孩子的上网规则' : '按小程序里的引导认领这台路由器'))
					])
				])
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
