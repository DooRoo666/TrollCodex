#!/bin/bash
# TrollAgent 骨架 IPA 构建脚本（macOS runner / 本地 Mac 均可）
# 产物：ldid ad-hoc 签名 + 特权 entitlements 注入的 TrollAgent.ipa —— TrollStore 安装时直接继承
set -euo pipefail

cd "$(dirname "$0")/.."

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
echo ">>> iphoneos SDK: $SDK"

# P1 Step A (fix3cy26c)：默认走 Xcode app-extension 形态（Xcode 自动 -e _NSExtensionMain，
#   生成标准扩展 Mach-O，对照 Fuck 1.8.5 同形态）。诊断期 MINIMAL_C / MINIMAL_APPEX 开关
#   已改为 workflow 显式控制，此处不再硬编码，避免覆盖 workflow 意图。
: "${XCODE_APPEX:=1}"   # 未显式指定则默认启用 Xcode 形态（P1 主线）
if [ -n "${MINIMAL_C:-}" ]; then unset XCODE_APPEX || true; fi  # 空壳诊断仅在 workflow 显式传入时覆盖

# v3.0.37: iSH 引擎依赖——CI 已由 workflow 的 "Build iSH engine" 步骤生成 ish-stage/
# （libs/include/resources + alpine-rootfs.zip）；本地构建需先跑 scripts/ish-build/*.sh
if [ ! -f "ish-stage/libs/libish.a" ]; then
    echo "!!! ish-stage/libs/libish.a 缺失——本地构建请先运行 scripts/ish-build/build_ish.sh 与 prepare_alpine_rootfs.sh" >&2
    exit 1
fi
echo ">>> iSH libs: $(du -sh ish-stage/libs | cut -f1)"

# v3.3.0: MITM 内核依赖 OpenSSL 静态库——本地构建先跑 scripts/build-openssl.sh
if [ ! -f "openssl-stage/lib/libssl.a" ]; then
    echo "!!! openssl-stage/lib/libssl.a 缺失——本地构建请先运行 scripts/build-openssl.sh（仅 macOS；CI 已内置该步骤）" >&2
    exit 1
fi
echo ">>> OpenSSL: $(du -sh openssl-stage/lib | cut -f1)"

# v4.5.2：桌面悬浮 HUD 单可执行双模式（TrollSpeed 正解）——先把 HUD/sources 的 ObjC++
# 悬浮核心编成 libHUD.a，主 App（SwiftPM）链接（Package.swift unsafeFlags 引用）。
# 必须在此之前跑完，否则主 App swift build 链接缺 libHUD.a 失败。
echo ">>> building libHUD.a (desktop floating HUD core)"
bash scripts/build-hud.sh

# v2.9.249: 部署目标 16→15 治本——按 ios16 编译会引用 iOS16+ 符号(URLRequest.httpMethod/timeoutInterval 等 availability 标注错误的 Swift setter),iOS 15.6 dyld 启动崩;降到 ios14 后编译器自动避免 iOS16+ API
# v4.3.54: 双架构（arm64 + arm64e）——TrollAgent 纯 arm64 在 A12+(arm64e 芯片)
# 设备上以兼容模式运行，MobileIcons/CoreImage 在 compat 模式下处理图标异常 →
# 分享面板 LICreateIconForImages SIGSEGV（与 TrollFools 双架构原生运行对比）。
# fix19d(24b1994+): 取消双架构——iSH 引擎 14c1 起纯 arm64（ARCHS="arm64"），libish.a 无 arm64e 切片，
# arm64e swift build 链接必然失败→每次构建白跑 10min 后 fallback。且 libish 若编 arm64e，
# A15 原生 arm64e 执行 iSH x86 模拟即段错误(cpu_run_to_interrupt，14c1 已回退)。
# 因此主 app 定纯 arm64；分享面板 SIGSEGV 留待后续单独处理（与 TrollFools 双架构对比另行解决）。
echo ">>> swift build (arm64-apple-ios15.0, release)"
# fix3cy18: --product TrollAgent——只构建主 app；VpnTunnel appex 由下方 P1 专属段构建
#   （其链接需要先下载 hev-stage/lib；主 build 不带 product 会连 VpnTunnel 一起编，链接失败）
swift build -c release --product TrollAgent \
    -Xswiftc -sdk -Xswiftc "$SDK" \
    -Xswiftc -target -Xswiftc arm64-apple-ios15.0 \
    -Xcc -isysroot -Xcc "$SDK" \
    -Xcc -target -Xcc arm64-apple-ios15.0

BIN=".build/release/TrollAgent"
test -f "$BIN"
echo ">>> binary: $(du -h "$BIN" | cut -f1)"

APP="TrollAgent.app"
IPA="TrollAgent.ipa"
rm -rf "$APP" Payload "$IPA"
mkdir -p "$APP"

cp "$BIN" "$APP/TrollAgent"
cp Support/Info.plist "$APP/Info.plist"

# v2.9.133: 版本注入——CI 传 RELEASE_VERSION 时覆盖产物版本，
# 解决"构建产物版本永远停在仓库写死值、装上分不清新旧"的脱节问题。
# 未传时保持 Support/Info.plist 原值（本地构建默认）。
if [ -n "${RELEASE_VERSION:-}" ]; then
    echo ">>> injecting RELEASE_VERSION=$RELEASE_VERSION"
    if command -v /usr/libexec/PlistBuddy >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $RELEASE_VERSION" "$APP/Info.plist" 2>/dev/null || \
        /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $RELEASE_VERSION" "$APP/Info.plist"
        /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-parse --short HEAD 2>/dev/null || echo 1)" "$APP/Info.plist" 2>/dev/null || true
    else
        /usr/bin/sed -i '' "s#<string>2\.9\.[0-9]*</string>#<string>$RELEASE_VERSION</string>#" "$APP/Info.plist" || true
    fi
fi

# 内置注入工具链（ldid/optool/insert_dylib/ct_bypass + coreutils + 依赖 dylib）
if [ -d "Resources/bin" ]; then
    cp -R "Resources/bin" "$APP/bin"
    chmod +x "$APP/bin/"* 2>/dev/null || true
    echo ">>> bundled bin: $(ls "$APP/bin" | wc -l | tr -d ' ') files"
    # v4.4.5: 原生工具（CI native-tools job 交叉编译/预编译提取的 arm64 iOS 二进制：
    # lua=源码编译, node=nodejs-mobile iOS 预编译, r2=radare2 r2ios-sdk 预编译, cstool=capstone 交叉编译,
    # jq=源码编译(v4.4.9-fix3cm 补, 消除提示词示例有/实物无的不一致)；
    # 14c2 P1原生化: tree/xz/which=v16 新增（14c4 曾编译成功但未进包——此处白名单漏加, 已补）
# Alpine binutils 替代：objdump/nm/readelf/size/strings）；
    # jtool2 保留（Mach-O 解析专长——Alpine 无替代）
    for t in jtool2; do
        if [ -f "native-llvm-out/$t" ]; then
            cp "native-llvm-out/$t" "$APP/bin/$t"
            chmod +x "$APP/bin/$t"
            echo ">>> native $t bundled ($(du -h "$APP/bin/$t" | cut -f1))"
        fi
    done
    # v6.6.0-fix15: 原生 node（nodejs-mobile iOS arm64）——node-native 显式命令
    #（AI 重 node 任务选择：构建/打包工具芯片直跑；轻量 JS 用统一环境 Alpine nodejs）。
    if [ -f "native-node-out/node" ]; then
        cp "native-node-out/node" "$APP/bin/node"
        chmod +x "$APP/bin/node"
        echo ">>> native node bundled ($(du -h "$APP/bin/node" | cut -f1))"
        # NodeMobile dylib：install name @rpath/NodeMobile.framework/NodeMobile → 必须 framework 目录结构
        if [ -f "native-node-out/NodeMobile.dylib" ]; then
            mkdir -p "$APP/Frameworks/NodeMobile.framework"
            cp "native-node-out/NodeMobile.dylib" "$APP/Frameworks/NodeMobile.framework/NodeMobile"
            echo ">>> NodeMobile.framework/NodeMobile bundled"
        fi
    fi
    # v4.4.9-fix3cn: git 替代——iOS 拦 fork() 真 git 跑不了；dulwich 纯 Python 在 site-packages,
    # 此封装脚本(porcelain API, 绕开 dulwich CLI 的 add bug)进 bin/——v6.6.0 起 git 统一走 Alpine(rootfs 预装), git.py 仅作 rootfs 缺失兜底
    if [ -f "scripts/git.py" ]; then
        cp "scripts/git.py" "$APP/bin/git.py"
        chmod +x "$APP/bin/git.py"
        echo ">>> git.py bundled"
    fi
    # v2.9.38: 给注入工具签 no-sandbox entitlements
    # iOS 沙箱按每次 exec 的新二进制签名计算：工具不签 no-sandbox 则即使被 root spawn 也仍套普通沙箱，
    # 写其他 App bundle（/private/var/containers/Bundle/Application/...）会 Permission denied。
    if [ -f "Support/bin-entitlements.plist" ]; then
        # v2.9.38c: 优先 macOS 原生 ldid（CI 已加 brew install ldid；xerub ldid 对 iOS arm64e 兼容最好）。
        # fallback codesign（macOS 原生，主二进制已验证可用）。
        # 切勿 fallback 到 $APP/bin/ldid —— 那是 iOS arm64 二进制，在 macOS runner 上会被 SIGKILL。
        if command -v ldid >/dev/null 2>&1; then
            SIGN_TOOL=ldid
        elif command -v codesign >/dev/null 2>&1; then
            SIGN_TOOL=codesign
        else
            SIGN_TOOL=""
        fi
        if [ -n "$SIGN_TOOL" ]; then
            FAILED=""
            for t in "$APP"/bin/*; do
                [ -f "$t" ] || continue
                case "$t" in *.dylib) continue;; esac
                # fix19b: 只签 Mach-O 二进制——git.py/nscan.py(python脚本)/libcapstone.a(静态库)/magic.mgc(magic数据) 非 Mach-O，
                # ldid 无法签名（此前原代码 || true 静默跳过；fix19 严格化后误伤非二进制导致构建失败）。
                # macOS runner 的 file 识别 Mach-O；非二进制跳过签名（它们不是可执行，无沙箱计算）。
                if ! file "$t" 2>/dev/null | grep -q "Mach-O"; then continue; fi
                if [ "$SIGN_TOOL" = codesign ]; then
                    codesign -s - -f --entitlements "Support/bin-entitlements.plist" "$t" 2>/dev/null || FAILED="$FAILED $(basename "$t")"
                else
                    # xerub ldid 语法：-S 后必须紧跟文件名（-Sent.plist），否则 entitlements 写不进去
                    "$SIGN_TOOL" -S"Support/bin-entitlements.plist" "$t" 2>/dev/null || FAILED="$FAILED $(basename "$t")"
                fi
            done
            if [ -n "$FAILED" ]; then
                echo "!!! bin tool signing FAILED for:$FAILED —— no-sandbox 未注入，真机网络/跨容器读写会被沙箱拦截" >&2
                exit 1
            fi
            echo ">>> signed bin tools with no-sandbox entitlements (via $SIGN_TOOL, verified)"
        else
            echo "!!! ldid/codesign not available; bin tools stay sandboxed (injection may fail)" >&2
        fi
    fi
fi

# v4.5.2：桌面悬浮 HUD 已改为【单可执行双模式】——HUD ObjC 核心编成 libHUD.a 直接链接进主可执行
#（见上方 build-hud.sh + Package.swift），不再打进独立 TrollAgentHUD 二进制（假签名被 AMFI 106/109 拒，
# 已废弃）。主可执行被 TrollStore 有效签名，-hud 复用有效签名 → 悬浮进程 AMFI 放行。


# 其他资源文件（开发者指令、配置模板、图标等）
if [ -d "Resources" ]; then
    # 复制文件
    find Resources -mindepth 1 -maxdepth 1 -type f -exec cp {} "$APP/" \;
    # v2.9.62：复制子目录（tweaks/ 内置 dylib 等）——用 find 避免 bash glob 尾部斜杠问题
    find Resources -mindepth 1 -maxdepth 1 -type d | while read -r d; do
        dirname=$(basename "$d")
        # bin 已在前面单独复制（需要 chmod + 签名），跳过避免重复
        [ "$dirname" = "bin" ] && continue
        rm -rf "$APP/$dirname"
        cp -R "$d" "$APP/$dirname"
    done
    echo ">>> bundled resources: $(find Resources -maxdepth 1 -type f | wc -l | tr -d ' ') files + $(find Resources -maxdepth 1 -type d | tail -n +2 | wc -l | tr -d ' ') dirs"
fi

# v3.0.48: tweaks/*.dylib 注入用——必须纯 arm64 + adhoc 签名。
# 1) arm64e 进程（A12+ 的 App Store App 如豆包）dlopen fat dylib 会选 arm64e slice，
#    arm64e slice 的 adhoc 签名在 iOS16 dyld 上必报 "code signature invalid"（真机实测）。
#    lipo -thin arm64 只留 arm64 slice（arm64e 进程可正常 dlopen 纯 arm64 dylib，TrollFools 同款）。
# 2) ldid 重签（老 xerub ldid 生成的签名 iOS16 也 invalid；CI brew 版为 Procursus 维护版）。
for d in "$APP"/tweaks/*.dylib; do
    [ -f "$d" ] || continue
    if lipo -info "$d" 2>/dev/null | grep -qi "architectures"; then
        lipo -thin arm64 "$d" -output "$d.tmp" 2>/dev/null && mv "$d.tmp" "$d" && echo ">>> thinned to arm64: $d"
    fi
    if command -v ldid >/dev/null 2>&1 && ldid -S "$d" >/dev/null 2>&1; then
        echo ">>> ldid re-signed $d"
    elif codesign -s - -f "$d" >/dev/null 2>&1; then
        echo ">>> codesign adhoc re-signed $d"
    else
        echo "!!! sign failed: $d"
    fi
done

# v3.0.37: iSH 引擎资源——alpine-rootfs.zip（首次启动解压）+ VDSO + RootfsPatch
if [ -f "ish-stage/resources/alpine-rootfs.zip" ]; then
    cp "ish-stage/resources/alpine-rootfs.zip" "$APP/alpine-rootfs.zip"
    echo ">>> bundled alpine-rootfs.zip ($(du -h "$APP/alpine-rootfs.zip" | cut -f1))"
fi
if [ -f "ish-stage/resources/libvdso.so.elf" ]; then
    cp "ish-stage/resources/libvdso.so.elf" "$APP/"
fi
if [ -d "ish-stage/resources/RootfsPatch.bundle" ]; then
    rm -rf "$APP/RootfsPatch.bundle"
    cp -R "ish-stage/resources/RootfsPatch.bundle" "$APP/"
fi

# v3.0.41：ios_system 已删除，不再需要 @executable_path rpath 与 shellhelper 独立进程

# fix3cy11 (P1)：VPN appex 优先【自研 swift build】——全接管 + hev-socks5-tunnel 转发内核
#   （Tun2SocksKit xcframework）→ 本机 Socks5Server(127.0.0.1:19080) 出网+记录 → 写回隧道。
#   = 不断网全流量抓包（依据深度调研 RESEARCH_REPORT.md P1，socksguard 同款架构）。
#   Fuck 1.8.5 成品（全接管纯记录 → 断网）降级为 fallback 兜底。
if [ -n "$XCODE_APPEX" ] && command -v xcodegen >/dev/null 2>&1; then
    # fix3cy26 (P1 Step A)：Xcode app-extension 形态——Xcode 自动 -e _NSExtensionMain 布线，
    #   生成标准扩展 Mach-O（Fuck 1.8.5 同形态）。诊断期开关，先验证 NE 能否拉起。
    echo ">>> VPN appex: Xcode app-extension 形态 (XCODE_APPEX=1, P1 Step A 最小 TunnelProvider)"
    mkdir -p "$APP/PlugIns"
    set +e
    bash vpnxcode/build_appex.sh "$APP/PlugIns" > /tmp/xcode_appex_build.log 2>&1
    XC_RC=$?
    set -e
    tail -25 /tmp/xcode_appex_build.log
    if [ $XC_RC -eq 0 ] && [ -d "$APP/PlugIns/VpnTunnel.appex" ]; then
        echo ">>> Xcode appex OK: $(ls -la "$APP/PlugIns/VpnTunnel.appex/VpnTunnel" 2>/dev/null | awk '{print $5"B"}')"
    else
        echo "!!! Xcode appex build FAILED (rc=$XC_RC) — VPN mode unavailable"
        rm -rf "$APP/PlugIns/VpnTunnel.appex"
    fi
elif [ -n "${MINIMAL_C:-}" ]; then
    # fix3cy25l：C 纯空壳诊断——排除 Swift runtime。进程 main 只写一行日志退出。
    #   判定：NE 能否拉起进程（Swift 26.5 产物在 iOS 16.3 dyld 的兼容性是否背锅）。
    echo ">>> VPN appex: C 空壳诊断 (MINIMAL_C=1)"
    mkdir -p "$APP/PlugIns/VpnTunnel.appex"
    cat > /tmp/appex_min.c <<'CEOF'
#include <stdio.h>
#include <time.h>
#include <unistd.h>
int main(int argc, char **argv) {
    time_t t = time(NULL);
    FILE *f;
    char home[1024];
    const char *paths[8];
    int n = 0;
    paths[n++] = "/var/mobile/Documents/Workspace/logs/appex.log";   // 主App容器（需no-sandbox）
    paths[n++] = "/tmp/appex.log";                                   // 系统tmp（需no-sandbox）
    paths[n++] = "/var/mobile/Documents/appex.log";                  // 主App Documents
    if (getenv("HOME")) {
        snprintf(home, sizeof(home), "%s/appex.log", getenv("HOME"));
        paths[n++] = home;
    }
    for (int i = 0; i < n; i++) {
        f = fopen(paths[i], "a");
        if (f) { fprintf(f, "[%ld] C-minimal appex REACHED argc=%d pid=%d\n", (long)t, argc, (int)getpid()); fclose(f); }
    }
    sleep(600);  // 挂住10分钟：远程 ps 抓进程（比日志更可靠）
    return 0;
}
CEOF
    if xcrun -sdk iphoneos clang -arch arm64 -isysroot "$SDK" -miphoneos-version-min=15.0 \
        /tmp/appex_min.c -o "$APP/PlugIns/VpnTunnel.appex/VpnTunnel" 2>&1 | tail -5; then
        cp "Support/VpnTunnel-Info.plist" "$APP/PlugIns/VpnTunnel.appex/Info.plist"
        if command -v ldid >/dev/null 2>&1 && ldid -S"Support/VpnTunnel.entitlements" "$APP/PlugIns/VpnTunnel.appex/VpnTunnel"; then
            echo ">>> signed C-minimal appex (diagnostic)"
        else
            echo "!!! C appex sign FAILED" >&2
        fi
    else
        echo "!!! C appex build FAILED" >&2
    fi
elif [ -d "openssl-stage/lib" ] && [ -f "openssl-stage/lib/libssl.a" ]; then
    echo ">>> VPN appex: swift build 自研 VpnTunnel (P1 hev 转发内核: 全接管+转发+记录)"
    # fix3cy16：hev-socks5-tunnel iOS 真机 slice（Tun2SocksKit 5.16.0 release 的 xcframework）
    #   手动下载解压 → hev-stage/lib/libhev-socks5-tunnel.a（避开 SwiftPM binaryTarget 平台选择：
    #   SwiftPM 在 macOS host 默认按 macOS 解析，会把 macOS slice 链接进 iOS，ld 直接报错）
    if [ ! -f "hev-stage/lib/libhev-socks5-tunnel.a" ]; then
        echo ">>> downloading HevSocks5Tunnel.xcframework (Tun2SocksKit 5.16.0) for iOS arm64 slice"
        mkdir -p hev-stage/lib
        curl -sL --max-time 120 -o hev-stage/hev.zip \
            "https://github.com/EbrahimTahernejad/Tun2SocksKit/releases/download/5.16.0/HevSocks5Tunnel.xcframework.zip"
        unzip -o -q hev-stage/hev.zip -d hev-stage/xcf
        cp hev-stage/xcf/HevSocks5Tunnel.xcframework/ios-arm64/libhev-socks5-tunnel.a hev-stage/lib/
        echo ">>> hev lib: $(ls -la hev-stage/lib/ | grep hev)"
    fi
    echo ">>> swift build VpnTunnel appex (fix3cy24: -e _NSExtensionMain 扩展入口)"
    # fix3cy24（根因修复）：iOS App Extension 进程入口必须是 _NSExtensionMain（Foundation 的
    #   扩展 XPC 引导：注册 NSXPCListener + 实例化 NSExtensionPrincipalClass）。
    #   swift build 默认把入口设成普通 _main（进程跑完 main 即退出、不注册 XPC），
    #   NE 系统拉起扩展后永远等不到响应 → 状态卡 .connecting → App 侧 confirmConnected 超时。
    #   对照 Fuck 1.8.5 成品 appex 二进制含 _NSExtensionMain 符号（Xcode 编译自动 -e），
    #   自研产物无此符号 → 实锤。入口组合：LC_MAIN=自己的 main（@_cdecl("main") 已定义），
    #   main 内部调 NSExtensionMain；_NSExtensionMain 是私有符号（SDK tbd 不导出）→
    #   -U 允许 undefined（dyld 运行时从系统 Foundation 解析），且 entry 不是该符号、
    #   不与 -U 冲突（fix3cy25e）。
    if swift build -c release --product VpnTunnel \
        -Xswiftc -sdk -Xswiftc "$SDK" \
        -Xswiftc -target -Xswiftc arm64-apple-ios15.0 \
        -Xcc -isysroot -Xcc "$SDK" \
        -Xcc -target -Xcc arm64-apple-ios15.0 \
        -Xlinker -syslibroot -Xlinker "$SDK" \
        -Xswiftc -D -Xswiftc MINIMAL_APPEX 2>&1 | tail -8; then
        VT_BIN=""
        for p in ".build/release/VpnTunnel" ".build/arm64-apple-ios15.0/release/VpnTunnel"; do
            [ -f "$p" ] && VT_BIN="$p"
        done
        if [ -n "$VT_BIN" ]; then
            mkdir -p "$APP/PlugIns/VpnTunnel.appex"
            cp "$VT_BIN" "$APP/PlugIns/VpnTunnel.appex/VpnTunnel"
            cp "Support/VpnTunnel-Info.plist" "$APP/PlugIns/VpnTunnel.appex/Info.plist"
            if command -v ldid >/dev/null 2>&1; then
                if ldid -S"Support/VpnTunnel.entitlements" "$APP/PlugIns/VpnTunnel.appex/VpnTunnel"; then
                    echo ">>> signed VpnTunnel appex (自研 hev 引擎)"
                else
                    echo "!!! VpnTunnel appex sign FAILED — removing (VPN mode unavailable)"
                    rm -rf "$APP/PlugIns/VpnTunnel.appex"
                fi
            else
                echo "!!! ldid missing; VpnTunnel appex unsigned — removing"
                rm -rf "$APP/PlugIns/VpnTunnel.appex"
            fi
        else
            echo "!!! VpnTunnel binary missing; VPN mode unavailable"
        fi
    else
        echo "!!! VpnTunnel build FAILED — falling back to Fuck 成品 (local proxy mode still works)"
    fi
elif [ -d "Resources/fuck_vpn/VpnTunnel.appex" ]; then
    echo ">>> VPN appex fallback: 使用 Fuck 1.8.5 成品 (全接管纯记录，抓包断网；仅自研不可用时兜底)"
    rm -rf "$APP/PlugIns/VpnTunnel.appex"
    mkdir -p "$APP/PlugIns/VpnTunnel.appex"
    cp -R "Resources/fuck_vpn/VpnTunnel.appex/." "$APP/PlugIns/VpnTunnel.appex/"
    echo ">>> VPN Frameworks: 复制 TunnelServices + swift-nio 全家桶 (20MB)"
    mkdir -p "$APP/Frameworks"
    for fw in Resources/fuck_vpn/*.framework; do
        [ -d "$fw" ] && cp -R "$fw" "$APP/Frameworks/"
    done
    if command -v ldid >/dev/null 2>&1; then
        if ldid -S"Support/VpnTunnel.entitlements" "$APP/PlugIns/VpnTunnel.appex/VpnTunnel"; then
            echo ">>> signed VpnTunnel appex (Fuck 引擎 fallback)"
        else
            echo "!!! VpnTunnel appex sign FAILED — removing (VPN mode unavailable)"
            rm -rf "$APP/PlugIns/VpnTunnel.appex"
        fi
    else
        echo "!!! ldid missing; VpnTunnel appex unsigned — removing"
        rm -rf "$APP/PlugIns/VpnTunnel.appex"
    fi
else
    echo "!!! openssl-stage 与 fuck_vpn 均缺失 — skipping VpnTunnel appex (VPN mode unavailable)"
fi

# v6.6.0-fix15: 原生 Python（CPython 3.14 iOS, PEP 730）恢复——作为 py3-native 显式命令
#（AI 按场景选择：numpy/pandas 深度运算 → py3-native 芯片直跑；日常/装包 → python3 统一环境 Alpine）。
# CI 由 native-python job 编译 Python.xcframework 并 upload artifact（tar.gz 包装）；build job download 到 python-ios/。
# 本地构建无 artifact 时自动跳过。
if ls python-ios/python-*.tar.gz >/dev/null 2>&1; then
    mkdir -p python-ios/unpacked
    tar -xzf python-ios/python-*.tar.gz -C python-ios/unpacked
fi
# 定位 Python.xcframework：不猜 tar 顶层目录名（官方产物可能是 python-3.14.8-iOS-XCframework/
# 包一层，也可能直接散落），find 一次命中。|| true：download 未就位/缺失时不得触发
# set -euo pipefail 杀死整个打包（fix3d 曾因此静默失败——find 找不到目录 exit 1）
XCF_DIR=$(find python-ios -type d -name "Python.xcframework" 2>/dev/null | head -1 || true)
if [ -n "$XCF_DIR" ]; then
    SLICE="$XCF_DIR/ios-arm64"
    if [ -d "$SLICE" ]; then
        echo ">>> integrating native Python (iOS arm64)..."
        # 1. Python.framework → App/Frameworks（CLI 链接 libPython，rpath 指向 ../Frameworks）
        mkdir -p "$APP/Frameworks"
        cp -R "$SLICE/Python.framework" "$APP/Frameworks/"
        # 2. stdlib（PYTHONHOME = App/python）：PEP 730 布局 = XCFramework 顶层共享
        #    lib/python3.14/（纯 Python 模块 + ensurepip + site-packages）+
        #    ios-arm64/lib-arm64/python3.14/lib-dynload/（平台 .so 扩展）
        if [ -d "$XCF_DIR/lib/python3.14" ]; then
            mkdir -p "$APP/python/lib"
            cp -R "$XCF_DIR/lib/python3.14" "$APP/python/lib/"
            # v6.6.0-fix30: 排除 python test 目录（162MB 纯测试文件——运行时不需要——tipa 瘦身 ~30MB）
            rm -rf "$APP/python/lib/python3.14/test"
            echo ">>> stdlib: $(du -sh "$APP/python" | cut -f1)"
        else
            echo "!!! XCFramework lib/python3.14 missing (shared stdlib)" >&2
        fi
        if [ -d "$SLICE/lib-arm64/python3.14/lib-dynload" ]; then
            mkdir -p "$APP/python/lib/python3.14"
            cp -R "$SLICE/lib-arm64/python3.14/lib-dynload" "$APP/python/lib/python3.14/"
            echo ">>> lib-dynload merged: $(ls "$APP/python/lib/python3.14/lib-dynload" | wc -l | tr -d ' ') exts"
        else
            echo "!!! ios-arm64 lib-dynload missing (platform extensions)" >&2
        fi
        # 3. numpy/pandas iOS wheel（CI native-wheels job 用 cibuildwheel 编的 cp314 arm64 iphoneos wheel）
        #    解包进 site-packages——原生 python3 直接 import numpy/pandas
        if ls native-wheels/*.whl >/dev/null 2>&1; then
            SP="$APP/python/lib/python3.14/site-packages"
            mkdir -p "$SP"
            for w in native-wheels/*.whl; do
                unzip -oq "$w" -d "$SP" && echo ">>> wheel unpacked: $(basename "$w")"
            done
            echo ">>> site-packages: $(du -sh "$SP" | cut -f1)"
        else
            echo "!!! native-wheels not present — py3-native numpy/pandas 未进包（Alpine 侧 apk py3-numpy 仍可用）" >&2
        fi
        # fix3cn: 真机实测 _ios_support 未进包 → platform.uname() 走 ios_ver() 崩(import 失败) → pandas
        # import 崩(traceback 实证)。os.uname() 真机可用(Darwin/iPhone14,3)——patch platform.py 的 ios
        # 分支 try/except 保护, fallback 保留 os.uname 结果, pandas 即可正常 import。
        PLATFORM_PY="$APP/python/lib/python3.14/platform.py"
        if [ -f "$PLATFORM_PY" ]; then
            perl -0pi -e "s/if sys\.platform == 'ios':\n\s+system, release, _, _ = ios_ver\(\)/if sys.platform == 'ios':\n        try:\n            system, release, _, _ = ios_ver()\n        except Exception:\n            pass/" "$PLATFORM_PY"
            echo ">>> platform.py ios_ver try/except patched"
        fi
        # fix3cn: python-ios dist 未生成 _sysconfigdata 模块 → sysconfig.get_config_var() import 崩 →
        # pandas compat._constants 的 ISMUSL 检查崩(traceback 实证)。patch sysconfig._get_sysconfigdata
        # try/except 返回空 dict——get_config_var 对缺失项返回 None(标准行为), 一次性覆盖任意缺失。
        SYSCONFIG_PY="$APP/python/lib/python3.14/sysconfig/__init__.py"
        if [ -f "$SYSCONFIG_PY" ]; then
            perl -0pi -e "s/def _get_sysconfigdata\(\):\n    import importlib\n\n    name = _get_sysconfigdata_name\(\)\n    path = os\.environ\.get\('_PYTHON_SYSCONFIGDATA_PATH'\)\n    module = _import_from_directory\(path, name\) if path else importlib\.import_module\(name\)\n\n    return module\.build_time_vars/def _get_sysconfigdata():\n    import importlib\n\n    name = _get_sysconfigdata_name()\n    path = os.environ.get('_PYTHON_SYSCONFIGDATA_PATH')\n    try:\n        module = _import_from_directory(path, name) if path else importlib.import_module(name)\n        return module.build_time_vars\n    except Exception:\n        return {}/" "$SYSCONFIG_PY"
            echo ">>> sysconfig _get_sysconfigdata fallback patched"
        fi
        # 4. 编译 py3-native CLI（嵌入式入口：PyConfig + PYTHONHOME + -c/-m/script）
        if [ -f "Sources/PythonCLI/main.c" ] && [ -f "$APP/Frameworks/Python.framework/Headers/Python.h" ]; then
            # fix3ck: 用户定案用动态版——动态 wrapper 链 Python.framework（官方 PEP 730 --enable-framework 产物，
            # node 同款 @rpath/NodeMobile.framework 方案已被验证可跑）。fix3cg 补签 no-sandbox 对两条路径都覆盖；
            # 137 根因=签名(未签 no-sandbox)，与静态/动态无关。动态版省 ~5.8MB、升级 Python 只换 framework。
            # 静态库分支仅作兜底（动态失败时）。
            echo ">>> py3-native CLI: dynamic link (primary, @rpath/Python.framework/Python)"
            xcrun -sdk iphoneos clang -arch arm64 -isysroot "$SDK" -miphoneos-version-min=13.0 \
                -I"$APP/Frameworks/Python.framework/Headers" \
                -F"$APP/Frameworks" -framework Python \
                -Wl,-rpath,@executable_path/../Frameworks \
                -o "$APP/bin/python3" Sources/PythonCLI/main.c || \
                { echo "!!! py3-native CLI dynamic build FAILED, fallback static" >&2; rm -f "$APP/bin/python3"; }
            if [ ! -f "$APP/bin/python3" ] && [ -f "python-ios/static-lib/libpython3.14.a" ]; then
                echo ">>> py3-native CLI: static link (fallback)"
                xcrun -sdk iphoneos clang -arch arm64 -isysroot "$SDK" -miphoneos-version-min=13.0 \
                    -I"$APP/Frameworks/Python.framework/Headers" \
                    -I"python-ios/static-lib/include" \
                    -o "$APP/bin/python3" Sources/PythonCLI/main.c \
                    python-ios/static-lib/libpython3.14.a \
                    -lpthread -ldl -lutil -lm || \
                    { echo "!!! py3-native CLI static build FAILED" >&2; rm -f "$APP/bin/python3"; }
            fi
            # fix3cn: python3 是核心能力——两条路径都失败必须 exit 1（此前吞错继续 → 出
            # "run success 但包内无 python3" 的残缺包, 真机 AI 调用 python3 报"未内置", 用户白装一轮）。
            # 本地构建无 python artifact 时走外层 if 跳过, 不受影响；只有"有 artifact 却编不出来"才 fail。
            if [ ! -f "$APP/bin/python3" ]; then
                echo "!!! py3-native CLI BOTH dynamic and static failed — failing build (no silent half-package)" >&2
                exit 1
            fi
            if [ -f "$APP/bin/python3" ]; then
                chmod +x "$APP/bin/python3"
                echo ">>> native py3-native CLI built ($(du -h "$APP/bin/python3" | cut -f1))"
                # fix3cg: python3 是本脚本内后生成的——前面的 bin 签名循环(≈123-150 行)展开时它还不存在，
                # 未签 no-sandbox entitlements → iOS 沙箱按每次 exec 的二进制签名计算 → 真机 spawn 套普通沙箱
                # → 启动即被 SIGKILL(137)。编译成功后必须补签一次 no-sandbox（动态/静态两条路径都覆盖）。
                if [ -f "Support/bin-entitlements.plist" ]; then
                    if command -v ldid >/dev/null 2>&1; then
                        if ! ldid -S"Support/bin-entitlements.plist" "$APP/bin/python3" 2>/dev/null \
                            || ! ldid -e "$APP/bin/python3" 2>/dev/null | grep -q no-sandbox; then
                            echo "!!! python3 no-sandbox re-sign FAILED —— 真机 python3 将套普通沙箱（网络/容器权限缺失）" >&2
                            exit 1
                        fi
                        echo ">>> python3 re-signed no-sandbox (ldid, verified)"
                    elif command -v codesign >/dev/null 2>&1; then
                        codesign -s - -f --entitlements "Support/bin-entitlements.plist" "$APP/bin/python3" 2>/dev/null \
                            && echo ">>> python3 re-signed no-sandbox (codesign)" \
                            || { echo "!!! python3 no-sandbox re-sign FAILED (codesign)" >&2; exit 1; }
                    else
                        echo "!!! no sign tool for python3 — stays sandboxed" >&2
                    fi
                else
                    echo "!!! bin-entitlements.plist missing — python3 stays sandboxed" >&2
                fi
            fi
        else
            echo "!!! PythonCLI/main.c or Python.h missing — native Python skipped" >&2
        fi
    else
        echo "!!! ios-arm64 slice missing in $XCF_DIR — native Python skipped" >&2
    fi
else
    echo ">>> python-ios xcframework not present — native Python skipped" >&2
fi

# v7.1.290：内置 codex 运行时（CI 里 native-codex job 交叉编译的 aarch64-apple-ios 可执行文件）
# 目标：用户装完 App 就能用 codex 内核，不需要再装 NanoCode、也不需要手工投放二进制。
# 找不到产物时退化为"外部运行时探测"（CodexKernel.binaryCandidates 里那串路径），不阻塞出包。
if [ -f "native-codex-out/codex" ]; then
    mkdir -p "$APP/CodexRuntime"
    cp "native-codex-out/codex" "$APP/CodexRuntime/codex"
    chmod +x "$APP/CodexRuntime/codex"
    # v7.1.309：codex 会按自身路径找 codex-code-mode-host（缺它 → code mode 失败，
    # 表现就是"设备工具调用环境启动失败 / No such file or directory"）。
    if [ -f "native-codex-out/codex-code-mode-host" ]; then
        cp "native-codex-out/codex-code-mode-host" "$APP/CodexRuntime/codex-code-mode-host"
        chmod +x "$APP/CodexRuntime/codex-code-mode-host"
        echo ">>> bundled code-mode host ($(du -h "$APP/CodexRuntime/codex-code-mode-host" | cut -f1))"
    else
        echo ">>> code-mode host 未就绪（code mode 会 fail-closed）" >&2
    fi
    # iOS 上子进程必须自带签名才能 exec，走和 bin/ 工具同一套 entitlements
    if command -v ldid >/dev/null 2>&1; then
        if [ -f "Support/bin-entitlements.plist" ]; then
            ldid -S"Support/bin-entitlements.plist" "$APP/CodexRuntime/codex" 2>/dev/null \
                || ldid -S "$APP/CodexRuntime/codex" 2>/dev/null || true
        else
            ldid -S "$APP/CodexRuntime/codex" 2>/dev/null || true
        fi
    fi
    echo ">>> bundled codex runtime ($(du -h "$APP/CodexRuntime/codex" | cut -f1))"
    # v7.1.309：host 同样要签（iOS 上子进程必须自带签名才能 exec）
    if [ -f "$APP/CodexRuntime/codex-code-mode-host" ] && command -v ldid >/dev/null 2>&1; then
        ldid -S"Support/bin-entitlements.plist" "$APP/CodexRuntime/codex-code-mode-host" 2>/dev/null \
            || ldid -S "$APP/CodexRuntime/codex-code-mode-host" 2>/dev/null || true
    fi
else
    echo ">>> codex runtime 未就绪（native-codex 产物缺失）——退化为外部运行时探测" >&2
fi

# 把特权 entitlements 签入主二进制，TrollStore 安装时才能继承 no-sandbox/no-container/task_for_pid 等权限
# v2.9.64：强制用 ldid 签名（TrollStore 官方明确要求 ldid -S 格式；codesign ad-hoc 签名格式不同，可能导致 entitlements 不被保留）
if [ -f "Support/TrollAgent.entitlements" ]; then
    echo ">>> ldid sign main binary with entitlements"
    # CI 已 brew install ldid；优先用 macOS 原生 ldid（xerub ldid 对 iOS arm64e 兼容最好）
    LDID="$(command -v ldid || true)"
    if [ -z "$LDID" ]; then
        echo "!!! ldid not available; cannot inject entitlements" >&2
        exit 1
    fi
    "$LDID" -S"Support/TrollAgent.entitlements" "$APP/TrollAgent"
    echo ">>> signed main binary with ldid"
else
    echo "!!! Support/TrollAgent.entitlements missing" >&2
    exit 1
fi

mkdir -p Payload
cp -R "$APP" Payload/

zip -qry "$IPA" Payload
echo ">>> built: $IPA ($(du -h "$IPA" | cut -f1))"

# v2.9.206: 同时输出 TrollStore 原生 .tipa（TrollDecrypt/TrollFools 同款格式，
# TrollStore 对自家格式签名/entitlements 处理最完整）。tipa 即 zip（内含 Payload）。
cp "$IPA" TrollAgent.tipa
echo ">>> built: TrollAgent.tipa ($(du -h "TrollAgent.tipa" | cut -f1))"
