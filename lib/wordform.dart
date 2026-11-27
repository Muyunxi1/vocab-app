/// 词形还原的启发式候选生成。
///
/// 这里只负责「猜出可能的原形」，猜得对不对由调用方回查词典决定：
/// 候选必须能在词库里命中，才被当成该词的变形；命不中就按未收录处理。
/// 因此本文件不产生任何含歧义的结论，只提供候选列表。
library;

/// 不规则变化：变形 -> 原形。只收高频词，覆盖阅读材料的主体。
const Map<String, String> irregularForms = {
  'has': 'have', 'had': 'have', 'having': 'have',
  'is': 'be', 'am': 'be', 'are': 'be', 'was': 'be', 'were': 'be',
  'been': 'be', 'being': 'be',
  'does': 'do', 'did': 'do', 'done': 'do', 'doing': 'do',
  'goes': 'go', 'went': 'go', 'gone': 'go', 'going': 'go',
  'says': 'say', 'said': 'say', 'saying': 'say',
  'gets': 'get', 'got': 'get', 'gotten': 'get', 'getting': 'get',
  'makes': 'make', 'made': 'make', 'making': 'make',
  'takes': 'take', 'took': 'take', 'taken': 'take', 'taking': 'take',
  'comes': 'come', 'came': 'come', 'coming': 'come',
  'sees': 'see', 'saw': 'see', 'seen': 'see', 'seeing': 'see',
  'knows': 'know', 'knew': 'know', 'known': 'know', 'knowing': 'know',
  'thinks': 'think', 'thought': 'think', 'thinking': 'think',
  'gives': 'give', 'gave': 'give', 'given': 'give', 'giving': 'give',
  'finds': 'find', 'found': 'find', 'finding': 'find',
  'tells': 'tell', 'told': 'tell', 'telling': 'tell',
  'becomes': 'become', 'became': 'become', 'becoming': 'become',
  'leaves': 'leave', 'left': 'leave', 'leaving': 'leave',
  'feels': 'feel', 'felt': 'feel', 'feeling': 'feel',
  'brings': 'bring', 'brought': 'bring', 'bringing': 'bring',
  'deals': 'deal', 'dealt': 'deal', 'dealing': 'deal',
  'begins': 'begin', 'began': 'begin', 'begun': 'begin', 'beginning': 'begin',
  'keeps': 'keep', 'kept': 'keep', 'keeping': 'keep',
  'holds': 'hold', 'held': 'hold', 'holding': 'hold',
  'writes': 'write', 'wrote': 'write', 'written': 'write', 'writing': 'write',
  'stands': 'stand', 'stood': 'stand', 'standing': 'stand',
  'hears': 'hear', 'heard': 'hear', 'hearing': 'hear',
  'means': 'mean', 'meant': 'mean', 'meaning': 'mean',
  'meets': 'meet', 'met': 'meet', 'meeting': 'meet',
  'runs': 'run', 'ran': 'run', 'running': 'run',
  'pays': 'pay', 'paid': 'pay', 'paying': 'pay',
  'sits': 'sit', 'sat': 'sit', 'sitting': 'sit',
  'speaks': 'speak', 'spoke': 'speak', 'spoken': 'speak', 'speaking': 'speak',
  'leads': 'lead', 'led': 'lead', 'leading': 'lead',
  'grows': 'grow', 'grew': 'grow', 'grown': 'grow', 'growing': 'grow',
  'loses': 'lose', 'lost': 'lose', 'losing': 'lose',
  'lies': 'lie', 'lay': 'lie', 'lain': 'lie', 'lying': 'lie',
  'falls': 'fall', 'fell': 'fall', 'fallen': 'fall', 'falling': 'fall',
  'sends': 'send', 'sent': 'send', 'sending': 'send',
  'builds': 'build', 'built': 'build', 'building': 'build',
  'understands': 'understand', 'understood': 'understand',
  'understanding': 'understand',
  'draws': 'draw', 'drew': 'draw', 'drawn': 'draw', 'drawing': 'draw',
  'breaks': 'break', 'broke': 'break', 'broken': 'break', 'breaking': 'break',
  'spends': 'spend', 'spent': 'spend', 'spending': 'spend',
  'rises': 'rise', 'rose': 'rise', 'risen': 'rise', 'rising': 'rise',
  'drives': 'drive', 'drove': 'drive', 'driven': 'drive', 'driving': 'drive',
  'buys': 'buy', 'bought': 'buy', 'buying': 'buy',
  'wears': 'wear', 'wore': 'wear', 'worn': 'wear', 'wearing': 'wear',
  'chooses': 'choose', 'chose': 'choose', 'chosen': 'choose',
  'choosing': 'choose',
  'eats': 'eat', 'ate': 'eat', 'eaten': 'eat', 'eating': 'eat',
  'wins': 'win', 'won': 'win', 'winning': 'win',
  'teaches': 'teach', 'taught': 'teach', 'teaching': 'teach',
  'catches': 'catch', 'caught': 'catch', 'catching': 'catch',
  'fights': 'fight', 'fought': 'fight', 'fighting': 'fight',
  'throws': 'throw', 'threw': 'throw', 'thrown': 'throw', 'throwing': 'throw',
  'flies': 'fly', 'flew': 'fly', 'flown': 'fly', 'flying': 'fly',
  'forgets': 'forget', 'forgot': 'forget', 'forgotten': 'forget',
  'forgetting': 'forget',
  'sleeps': 'sleep', 'slept': 'sleep', 'sleeping': 'sleep',
  'speeds': 'speed', 'sped': 'speed', 'speeding': 'speed',
  'flees': 'flee', 'fled': 'flee', 'fleeing': 'flee',
  'rides': 'ride', 'rode': 'ride', 'ridden': 'ride', 'riding': 'ride',
  'sings': 'sing', 'sang': 'sing', 'sung': 'sing', 'singing': 'sing',
  'shakes': 'shake', 'shook': 'shake', 'shaken': 'shake', 'shaking': 'shake',
  'springs': 'spring', 'sprang': 'spring', 'sprung': 'spring',
  'springing': 'spring',
  'hides': 'hide', 'hid': 'hide', 'hidden': 'hide', 'hiding': 'hide',
  'blows': 'blow', 'blew': 'blow', 'blown': 'blow', 'blowing': 'blow',
  'mistakes': 'mistake', 'mistook': 'mistake', 'mistaken': 'mistake',
  'mistaking': 'mistake',
  'breeds': 'breed', 'bred': 'breed', 'breeding': 'breed',
  'shoes': 'shoe', 'shod': 'shoe', 'shoeing': 'shoe',
  'swims': 'swim', 'swam': 'swim', 'swum': 'swim', 'swimming': 'swim',
  'drinks': 'drink', 'drank': 'drink', 'drunk': 'drink', 'drinking': 'drink',
  'shows': 'show', 'showed': 'show', 'shown': 'show', 'showing': 'show',
  'puts': 'put', 'putting': 'put',
  'cuts': 'cut', 'cutting': 'cut',
  'sets': 'set', 'setting': 'set',
  'lets': 'let', 'letting': 'let',
  'children': 'child', 'men': 'man', 'women': 'woman', 'feet': 'foot',
  'teeth': 'tooth', 'mice': 'mouse', 'geese': 'goose', 'people': 'person',
  'lives': 'life', 'knives': 'knife', 'wives': 'wife',
};

const Set<String> _vowels = {'a', 'e', 'i', 'o', 'u'};

bool _isVowel(String c) => _vowels.contains(c);

/// 双写辅音还原：`stopp` -> `stop`，只在末两个字母相同且为辅音时生效。
void _addDoubled(List<String> out, String stem) {
  if (stem.length < 3) return;
  final last = stem[stem.length - 1];
  final prev = stem[stem.length - 2];
  if (last != prev || _isVowel(last)) return;
  final candidate = stem.substring(0, stem.length - 1);
  if (candidate.length >= 2 && !out.contains(candidate)) out.add(candidate);
}

/// 生成可能的原形候选，按可信度从高到低排列，不含原词本身。
///
/// 调用方必须把候选回查词典，只有命中才算还原成功。
List<String> lemmaCandidates(String word) {
  final w = word.trim().toLowerCase().replaceAll(RegExp(r"'s$"), '');
  if (w.isEmpty) return const [];

  final out = <String>[];

  void add(String? candidate) {
    if (candidate == null) return;
    final value = candidate.trim();
    if (value.length < 2 || value == w) return;
    if (!out.contains(value)) out.add(value);
  }

  // 1. 不规则变化最可信
  add(irregularForms[w]);

  // 2. 三单、复数
  //   -ies 必须先判，否则 flies 会先被 -s 规则削成 flie
  //  -s 排在 -es 之前：uses -> use 命中；若先走 -es 会削成 us，命中错误原形
  if (w.length > 4 && w.endsWith('ies')) {
    add('${w.substring(0, w.length - 3)}y');
  }
  if (w.length > 2 && w.endsWith('s') && !w.endsWith('ss')) {
    add(w.substring(0, w.length - 1));
  }
  if (w.length > 3 && w.endsWith('es')) {
    final stem = w.substring(0, w.length - 2);
    add(stem);
    // gas -> gasses / bus -> busses：-es 前的双写辅音要去掉一个
    _addDoubled(out, stem);
  }
  // chairman -> chairmen 这类 -man 的复数
  if (w.length > 4 && w.endsWith('men')) {
    add('${w.substring(0, w.length - 3)}man');
  }

  // 3. 过去式、过去分词
  //  加 e 的原形先于裸词干：stated -> state（若先试 stat 会命中「统计」）
  if (w.length > 4 && w.endsWith('ied')) {
    add('${w.substring(0, w.length - 3)}y');
  }
  if (w.length > 3 && w.endsWith('ed')) {
    final stem = w.substring(0, w.length - 2);
    add('${stem}e');
    add(stem);
    _addDoubled(out, stem);
    // panic -> panicked / panicking：词干 ck 要去掉 k 才是原形
    if (stem.endsWith('ck')) add(stem.substring(0, stem.length - 1));
  }

  // 4. 现在分词
  //  同理：using -> use，而不是 us（「我们」）
  if (w.length > 4 && w.endsWith('ing')) {
    final stem = w.substring(0, w.length - 3);
    add('${stem}e');
    add(stem);
    _addDoubled(out, stem);
    if (stem.endsWith('ck')) add(stem.substring(0, stem.length - 1));
  }

  // 5. 比较级、最高级放最后，误命中概率最高
  if (w.length >= 5 && w.endsWith('ier')) {
    add('${w.substring(0, w.length - 3)}y');
  }
  //  -iest 必须单独处理：easiest / happiest / prettiest 都要还原成 -y 结尾
  if (w.length >= 6 && w.endsWith('iest')) {
    add('${w.substring(0, w.length - 4)}y');
  }
  if (w.length > 4 && w.endsWith('est')) {
    final stem = w.substring(0, w.length - 3);
    add('${stem}e');
    add(stem);
    _addDoubled(out, stem);
  }
  if (w.length > 3 && w.endsWith('er')) {
    final stem = w.substring(0, w.length - 2);
    add('${stem}e');
    add(stem);
    _addDoubled(out, stem);
  }

  return out;
}

/// 这个词在英文正文里可能出现的形式，用于在生成的文章中定位它。
/// 与 [lemmaCandidates] 方向相反：这里由原形推变形。
///
/// 返回值始终包含原词本身。
Set<String> wordVariants(String word) {
  final w = word.trim().toLowerCase();
  final out = <String>{};
  if (w.isEmpty) return out;
  out.add(w);

  // 不规则变化：反查原形对应的变形
  for (final entry in irregularForms.entries) {
    if (entry.value == w) out.add(entry.key);
  }

  // 复数 / 三单
  if (w.endsWith('y') &&
      w.length > 1 &&
      !w.endsWith('ay') &&
      !w.endsWith('ey') &&
      !w.endsWith('oy') &&
      !w.endsWith('uy')) {
    out.add('${w.substring(0, w.length - 1)}ies');
  } else if (w.endsWith('s') || w.endsWith('x') || w.endsWith('ch') || w.endsWith('sh')) {
    out.add('${w}es');
  } else {
    out.add('${w}s');
  }

  // 过去式 / 过去分词
  if (w.endsWith('e')) {
    out.add('${w}d');
  } else if (w.endsWith('y') && w.length > 1 && !_isVowel(w[w.length - 2])) {
    out.add('${w.substring(0, w.length - 1)}ied');
  } else {
    out.add('${w}ed');
  }

  // 现在分词
  if (w.endsWith('e') && w.length > 2) {
    out.add('${w.substring(0, w.length - 1)}ing');
  } else {
    out.add('${w}ing');
  }
  if (w.endsWith('ie')) {
    out.add('${w.substring(0, w.length - 2)}ying');
  }

  // 双写辅音：stop -> stopped / stopping
  if (w.length >= 3) {
    final last = w[w.length - 1];
    final prev = w[w.length - 2];
    final before = w[w.length - 3];
    if (!_isVowel(last) && _isVowel(prev) && !_isVowel(before)) {
      out.add('$w$last${'ed'}');
      out.add('$w$last${'ing'}');
    }
  }

  // 比较级 / 最高级
  if (w.endsWith('e')) {
    out.add('${w}r');
    out.add('${w}st');
  } else {
    out.add('${w}er');
    out.add('${w}est');
  }

  return out;
}
