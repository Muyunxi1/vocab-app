#!/usr/bin/env bash
# 词学家 iOS 构建脚本（在 macOS 上执行）
#
# 用法：
#   bash tools/build_ios.sh              # 只验证能编出 iOS 产物，不签名
#   打开 Xcode 配好签名后再 build        # 签名必须人工做，见 iOS-BUILD.md
#
# 脚本可重复执行，已经装好的东西会跳过。

set -uo pipefail

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

step()  { printf "${BLUE}==> %s${NC}\n" "$1"; }
ok()    { printf "${GREEN}  ✓ %s${NC}\n" "$1"; }
warn()  { printf "${YELLOW}  ! %s${NC}\n" "$1"; }
fail()  { printf "${RED}  ✗ %s${NC}\n" "$1"; }

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR" || exit 1

# ---------------------------------------------------------------- 0. 系统检查
step "检查运行环境"
if [[ "$(uname -s)" != "Darwin" ]]; then
  fail "当前系统是 $(uname -s)，不是 macOS。"
  echo
  echo "iOS 安装包只能在 macOS 上编译：Xcode 和苹果的签名工具（codesign / altool）"
  echo "都只有 macOS 版本。Linux 或 Windows 的云主机上没有任何替代方案，"
  echo "继续执行只会浪费时间，请改用一台真实的 Mac，或租一台云 Mac。"
  exit 2
fi

MACOS_VER="$(sw_vers -productVersion)"
ok "macOS $MACOS_VER"
if [[ "${MACOS_VER%%.*}" -lt 13 ]]; then
  warn "Xcode 15 要求 macOS 13 以上，当前 $MACOS_VER 可能装不上最新 Xcode。"
fi

# ---------------------------------------------------------------- 1. Xcode
step "检查 Xcode"
if ! command -v xcodebuild >/dev/null 2>&1; then
  fail "没装 Xcode。"
  echo "  打开 App Store 搜「Xcode」安装（约 10-15GB），装完重新跑本脚本。"
  exit 3
fi

XCODE_PATH="$(xcode-select -p 2>/dev/null || true)"
if [[ "$XCODE_PATH" == *CommandLineTools* ]]; then
  fail "当前指向的是命令行工具，不是完整 Xcode：$XCODE_PATH"
  echo "  执行：sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  exit 4
fi

XCODE_VER="$(xcodebuild -version 2>/dev/null | head -1 || true)"
ok "$XCODE_VER"

# 首次启动组件没装完时，这里会报 "iOS xx platform not installed"
if ! xcodebuild -showsdks 2>/dev/null | grep -q "iphoneos"; then
  fail "找不到 iOS SDK，Xcode 首次启动的组件还没装完。"
  echo "  执行：sudo xcodebuild -runFirstLaunch"
  echo "  然后手动打开一次 Xcode，等它弹窗装完平台组件。"
  exit 5
fi
ok "iOS SDK 已就绪"

# ---------------------------------------------------------------- 2. Flutter
step "检查 Flutter"
export PUB_HOSTED_URL="${PUB_HOSTED_URL:-https://pub.flutter-io.cn}"
export FLUTTER_STORAGE_BASE_URL="${FLUTTER_STORAGE_BASE_URL:-https://storage.flutter-io.cn}"

if command -v flutter >/dev/null 2>&1; then
  ok "$(flutter --version 2>/dev/null | head -1)"
elif [[ -x "$HOME/flutter/bin/flutter" ]]; then
  export PATH="$HOME/flutter/bin:$PATH"
  ok "用 ~/flutter 下的 SDK"
else
  warn "没找到 Flutter，开始下载 macOS 版（约 1GB）"
  curl -fL -o /tmp/flutter_macos.zip \
    "https://storage.flutter-io.cn/flutter_infra_release/releases/stable/macos/flutter_macos_3.47.9-stable.zip" \
    || { fail "下载失败，检查网络或手动下载后解压到 ~/flutter"; exit 6; }
  unzip -q /tmp/flutter_macos.zip -d "$HOME"
  export PATH="$HOME/flutter/bin:$PATH"
  rm -f /tmp/flutter_macos.zip
  ok "已解压到 ~/flutter"
  warn "记得把 export PATH=\"\$HOME/flutter/bin:\$PATH\" 写进 ~/.zshrc，否则新终端里没有 flutter"
fi

flutter config --no-analytics >/dev/null 2>&1 || true

# ---------------------------------------------------------------- 3. CocoaPods
step "检查 CocoaPods"
if ! command -v pod >/dev/null 2>&1; then
  warn "没装 CocoaPods"
  if command -v brew >/dev/null 2>&1; then
    brew install cocoapods || { fail "brew 安装失败，改试 sudo gem install cocoapods"; exit 7; }
  else
    fail "这台机器没有 Homebrew。先装 Homebrew（https://brew.sh），再执行 brew install cocoapods"
    exit 7
  fi
fi
ok "$(pod --version 2>/dev/null)  版本"

# ---------------------------------------------------------------- 4. 依赖
step "拉取 Dart 依赖"
flutter pub get || { fail "flutter pub get 失败"; exit 8; }
ok "依赖就绪"

step "安装 iOS 原生依赖（pod install）"
if [[ -d ios/Pods ]]; then
  ok "已有 Pods 目录，跳过"
else
  echo "  首次会拉 CocoaPods spec 仓库，国内很慢，卡住就按 Ctrl+C 后执行："
  echo "  cd ~/.cocoapods/repos && git clone --depth 1 https://mirrors.tuna.tsinghua.edu.cn/git/CocoaPods/Specs.git master"
  (cd ios && pod install) || { fail "pod install 失败"; exit 9; }
  ok "pod install 完成"
fi

# ---------------------------------------------------------------- 5. 构建
step "编译 iOS（不签名）"
echo "  这一步只验证代码能编出 iOS 产物，不需要 Apple ID。"
flutter build ios --release --no-codesign || { fail "编译失败，把上面的报错发回去"; exit 10; }

ok "编译成功"
echo
echo "产物目录：$PROJECT_DIR/build/ios/iphoneos/Runner.app"
echo "（未签名的 .app 不能直接装到手机，只是证明编译链路是通的）"
echo
printf "${YELLOW}下一步是签名，必须人工做：${NC}\n"
echo "  1. open ios/Runner.xcworkspace"
echo "  2. Xcode → Settings → Accounts 登录自己的 Apple ID"
echo "  3. Runner target → Signing & Capabilities → Team 选刚登录的账号"
echo "  4. 手机连线，顶部选设备，点 Run"
echo
echo "详细步骤和报错对照见项目根目录的 iOS-BUILD.md。"
