'use strict';
'require view';
'require dom';
'require poll';
'require rpc';
'require uci';
'require fs';

/*
 * 只读状态面板，每 5 秒轮询。
 *
 * 每个数据源都包 L.resolveDefault 给出降级值：任何一个不可用（ACL 被
 * 收窄、logd 没起、passwall 配置读不到）都不许让整页崩，对应行显示
 * "—"即可。
 *
 * 防火墙三行读的是配置层（uci firewall），刻意不查内核 nft——那需要
 * exec 权限，而本面板全程无 exec（有意）；配置层 + 未验证标记合起来
 * 语义反而更准（见包内 README）。
 *
 * 红线：无任何写操作、无 exec、无 fw4 reload / 回滚按钮。
 */

var UNPROVEN_MARK = '/etc/uuplugin/firewall.unproven';
var GUARD_ACTIVE_MARK = '/etc/uuplugin/checkpoint/.active';

var callServiceList = rpc.declare({
	object: 'service',
	method: 'list',
	params: [ 'name' ],
	expect: { '': {} }
});

var callRcList = rpc.declare({
	object: 'rc',
	method: 'list',
	params: [ 'name' ],
	expect: { '': {} }
});

var callNetworkDeviceStatus = rpc.declare({
	object: 'network.device',
	method: 'status',
	expect: { '': {} }
});

/* logd 的非流式读取：必须显式 stream:false（默认是流式，经 rpcd/uhttpd
   转发拿不到内容）。返回 [{msg, id, priority, source, time(毫秒)}]。 */
var callLogRead = rpc.declare({
	object: 'log',
	method: 'read',
	params: [ 'lines', 'stream' ],
	expect: { log: [] }
});

function collectData() {
	/* uci.js 有缓存：轮询要看到 firewall/passwall 的新状态必须先 unload */
	uci.unload('firewall');
	uci.unload('passwall');

	return Promise.all([
		L.resolveDefault(callServiceList('uuplugin'), null),           /* 0 */
		L.resolveDefault(callRcList('uuplugin'), null),                /* 1 */
		L.resolveDefault(callNetworkDeviceStatus(), null),             /* 2 */
		L.resolveDefault(callLogRead(300, false), null),               /* 3 */
		L.resolveDefault(fs.stat(UNPROVEN_MARK), null),                /* 4 */
		L.resolveDefault(fs.stat(GUARD_ACTIVE_MARK), null),            /* 5 */
		L.resolveDefault(uci.load('firewall'), null),                  /* 6 */
		L.resolveDefault(uci.load('passwall'), null)                   /* 7 */
	]);
}

function isSection(conf, sid, type) {
	var s = uci.get(conf, sid);
	return s != null && s['.type'] == type;
}

function statusRow(label, value) {
	return E('tr', { 'class': 'tr' }, [
		E('td', { 'class': 'td left', 'width': '33%' }, label),
		E('td', { 'class': 'td left' }, value)
	]);
}

return view.extend({
	/* 只读视图：去掉底部 保存/应用/复位 按钮 */
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	load: function() {
		return collectData();
	},

	renderStatus: function(data) {
		var svcList = data[0], rcList = data[1], netDevs = data[2],
		    logData = data[3], unproven = data[4], guardActive = data[5],
		    fwLoaded = data[6] != null, pwLoaded = data[7] != null;

		/* 1. 服务运行：service list 的实例 running/pid；无实例 → 未运行 */
		var runValue = '—';
		if (svcList != null) {
			var inst = null,
			    insts = (svcList.uuplugin && svcList.uuplugin.instances) || {};
			for (var k in insts)
				if (insts[k].running) { inst = insts[k]; break; }
			runValue = inst ? _('Running (PID %s)').format(inst.pid) : _('Not running');
		}

		/* 2. 开机自启：专门用来暴露 guard 第 3 级的 disable */
		var bootValue = '—';
		if (rcList != null && rcList.uuplugin != null) {
			if (rcList.uuplugin.enabled) {
				bootValue = _('Enabled on boot');
			} else {
				bootValue = E('span', {}, [
					E('strong', { 'style': 'color:#e00000' }, _('Disabled')),
					' — ',
					_('A guard rollback disables the service; after investigating, run: /etc/init.d/uuplugin enable && /etc/init.d/uuplugin start')
				]);
			}
		}

		/* 3. 加速隧道：network.device status 里 ^tun 的设备 */
		var tunValue = '—';
		if (netDevs != null) {
			var tuns = [];
			for (var dev in netDevs)
				if (/^tun/.test(dev))
					tuns.push(dev + (netDevs[dev].up ? ' (up)' : ' (down)'));
			tuns.sort();
			tunValue = tuns.length ? tuns.join(', ') : _('None (not accelerating)');
		}

		/* 4. 防火墙三段（配置层）：uci-defaults 写入的命名段 */
		var fwValue = '—';
		if (fwLoaded) {
			var missing = [];
			if (!isSection('firewall', 'uu', 'zone')) missing.push('uu');
			if (!isSection('firewall', 'lan_uu', 'forwarding')) missing.push('lan_uu');
			if (!isSection('firewall', 'uu_lan', 'forwarding')) missing.push('uu_lan');
			fwValue = missing.length
				? E('strong', {}, _('Missing: %s').format(missing.join(', ')))
				: _('All three present (uu zone, lan_uu, uu_lan)');
		}

		/* 5. 未验证标记（黄色警示） */
		var unprovenValue = (unproven != null)
			? E('strong', { 'style': 'color:#b8860b' },
				_('Present: committed to persistent configuration but never passed an egress health check; a guard rollback is authorized to remove the three sections'))
			: _('Not present');

		/* 6. guard 布防中（橙色警示） */
		var guardValue = (guardActive != null)
			? E('strong', { 'style': 'color:#e07800' },
				_('Armed: a dangerous change is inside its unconfirmed window (or a previous change never finished)'))
			: _('Not armed');

		/* 7. PassWall 联动：匿名 acl_rule 段按 remarks 锚定（与 render 的
		      find_sid 一致，排除历史遗留的命名段 passwall.uuplugin） */
		var pwValue = '—';
		if (pwLoaded) {
			var acl = uci.sections('passwall', 'acl_rule').filter(function(sec) {
				return sec['.name'] != 'uuplugin' && sec.remarks == 'uuplugin';
			})[0];
			pwValue = acl ? _('Bypass ACL rendered') : _('Bypass ACL not rendered');
		}

		/* 8. 最近日志：客户端过滤 msg 含 uuplugin（含 uuplugin-guard），末 20 行 */
		var logNode;
		if (Array.isArray(logData)) {
			var lines = [];
			for (var i = 0; i < logData.length; i++) {
				var entry = logData[i];
				if (!entry || typeof entry.msg != 'string' ||
				    entry.msg.indexOf('uuplugin') == -1)
					continue;
				var when = (typeof entry.time == 'number')
					? new Date(entry.time).toLocaleString() + '  ' : '';
				lines.push(when + entry.msg);
			}
			lines = lines.slice(-20);
			logNode = E('pre', { 'style': 'overflow:auto;max-height:24em' },
				lines.length ? lines.join('\n') : _('No uuplugin log entries'));
		} else {
			logNode = E('pre', {},
				_('Log unavailable (no permission or logd not running)'));
		}

		return [
			E('h3', {}, _('Service')),
			E('table', { 'class': 'table' }, [
				statusRow(_('Running state'), runValue),
				statusRow(_('Start on boot'), bootValue),
				statusRow(_('Acceleration tunnels'), tunValue)
			]),
			E('h3', {}, _('Firewall & PassWall')),
			E('table', { 'class': 'table' }, [
				statusRow(_('Firewall sections (config layer)'), fwValue),
				statusRow(_('Unproven firewall marker'), unprovenValue),
				statusRow(_('Guard checkpoint'), guardValue),
				statusRow(_('PassWall integration'), pwValue)
			]),
			E('h3', {}, _('Recent Log')),
			logNode
		];
	},

	render: function(data) {
		var container = E('div', {}, this.renderStatus(data));

		poll.add(L.bind(function() {
			return collectData().then(L.bind(function(newData) {
				dom.content(container, this.renderStatus(newData));
			}, this));
		}, this), 5);

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('UU Accelerator Status')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Read-only status panel; refreshes every 5 seconds and performs no action on the router.')),
			container
		]);
	}
});
