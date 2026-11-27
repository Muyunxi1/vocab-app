r"""把 ECDICT 精简 CSV 转成 App 内置的只读 SQLite 词典。

用法（在 mobile 目录下，用后端 venv 的 python）：
    ..\backend\.venv\Scripts\python.exe tools\build_dict.py

输入：..\backend\data\ecdict_top.csv（列：word,phonetic,translation,...）
      ..\backend\data\ecdict_full.csv（可选，有的话就用它的 exchange/pos 列）
输出：assets\dict.db（表 dict(word, phonetic, translation, forms)）

translation 按词性分行，第一行是最常用的那个词性；pos 字段能判断哪个词性最常用。
forms 是「常用变形」，一行一条，例如：
    过去式 went
    过去分词 gone
    现在分词 going
"""

import csv
import os
import re
import sqlite3

try:
    from phrases import PHRASES
except ImportError:  # 脚本单独拷走时也要能跑
    PHRASES = {}

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.normpath(os.path.join(HERE, "..", "..", "backend", "data"))
SRC = os.path.join(DATA, "ecdict_top.csv")
FULL = os.path.join(DATA, "ecdict_full.csv")
DST = os.path.normpath(os.path.join(HERE, "..", "assets", "dict.db"))

# ---------------------------------------------------------------- 释义分行

# 长标记排前面，免得 "adj." 被当成 "a."、"adv." 被当成 "ad."
POS_TAGS = ["adj.", "adv.", "abbr.", "prep.", "conj.", "pron.", "phr.",
            "aux.", "art.", "num.", "int.", "pl.", "vt.", "vi.", "ad.",
            "a.", "v.", "n."]


def format_definition(raw):
    """把「n. 会 vt. 遇见 a. 合适的」这种一行压平的释义按词性拆成多行。"""
    text = " ".join((raw or "").split())
    if not text:
        return ""
    for tag in POS_TAGS:
        text = re.sub(r"(?<![A-Za-z0-9])" + re.escape(tag) + r"\s", "\n" + tag + " ", text)
    # [计] [医] 这类领域标记也单独起一行
    text = re.sub(r"\s(\[[^\]]{1,8}\])\s", lambda m: "\n" + m.group(1) + " ", text)
    lines = [ln.strip() for ln in text.split("\n")]
    return "\n".join([ln for ln in lines if ln])


def pos_ratio(pos_raw):
    """解析 pos 字段，形如 n:64/v:36，返回 {键: 百分比}。"""
    ratios = {}
    for part in (pos_raw or "").split("/"):
        if ":" not in part:
            continue
        key, val = part.split(":", 1)
        try:
            ratios[key.strip()] = float(val)
        except ValueError:
            pass
    return ratios


TAG_TO_POS_KEY = {"n": "n", "vt": "v", "vi": "v", "v": "v", "a": "a",
                  "adj": "a", "ad": "r", "adv": "r"}


def order_lines(lines, ratios):
    """把词性占比最高的那行挪到第一行，这就是「常用释义」。"""
    if not lines or not ratios:
        return lines

    def rank(line):
        token = line.split(" ", 1)[0].rstrip(".").strip("[]")
        return -ratios.get(TAG_TO_POS_KEY.get(token, ""), 0.0)

    return sorted(lines, key=rank)


def definition_with_order(raw, pos_raw):
    return "\n".join(order_lines(format_definition(raw).split("\n"), pos_ratio(pos_raw)))


# ---------------------------------------------------------------- 词形变化

# 不可数名词，不应该长出复数
UNCOUNTABLE = {
    "information", "advice", "equipment", "furniture", "knowledge", "research",
    "evidence", "money", "news", "luggage", "baggage", "homework", "housework",
    "bread", "butter", "cheese", "milk", "water", "air", "weather", "music",
    "traffic", "machinery", "scenery", "jewellery", "clothing", "garbage",
    "rubbish", "trash", "stationery", "software", "hardware", "feedback",
    "staff", "personnel", "vocabulary", "grammar", "slang", "accommodation",
    "transportation", "transport", "education", "health", "wealth", "rice",
    "sugar", "salt", "meat", "fruit", "progress", "permission", "assistance",
    "patience", "courage", "damage", "homework", "mathematics", "physics",
    "economics", "politics", "linguistics", "athletics", "gymnastics",
}

VOWELS = "aeiou"
SINGLE_SYLLABLE = re.compile(r"^[^aeiouy]*[aeiou]+[^aeiou]*$")

IRREG_VERBS = {
    "be": ("was/were", "been"),
    "have": ("had", "had"),
    "do": ("did", "done"),
    "say": ("said", "said"),
    "go": ("went", "gone"),
    "get": ("got", "got/gotten"),
    "make": ("made", "made"),
    "know": ("knew", "known"),
    "think": ("thought", "thought"),
    "take": ("took", "taken"),
    "see": ("saw", "seen"),
    "come": ("came", "come"),
    "give": ("gave", "given"),
    "find": ("found", "found"),
    "tell": ("told", "told"),
    "become": ("became", "become"),
    "show": ("showed", "shown"),
    "leave": ("left", "left"),
    "feel": ("felt", "felt"),
    "put": ("put", "put"),
    "bring": ("brought", "brought"),
    "begin": ("began", "begun"),
    "keep": ("kept", "kept"),
    "hold": ("held", "held"),
    "write": ("wrote", "written"),
    "stand": ("stood", "stood"),
    "hear": ("heard", "heard"),
    "let": ("let", "let"),
    "mean": ("meant", "meant"),
    "set": ("set", "set"),
    "meet": ("met", "met"),
    "run": ("ran", "run"),
    "pay": ("paid", "paid"),
    "sit": ("sat", "sat"),
    "speak": ("spoke", "spoken"),
    "lead": ("led", "led"),
    "read": ("read", "read"),
    "grow": ("grew", "grown"),
    "lose": ("lost", "lost"),
    "fall": ("fell", "fallen"),
    "send": ("sent", "sent"),
    "build": ("built", "built"),
    "understand": ("understood", "understood"),
    "draw": ("drew", "drawn"),
    "break": ("broke", "broken"),
    "spend": ("spent", "spent"),
    "cut": ("cut", "cut"),
    "rise": ("rose", "risen"),
    "drive": ("drove", "driven"),
    "buy": ("bought", "bought"),
    "wear": ("wore", "worn"),
    "choose": ("chose", "chosen"),
    "eat": ("ate", "eaten"),
    "fly": ("flew", "flown"),
    "catch": ("caught", "caught"),
    "teach": ("taught", "taught"),
    "fight": ("fought", "fought"),
    "throw": ("threw", "thrown"),
    "sleep": ("slept", "slept"),
    "forget": ("forgot", "forgotten"),
    "win": ("won", "won"),
    "sing": ("sang", "sung"),
    "drink": ("drank", "drunk"),
    "swim": ("swam", "swum"),
    "ride": ("rode", "ridden"),
    "sell": ("sold", "sold"),
    "shoot": ("shot", "shot"),
    "hit": ("hit", "hit"),
    "hurt": ("hurt", "hurt"),
    "cost": ("cost", "cost"),
    "shut": ("shut", "shut"),
    "spread": ("spread", "spread"),
    "feed": ("fed", "fed"),
    "flee": ("fled", "fled"),
    "freeze": ("froze", "frozen"),
    "hide": ("hid", "hidden"),
    "bend": ("bent", "bent"),
    "blow": ("blew", "blown"),
    "dig": ("dug", "dug"),
    "hang": ("hung", "hung"),
    "lend": ("lent", "lent"),
    "ring": ("rang", "rung"),
    "seek": ("sought", "sought"),
    "shake": ("shook", "shaken"),
    "shine": ("shone", "shone"),
    "steal": ("stole", "stolen"),
    "sink": ("sank", "sunk"),
    "stick": ("stuck", "stuck"),
    "strike": ("struck", "struck"),
    "tear": ("tore", "torn"),
    "wake": ("woke", "woken"),
    "weep": ("wept", "wept"),
    "kneel": ("knelt", "knelt"),
    "lay": ("laid", "laid"),
    "bear": ("bore", "borne"),
    "beat": ("beat", "beaten"),
    "bind": ("bound", "bound"),
    "bleed": ("bled", "bled"),
    "breed": ("bred", "bred"),
    "cast": ("cast", "cast"),
    "cling": ("clung", "clung"),
    "creep": ("crept", "crept"),
    "deal": ("dealt", "dealt"),
    "dwell": ("dwelt", "dwelt"),
    "grind": ("ground", "ground"),
    "leap": ("leapt", "leapt"),
    "mistake": ("mistook", "mistaken"),
    "overcome": ("overcame", "overcome"),
    "quit": ("quit", "quit"),
    "rebuild": ("rebuilt", "rebuilt"),
    "repay": ("repaid", "repaid"),
    "retell": ("retold", "retold"),
    "rid": ("rid", "rid"),
    "sew": ("sewed", "sewn"),
    "shed": ("shed", "shed"),
    "sow": ("sowed", "sown"),
    "speed": ("sped", "sped"),
    "spill": ("spilt", "spilt"),
    "spin": ("spun", "spun"),
    "split": ("split", "split"),
    "spoil": ("spoilt", "spoilt"),
    "spring": ("sprang", "sprung"),
    "stink": ("stank", "stunk"),
    "strive": ("strove", "striven"),
    "swear": ("swore", "sworn"),
    "sweep": ("swept", "swept"),
    "swing": ("swung", "swung"),
    "upset": ("upset", "upset"),
    "withdraw": ("withdrew", "withdrawn"),
    "undertake": ("undertook", "undertaken"),
    "lie": ("lay", "lain"),
    # 多音节但需要双写
    "prefer": ("preferred", "preferred"),
    "refer": ("referred", "referred"),
    "occur": ("occurred", "occurred"),
    "admit": ("admitted", "admitted"),
    "regret": ("regretted", "regretted"),
    "control": ("controlled", "controlled"),
    "permit": ("permitted", "permitted"),
    "commit": ("committed", "committed"),
    "forbid": ("forbade", "forbidden"),
    "equip": ("equipped", "equipped"),
    "travel": ("travelled", "travelled"),
}

IRREG_THIRD = {"be": "is/are", "have": "has", "do": "does", "go": "goes"}

IRREG_PLURAL = {
    "man": "men", "woman": "women", "child": "children", "foot": "feet",
    "tooth": "teeth", "goose": "geese", "mouse": "mice", "ox": "oxen",
    "person": "people", "sheep": "sheep", "deer": "deer", "fish": "fish",
    "means": "means", "series": "series", "species": "species",
    "phenomenon": "phenomena", "crisis": "crises", "analysis": "analyses",
    "basis": "bases", "thesis": "theses", "datum": "data", "medium": "media",
    "quantum": "quanta", "stratum": "strata", "curriculum": "curricula",
    "memorandum": "memoranda", "criterion": "criteria", "bacterium": "bacteria",
    "symposium": "symposia", "millennium": "millennia", "index": "indices",
    "appendix": "appendices", "matrix": "matrices", "vertex": "vertices",
    "axis": "axes", "nucleus": "nuclei", "stimulus": "stimuli",
    "syllabus": "syllabi", "radius": "radii", "alumnus": "alumni",
    "larva": "larvae", "formula": "formulas", "vertebra": "vertebrae",
    "spectrum": "spectra", "addendum": "addenda", "erratum": "errata",
    "genus": "genera", "corpus": "corpora", "plateau": "plateaus",
    "bureau": "bureaus", "cactus": "cacti", "focus": "foci",
}

F_TO_VES = {
    "leaf", "knife", "wife", "life", "half", "shelf", "wolf", "calf",
    "thief", "loaf", "self", "sheaf", "elf", "scarf", "wharf", "hoof",
}

# 本身就是复数形式的词，别再给它加 -s
PLURAL_FORMS = {v.split("/")[0] for v in IRREG_PLURAL.values()} | {
    "children", "people", "men", "women", "feet", "teeth", "mice", "geese",
}

IRREG_ADJ = {
    "good": ("better", "best"),
    "bad": ("worse", "worst"),
    "many": ("more", "most"),
    "much": ("more", "most"),
    "little": ("less", "least"),
    "far": ("farther/further", "farthest/furthest"),
    "old": ("older/elder", "oldest/eldest"),
}


def is_syllable_cvc(word):
    """单音节、结尾是「辅音-元音-辅音」，加后缀要双写最后一个字母。"""
    return bool(SINGLE_SYLLABLE.match(word)) and len(word) >= 3 \
        and word[-1] not in "wxy" and word[-1] not in VOWELS \
        and word[-2] in VOWELS and word[-3] not in VOWELS


def plural_of(word):
    if word in IRREG_PLURAL:
        return IRREG_PLURAL[word]
    if word.endswith(("s", "x", "z", "ch", "sh")):
        return word + "es"
    if word.endswith("y") and len(word) > 1 and word[-2] not in VOWELS:
        return word[:-1] + "ies"
    if word.endswith("f") and word in F_TO_VES:
        return word[:-1] + "ves"
    if word.endswith("fe") and word[:-2] in F_TO_VES:
        return word[:-2] + "ves"
    if word.endswith("o") and word in {"potato", "tomato", "hero", "echo", "veto", "torpedo"}:
        return word + "es"
    return word + "s"


def third_of(word):
    if word in IRREG_THIRD:
        return IRREG_THIRD[word]
    if word.endswith(("s", "x", "z", "ch", "sh", "o")):
        return word + "es"
    if word.endswith("y") and len(word) > 1 and word[-2] not in VOWELS:
        return word[:-1] + "ies"
    return word + "s"


def gerund_of(word):
    if word.endswith("ie"):
        return word[:-2] + "ying"
    if word.endswith("e") and not word.endswith(("ee", "ye", "oe")):
        return word[:-1] + "ing"
    if is_syllable_cvc(word):
        return word + word[-1] + "ing"
    return word + "ing"


def past_of(word):
    """返回 (过去式, 过去分词)。"""
    if word in IRREG_VERBS:
        return IRREG_VERBS[word]
    if word.endswith("e"):
        return word + "d", word + "d"
    if word.endswith("y") and len(word) > 1 and word[-2] not in VOWELS:
        return word[:-1] + "ied", word[:-1] + "ied"
    if is_syllable_cvc(word):
        return word + word[-1] + "ed", word + word[-1] + "ed"
    return word + "ed", word + "ed"


COMPARE_SUFFIX_BLOCK = ("ous", "ful", "less", "ing", "ed", "able", "ible",
                        "ive", "al", "ic", "ary", "ant", "ent")


def comparative_of(word):
    """返回 (比较级, 最高级)；长词用 more/most。"""
    if word in IRREG_ADJ:
        return IRREG_ADJ[word]
    if len(word) > 6 or word.endswith(COMPARE_SUFFIX_BLOCK):
        return "more " + word, "most " + word
    if word.endswith("e"):
        return word + "r", word + "st"
    if word.endswith("y") and len(word) > 1 and word[-2] not in VOWELS:
        return word[:-1] + "ier", word[:-1] + "iest"
    if is_syllable_cvc(word):
        return word + word[-1] + "er", word + word[-1] + "est"
    return word + "er", word + "est"


POS_FLAG_RE = {
    "n": re.compile(r"(?<![A-Za-z0-9])n\."),
    "v": re.compile(r"(?<![A-Za-z0-9])(v|vt|vi)\."),
    "a": re.compile(r"(?<![A-Za-z0-9])(a|adj)\."),
}


def pos_flags(raw):
    flags = set()
    for key, pattern in POS_FLAG_RE.items():
        if pattern.search(raw or ""):
            flags.add(key)
    return flags


def primary_pos(translation, pos_raw=""):
    """判断这个词的主要词性，没有 pos 数据就取释义第一行的词性。"""
    ratios = pos_ratio(pos_raw)
    if ratios:
        best = max(ratios.items(), key=lambda kv: kv[1])
        return TAG_TO_POS_KEY.get(best[0], "")
    first_line = (translation or "").split("\n")[0]
    if not first_line:
        return ""
    token = first_line.split(" ", 1)[0].rstrip(".").strip("[]")
    return TAG_TO_POS_KEY.get(token, "")


def merge_by_value(items):
    """值一样的标签合成一行，避免「复数 sets / 第三人称单数 sets」占两行。"""
    buckets = {}
    for label, value in items:
        buckets.setdefault(value, []).append(label)
    return [("/".join(labels), value) for value, labels in buckets.items()]


def build_forms(word, flags, primary=""):
    """按词性生成常用变形。

    只给「主要词性」生成容易出错的那类变形（比如 set 释义里虽有 a.，但它不是形容词，
    就不该给 setter / settest 这种东西）。
    """
    out = []
    has_n = "n" in flags
    has_v = "v" in flags
    has_a = "a" in flags

    # 已经是复数形式、不可数名词、或者本身就是复数结尾的词，不再加 -s
    plural_ok = word not in UNCOUNTABLE \
        and word not in PLURAL_FORMS \
        and not (word.endswith("s") and len(word) > 4)
    if has_n and (primary == "n" or not has_v) and plural_ok:
        out.append(("复数", plural_of(word)))
    if has_v:
        out.append(("第三人称单数", third_of(word)))
        out.append(("现在分词", gerund_of(word)))
        past, past_participle = past_of(word)
        out.append(("过去式", past))
        out.append(("过去分词", past_participle))
    if has_a and primary == "a":
        comp, sup = comparative_of(word)
        out.append(("比较级", comp))
        out.append(("最高级", sup))
    return out


EX_LABELS = {"p": "过去式", "d": "过去分词", "i": "现在分词",
             "3": "第三人称单数", "r": "比较级", "t": "最高级", "s": "复数"}


def exchange_pairs(exchange):
    """ECDICT 的 exchange 字段：p:went/d:gone/i:going/3:goes，拆成 [(标签, 值)]。"""
    pairs = []
    for seg in (exchange or "").split("/"):
        if ":" not in seg:
            continue
        key, val = seg.split(":", 1)
        key = key.strip()
        val = val.strip()
        if key in EX_LABELS and val:
            pairs.append((EX_LABELS[key], val))
    return pairs


def filter_pairs(word, pairs):
    """源数据会给不可数名词、已经是复数的词也填复数，这里挡掉。"""
    drop_plural = (word in UNCOUNTABLE or word in PLURAL_FORMS
                   or (word.endswith("s") and len(word) > 4))
    return [p for p in pairs if not (drop_plural and p[0] == "复数")]


def render_forms(items):
    return "\n".join(f"{label} {value}" for label, value in items)


# ---------------------------------------------------------------- 主流程

def load_front_index():
    """有完整的 ECDICT CSV（66MB 那版）就建一份索引，用它的 exchange/pos 提更准的变形。

    文件小于 60MB 说明是没下完的半截，直接用会前后不一致，所以忽略。
    """
    if not os.path.exists(FULL) or os.path.getsize(FULL) < 60 * 1024 * 1024:
        return {}
    index = {}
    with open(FULL, "r", encoding="utf-8", newline="", errors="replace") as fh:
        reader = csv.DictReader(fh)
        if not reader.fieldnames or "exchange" not in reader.fieldnames:
            return {}
        for row in reader:
            word = (row.get("word") or "").strip().lower()
            if word:
                index[word] = ((row.get("exchange") or "").strip(), (row.get("pos") or "").strip())
    return index


def main():
    os.makedirs(os.path.dirname(DST), exist_ok=True)
    if os.path.exists(DST):
        os.remove(DST)

    extra = load_front_index()
    print(f"front_index={len(extra)}")

    conn = sqlite3.connect(DST)
    conn.execute(
        "CREATE TABLE dict(word TEXT PRIMARY KEY, phonetic TEXT, translation TEXT, forms TEXT)"
    )

    rows = []
    with open(SRC, "r", encoding="utf-8", newline="") as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            word = (row.get("word") or "").strip().lower()
            if not word:
                continue
            phonetic = " ".join((row.get("phonetic") or "").split())
            raw = row.get("translation") or ""
            if not raw.strip():
                continue

            exchange, pos = extra.get(word, ("", ""))
            translation = definition_with_order(raw, pos)

            if exchange:
                pairs = exchange_pairs(exchange)
            else:
                pairs = build_forms(word, pos_flags(translation), primary_pos(translation, pos))
            forms = render_forms(merge_by_value(filter_pairs(word, pairs)))

            rows.append((word, phonetic, translation, forms or None))

    # 短语包：单词库里没有含空格的条目，这里按自己的清单补进去
    existing = {row[0] for row in rows}
    added = 0
    for phrase, meaning in PHRASES.items():
        key = phrase.strip().lower()
        if not key or key in existing:
            continue
        rows.append((key, "", meaning, None))
        existing.add(key)
        added += 1

    conn.executemany("INSERT OR REPLACE INTO dict VALUES(?,?,?,?)", rows)
    conn.execute("CREATE INDEX IF NOT EXISTS idx_dict_word ON dict(word)")
    conn.commit()
    conn.execute("VACUUM")
    conn.close()

    size = os.path.getsize(DST)
    with_forms = sum(1 for r in rows if r[3])
    with_multi = sum(1 for r in rows if "\n" in r[2])
    print(f"entries={len(rows)}")
    print(f"phrases={added}")
    print(f"with_forms={with_forms}")
    print(f"multi_line_definition={with_multi}")
    print(f"output={DST}")
    print(f"size_bytes={size}")
    print(f"size_mb={size / 1024 / 1024:.2f}")

    for sample in ("set", "meet", "go", "happy"):
        row = next((r for r in rows if r[0] == sample), None)
        if row:
            print("----", sample)
            print(repr(row[2]))
            print(repr(row[3]))


if __name__ == "__main__":
    main()
