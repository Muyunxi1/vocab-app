// 一次性校验脚本：切句与漏词匹配的边界样例。
// 用法：在 mobile 目录下执行 dart run tool/check_article_text.dart
import '../lib/article.dart' as a;

void main() {
  var fail = 0;

  void check(String name, Object actual, Object expected) {
    final ok = '$actual' == '$expected';
    print('${ok ? 'PASS' : 'FAIL'}  $name  actual=$actual  expected=$expected');
    if (!ok) fail++;
  }

  // ---- 切句：缩写不切断
  check('cut: Dr. Smith arrived. He sat down.',
      a.splitSentences('Dr. Smith arrived. He sat down.').length, 2);
  check('cut: 5 p.m. in the U.S.',
      a.splitSentences('We met at 5 p.m. in the U.S. yesterday.').length, 1);
  check('cut: Mr. and Mrs. Lee',
      a.splitSentences('Mr. and Mrs. Lee came.').length, 1);
  check('cut: The U.K. team won! Did they? Yes.',
      a.splitSentences('The U.K. team won! Did they? Yes.').length, 3);
  check('cut: 普通三句',
      a.splitSentences('I like apples. She likes pears. We both eat fruit.').length, 3);
  check('cut: 段落边界',
      a.splitSentences('First line.\nSecond line.').length, 2);

  // ---- 漏词：单词变形
  check('miss: went -> go',
      a.missingWords('He went home yesterday.', ['go']), <String>[]);
  check('miss: 未出现判漏',
      a.missingWords('He stayed home.', ['go']), <String>['go']);

  // ---- 漏词：词组
  check('miss: took off 命中 take off',
      a.missingWords('He took off his coat.', ['take off']), <String>[]);
  check('miss: 原样 take off',
      a.missingWords('Please take off your shoes.', ['take off']), <String>[]);
  check('miss: 隔太远应判漏',
      a.missingWords('Take the box. Later he switched the light off.', ['take off']),
      <String>['take off']);

  print(fail == 0 ? 'ALL PASS' : 'FAILED $fail');
}
