import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// 翻译相关错误，界面上直接把 message 给用户看。
/// [retryable] 表示这类失败重发一次有意义（网络抖动、服务端偶发），密钥错、参数错就没必要重试。
class TranslateException implements Exception {
  const TranslateException(this.message, {this.retryable = false});

  final String message;
  final bool retryable;

  @override
  String toString() => message;
}

/// 有道智云文本翻译的客户端。
///
/// 接口地址 https://openapi.youdao.com/api，v3 签名：
/// sha256(appKey + input + salt + curtime + appSecret)，
/// 其中 input 在原文超过 20 个字符时取「前10 + 总长度 + 后10」。
class YoudaoTranslator {
  const YoudaoTranslator({required this.appKey, required this.appSecret});

  final String appKey;
  final String appSecret;

  static const String _endpoint = 'https://openapi.youdao.com/api';

  /// 有道单次上限 5000 字符，留点余量分段发。
  static const int _maxCharsPerRequest = 4500;

  /// 单次请求的总超时（含连接、发送、等响应、读响应）。
  static const Duration _requestTimeout = Duration(seconds: 30);

  /// 整段翻译。超长文本按行 / 句子切段，逐段请求后拼回来。
  Future<String> translate(String text, {String from = 'auto', String to = 'zh-CHS'}) async {
    final source = text.trim();
    if (source.isEmpty) return '';
    final pieces = _split(source);
    final buffer = StringBuffer();
    for (var i = 0; i < pieces.length; i++) {
      if (i > 0) buffer.write('\n');
      buffer.write(await _chunkWithRetry(pieces[i], from: from, to: to));
    }
    return buffer.toString();
  }

  /// 这次运行里已经翻好的段落，按「目标语言 + 原文」做 key。
  /// 长文分十几段时中途失败，再点一次翻译能直接跳过前面翻好的部分，不重复花额度。
  static final Map<String, String> _cache = <String, String>{};
  static const int _cacheLimit = 300;

  /// 网络抖动这类失败重发一次，避免一整篇长文因为某一段掉线全部作废。
  Future<String> _chunkWithRetry(String q, {required String from, required String to}) async {
    final cacheKey = '$to\u0000$q';
    final cached = _cache[cacheKey];
    if (cached != null) return cached;

    String text;
    try {
      text = await _translateChunk(q, from: from, to: to);
    } on TranslateException catch (e) {
      if (!e.retryable) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 800));
      text = await _translateChunk(q, from: from, to: to);
    }

    _cache[cacheKey] = text;
    if (_cache.length > _cacheLimit) _cache.remove(_cache.keys.first);
    return text;
  }

  /// 清掉段落缓存，换新的文档时调用。
  static void clearCache() => _cache.clear();

  Future<String> _translateChunk(String q, {required String from, required String to}) async {
    final salt = DateTime.now().microsecondsSinceEpoch.toString();
    final curtime = (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
    final sign = sha256
        .convert(utf8.encode('$appKey${_truncate(q)}$salt$curtime$appSecret'))
        .toString();

    final body = <String, String>{
      'q': q,
      'from': from,
      'to': to,
      'appKey': appKey,
      'salt': salt,
      'sign': sign,
      'signType': 'v3',
      'curtime': curtime,
    };

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.postUrl(Uri.parse(_endpoint)).timeout(_requestTimeout);
      request.headers.contentType =
          ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
      request.write(body.entries
          .map((e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
          .join('&'));
      final response = await request.close().timeout(_requestTimeout);
      final raw = await response.transform(utf8.decoder).join().timeout(_requestTimeout);
      if (response.statusCode != 200) {
        throw TranslateException('翻译服务返回 HTTP ${response.statusCode}');
      }
      return _parse(raw);
    } on SocketException catch (e) {
      throw TranslateException('连不上翻译服务，检查网络：${e.message}', retryable: true);
    } on HandshakeException {
      throw const TranslateException('和翻译服务建立安全连接失败', retryable: true);
    } on TimeoutException {
      throw const TranslateException('翻译服务响应超时（30 秒），网络太慢时拆短一点再试', retryable: true);
    } finally {
      client.close(force: true);
    }
  }

  String _parse(String raw) {
    Map<String, dynamic> json;
    try {
      json = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      throw const TranslateException('翻译服务返回的数据解析不了', retryable: true);
    }
    final code = json['errorCode']?.toString() ?? '';
    if (code != '0') throw _errorException(code);
    final list = json['translation'];
    if (list is List && list.isNotEmpty) {
      // translation 是数组：一个 q 里塞多行时服务端按行拆成多个元素返回，
      // 只取 first 会把除第一行以外的译文全丢掉（那时界面还显示"译文 N 字"，
      // 用户会以为是模型没翻完）。按返回顺序拼回多行。
      return list.map((e) => e.toString()).join('\n');
    }
    throw const TranslateException('没拿到译文，可能是这段内容没有可翻译的文本');
  }

  TranslateException _errorException(String code) {
    // 这几类是服务端偶发失败，重发一次通常就过了
    const retryableCodes = {'302', '303', '304'};
    return TranslateException(_errorText(code), retryable: retryableCodes.contains(code));
  }

  String _errorText(String code) {
    switch (code) {
      case '101':
        return '缺少必填参数，检查应用 ID 和密钥是否填全';
      case '102':
        return '不支持的语言类型';
      case '103':
        return '这段文本太长，拆短一点再试';
      case '108':
        return '应用 ID 无效，回去核对有道后台的应用 ID';
      case '110':
        return '这个应用没绑定文本翻译服务，去有道后台开通后再试';
      case '113':
        return '没有可翻译的内容';
      case '202':
        return '签名校验失败，多半是应用密钥填错了（也要确认原文是 UTF-8）';
      case '203':
        return '有道后台限制了访问 IP，把这台设备的出口 IP 加白或清空白名单';
      case '205':
        return '应用平台类型不对：有道后台建应用时平台要选「API」，不能选 Android SDK';
      case '206':
        return '手机时间不准，签名里的时间戳失效，校准系统时间再试';
      case '207':
        return '重复请求被拒，隔几秒再点一次';
      case '302':
      case '304':
        return '翻译服务这次没出结果，重试一次';
      case '401':
        return '有道账户余额不足，去后台充值（新账号有 50 元体验金）';
      case '411':
      case '412':
        return '请求太频繁，等一会儿再试';
      default:
        return '翻译失败，错误码 $code';
    }
  }

  /// 签名用的 input：超过 20 字符时取前 10 + 长度 + 后 10。
  String _truncate(String q) {
    final chars = q.runes.toList();
    if (chars.length <= 20) return q;
    final head = String.fromCharCodes(chars.sublist(0, 10));
    final tail = String.fromCharCodes(chars.sublist(chars.length - 10));
    return '$head${chars.length}$tail';
  }

  List<String> _split(String text) {
    if (text.length <= _maxCharsPerRequest) return [text];
    final result = <String>[];
    final buffer = StringBuffer();

    void flush() {
      final piece = buffer.toString().trim();
      if (piece.isNotEmpty) result.add(piece);
      buffer.clear();
    }

    for (final line in text.split('\n')) {
      if (buffer.length + line.length + 1 > _maxCharsPerRequest) {
        flush();
        if (line.length > _maxCharsPerRequest) {
          result.addAll(_splitLongLine(line));
          continue;
        }
      }
      if (buffer.isNotEmpty) buffer.write('\n');
      buffer.write(line);
    }
    flush();
    return result.isEmpty ? [text] : result;
  }

  List<String> _splitLongLine(String line) {
    final pieces = <String>[];
    var rest = line;
    while (rest.length > _maxCharsPerRequest) {
      final window = rest.substring(0, _maxCharsPerRequest);
      var cut = _maxCharsPerRequest;
      // 优先在句末断开，其次空格，都不行就硬切
      final sentenceEnd = window.lastIndexOf(RegExp(r'[.!?。！？]'));
      if (sentenceEnd > _maxCharsPerRequest ~/ 2) {
        cut = sentenceEnd + 1;
      } else {
        final space = window.lastIndexOf(' ');
        if (space > _maxCharsPerRequest ~/ 2) cut = space;
      }
      pieces.add(rest.substring(0, cut).trim());
      rest = rest.substring(cut).trimLeft();
    }
    if (rest.isNotEmpty) pieces.add(rest);
    return pieces;
  }
}
