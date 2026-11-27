#!/usr/bin/env python
"""CSV 往返契约测试：自己导出的文件必须能自己导入回来。

book_detail._toCsv 按 CSV 标准给含换行的字段加引号，所以释义里带换行是
合法导出。旧导入端先用 LineSplitter 按 \\n 切行、再逐行解析引号，引号内的
换行会被提前切断，后半截单独成行变成一个假单词。

这里同时验证切分语义和源码形态：
  - 记录切分必须认引号，未闭合引号要报错而不是静默吞；
  - _readCsvLines 不能再直接用 LineSplitter。

用法：python tool/verify_csv_roundtrip.py
退出码：0 通过；1 切分语义不符或源码退回旧写法
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
API = os.path.join(ROOT, "lib", "api.dart")
STREAM = os.path.join(ROOT, "lib", "csv_stream.dart")

# 与 book_detail._toCsv 的输出形态一致：第 2 行释义里有换行，被引号包着
CSV_SAMPLE = (
    'spelling,phonetic,definition,forms,failCount,fuzzyCount,mastered\r\n'
    'abandon,/əˈbændən/,"v. 放弃\nn. 放纵",abandoned,3,1,0\r\n'
    'ability,/əˈbɪləti/,n. 能力,,1,0,0\r\n'
)


def split_records(text):
    """按 CSV 语义切记录：引号外的换行才是分隔符，引号内的换行留着。"""
    out, buf, in_quote, i = [], [], False, 0
    while i < len(text):
        ch = text[i]
        if ch == '"':
            if in_quote and i + 1 < len(text) and text[i + 1] == '"':
                buf.append('""')
                i += 2
                continue
            in_quote = not in_quote
            buf.append(ch)
        elif not in_quote and ch in "\r\n":
            if ch == "\r" and i + 1 < len(text) and text[i + 1] == "\n":
                i += 1
            out.append("".join(buf))
            buf = []
        else:
            buf.append(ch)
        i += 1
    if buf:
        out.append("".join(buf))
    return out, in_quote


def split_line(line, delim=","):
    cells, buf, in_quote, i = [], [], False, 0
    while i < len(line):
        ch = line[i]
        if in_quote:
            if ch == '"':
                if i + 1 < len(line) and line[i + 1] == '"':
                    buf.append('"')
                    i += 1
                else:
                    in_quote = False
            else:
                buf.append(ch)
        elif ch == '"':
            in_quote = True
        elif ch == delim:
            cells.append("".join(buf))
            buf = []
        else:
            buf.append(ch)
        i += 1
    cells.append("".join(buf))
    return cells


def main():
    failed = False

    # --- 1. 新切分：3 条记录，第二条 7 个字段，释义保留换行 ---
    records, still_open = split_records(CSV_SAMPLE)
    if len(records) != 3:
        print("FAIL: 应切出 3 条记录（表头 + 2 词），实际 %d 条：%s" % (len(records), records))
        failed = True
    elif still_open:
        print("FAIL: 样本引号是闭合的，却判定为未闭合")
        failed = True
    else:
        cells = split_line(records[1])
        if len(cells) != 7:
            print("FAIL: 第二条记录应有 7 个字段，实际 %d 个：%s" % (len(cells), cells))
            failed = True
        elif cells[2] != "v. 放弃\nn. 放纵":
            print("FAIL: 释义没保住换行，实际 %r" % cells[2])
            failed = True
        else:
            print("PASS: 引号内换行不切记录，释义完整保留")

    # --- 2. 对照：旧的按行切法在同一份导出上就是错 ---
    old_lines = [l for l in CSV_SAMPLE.split("\n") if l.strip()]
    if len(old_lines) <= 3:
        print("FAIL: 对照样本没构造出旧写法的错误")
        failed = True
    else:
        print("PASS: 旧 LineSplitter 会把这份导出切成 %d 行（%d 条记录），确认是 bug"
              % (len(old_lines), len(records)))

    # --- 3. 未闭合引号要能被识别 ---
    broken, still_open2 = split_records('a,"b\nc')
    if still_open2:
        print("PASS: 未闭合引号可识别（应据此报错，不能静默吞）")
    else:
        print("FAIL: 未闭合引号没被识别")
        failed = True

    # --- 4. 源码形态：记录切分已迁到 csv_stream.dart，api.dart 里不再自己按行切 ---
    with open(API, encoding="utf-8", errors="replace") as f:
        src = f.read()

    if "LineSplitter()" in src:
        print("FAIL: api.dart 还在用 LineSplitter 按行切，往返必然失真")
        failed = True
    elif "CsvStreamReader.read(" not in src:
        print("FAIL: api.dart 没有走 CsvStreamReader")
        failed = True
    else:
        print("PASS: 导入改由 CsvStreamReader 流式读")

    # --- 5. 引号只还原一次：导入端不得再整行清洗引号 ---
    # _CsvLineMerger 已把 "" 还原成 "，上层再 replaceAll('"','') 就是把
    # 合法的双引号字符吃掉（He is 5" tall 回导成 He is 5 tall）。
    # 注释里提到这个写法不算违规，所以先去掉行内注释再找。
    code_only = "\n".join(l.split("//")[0] for l in src.splitlines())
    if re.search(r"replaceAll\(\s*'\"'\s*,\s*''\s*\)", code_only):
        print("FAIL: 导入端还在 replaceAll 清洗引号，合法的引号会被二次删除")
        failed = True
    else:
        print("PASS: 导入端不再二次删除引号（引号只由合并层还原一次）")

    # --- 6. 未闭合引号吞行必须回传成坏行计数 ---
    if "onBrokenRecord" not in src:
        print("FAIL: 未闭合引号合并后没有坏行回传，用户只会看到「新增 1」")
        failed = True
    else:
        print("PASS: 未闭合引号按坏行回传，导入结果会报跳过行数")

    with open(STREAM, encoding="utf-8", errors="replace") as f:
        stream = f.read()

    if "class CsvStreamReader" not in stream:
        print("FAIL: 缺 CsvStreamReader 实现")
        failed = True
    elif "class _CsvLineMerger" not in stream or "_endsInsideQuote" not in stream:
        print("FAIL: 物理行合并缺引号状态，引号内换行会被切断")
        failed = True
    elif "_maxRecordLines" not in stream:
        print("FAIL: 未闭合引号没有兜底上限，一个坏引号会吞掉整份文件")
        failed = True
    else:
        print("PASS: 记录合并在 _CsvLineMerger 里，带引号状态和兜底上限")

    if "allowMalformed: false" in stream:
        print("FAIL: 编码探测还在用严格 decode 试探，切口落在汉字中间就会误判成 GBK")
        failed = True
    elif "_looksUtf8" not in stream:
        print("FAIL: 缺 UTF-8 字节结构探测")
        failed = True
    else:
        print("PASS: 编码探测按字节结构判断，尾部截断不算错")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
