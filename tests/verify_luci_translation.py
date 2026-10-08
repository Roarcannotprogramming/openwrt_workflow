"""Check the shipped LuCI catalog against the actual pinned, patched frontend."""
import ast
import json
from pathlib import Path
import re
import subprocess
import sys


def read_catalog(path):
    entries = {}
    key = value = None
    field = None
    for line in path.read_text().splitlines() + ['']:
        if line.startswith('msgid '):
            if key is not None:
                assert key not in entries, f'Duplicate message: {key}'
                entries[key] = value
            key, value, field = ast.literal_eval(line[6:]), '', 'key'
        elif line.startswith('msgstr '):
            value, field = ast.literal_eval(line[7:]), 'value'
        elif line.startswith('"'):
            if field == 'key':
                key += ast.literal_eval(line)
            elif field == 'value':
                value += ast.literal_eval(line)
    if key is not None:
        entries[key] = value
    return entries


def verify(source_dir):
    app = source_dir / 'luci-app-internet-detector'
    repo = Path(__file__).resolve().parents[1]
    catalog = read_catalog(repo / 'watchdog/luci/po/zh_Hans/internet-detector.po')
    sources = list((app / 'htdocs').rglob('*.js'))
    messages = set()
    literal = r'''_\(\s*((?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'))\s*\)'''
    for path in sources:
        messages.update(ast.literal_eval(m.group(1)) for m in re.finditer(literal, path.read_text()))
    messages.add('Internet Detector')  # LuCI menu entry
    missing = sorted(m for m in messages if not catalog.get(m))
    assert not missing, f'Missing Chinese translations: {missing}'
    for message in messages:
        assert re.search(r'[\u4e00-\u9fff]', catalog[message]), f'Untranslated UI text: {message}'
        assert sorted(re.findall(r'%[sd]', message)) == sorted(re.findall(r'%[sd]', catalog[message])), message
    # Execute the real view with lightweight LuCI form stubs and inspect the options
    # it constructs. This catches ambiguous startup controls and losing a configured
    # 15-second timeout on saving, rather than matching the patch text itself.
    result = subprocess.run(['node', '-e', r'''
const fs = require('fs'), assert = require('assert');
const catalog = JSON.parse(process.argv[2]);
// Core catalogs can override shared strings in LuCI's merged translations.
const core = {Service:'服务', Enabled:'已启用', Logging:'日志记录'};
const _ = text => core[text] || catalog[text] || text;
String.prototype.format = function(...args) { let i=0; return this.replace(/%[sd]/g, () => args[i++]); };
const records=[];
function option(type, name, title, description) {
  const o={ name, title, description, choices:[], labels:{}, value(v,label){this.choices.push(String(v));this.labels[v]=label}, depends(){},
    subsection:section() }; records.push(o);return o;
}
function section(){return {section:'internet', tab(){},option,taboption(tab,...args){return option(...args)}};}
const maps=[];
function Map(){ maps.push(this);this.children=[];this.section=()=>{const s=section();this.children.push(s);return s};
  this.render=()=>Promise.resolve({classList:{add(){}}}); }
const classStub={extend: o=>o};
const form=new Proxy({Map}, {get:(target,key)=>target[key] || classStub});
const ui={Dropdown:classStub,Textfield:classStub,createHandlerFn(){return ()=>{}},addNotification(){}};
const L={env:{pollinterval:5},bind:()=>()=>{},resolveDefault:x=>x};
const rpc={declare:()=>()=>Promise.resolve({})}, fsStub={}, poll={add(){}}, widgets={DeviceSelect:classStub};
const uci={get:()=> '1'};
const E=()=>({});
const document={head:{append(){}}};
const baseclass={extend:o=>o};
const code=fs.readFileSync(process.argv[1], 'utf8');
const view=new Function('view','form','ui','L','rpc','fs','poll','widgets','uci','E','_','document','baseclass',code)(
  {extend:o=>o},form,ui,L,rpc,fsStub,poll,widgets,uci,E,_,document,baseclass);
view.setInternetStatus=()=>{};
view.render([{code:0,stdout:'running'},true,[{name:'test-led'}],
  {curl_exec:true,mm_mod:true,mm_init:true,email_mod:true,email_exec:true,telegram:true}]);
const s=maps[0].children.find(s=>s.addModalOptions);s.addModalOptions(s,'internet',{});
const get=name=>records.find(o=>o.name===name);
assert(get('mode').labels['1'].includes('后台'), 'Mode must explicitly say background service even with core translations loaded');
for(const name of ['mod_led_control_enabled','mod_reboot_enabled','mod_network_restart_enabled',
  'mod_modem_restart_enabled','mod_public_ip_enabled','mod_email_enabled','mod_telegram_enabled',
  'mod_user_scripts_enabled','mod_regular_script_enabled']) {
  assert(get(name).title.startsWith('启用'), 'Unchecked module must use an enable-action label, not an enabled-state label: '+name);
}
const timeout=get('connection_timeout');assert(timeout.choices.includes('15'),'15s must be a selectable timeout');
const down=get('mod_user_scripts_disconnected_at_startup');
const up=get('mod_user_scripts_connected_at_startup');
assert(down.title.includes('断网') && up.title.includes('联网'), 'Startup controls must say which state triggers them');
assert(down.description.includes('开机') && down.description.includes('开启'), 'Down-script startup help must explain boot recovery');
assert(up.description.includes('关闭'), 'Up-script startup help must state this workflow does not need it');
assert(get('enabled').description.includes('开启'), 'Instance enable control needs a recommendation');
for(const tab of ['main','led_control','reboot_device','restart_network','restart_modem',
  'public_ip','user_scripts','regular_script','email','telegram']) {
  const guide=get('_watchdog_guide_'+tab);
  assert(guide && /[\u4e00-\u9fff]/.test(guide.default), 'Missing rendered Chinese help for '+tab);
}
console.log('Chinese catalog covers '+Object.keys(catalog).length+' messages; LuCI startup and timeout controls verified');
''', str(app / 'htdocs/luci-static/resources/view/internet-detector.js'), json.dumps(catalog)])
    assert result.returncode == 0, 'LuCI option construction failed'


if __name__ == '__main__':
    verify(Path(sys.argv[1]))
