"""Run upstream Lua behavior against a controlled curl process (no device reboot)."""
import ctypes
import ctypes.util
import json
import os
from pathlib import Path
import sys
import subprocess
import tempfile


def lua_run(source):
    lib = ctypes.CDLL(ctypes.util.find_library('lua5.3') or ctypes.util.find_library('lua5.4'))
    lib.luaL_newstate.restype = ctypes.c_void_p
    lib.luaL_openlibs.argtypes = [ctypes.c_void_p]
    lib.luaL_loadstring.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    lib.lua_pcallk.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int,
                             ctypes.c_ssize_t, ctypes.c_void_p]
    lib.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
    lib.lua_tolstring.restype = ctypes.c_char_p
    lib.lua_close.argtypes = [ctypes.c_void_p]
    state = lib.luaL_newstate()
    try:
        lib.luaL_openlibs(state)
        code = lib.luaL_loadstring(state, source.encode())
        if not code:
            code = lib.lua_pcallk(state, 0, 0, 0, 0, None)
        if code:
            raise AssertionError(lib.lua_tolstring(state, -1, None).decode())
    finally:
        lib.lua_close(state)


def verify(source_dir):
    main = source_dir / 'internet-detector/files/usr/lib/lua/internet-detector/main.lua'
    modules = source_dir / 'internet-detector/files/usr/lib/lua/internet-detector/modules'
    temporary_root = Path(os.environ.get('TMPDIR', str(Path.home() / '.paseo/.tmp')))
    temporary_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=temporary_root) as directory:
        root = Path(directory)
        argv_path = root / 'argv.json'
        marker = root / 'injected'
        fake_curl = root / 'curl'
        fake_curl.write_text('#!' + sys.executable + '\nimport json,sys\n'
            'open(' + repr(str(argv_path)) + ',"w").write(json.dumps(sys.argv[1:]))\n'
            'print("HTTP/1.1 103 Early Hints\\r\\n\\r\\nHTTP/1.1 503 Service Unavailable\\r\\nContent-Length: 0\\r\\n\\r\\n")\n')
        fake_curl.chmod(0o755)
        url = "https://example.invalid/?q=';touch " + str(marker) + ";$(touch " + str(marker) + ")"
        stubs = '''
for _, name in ipairs({'posix.dirent','posix.fcntl','posix.signal','posix.sys.socket',
 'posix.sys.stat','posix.syslog','posix.time','posix.unistd'}) do
 package.preload[name] = function() return {} end
end
package.preload['uci'] = function() return {cursor=function() return {get=function() return nil end} end} end
'''
        lua_run(stubs + '\nlocal detector=dofile(' + json.dumps(str(main)) + ')\n'
            'detector.curlExec=' + json.dumps(str(fake_curl)) + '\n'
            'local rows={};detector.auditEvent=function(self,event,fields) rows[#rows+1]={event=event,fields=fields} end\n'
            'assert(detector:checkURL(' + json.dumps(url) + ')==0,"HTTPS response must prove connectivity")\n'
            'assert(#rows==1 and rows[1].event=="https_probe","Every native probe needs an audit record")\n'
            'assert(rows[1].fields.target=="example.invalid" and rows[1].fields.result=="online","Log only the target origin and result")\n'
            'assert(detector:checkURL("http://example.invalid")==1,"Plain HTTP must not be accepted")\n')
        assert not marker.exists(), 'URL was executed as shell code'
        argv = json.loads(argv_path.read_text())
        assert argv[-1] == url, 'curl did not receive the literal URL'
        assert '--proto' in argv and argv[argv.index('--proto') + 1] == '=https'
        assert '--max-time' in argv and int(argv[argv.index('--max-time') + 1]) > 0
        assert '--insecure' not in argv and '-k' not in argv
        assert '--location' not in argv and '-L' not in argv
        # The installed upstream callback module, not a reimplementation of its counters.
        lua_run('package.preload["posix.unistd"]=function() return {} end\n'
            'local module=dofile(' + json.dumps(str(modules / 'mod_user_scripts.lua')) + ')\n'
            'module.config={configDir="/etc/internet-detector",serviceConfig={instance="internet"}}\n'
            'module:init({dead_period=0,down_script_attempts=0,down_script_attempt_interval=300,disconnected_at_startup=1})\n'
            'local count=0; module.runExternalScript=function(self,path) if path==self.downScript then count=count+1 end end\n'
            'for t=0,603 do module:run(1,1,1,t,false) end\n'
            'assert(count==3,"Persistent outage must retry without a once-only latch")\n'
            'module:run(0,1,1,604,true);module:run(1,0,1,605,true)\n'
            'assert(count==4,"A later outage must repeat recovery")\n')
    lua_run('package.preload["posix.unistd"]=function() return {access=function() return true end} end\n'
        'local module=dofile(' + json.dumps(str(modules / 'mod_user_scripts.lua')) + ')\n'
        'local fields;module.config={auditCycle="pending-round",auditDecisionCycle="finished-round",auditEvent=function(self,event,data) fields=data end}\n'
        'module.downScript="/fixture/down";local command;os.execute=function(cmd) command=cmd;return 0 end\n'
        'module:runExternalScript(module.downScript)\n'
        'assert(fields.cycle=="finished-round","Dispatch must reference the completed decision round")\n'
        'assert(command:find("finished%-round"),"Recovery must inherit the decision round")\n')
    frontend = source_dir / 'luci-app-internet-detector/htdocs/luci-static/resources/view/internet-detector.js'
    subprocess.run(['node', '-e', r"""
const fs = require('fs');
const assert = require('assert');
const source = fs.readFileSync(process.argv[1], 'utf8');
const body = source.match(/validateUrl\(section, value\) \{([\s\S]*?)\n\t\},/)[1];
const validate = new Function('section', 'value', '_', body);
assert.strictEqual(validate(null, 'https://www.baidu.com/', x => x), true);
assert.notStrictEqual(validate(null, 'http://www.baidu.com/', x => x), true);
assert(source.includes('Any response over verified HTTPS means online'));
""", str(frontend)], check=True)
    print('Patched Lua/LuCI checks passed: HTTPS transport, bounded curl, literal URL, unlimited recovery')


if __name__ == '__main__':
    verify(Path(sys.argv[1]))
