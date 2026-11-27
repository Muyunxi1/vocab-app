# 第三方组件与数据来源

本项目自身代码以 MIT 许可证发布（见 `LICENSE`）。下列组件与数据由第三方提供，各自遵循其原始许可证，不因本项目采用 MIT 而改变。

## 内置词典数据

- 来源：ECDICT（https://github.com/skywind3000/ECDICT）
- 许可证：MIT License，Copyright (c) 2025 Linwei
- 使用方式：经 `tools/build_dict.py` 抽取并压缩，生成只读的 `assets/dict.db`，共 61595 条词条
- 说明：词典内容依 MIT 许可随本仓库分发，保留上述版权与许可声明

## 原生与运行时

- sherpa-onnx（https://github.com/k2-fsa/sherpa-onnx）：Apache License 2.0，用于端侧语音合成
- ONNX Runtime：MIT License，随 sherpa-onnx 使用
- Google ML Kit（文字识别、数字墨水识别）：Google 闭源 SDK，遵循 Google ML Kit Terms of Service。代码不可修改、不可单独再分发，仅在应用内集成使用
- 数字墨水与文字识别模型由 Google 在运行时按需下载

## Flutter 与插件

以下依赖均为 BSD-3-Clause 或 MIT 许可证，具体条款见各包仓库：

- flutter、flutter_lints
- sqflite、path、path_provider
- file_picker、image_picker
- flutter_tts、audioplayers
- crypto、archive、enough_convert
- google_mlkit_text_recognition、google_mlkit_digital_ink_recognition（插件层为 MIT，底层 SDK 见上条）

## 商业组件

- syncfusion_flutter_pdf：遵循 Syncfusion Community License，个人与小规模团队免费，超出其营收或人数门槛需另行购买授权。若你要商用分发，请先确认自己的使用规模是否符合该许可证

## 图标与其他资源

- `assets/icon_512.png`、`icon_light.png`、`icon_src.png`：本项目自有资源，随本项目以 MIT 分发
