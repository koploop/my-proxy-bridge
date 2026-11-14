#!/bin/bash
# 用本地开发证书给 CI 产出的未签名 ProxyBridge.app 签名。
#
# 前提(缺一不可,否则 codesign 会失败):
#   1. App ID com.commonuse.magic 和 com.commonuse.magic.extension 的
#      Network Extensions 能力必须勾选【系统扩展(System Extension)子项】,
#      且两张描述文件是在勾选之后重新生成的(旧描述文件不含该权限值);
#   2. cer/cer_file.p12(Apple Development 证书+私钥,团队 P57F6K6J34)、
#      cer/p12密码.txt、cer/macCommonUse.provisionprofile、
#      cer/macCommonUseExtension.provisionprofile 都存在;
#   3. 本机 Mac 的 UDID 已在描述文件的设备列表中。
#
# 用法: Scripts/sign-local.sh path/to/ProxyBridge.app
set -euo pipefail

APP="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CERT_DIR="$ROOT/cer"
P12="$CERT_DIR/cer_file.p12"
PW_FILE="$CERT_DIR/p12密码.txt"
APP_PROFILE="$CERT_DIR/macCommonUse.provisionprofile"
EXT_PROFILE="$CERT_DIR/macCommonUseExtension.provisionprofile"

die() { echo "error: $*" >&2; exit 1; }

[ -n "$APP" ] && [ -d "$APP" ] || die "usage: $0 path/to/ProxyBridge.app"
[ -e "$P12" ] || die "missing $P12"
[ -e "$PW_FILE" ] || die "missing $PW_FILE"
[ -e "$APP_PROFILE" ] || die "missing $APP_PROFILE"
[ -e "$EXT_PROFILE" ] || die "missing $EXT_PROFILE"

APP="$(cd "$APP" && pwd)"
EXT_DIR="$(find "$APP/Contents/Library/SystemExtensions" -maxdepth 1 -name '*.systemextension' | head -1)"
[ -n "$EXT_DIR" ] || die "no .systemextension found inside $APP"

find_identity() {
  security find-identity -v -p codesigning 2>/dev/null \
    | grep 'Apple Development' \
    | sed -E 's/.*"([^"]+)".*/\1/' \
    | head -1 || true
}

# 1. 确保证书+私钥在本机钥匙串
IDENTITY="$(find_identity)"
if [ -z "$IDENTITY" ]; then
  echo "未找到 Apple Development 身份,正在导入 $P12 ..."
  security import "$P12" -k login.keychain-db -P "$(cat "$PW_FILE")" -T /usr/bin/codesign -A
  security set-key-partition-list -S apple-tool:,apple: -s -k "$(cat "$PW_FILE")" login.keychain-db >/dev/null 2>&1 || true
  IDENTITY="$(find_identity)"
fi
[ -n "$IDENTITY" ] || die "导入 p12 后仍未找到 Apple Development 身份"
echo "签名身份: $IDENTITY"

# 2. 嵌入描述文件(macOS 应用/系统扩展各一份)
cp "$APP_PROFILE" "$APP/Contents/embedded.provisionprofile"
cp "$EXT_PROFILE" "$EXT_DIR/Contents/embedded.provisionprofile"

# 3. 去掉隔离属性(从浏览器/聊天工具下载的文件可能带 quarantine)
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

# 4. 先签内层系统扩展,再签外层 App
echo "签名系统扩展: $EXT_DIR"
codesign --force --sign "$IDENTITY" --options runtime \
  --entitlements "$ROOT/extension/extensionRelease.entitlements" \
  "$EXT_DIR"

echo "签名主应用: $APP"
codesign --force --sign "$IDENTITY" --options runtime \
  --entitlements "$ROOT/ProxyBridge/ProxyBridgeRelease.entitlements" \
  "$APP"

# 5. 校验
codesign --verify --strict --verbose=2 "$APP"
codesign -d --entitlements :- "$APP" | grep -q 'networkextension' \
  || die "最终签名缺少 networkextension entitlement"
security cms -D -i "$APP/Contents/embedded.provisionprofile" >/dev/null
echo
echo "签名完成: $APP"
echo "安装: ditto \"$APP\" /Applications/ProxyBridge.app"
echo "首次运行请在 系统设置 -> 隐私与安全性 中允许系统扩展, 并在网络设置中批准。"
