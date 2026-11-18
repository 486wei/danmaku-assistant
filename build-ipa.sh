#!/bin/bash
# 在 macOS 上跑：产出一个未签名 .ipa，交给 Windows 上的 Sideloadly 签名安装。
#
#   bash build-ipa.sh                       # 用工程里的 bundle id
#   bash build-ipa.sh com.yg.danmaku2       # 临时覆盖 bundle id（换账号/换机时用）
#
# 产物：build/ipa/DanmakuAssistant-unsigned.ipa
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="DanmakuAssistant"
PROJ="DanmakuAssistant/${APP_NAME}.xcodeproj"
OUT_DIR="build/ipa"
PAYLOAD="${OUT_DIR}/Payload"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "这台机器没有 xcodebuild。请在装了 Xcode 的 Mac 上跑这个脚本（或在 GitHub Actions 的 macos runner 上跑）。"
  exit 1
fi

xcodebuild -version

EXTRA=()
if [ "${1:-}" != "" ]; then
  EXTRA+=(PRODUCT_BUNDLE_IDENTIFIER="$1")
  echo "覆盖 bundle id -> $1"
fi

rm -rf build
mkdir -p "${PAYLOAD}"

# 关掉签名：Sideloadly 会用你的 Apple ID 重新签
xcodebuild \
  -project "${PROJ}" \
  -target "${APP_NAME}" \
  -configuration Release \
  -sdk iphoneos \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  CONFIGURATION_BUILD_DIR="${PWD}/${PAYLOAD}" \
  ${EXTRA[@]+"${EXTRA[@]}"} \
  build

APP="${PAYLOAD}/${APP_NAME}.app"
if [ ! -d "${APP}" ]; then
  echo "构建结束但没找到 ${APP}"
  exit 1
fi

echo "架构：$(lipo -archs "${APP}/${APP_NAME}" 2>/dev/null || echo 'n/a')"

# 未签名 ipa：Payload/<App>.app 打 zip 改后缀。Sideloadly 会往里塞证书和描述文件。
rm -f "${OUT_DIR}/${APP_NAME}-unsigned.ipa"
(
  cd "${OUT_DIR}"
  /usr/bin/zip -qry "${APP_NAME}-unsigned.ipa" Payload
)
rm -rf "${PAYLOAD}"

echo
ls -lh "${OUT_DIR}/${APP_NAME}-unsigned.ipa"
echo "OK -> ${PWD}/${OUT_DIR}/${APP_NAME}-unsigned.ipa"
echo "把这个 ipa 拷到 Windows，拖进 Sideloadly，填 Apple ID 后点 Start。"
