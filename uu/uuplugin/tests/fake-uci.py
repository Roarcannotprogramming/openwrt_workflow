#!/usr/bin/env python3
"""测试用的假 uci：用 JSON 文件模拟 uci 状态机。

支持 uuplugin-render / uuplugin.defaults 用到的子集：
  get / set / delete / add_list / commit / batch
外加两个测试专用命令：
  _sections <config> <type>   按序输出指定类型的 section 名（给假 functions.sh 用）
  _dump                       打印整个状态（调试用）

额外行为：所有写操作追加记录到 $UCI_OPLOG（若设置），
用于断言"幂等路径上没有发生任何写"。
"""

import json
import os
import re
import sys

STATE = os.environ.get("UCI_STATE", "/tmp/fake-uci.json")
OPLOG = os.environ.get("UCI_OPLOG", "")
REFUSE = os.environ.get("UCI_REFUSE", "")


def load():
    if os.path.exists(STATE):
        with open(STATE) as f:
            return json.load(f)
    return {}


def save(db):
    with open(STATE, "w") as f:
        json.dump(db, f, indent=1)


def oplog(line):
    if OPLOG:
        with open(OPLOG, "a") as f:
            f.write(line + "\n")


def resolve_section(db, config, sec):
    """把 @type[idx] 解析成实际 section 名；普通名字原样返回。"""
    m = re.fullmatch(r"@([a-zA-Z_]+)\[(-?\d+)\]", sec)
    if not m:
        return sec
    typ, idx = m.group(1), int(m.group(2))
    names = [n for n in db.get(config, {}).get("_order", [])
             if db[config]["sections"][n]["_type"] == typ]
    try:
        return names[idx]
    except IndexError:
        return None


def parse_ref(db, ref):
    """config.section[.option] -> (config, secname, option|None)"""
    parts = ref.split(".")
    if len(parts) == 2:
        cfg, sec = parts
        opt = None
    elif len(parts) == 3:
        cfg, sec, opt = parts
    else:
        raise SystemExit(f"uci: invalid ref {ref}")
    return cfg, resolve_section(db, cfg, sec), opt


def cmd_get(db, ref):
    cfg, sec, opt = parse_ref(db, ref)
    sections = db.get(cfg, {}).get("sections", {})
    if sec not in sections:
        return 1
    if opt is None:
        print(sections[sec]["_type"])
        return 0
    if opt not in sections[sec]:
        return 1
    v = sections[sec][opt]
    print(" ".join(v) if isinstance(v, list) else v)
    return 0


def cmd_set(db, assignment):
    ref, _, value = assignment.partition("=")
    cfg, sec, opt = parse_ref(db, ref)
    if sec is None:
        return 1
    db.setdefault(cfg, {"_order": [], "sections": {}})
    sections = db[cfg]["sections"]
    if opt is None:  # set config.section=type
        if sec not in sections:
            sections[sec] = {"_type": value}
            db[cfg]["_order"].append(sec)
        else:
            sections[sec]["_type"] = value
    else:
        if sec not in sections:
            return 1
        sections[sec][opt] = value
    oplog(f"set {assignment}")
    save(db)
    return 0


def cmd_add_list(db, assignment):
    ref, _, value = assignment.partition("=")
    cfg, sec, opt = parse_ref(db, ref)
    sections = db.get(cfg, {}).get("sections", {})
    if sec not in sections or opt is None:
        return 1
    cur = sections[sec].get(opt, [])
    if not isinstance(cur, list):
        cur = [cur]
    cur.append(value)
    sections[sec][opt] = cur
    oplog(f"add_list {assignment}")
    save(db)
    return 0


def cmd_delete(db, ref):
    cfg, sec, opt = parse_ref(db, ref)
    sections = db.get(cfg, {}).get("sections", {})
    if sec not in sections:
        return 1
    if opt is None:
        del sections[sec]
        db[cfg]["_order"].remove(sec)
    elif opt in sections[sec]:
        del sections[sec][opt]
    else:
        return 1
    oplog(f"delete {ref}")
    save(db)
    return 0


def cmd_add(db, config, typ):
    db.setdefault(config, {"_order": [], "sections": {}})
    n = db[config].get("_seq", 0) + 1
    db[config]["_seq"] = n
    name = f"cfg{n:02d}{typ[:4]}"
    # _anon：`uci add` 建出来的是匿名 section。真 uci 的 show 会把它印成
    # @type[idx]（cli.c 里 sprintf "@%s[%d]"），而 stock OpenWrt 的
    # /etc/config/firewall 全是这种形态——不模拟就没法测真机上唯一跑的那条路径
    db[config]["sections"][name] = {"_type": typ, "_anon": True}
    db[config]["_order"].append(name)
    oplog(f"add {config} {typ}")
    save(db)
    print(name)
    return 0


def dispatch(db, argv):
    cmd, args = argv[0], argv[1:]
    # 测试钩子：UCI_REFUSE 是个正则，命中的命令原样拒掉（返回 1、不改状态）。
    # 用来模拟 `uci batch` 写到一半失败——真 uci 的 batch 是逐行执行的，
    # 前面的行已经落盘，后面的行没有，留下半成品。没有这个钩子就没法证明
    # 脚本的写后验收真的在干活。
    if REFUSE and re.search(REFUSE, " ".join(argv)):
        return 1
    if cmd == "get":
        return cmd_get(db, args[0])
    if cmd == "add":
        return cmd_add(db, args[0], args[1])
    if cmd == "set":
        return cmd_set(db, args[0])
    if cmd == "add_list":
        return cmd_add_list(db, args[0])
    if cmd == "delete":
        return cmd_delete(db, args[0])
    if cmd == "commit":
        oplog(f"commit {args[0] if args else ''}".rstrip())
        return 0
    if cmd == "batch":
        rc = 0
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            # batch 里的值可能带引号
            line = re.sub(r"='(.*)'$", lambda m: "=" + m.group(1), line)
            rc |= dispatch(db, line.split(None, 1)) or 0
        return rc
    if cmd == "show":
        c = args[0]
        # 匿名 section 按真 uci 的样子印成 @type[idx]，idx 在同类型 section
        # 里从 0 数起（具名的也计入，与 resolve_section 的口径一致）
        seen = {}
        for name in db.get(c, {}).get("_order", []):
            sec = db[c]["sections"][name]
            typ = sec["_type"]
            idx = seen.get(typ, 0)
            seen[typ] = idx + 1
            label = f"@{typ}[{idx}]" if sec.get("_anon") else name
            print(f"{c}.{label}={typ}")
            for k, v in sec.items():
                if k in ("_type", "_anon"):
                    continue
                val = " ".join(v) if isinstance(v, list) else v
                print(f"{c}.{label}.{k}='{val}'")
        return 0
    if cmd == "_sections":
        cfg, typ = args
        for n in db.get(cfg, {}).get("_order", []):
            if db[cfg]["sections"][n]["_type"] == typ:
                print(n)
        return 0
    if cmd == "_dump":
        print(json.dumps(db, indent=1, ensure_ascii=False))
        return 0
    raise SystemExit(f"uci: unsupported command {cmd}")


def main():
    argv = sys.argv[1:]
    while argv and argv[0] in ("-q", "-P", "-c"):
        argv = argv[2:] if argv[0] in ("-P", "-c") else argv[1:]
    if not argv:
        raise SystemExit("uci: no command")
    sys.exit(dispatch(load(), argv) or 0)


if __name__ == "__main__":
    main()
