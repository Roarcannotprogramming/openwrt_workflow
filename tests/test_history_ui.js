'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const sourcePath = path.join(__dirname,
    '../watchdog/overlay/www/luci-static/resources/view/cpe-watchdog-logs.js');
const source = fs.readFileSync(sourcePath, 'utf8');

let queryCalls = [];
let exportCalls = [];
let downloaded = null;

function E(tag, attrs, children) {
    if (children === undefined && (Array.isArray(attrs) || typeof attrs === 'string')) {
        children = attrs;
        attrs = {};
    }
    return { tag: tag, attrs: attrs || {}, children: children || [] };
}

const rpc = {
    declare: function(spec) {
        if (spec.method === 'query') {
            return function(page, pageSize, date, event) {
                queryCalls.push([page, pageSize, date, event]);
                return Promise.resolve({
                    records: [{
                        timestamp: '2026-10-15T02:00:00+00:00',
                        event: '<img src=x onerror=alert(1)>',
                        result: 'ok'
                    }],
                    meta: { available: 1, total: 1, page: 1, page_size: 25,
                        pages: 1, first: 1, last: 1 }
                });
            };
        }
        return function(offset, limit, date, event, snapshot) {
            exportCalls.push([offset, limit, date, event, snapshot]);
            if (offset === 0)
                return Promise.resolve({ data: '{"event":"new"}\n', next_offset: 1, snapshot: 'fixture' });
            return Promise.resolve({ data: '{"event":"old"}\n', next_offset: null, snapshot: 'fixture' });
        };
    }
};

const view = { extend: function(value) { return value; } };
const dom = { content: function(node, children) { node.children = children; } };
const poll = { add: function() {} };
const L = {
    bind: function(fn, self) { return fn.bind(self); },
    resolveDefault: function(value, fallback) {
        return Promise.resolve(value).catch(function() { return fallback; });
    }
};
const translate = function(value) { return value; };

global.Blob = class BlobFixture {
    constructor(parts, options) { this.parts = parts; this.options = options; }
};
global.URL = {
    createObjectURL: function(blob) { downloaded = blob; return 'blob:fixture'; },
    revokeObjectURL: function() {}
};
global.document = {
    createElement: function() {
        return { click: function() {}, remove: function() {} };
    },
    body: { appendChild: function() {} }
};

const factory = new Function('view', 'dom', 'poll', 'rpc', 'L', 'E', '_', source);
const page = factory(view, dom, poll, rpc, L, E, translate);

function walk(node, visit) {
    if (node == null) return;
    visit(node);
    if (typeof node === 'object') {
        const children = Array.isArray(node.children) ? node.children : [node.children];
        children.forEach(function(child) { walk(child, visit); });
    }
}

(async function() {
    const data = await page.load();
    const tree = page.render(data);
    let maliciousAsText = false;
    walk(tree, function(node) {
        if (node === '<img src=x onerror=alert(1)>') maliciousAsText = true;
        if (node && node.attrs) assert.equal(node.attrs.innerHTML, undefined);
    });
    assert.equal(maliciousAsText, true, 'event must be passed to E() as text');
    assert.deepEqual(queryCalls[0], [1, 25, '', '']);

    const multiplePages = { records: data.records, meta: {
        available: 50, total: 50, page: 1, page_size: 25, pages: 2, first: 1, last: 25
    }};
    let next;
    walk(E('div', {}, page.renderResults(multiplePages)), function(node) {
        if (node && node.tag === 'button' && node.children === '下一页') next = node;
    });
    assert.ok(next);
    // LuCI E() uses setAttribute: disabled=false still disables an HTML button.
    assert.ok(next.attrs.disabled == null, 'enabled pager must omit disabled attribute');

    await page.handleExport();
    assert.deepEqual(exportCalls, [[0, 200, '', '', ''], [1, 200, '', '', 'fixture']]);
    assert.deepEqual(downloaded.parts, ['{"event":"new"}\n', '{"event":"old"}\n']);
    assert.equal(downloaded.options.type, 'application/x-ndjson;charset=utf-8');

    process.stdout.write('history UI runtime checks passed\n');
})().catch(function(error) {
    console.error(error);
    process.exitCode = 1;
});
