#!/usr/bin/env python
"""通用"编译器当验收人"的警告改写驱动器（本仓零警告施工的主力工具）。

为什么要有这个东西（三条实测教训堆出来的）：
 1. 本仓 .mbt 的 blob 是 `\\r\\r\\n` 行尾 ⇒ moon 诊断给的**行号偏大**（实测报 145 实为 112），
    context 窗口也跟着偏 ⇒ 想"按位置改"根本锁不准，硬按位置改会把代码剪碎（W3 的 71 个 error）。
 2. 文本形状也不足以决定改法：`substring(…)` 的返回类型跟着接收者走
    （String→String、StringView→StringView），同一串文本两种改法，猜错就是
    "Type String has no method to_owned"（W6b 实测 37 站全错）。
 3. 连"两个编译通道都报未用"都不能当准绳（W5：check+test 都报 @id_gen 未用，删掉即 11 error）。
 ⇒ 唯一可信的是**改完再让编译器判一次**。这个驱动就把这件事标准化：
    · 先整批试（便宜：一次 check 覆盖全部站点，命中即省 N-1 次）；
    · 整批不过 ⇒ 逐站试，一站多形态（按 variants 顺序试到第一个"0 error 且目标类警告数下降"）；
    · 每站的失败都回滚，只保留编译器认可的那一版。

用法：
  python scripts/moon_warn_oracle.py <recipe> [--limit N]
  recipe 见本文件 RECIPES（新形状往里加一条即可，不要另写脚本）。
"""
import io
import json
import os
import re
import subprocess
import sys

ROOT = os.getcwd()
MOON = r"G:/dev-tools/moon/bin/moon.exe"
ENV = dict(os.environ, MOON_HOME=r"G:/dev-tools/moon",
           PATH=r"G:/dev-tools/moon/bin;" + os.environ.get("PATH", ""))


def mbt_files():
    out = subprocess.run(["git", "ls-files", "*.mbt"], capture_output=True, text=True).stdout.split()
    return [f for f in out if ".mooncakes" not in f.replace("\\", "/")]


def rd(f):
    return io.open(os.path.join(ROOT, f), encoding="utf-8", newline="").read()


def wr(f, s):
    io.open(os.path.join(ROOT, f), "w", encoding="utf-8", newline="").write(s)


_cache = {}


def check():
    """→ {类名: 条数}, error 数.  类名取 `Warning (X)` 的 X；error 单列。"""
    p = subprocess.run([MOON, "check", "--target", "wasm", "--output-json"],
                       capture_output=True, text=True, encoding="utf-8", errors="replace",
                       env=ENV, cwd=ROOT)
    tally, errs, why = {}, 0, []
    for line in (p.stdout or "").splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            d = json.loads(line)
        except ValueError:
            continue
        m = d.get("message", "")
        if d.get("level") == "error":
            errs += 1
            if len(why) < 2:
                why.append(m.replace("\n", " / ")[:110])
            continue
        key = re.match(r"Warning \((\w+)\)", m)
        key = key.group(1) if key else "other"
        tally[key] = tally.get(key, 0) + 1
    return tally, errs, why


# ── 菜谱：每条 = 类名 + 找站点的正则 + 依次尝试的改写形态 ────────────────────────
# 占位符沿用 re.sub 的 \\1 语义（group 由正则自己命名/编号）。
# 接收者只吃"标识符/限定名"，尾巴可选（原来就跟了 .to_string() 的要一起处理）
SUB_TARGET = r"(?P<recv>[A-Za-z_@][\w.]*?)\.substring\((?P<args>[^()]*(?:\([^()]*\)[^()]*)*)\)(?P<tail>\.to_string\(\)|\.to_owned\(\)|)"
RECIPES = {
    # substring(start=A, end=B) → recv[A:B]；无 end 时 → recv[A:]；带尾巴时补 to_owned()
    "slice": dict(
        cls="deprecated",
        site=re.compile(SUB_TARGET),
        variants=lambda m: _slice_variants(m),
    ),
    # Json 的 .value(k) → @json.get(x, k)（我们自己的 get 就是编译器建议的那一形状）
    "jget": dict(
        cls="deprecated",
        site=re.compile(r"(?P<recv>[A-Za-z_@][\w.]*?)\.value\((?P<arg>[^()]+)\)"),  # 空实参的那些是我们自己的 DictItem/QueryFilter::value，不该动
        variants=lambda m: [
            ("@json.get(%s, %s)" % (m["recv"], m["arg"])),
            ("get(%s, %s)" % (m["recv"], m["arg"])),          # core/json 自己包内直呼
        ],
    ),
    # unused_error_type：函数声明了 raise 却一处不抛 ⇒ 把 ` raise` 摘掉。
    # 只匹配"签名末尾紧跟 {" 的那一个（`-> T raise {` / `-> T raise @error.JeeflowError {`），
    # 不碰语句里的 raise。摘了会不会有连锁（调用方的 try 变空）——交给验收人说谎不了。
    "noer": dict(
        cls="unused_error_type",
        site=re.compile(r" raise(?: @error\.JeeflowError)?(?= \{)"),
        variants=lambda m: [""],
    ),
    "jasm": dict(
        cls="deprecated",
        site=re.compile(r"(?P<recv>[A-Za-z_@][\w.]*?)\.as_(string|bool|number|array)\(\)"),
        # 本仓 core/json 的助手名与内建不是一一对应：as_number→as_f64、as_string→as_str，
        # as_array 是 W8a 刚补的那一个。包内直呼的形态排第二，给 core/json 自己用。
        variants=lambda m: (lambda pair: [
            "@json.%s(%s)" % (pair, m["recv"]),
            "%s(%s)" % (pair, m["recv"]),
        ])({"string": "as_str", "number": "as_f64",
            "bool": "as_bool", "array": "as_array"}[m.group(2)]),
    ),
}


def _slice_variants(m):
    recv, tail = m["recv"], m["tail"]
    args = {}
    for part in m["args"].split(","):
        if "=" in part:
            k, v = part.split("=", 1)
            args[k.strip()] = v.strip()
    a, b = args.get("start"), args.get("end")
    if a is None:
        return []
    idx = "%s[%s:%s]" % (recv, a, b or "")
    out = [idx]
    if tail:                                   # 原来就要 String ⇒ 切片后补 to_owned()
        out.append(idx + ".to_owned()")
    return out


def run(name, limit=0):
    r = RECIPES[name]
    cls = r["cls"]
    base, errs0, _ = check()
    if errs0:
        sys.exit("开局就有 %d 个 error，先修干净再跑（%s）" % (errs0, base))
    b0 = base.get(cls, 0)
    print("基线 %s=%d，总 warn=%d，err=0" % (cls, b0, sum(base.values())))

    files = [f for f in mbt_files() if r["site"].search(rd(f))]
    snaps = {f: rd(f) for f in files}
    batch = 0
    for f in files:
        s = rd(f)

        def rep(m):
            v = r["variants"](m)
            return v[0] if v else m.group(0)

        s2, n = r["site"].subn(rep, s)
        batch += n
        wr(f, s2)
    t, e, why = check()
    if e == 0 and t.get(cls, 0) < b0:
        print("整批改写 %d 站 ⇒ %s %d→%d（err=0）" % (batch, cls, b0, t.get(cls, 0)))
        b0 = t.get(cls, 0)
    else:
        print("整批不过（批内命中 %d、err=%d %s，%s %d→%d）⇒ 逐站试"
              % (batch, e, why[:1], cls, b0, t.get(cls, 0)))
        for f, raw in snaps.items():
            wr(f, raw)
        done = skipped = 0
        for f in files:
            for m in reversed(list(r["site"].finditer(rd(f)))):          # 从后往前：前面的偏移不动
                raw = rd(f)
                variants = r["variants"](m)
                ok = False
                for v in variants:
                    wr(f, raw[:m.start()] + v + raw[m.end():])
                    t, e, why = check()
                    if e == 0 and t.get(cls, 999) < b0:
                        b0 = t[cls]
                        done += 1
                        ok = True
                        print("  保留 %-40s ⇒ %-46s %s=%d" % (f, v[:44], cls, b0))
                        break
                if not ok:
                    wr(f, raw)
                    skipped += 1
                    print("  跳过 %-40s @%-6d %d 个形态都不过：%s"
                          % (f, m.start(), len(variants), why[0] if why else "目标类警告数不降"))
                    check()
                if limit and done >= limit:
                    break
        print("逐站：保留 %d、跳过 %d" % (done, skipped))
    t, e, _ = check()
    print("收尾 %s=%d 总 warn=%d err=%d" % (cls, t.get(cls, 0), sum(t.values()), e))


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        print("可选菜谱：", " ".join(sorted(RECIPES)))
        sys.exit(2)
    lim = 0
    if "--limit" in sys.argv:
        lim = int(sys.argv[sys.argv.index("--limit") + 1])
    run(args[0], lim)
