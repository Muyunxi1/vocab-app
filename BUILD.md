# 词学家 1.7.31 源码包说明

这个包的目标是「解开就能构建」，不是「只放几个改动过的文件」。
上一版源码备份只给了 `lib/` 和单个 `build.gradle`，第三方拿到手无法构建，
这条在审查报告 P0-3 里被列为阻断项，本版已修正。

## 环境

| 项目 | 版本 |
| --- | --- |
| Flutter | 3.47.9（stable，revision c197ca5199） |
| Dart | 3.13.7 |
| Android compileSdk / targetSdk | 36 |
| Android minSdk | 24 |
| 构建机 ABI | 只出 arm64-v8a |

依赖版本由 `pubspec.lock` 锁定，不要用 `pub upgrade`，会改变解析结果。

## 构建

```bash
# 1. 还原依赖（用锁文件，不要 upgrade）
flutter pub get

# 2. 本地 SDK 路径：包内没有 local.properties（含本机绝对路径，不通用），
#    首次构建由 Gradle 自动生成，或手动写入 sdk.dir。
# 3. 出包
flutter build apk --release --target-platform android-arm64 \
  --split-debug-info=build/symbols
```

产物在 `build/app/outputs/flutter-apk/app-release.apk`。

`--split-debug-info` 会额外生成 `build/symbols/app.android-arm64.symbols`，
它和 `mapping.txt` 一起才能还原线上崩溃堆栈（前者管 Dart 层，后者管 Java/Kotlin 层）。
只保留 `mapping.txt` 的话，Dart 异常堆栈仍是混淆后的地址。

## 签名（重要）

`android/app/build.gradle` 的 release 配置当前是：

```groovy
release {
    signingConfig = signingConfigs.debug
}
```

也就是说这个 release 包用的是 **Android Debug 证书**（`CN=Android Debug`）。
这是本轮明确保留的现状，不是遗漏：

- 可以自用、可以内部分发、可以直接覆盖安装升级；
- **不能上架应用商店**，也不能作为正式发布包分发；
- 换正式签名后包名不变但签名不同，用户需要先卸载旧包再装新包，
  本地数据（词库、复习记录）会一起丢失，升级前要先在应用内导出备份。

## 历史：构建 46 那一轮的变更（47 至 51 的改动见自查报告）

| 编号 | 位置 | 问题 | 处理 |
| --- | --- | --- | --- |
| S1 | `api.dart` `masteredCount()` | 用 `COUNT(*)` 数 book_words，一个词进两个词库就会重复计数，掌握数可能大于总词数 | 改 `COUNT(DISTINCT word_id)`，与 `overview().totalWords` 同口径 |
| S2 | `pages/mine_page.dart` `_usage()` | 只统计 `vocab_offline.db`，WAL 模式下数据实际在 `-wal`，占用严重低估 | 合计 `.db` `-wal` `-shm` 三个文件 |
| S3 | `pages/mine_page.dart` 存储/联系方式弹窗 | `Column` 不可滚动，横屏或小屏溢出 | 外层套 `SingleChildScrollView` |
| S4 | `pages/mine_page.dart` `_load()` | 快速切 tab 时两次请求重叠，慢的那次回来会覆盖新数据 | 加 `_loadSeq` 序号，只认最后一次 |
| S5 | `pages/mine_page.dart` `_editName()` | 弹窗用的 `TextEditingController` 没有释放 | 关闭后 dispose |
| S6 | `pages/mine_page.dart` `_clearCache()` | 缓存为空时提示「已释放 0 B」，看起来像失败 | 改为「缓存本来就是空的」 |

同版本新增：`lib/diag.dart`（40 条环形错误日志）、`lib/pages/mine_page.dart`（「我的」页）、
`api.dart` 的 `masteredCount/databasePath/articleCount`、
`neural_tts.dart` 的 `modelsBytes/cacheBytes/clearCache`、
`speech.dart` 的 `dictCacheBytes/clearDictCache`。

## 包内有什么

```
lib/                31 个 Dart 文件（18 个模块 + 13 个页面，不含 .bak 快照）
tool/               契约测试脚本（python，不依赖 flutter_test）
assets/dict.db      离线词典，8,056,832 B / 61,595 条（6 万单词 + 1,595 短语），构建时必须存在
android/            完整工程（app、gradle wrapper、清单、备份规则）
pubspec.yaml / pubspec.lock
analysis_options.yaml
BUILD.md            本文件
SHA256SUMS.txt      包内关键文件校验和
```

## 自检

```bash
dart analyze lib     # 应输出 No issues found!
python tool/verify_dirty_failcount.py
python tool/verify_addword_count.py
python tool/verify_like_escape.py
python tool/verify_csv_roundtrip.py
python tool/verify_backup_restore.py
python tool/verify_delete_article.py
python tool/verify_p0_contract.py
python tool/verify_p3_fixes.py
python tool/verify_neural_worker.py
python tool/verify_import_limit.py
```

十个脚本、合计 102 项断言，全部退出码 0 才算通过。脚本是纯 Python，
只读 Dart 源码做形态与语义断言，不需要 Flutter SDK，也不需要 python-docx 之外的三方库。
`verify_p0_contract.py`（36 项）覆盖 CSV 表头映射、备份含文章、删除无孤儿、复习计数、
加词计数与防重入、词典真人发音的缓存与拆词、听全文按模式等待；`verify_p3_fixes.py`（17 项）覆盖 CSV 引号规则、
异常文案、全局兜底、并发插入、计数自增、导出分页与进度提示；
`verify_neural_worker.py`（11 项）与 `verify_import_limit.py`（10 项）分别守合成线程与导入上限。

## 词典变更（构建 50 到 51）

构建 50 把 938 条短语、连接词与词语搭配写进 `assets/dict.db`（50,657 → 51,595 条）。
构建 51 再把 10,000 个单词补进去，单词由 5 万增至 6 万，总量 61,595 条，文件 6,873,088 B → 8,056,832 B。
这批以专业与领域词为主（医学/药学/生物 5,065、化学/物理 2,208、计算机/电子 520、法律/经济 844、其他 1,034，
另含 GRE 328 条），因为常用词已饱和：考研词表 5,390 词与 COCA 2 万高频词与库内比对后，
只剩 1 条尚未收录。

App 侧同步改了两处常量：`api.dart` 的 `_dictBytes`（按体积判断本地副本是否完好，现 8,056,832）
与 `_dictStamp`（词条刷新令牌，现 `2026-11-dict6`）。换词典后这两个值必须一起改，
只改文件不改令牌，老用户升级后拿不到新释义。

## 取词上限（构建 51 到 52）

翻译页「生词表」的取词上限在 `ocr.dart` 的 `Ocr.maxWords`，原来是 500。它跟导入上限
（`Api.maxBatchWords` = 5000）是两道闸门：导入能进 5000 个，但从 PDF、txt 或粘贴文本里
最多只挑 500 个候选，所以 3991 词的六级词表导进来只列出前 500 个，看上去像上限没修。

构建 52 把它抬到 5000，与导入上限对齐；候选达到上限时，结果行会补一句
「已达 5000 词取词上限，只取了前 5000 个」，不再静默截断。

## 语音来源（构建 52 到 53）

语音一共三种，都是免密钥的：

- 离线 · 系统语音：设备自带 TTS 引擎，不需要联网，音质取决于系统；
- 离线 · 神经语音：Piper 语音包下载到应用私有目录，本机推理，整句连贯朗读；
- 在线 · 词典真人发音：有道词典的词条录音（`dictvoice?audio=<词>&type=2`，2 美音、1 英音）。

第三种只覆盖词典收录的词条——单词和短语是现成录音，句子和整段文章取不到（接口直接 500），
所以文章朗读是把它拆成一个个词依次播放，词间有停顿、没有连读和句调。这是接口本身的边界，
不是播放器出错；要连贯整句只能用离线神经语音。

构建 53 删掉了第三种的另一套实现：`lib/youdao_tts.dart` 整份出库（8,661 字节，归档在
`_docx_work\removed-youdao_tts-20261116.dart`），`speech.dart` 里的 `modeOnline`、
`onlineVoices`、`metaOnlineVoice`、`onlineVoice` 字段、`hasOnlineKey()`、`_speakOnline()`
与方法内的分支、`applyConfig` 的 `onlineVoice` 参数一并删除；`voice_page.dart`、
`mine_page.dart` 的对应字段与 case 同步清掉。那套「有道语音合成」要求用户自己去有道智云
申请 appKey/appSecret 并开通服务，普通用户走不通，留着只会让设置页出现一个必然失败的入口。

老配置兼容：上个版本存过 `mode = 'online'` 的用户，启动时由 `_legacyOnlineMode` 映射到
词典真人发音（同为真人录音、同样免密钥），不会被留在无声音的状态。
**翻译页 `translate.dart` 里的有道翻译接口是另一套东西，仍在用 `youdao_app_key` /
`youdao_app_secret`，与本项无关，未改动。**

契约脚本 `verify_p0_contract.py` 同步调整：原来三条断言针对已删除的 `youdao_tts.dart`，
改为锁词典真人发音的缓存、文件长度校验与拆词路径，并新增一条「`speech.dart` 里不得再出现
`modeOnline`」，防止旧代码回流。

## 在本机 Windows 上构建 release 的已知问题

如果构建卡在下面的报错，那是构建机环境问题，不是源码问题：

```
Execution failed for task ':audioplayers_android:exportReleaseConsumerProguardFiles'.
> Failed to delete ...\build\<plugin>\intermediates\consumer_proguard_dir\release\exportReleaseConsumerProguardFiles
```

原因是 Windows Defender 实时扫描在插件写出 consumer-proguard 产物后短暂持有文件句柄，
AGP 紧接着删除旧目录就失败；每次报的插件名会变（file_picker、audioplayers_android 都出现过）。
同一目录在 PowerShell 里手工删除是立即成功的，说明没有静态锁。

处理办法，按生效概率排序：

1. 给构建目录加实时扫描排除（需要管理员）：`Add-MpPreference -ExclusionPath <构建目录>`；
2. **实测有效：把工程整体复制到另一个盘再全新构建。**
   本轮就是这么出的包：`robocopy <工程>\lib D:\vb\mobile\lib /MIR`，再单独拷 `pubspec.yaml`，
   然后在 `D:\vb\mobile` 执行本文的构建命令，一次通过（构建 46，62,453,378 字节）。
   同一份工程留在 C 盘反复重试时，会在 `:app:cleanMergeReleaseAssets`（删不掉 `mergeReleaseAssets`）、
   `:app:packageRelease`（报 `Could not find EOCD`，前一次被中断留下 0 字节 apk）、
   `build/reports/problems` 覆盖等位置随机失败，报错每次不同；
3. 若必须留在原盘：每轮构建前移走 `build/app/intermediates/assets/release/mergeReleaseAssets`、
   `build/app/outputs/apk`、`build/app/outputs/flutter-apk`、`build/reports/problems`，再增量重跑。
   注意不要保留 0 字节的 `app-release.apk`，AGP 增量打包会读不到 zip 结尾而直接失败。

中断过的构建要当作污染：拿不到包时先确认 `build/app/outputs/**/app-release.apk` 是不是 0 字节。

在关闭实时扫描的机器或 Linux 构建机上不会出现该问题。


## 已知限制

- 数据库 `assets/dict.db` 是只读资源，运行时复制到应用私有目录后使用，不在包里更新。
- 有道翻译与 DeepSeek 文章生成需要用户自备 key，包内不含任何密钥；语音三路都不需要 key。
- 只构建 arm64，模拟器（x86_64）与 32 位设备装不上，这是刻意的体积取舍。
