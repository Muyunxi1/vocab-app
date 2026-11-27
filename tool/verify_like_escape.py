#!/usr/bin/env python
"""搜索框 LIKE 转义契约测试。

SQLite 的 ESCAPE 必须是单个字符。Dart 源码里的字面量要产生 SQL 文本
`ESCAPE '\'`（一个反斜杠），也就是源码写两个反斜杠；写成四个反斜杠时
SQL 收到两个字符，直接抛：
    ESCAPE expression must be a single character (code 1 SQLITE_ERROR)

这里既验证 SQL 行为本身，也检查 api.dart 里没有残留的四反斜杠写法。

用法：python tool/verify_like_escape.py
退出码：0 通过；1 写法错误
"""
import os
import re
import sqlite3
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
API = os.path.join(ROOT, "lib", "api.dart")

# 源码文本里的形态（raw string，避免 python 自己再转义一层）
GOOD_IN_SOURCE = r"ESCAPE '\\'"    # 源码两个反斜杠 -> SQL 收到 ESCAPE '\' 单字符
BAD_IN_SOURCE = r"ESCAPE '\\\\'"   # 源码四个反斜杠 -> SQL 收到 ESCAPE '\\' 两字符


def sql_accepts(single):
    """single=True 用单字符 ESCAPE，False 用两字符，看 SQLite 是否报错。"""
    c = sqlite3.connect(":memory:")
    try:
        if single:
            c.execute(r"SELECT 'a_b' LIKE '%a\_b%' ESCAPE '\'").fetchone()
        else:
            c.execute(r"SELECT 'a_b' LIKE '%a\_b%' ESCAPE '\\'").fetchone()
        return True, None
    except sqlite3.OperationalError as e:
        return False, str(e)
    finally:
        c.close()


def main():
    failed = False

    ok, err = sql_accepts(True)
    if not ok:
        print("FAIL: 单字符 ESCAPE 竟然报错：%s" % err)
        failed = True
    else:
        print("PASS: 单字符 ESCAPE 可用")

    ok2, err2 = sql_accepts(False)
    if ok2:
        print("FAIL: 两字符 ESCAPE 居然通过，说明测试假设有误")
        failed = True
    elif "single character" not in err2:
        print("FAIL: 报错文案不符预期：%s" % err2)
        failed = True
    else:
        print("PASS: 两字符 ESCAPE 确实报 single character")

    if not os.path.exists(API):
        print("FAIL: 找不到 lib/api.dart")
        return 1
    with open(API, encoding="utf-8") as f:
        src = f.read()

    bad_count = src.count(BAD_IN_SOURCE)
    good_count = src.count(GOOD_IN_SOURCE)

    if bad_count:
        print("FAIL: api.dart 还有 %d 处 %s（会导致搜索直接崩）" % (bad_count, BAD_IN_SOURCE))
        for m in re.finditer(r"ESCAPE\s*'[^']*'", src):
            line = src[: m.start()].count("\n") + 1
            print("  第 %d 行: %s" % (line, m.group(0)))
        failed = True
    elif good_count < 2:
        print("FAIL: 只找到 %d 处正确写法，词库搜索与复习队列都应各有一处" % good_count)
        failed = True
    else:
        print("PASS: %d 处 ESCAPE 均为单字符写法" % good_count)

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
