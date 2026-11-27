// 临时探针：定位缩写正则为什么没命中。
void main() {
  const text = 'We met at 5 p.m. in the U.S. yesterday.';
  for (final abbr in ['Mr', 'Dr', 'p.m', 'U.S', 'U.K', 'e.g']) {
    final p = RegExp(r'\b' + RegExp.escape(abbr) + r'\.(?=\s|$)',
        caseSensitive: false);
    print('abbr=$abbr  pattern=${p.pattern}  hasMatch=${p.hasMatch(text)}');
  }

  final pi = text.indexOf('p.m.');
  print('p.m. at $pi, prev="${text[pi - 1]}", next="${text[pi + 4]}"');

  final guarded = text
      .replaceAll(RegExp(r'\b' + RegExp.escape('p.m') + r'\.(?=\s|$)', caseSensitive: false),
          'p.m\u0001')
      .replaceAll(RegExp(r'\b' + RegExp.escape('U.S') + r'\.(?=\s|$)', caseSensitive: false),
          'U.S\u0001');
  print('guarded="$guarded"');
}
