// 临时探针：看 splitSentences 实际切在哪。
import '../lib/article.dart' as a;

void main() {
  for (final text in <String>[
    'We met at 5 p.m. in the U.S. yesterday.',
    'The U.K. team won! Did they? Yes.',
    'Dr. Smith arrived. He sat down.',
  ]) {
    final s = a.splitSentences(text);
    print('IN: $text');
    print('count=${s.length}');
    for (final x in s) {
      print('  [$x]');
    }
    print('');
  }
}
