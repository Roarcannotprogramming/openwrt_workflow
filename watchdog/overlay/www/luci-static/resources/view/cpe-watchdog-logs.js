'use strict';
'require view';
'require dom';
'require poll';
'require rpc';

var PAGE_SIZE = 25;
var EXPORT_SIZE = 200;

var callQuery = rpc.declare({
	object: 'luci.cpe-watchdog',
	method: 'query',
	params: [ 'page', 'page_size', 'date', 'event' ]
});

var callExport = rpc.declare({
	object: 'luci.cpe-watchdog',
	method: 'export',
	params: [ 'offset', 'limit', 'date', 'event', 'snapshot' ]
});

function cell(value) {
	if (value === undefined || value === null || value === '')
		return '—';
	return String(value);
}

function errorResult(message) {
	return {
		records: [],
		meta: { available: 0, total: 0, page: 1, page_size: PAGE_SIZE,
			pages: 0, first: 0, last: 0 },
		client_error: message
	};
}

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	load: function() {
		return L.resolveDefault(callQuery(1, PAGE_SIZE, '', ''), null).then(function(data) {
			return data && !data.error ? data : errorResult('无法读取日志');
		});
	},

	fetchPage: function(resetPage) {
		if (resetPage)
			this.page = 1;
		var requestPage = this.page;
		return L.resolveDefault(callQuery(
			requestPage, PAGE_SIZE, this.filterDate, this.filterEvent
		), null).then(L.bind(function(data) {
			if (!data || data.error) {
				data = errorResult(data && data.message ? data.message : '无法读取日志');
				data.meta.page = requestPage;
			}
			this.data = data;
			if (this.resultsNode)
				dom.content(this.resultsNode, this.renderResults(data));
			return data;
		}, this));
	},

	handleFilter: function() {
		this.filterDate = this.dateInput.value || '';
		this.filterEvent = (this.eventInput.value || '').trim();
		return this.fetchPage(true);
	},

	handleClear: function() {
		this.dateInput.value = '';
		this.eventInput.value = '';
		this.filterDate = '';
		this.filterEvent = '';
		return this.fetchPage(true);
	},

	handlePage: function(delta) {
		var pages = this.data && this.data.meta ? this.data.meta.pages : 0;
		var next = this.page + delta;
		if (next < 1 || (pages && next > pages))
			return Promise.resolve();
		this.page = next;
		return this.fetchPage(false);
	},

	handleExport: function() {
		var offset = 0;
		var chunks = [];
		var iterations = 0;
		var snapshot = '';
		var date = this.filterDate, event = this.filterEvent;
		if (this.exportButton)
			this.exportButton.disabled = true;
		if (this.exportStatus)
			this.exportStatus.textContent = '正在导出全部匹配日志…';

		var fetchChunk = L.bind(function() {
			return callExport(offset, EXPORT_SIZE, date, event, snapshot)
				.then(L.bind(function(response) {
					if (!response || response.error)
						throw new Error(response && response.message || '导出失败');
					chunks.push(response.data || '');
					snapshot = response.snapshot;
					if (response.next_offset === null || response.next_offset === undefined)
						return chunks;
					if (typeof response.next_offset !== 'number' ||
					    response.next_offset <= offset || ++iterations > 10000)
						throw new Error('导出游标无效');
					offset = response.next_offset;
					return fetchChunk();
				}, this));
		}, this);

		return fetchChunk().then(L.bind(function(parts) {
			var blob = new Blob(parts, { type: 'application/x-ndjson;charset=utf-8' });
			var url = URL.createObjectURL(blob);
			var link = document.createElement('a');
			link.href = url;
			link.download = 'cpe-watchdog-history-' +
				new Date().toISOString().replace(/[:.]/g, '-') + '.jsonl';
			document.body.appendChild(link);
			link.click();
			link.remove();
			URL.revokeObjectURL(url);
			if (this.exportStatus)
				this.exportStatus.textContent = '导出完成';
		}, this)).catch(L.bind(function(error) {
			if (this.exportStatus)
				this.exportStatus.textContent = '导出失败：' + error.message;
		}, this)).then(L.bind(function() {
			if (this.exportButton)
				this.exportButton.disabled = false;
		}, this));
	},

	renderResults: function(data) {
		var meta = data.meta || {};
		var rows = (data.records || []).map(function(record) {
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, cell(record.timestamp)),
				E('td', { 'class': 'td' }, cell(record.event)),
				E('td', { 'class': 'td' }, cell(record.source)),
				E('td', { 'class': 'td' }, cell(record.result)),
				E('td', { 'class': 'td' }, cell(record.model)),
				E('td', { 'class': 'td' }, cell(record.action)),
				E('td', { 'class': 'td' }, E('details', {}, [
					E('summary', {}, '展开'),
					E('pre', { 'style': 'white-space:pre-wrap;word-break:break-all' },
						JSON.stringify(record, null, 2))
				]))
			]);
		});
		if (!rows.length)
			rows.push(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td', 'colspan': 7 },
					data.client_error || '没有匹配的日志')
			]));

		return [
			E('p', {}, '保留范围内有效记录：' + cell(meta.available) +
				'；筛选结果：' + cell(meta.total) +
				'；当前显示：' + cell(meta.first) + '–' + cell(meta.last)),
			E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th' }, '时间（UTC）'),
					E('th', { 'class': 'th' }, '事件'),
					E('th', { 'class': 'th' }, '来源'),
					E('th', { 'class': 'th' }, '结果'),
					E('th', { 'class': 'th' }, '设备型号'),
					E('th', { 'class': 'th' }, '动作'),
					E('th', { 'class': 'th' }, '安全详情')
				])
			].concat(rows)),
			E('div', { 'class': 'cbi-page-actions' }, [
				E('button', {
					'class': 'btn',
					'disabled': meta.page <= 1 || null,
					'click': L.bind(function() { return this.handlePage(-1); }, this)
				}, '上一页'),
				E('span', { 'style': 'padding:0 1em' },
					'第 ' + cell(meta.page) + ' / ' + cell(meta.pages) + ' 页'),
				E('button', {
					'class': 'btn',
					'disabled': !meta.pages || meta.page >= meta.pages || null,
					'click': L.bind(function() { return this.handlePage(1); }, this)
				}, '下一页')
			])
		];
	},

	render: function(data) {
		this.page = data.meta && data.meta.page || 1;
		this.filterDate = '';
		this.filterEvent = '';
		this.data = data;
		this.dateInput = E('input', { 'type': 'date', 'class': 'cbi-input-text' });
		this.eventInput = E('input', {
			'type': 'text', 'class': 'cbi-input-text', 'maxlength': 64,
			'placeholder': '例如：reboot（部分匹配）'
		});
		this.exportStatus = E('span', { 'style': 'padding-left:1em' }, '');
		this.exportButton = E('button', {
			'class': 'btn cbi-button-action',
			'click': L.bind(this.handleExport, this)
		}, '导出全部筛选结果（JSONL）');
		this.resultsNode = E('div', {}, this.renderResults(data));

		poll.add(L.bind(function() {
			if (!this.autoRefresh)
				return Promise.resolve();
			return this.fetchPage(false);
		}, this), 10);
		this.autoRefresh = true;

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, 'CPE 恢复日志'),
			E('div', { 'class': 'cbi-map-descr' },
				'只读显示当前日志及 4 个轮转归档。每个文件最大 1 MiB，完整保留量最多约 5 MiB；更早的记录会被轮转删除。'),
			E('div', { 'class': 'cbi-section' }, [
				E('label', { 'style': 'margin-right:1em' }, ['日期（UTC）：', this.dateInput]),
				E('label', { 'style': 'margin-right:1em' }, ['事件包含：', this.eventInput]),
				E('button', {
					'class': 'btn cbi-button-action',
					'click': L.bind(this.handleFilter, this)
				}, '筛选'),
				' ',
				E('button', {
					'class': 'btn', 'click': L.bind(this.handleClear, this)
				}, '清除'),
				' ',
				E('button', {
					'class': 'btn', 'click': L.bind(function() {
						return this.fetchPage(false);
					}, this)
				}, '立即刷新'),
				' ',
				E('label', {}, [
					E('input', {
						'type': 'checkbox', 'checked': true,
						'change': L.bind(function(event) {
							this.autoRefresh = event.target.checked;
						}, this)
					}),
					' 每 10 秒自动刷新'
				])
			]),
			E('div', { 'class': 'cbi-section' }, [this.exportButton, this.exportStatus]),
			this.resultsNode
		]);
	}
});
