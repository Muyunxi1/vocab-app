# ML Kit 的组件注册器（VisionCommonRegistrar 等）只通过反射和 .properties 文件装载，
# R8 在 release 里会把它们整类删掉，结果是 ImageUtils / MobileVisionBase 拿不到实现，
# InputImage.fromFilePath 里对 null 取 getClass() 直接抛 NPE —— 拍照导入每次必崩。
# 这些包必须整体保留，不做混淆也不做裁剪。
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_common.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_text_bundled_common.** { *; }

# ML Kit 文字识别插件把中文/日文/韩文/梵文的模型类声明成了 compileOnly 可选依赖，
# release 构建开 R8 收缩时这些类不存在，会直接报 Missing classes 让构建失败。
# 这里只是让 R8 别管它们，不影响英文识别。
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**

# WorkManager + Room：Room 按 "<数据库类名>_Impl" 反射加载数据库实现类，WorkManager 内部还会
# 反射构造 Worker / Factory / Configuration。R8 收缩把这些类移除或改名后，运行期反射找不到，
# 抛 "Failed to create an instance of androidx.work.impl.WorkDatabase"。
# 这里整体保留 work / room / sqlite 的类名、成员与反射所需构造器，不做裁剪和混淆。
-keep class androidx.work.** { *; }
-keep class androidx.room.** { *; }
-keep class androidx.sqlite.** { *; }
-keep class * extends androidx.room.RoomDatabase { <init>(); }
-keep class * extends androidx.work.ListenableWorker { <init>(); }
