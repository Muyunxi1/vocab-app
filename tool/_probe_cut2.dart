// 临时探针：用与 article.dart 逐字相同的逻辑复刻 guard，打印码点定位差异。
import '../lib/article.dart' as a;

const List<String> _abbreviations = <String>[
  'Mr', 'Mrs', 'Ms', 'Dr', 'Prof', 'St', 'Jr', 'Sr', 'vs', 'etc',
  'e.g', 'i.e', 'a.m', 'p.m', 'U.S', 'U.K',
];

const String _abbrMark = '\u0001';

String guard(String text) {
  var result = text;
  for (final abbr in _abbreviations) {
    final pattern = RegExp(
      r'\b' + RegExp.escape(abbr) + r'\.(?=\s|$)',
      caseSensitive: false,
    );
    final next = result.replaceAll(pattern, '$abbr$_abbrMark');
    if (next != result) print('  replaced: $abbr');
    result = next;
  }
  return result;
}

void main() {
  const text = 'We met at 5 p.m. in the U.S. yesterday.';
  final g = guard(text);
  print('guarded="$g"');
  print('codeUnits=${g.codeUnits.where((c) => c < 32).toList()}');
  print('plugin split count=${a.splitSentences(text).length}');
}
