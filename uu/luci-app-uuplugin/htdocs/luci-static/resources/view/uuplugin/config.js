'use strict';
'require view';
'require form';
'require uci';

/*
 * 配置视图：form.Map('uuplugin') → /etc/config/uuplugin。
 *
 * 红线：本界面只读写 uci；不提供任何 fw4 reload / firewall restart /
 * 手动回滚按钮。保存并应用后由 procd 的 reload trigger 走服务既有路径
 * （render → 必要时受 guard 保护地重启 PassWall）。
 *
 * 选项语义与默认值以 package/uuplugin/files/uuplugin.config 为准；
 * lan_iface / wan_iface 由实现侧并行任务提供，uci 里尚不存在时表单
 * 显示为空即是正确行为。
 */

return view.extend({
	render: function() {
		var m, s, o;

		m = new form.Map('uuplugin', _('UU Accelerator'),
			_('Device list and switches for the NetEase UU accelerator / PassWall coexistence layer. Dynamic configuration lives in /etc/config/uuplugin; the firewall zone and the PassWall bypass ACL are rendered from it by the uuplugin service.'));

		/* config uuplugin 'main' —— 命名段，段类型 uuplugin */
		s = m.section(form.NamedSection, 'main', 'uuplugin', _('Global Settings'));

		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.default = '1';

		o = s.option(form.Flag, 'autodetect', _('Auto-detect consoles'),
			_('When a suspected game console appears on the LAN, write a hint to the system log.'));
		o.default = '1';

		o = s.option(form.Flag, 'autoadd', _('Auto-add Nintendo devices'),
			_('Automatically add devices matching a Nintendo OUI. Warning: an auto-added device automatically leaves PassWall, which changes its traffic path. Enable with care.'));
		o.default = '0';

		o = s.option(form.Value, 'guard_timeout', _('Guard timeout (seconds)'),
			_('Dead-man switch: after a dangerous change, if it is not confirmed within this many seconds and the network is down, the change is rolled back automatically.'));
		o.datatype = 'uinteger';
		o.placeholder = '120';

		o = s.option(form.Value, 'passwall_wait', _('PassWall restart wait limit (seconds)'),
			_('Upper bound in seconds to wait for the inet passwall table to come back after PassWall is restarted; it is a deadline, not a fixed delay. If a slow device (e.g. MT7621) gets misjudged as a failed restart, raise it to 60.'));
		o.datatype = 'uinteger';
		o.placeholder = '20';

		o = s.option(form.DynamicList, 'health_target', _('Health check targets (ICMP)'),
			_('ICMP probe targets for the egress health check; ICMP and HTTP probes count as healthy if either passes. Leave empty for the built-in defaults.'));
		o.datatype = 'host';
		o.placeholder = '223.5.5.5';

		o = s.option(form.DynamicList, 'health_url', _('Health check URLs (HTTP)'),
			_('HTTP probe URLs for the egress health check; ICMP and HTTP probes count as healthy if either passes. Leave empty for the built-in defaults.'));
		o.placeholder = 'http://connect.rom.miui.com/generate_204';

		o = s.option(form.Value, 'lan_iface', _('LAN interface'),
			_('netifd logical interface name (not the device name); only needed on systems where the default interface naming was changed.'));
		o.datatype = 'uciname';
		o.placeholder = 'lan';

		o = s.option(form.Value, 'wan_iface', _('WAN interface'),
			_('netifd logical interface name (not the device name); only needed on systems where the default interface naming was changed.'));
		o.datatype = 'uciname';
		o.placeholder = 'wan';

		/* 设备列表：匿名 device 段——与 service uuplugin add / autoadd
		   创建的段同构，因此必须 anonymous */
		s = m.section(form.GridSection, 'device', _('Accelerated Devices'),
			_('Devices accelerated by UU; they bypass PassWall at the same time. After Save & Apply a procd reload re-renders the PassWall bypass ACL: PassWall is restarted and proxy clients lose connectivity for a few seconds.'));
		s.anonymous = true;
		s.addremove = true;
		s.nodescriptions = true;

		s.modaltitle = function(section_id) {
			var name = uci.get('uuplugin', section_id, 'name');
			return _('Edit device') + (name ? ': ' + name : '');
		};

		o = s.option(form.Value, 'name', _('Name'));

		o = s.option(form.Value, 'mac', _('MAC address'));
		o.datatype = 'macaddr';
		o.rmempty = false;
		/* 与实现侧 cmd_add 的 tr 'A-F' 'a-f' 归一对齐：强制小写落盘。
		   否则 scan 的去重按小写比对，会闪过大写重复项 */
		o.write = function(section_id, formvalue) {
			return form.Value.prototype.write.call(this, section_id, String(formvalue).toLowerCase());
		};

		o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.default = '1';

		return m.render();
	}
});
