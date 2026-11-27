/// 排障用的滚动日志：只留内存，不写库、不上传、不参与备份。
///
/// 前几轮的「切音色闪退」「换了音色声音没变」「朗读断掉」都只能靠口述现象猜，
/// 这里把出错的时间点、子系统、原始消息留下来，导出诊断报告时一起带走。
class Diag {
  Diag._();

  static const int maxLines = 40;

  static final List<String> _lines = [];

  /// [tag] 是子系统名，例如「朗读」「神经语音」「导入」。
  static void record(String tag, Object? message) {
    final text = (message ?? '').toString().trim();
    if (text.isEmpty) return;
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
    // 单条截断：异常堆栈能几十行，报告里没必要全留
    final body = text.length > 300 ? '${text.substring(0, 300)}…' : text;
    _lines.add('$stamp [$tag] $body');
    while (_lines.length > maxLines) {
      _lines.removeAt(0);
    }
  }

  /// 由旧到新。
  static List<String> snapshot() => List<String>.from(_lines);
}
