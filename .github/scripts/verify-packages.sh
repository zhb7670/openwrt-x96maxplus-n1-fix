#!/bin/bash
# ============================================================
# verify-packages.sh —— OpenWrt 插件"少插件"自动检测闸门
# ============================================================
# 用途：在 make defconfig 之后、编译之前，自动识别
#      "哪些插件没进 .config / 没被 Kconfig 识别"，并按
#      三层给出根因分类，而不是只报一个数字。
#
# 背景（实证根因，见本文件末尾）：
#   OpenWrt 的 tmp/.packageinfo 是 **mtime 增量缓存**。
#   在 CI 里先update feeds（触发一次 metadata 扫描）、
#   之后再 clone package/ 下的插件，新目录不会进索引，
#   Kconfig 从未见过这些符号 -> make defconfig 会把它们
#   当作未知行静默丢弃（连 "# xxx is not set" 都不产生）。
#   表现为：package/ 下 Makefile 明明存在，.config 里却没有。
#
# 用法（必须在 openwrt 源码根目录、执行 make defconfig 之后）：
#   bash .github/scripts/verify-packages.sh
#
# 退出码：
#   0 = 全部插件已进 .config，可以开编
#   1 = 有插件缺失（会打印根因分类和修复建议）
#   2 = 用法错误（不在 openwrt 根目录）
# ============================================================

set -uo pipefail

# ---------- 可调参数 ----------
# ★ 基线来源（2026-10-13 实测修正）：
#   直接从 haiibo/OpenWrt官方 configs/armv8-plus.config 统计得出，
#   不是拍脑袋估的。实测该config 里：
#     CONFIG_PACKAGE_*=y总数   = 1065
#     luci-app-*=y    总数     = 123   ← 官方真实基线
#     luci-i18n-*=y            = 0（官方 config 未显式列i18n，由依赖自动带入）
#   之前工作流里写的"83"是错的，会导致误判。
EXPECT_LUCI_APP="${EXPECT_LUCI_APP:-123}"
EXPECT_LUCI_I18N="${EXPECT_LUCI_I18N:-0}"

# 必选插件清单（缺一即失败，与数量无关）
# 前18个 = 科学上网核心（用户明确要求这几个必须最新且齐全）
REQUIRED_PACKAGES="${REQUIRED_PACKAGES:-\
luci-app-passwall luci-app-passwall2 luci-app-openclash \
luci-app-ssr-plus luci-app-smartdns luci-app-mosdns \
luci-app-alist luci-app-ddns luci-app-turboacc \
luci-app-frpc luci-app-frps luci-app-v2ray-server \
luci-app-kodexplorer luci-app-verysync luci-app-zerotier \
luci-app-transmission luci-app-wireguard luci-app-openvpn-server}"

# 官方分类目录：它们本来就没有 Makefile，不参与"应有包"统计
OFFICIAL="kernel libs devel utils network telephony base-files \
target toolchain firmware bootloader"

# ---------- 0. 环境自检 ----------
if [ ! -f tmp/.packageinfo ] && [ ! -d package ]; then
  echo "::error::请在 openwrt 源码根目录执行（找不到 package/ 与 tmp/.packageinfo）"
  exit 2
fi

echo "=============================================="
echo " 插件完整性自动检测"
echo "=============================================="

# ---------- 1. 采集三方事实 ----------
# (A) 物理层：package/ 下有 Makefile 的第三方包
declare -a HAVE_MAKEFILE=()
for d in package/*/; do
  n=$(basename "$d")
  case " $OFFICIAL " in *" $n "*) continue ;; esac
  [ -f "package/$n/Makefile" ] && HAVE_MAKEFILE+=("$n")
done

# (B) 索引层：tmp/.packageinfo 收录的包（这才是 Kconfig 能看见的）
#     格式：Package: <name>
declare -A IN_PACKAGEINFO=()
if [ -f tmp/.packageinfo ]; then
  while IFS= read -r line; do
    case "$line" in
Package:*)
      _p="${line#Package: }"
      IN_PACKAGEINFO["${_p%%[[:space:]]*}"]=1 ;;
    esac
  done < tmp/.packageinfo
fi

# (C) 配置层：.config 里真正 =y 的
declare -A IN_CONFIG=()
if [ -f .config ]; then
  while IFS= read -r line; do
    case "$line" in
    CONFIG_PACKAGE_*=y)
      _k="${line#CONFIG_PACKAGE_}"
      IN_CONFIG["${_k%=y}"]=1 ;;
    esac
  done < .config
fi

echo "[物理层] package/ 下有 Makefile 的第三方包: ${#HAVE_MAKEFILE[@]}"
echo "[索引层] tmp/.packageinfo 收录总包数: ${#IN_PACKAGEINFO[@]}"
n_cfg=$(grep -cE "^CONFIG_PACKAGE_luci-app-[a-zA-Z0-9_-]+=y" .config 2>/dev/null | head -1)
n_i18n=$(grep -cE "^CONFIG_PACKAGE_luci-i18n-[a-zA-Z0-9_-]+=y" .config 2>/dev/null | head -1)
n_cfg=${n_cfg:-0}; n_i18n=${n_i18n:-0}
echo "[配置层] .config 内luci-app=$n_cfg (基线 $EXPECT_LUCI_APP) / luci-i18n=$n_i18n (基线 $EXPECT_LUCI_I18N)"
echo ""

# ---------- 2. 逐个判定，分类根因 ----------
# 分类：
#   MISS_INDEX   = 有 Makefile 但 .packageinfo 没收录 -> 索引缓存过期（主因）
#   MISS_CONFIG  = 索引里有但 .config 没选中     -> 依赖链断裂/配置被 defconfig 丢弃
#   OK=三层都在
declare -a MISS_INDEX=() MISS_CONFIG=() MISS_FILE=() MISS_NESTED=() OK=()
for k in $REQUIRED_PACKAGES; do
  if [ ! -f "package/$k/Makefile" ]; then
    # 检测多级嵌套：package/<k>/<子>/<k>/Makefile（实测 sbwml/luci-app-alist
    # 顶层是壳，真正包在 alist/luci-app-alist/ 两层下）
    _nested=$(find "package/$k" -maxdepth 3 -name Makefile -path "*/$k/Makefile" 2>/dev/null | head -1)
    if [ -n "$_nested" ]; then
      # 有嵌套包 → 不算缺文件，但必须拍平后才进Kconfig
      if [ -z "${IN_PACKAGEINFO[$k]:-}" ]; then
        MISS_NESTED+=("$k  (需拍平: ${_nested#package/})")
      elif [ -z "${IN_CONFIG[$k]:-}" ]; then
        MISS_CONFIG+=("$k")
      else
        OK+=("$k")
      fi
    elif [ -n "${IN_PACKAGEINFO[$k]:-}" ]; then
      OK+=("$k")
    else
      MISS_FILE+=("$k")
    fi
    continue
  fi
  if [ -z "${IN_PACKAGEINFO[$k]:-}" ]; then
    MISS_INDEX+=("$k")
  elif [ -z "${IN_CONFIG[$k]:-}" ]; then
    MISS_CONFIG+=("$k")
  else
    OK+=("$k")
  fi
done

echo "----- 必选插件逐项判定 -----"
for k in "${OK[@]}";       do echo "  [OK]        $k"; done
for k in "${MISS_INDEX[@]:-}";  do [ -n "$k" ] && echo "  [缺索引]    $k  ← 有 Makefile 但 kconfig 不认识"; done
for k in "${MISS_NESTED[@]:-}"; do [ -n "$k" ] && echo "  [待拍平]    $k"; done
for k in "${MISS_CONFIG[@]:-}"; do [ -n "$k" ] && echo "  [缺配置]    $k  ← 索引有但未被选中"; done
for k in "${MISS_FILE[@]:-}";   do [ -n "$k" ] && echo "  [缺文件]    $k  ← clone 失败或地址失效"; done
echo ""

# ---------- 3. 额外：找出所有"有 Makefile 但 kconfig 不认识"的包 ----------
# 这是最有价值的输出：它直接告诉你哪些插件被静默丢弃了
declare -a ORPHAN=()
for n in "${HAVE_MAKEFILE[@]}"; do
  case " $OFFICIAL " in *" $n "*) continue ;; esac
  [ -z "${IN_PACKAGEINFO[$n]:-}" ] && ORPHAN+=("$n")
done
if [ "${#ORPHAN[@]}" -gt 0 ]; then
  echo "----- 孤儿包（Makefile 存在但 kconfig 完全不认识，共 ${#ORPHAN[@]} 个）-----"
  for n in "${ORPHAN[@]}"; do echo "  $n"; done
  echo ""
fi

# ---------- 4. 判定与修复建议 ----------
FAILED=0

if [ "${#ORPHAN[@]}" -gt 0 ]; then
  FAILED=1
  echo "::error::根因A —— tmp/.packageinfo 索引缓存过期"
  echo "  有 ${#ORPHAN[@]} 个包有Makefile 但 Kconfig 从未见过，"
  echo "  make defconfig 会把它们当未知符号静默丢弃。"
  echo "  修复：在拍平/clone 之后、make defconfig 之前执行↓"
  echo ""
  echo "    rm -f tmp/.packageinfo tmp/.config-package.in"
  echo "    make defconfig"
  echo ""
  echo "  （或直接 rm -rf tmp/.packageinfo 后重新 make defconfig）"
  echo ""
fi

if [ "${#MISS_NESTED[@]}" -gt 0 ]; then
  FAILED=1
  echo "::error::根因C —— 多级嵌套包未拍平"
  echo "  以下包的 Makefile 藏在子目录里，OpenWrt 只扫package/*/Makefile 一层："
  for k in "${MISS_NESTED[@]}"; do echo "    $k"; done
  echo "  修复：拍平后再重建索引（见根因A 的 rm tmp/.packageinfo）"
  echo ""
fi

if [ "${#MISS_CONFIG[@]}" -gt 0 ] || [ "${#MISS_FILE[@]}" -gt 0 ]; then
  FAILED=1
  echo "::error::根因B —— 依赖链断裂或包体缺失（索引正常但未被选中）"
  echo "  缺配置: ${MISS_CONFIG[*]:-无}"
  echo "  缺文件: ${MISS_FILE[*]:-无}"
  echo "  修复方向："
  echo "   1) 确认 .config 里有 CONFIG_ALL=y（未开时仅显式可见项入选）"
  echo "   2) make package/<pkg>/prepare V=s 看依赖是否 unmet"
  echo "   3) 检查这些包是否需要先装 feeds 里的基础包"
  echo ""
fi

# 数量基线仅作参考，不作为唯一判据（历史上反复误判）
if [ "$n_cfg" -lt "$EXPECT_LUCI_APP" ] || [ "$n_i18n" -lt "$EXPECT_LUCI_I18N" ]; then
  echo "::warning::数量基线未达标: luci-app $n_cfg/$EXPECT_LUCI_APP, i18n $n_i18n/$EXPECT_LUCI_I18N"
  echo "  （基线仅供参考；若上面必选插件全部 OK，可放行编译）"
  echo ""
fi

if [ "$FAILED" -eq 0 ]; then
  echo "=============================================="
  echo " ✓ 必选插件全部就位（${#OK[@]} 个包），可以开编"
  echo "=============================================="
else
  echo "=============================================="
  echo " ✗ 检测到插件缺失，编译无法产出预期固件"
  echo "=============================================="
  FAILED=1
fi

# ============================================================
# 科学上网插件版本新鲜度核查
# ------------------------------------------------------------
# 用户明确要求："保证科学上网的几个插件是最新的"
# 这里比对 package/ 下实际 clone 到的 commit 与上游 master/main
# 最新 commit，不一致就报警。
# 上游地址已按 2026-10 实测修正：
#   passwall 系列原 xiaorouji/* 已 404，迁移到 Openwrt-Passwall/*
# ============================================================
echo ""
echo "=============================================="
echo " 科学上网插件版本新鲜度核查"
echo "=============================================="

#格式：本地目录|上游仓库|上游分支|显示名
SCI="
package/luci-app-passwall|Openwrt-Passwall/openwrt-passwall|main|passwall
package/luci-app-passwall2|Openwrt-Passwall/openwrt-passwall2|main|passwall2
package/openwrt-passwall|Openwrt-Passwall/openwrt-passwall-packages|main|passwall核心库
package/luci-app-openclash|vernesong/OpenClash|master|openclash
package/luci-app-ssr-plus|fw876/helloworld|dev|ssr-plus
package/luci-app-smartdns|pymumu/luci-app-smartdns|master|smartdns
package/luci-app-mosdns|sbwml/luci-app-mosdns|main|mosdns
package/luci-app-alist|sbwml/luci-app-alist|main|alist
"

STALE=0
for row in $SCI; do
  dir=$(echo "$row" | cut -d'|' -f1)
  repo=$(echo "$row" | cut -d'|' -f2)
  br=$(echo "$row" | cut -d'|' -f3)
  name=$(echo "$row" | cut -d'|' -f4)

  if [ ! -d "$dir/.git" ]; then
    echo "  [缺失] $name  ($dir 未 clone 成功)"
    STALE=$((STALE+1))
    continue
  fi

  local_sha=$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)
  remote_sha=$(git ls-remote "https://github.com/$repo.git" "refs/heads/$br" 2>/dev/null | cut -c1-7)

  if [ -z "$remote_sha" ]; then
    echo "  [?] $name  无法查询上游（$repo/$br），跳过比对"
    continue
  fi

  if [ "$local_sha" = "$remote_sha" ]; then
    echo "  [最新] $name  $local_sha  ← 与上游 $br 一致"
  else
    echo "  [过期] $name  本地=$local_sha  上游$br=$remote_sha  ← 建议重新clone"
    STALE=$((STALE+1))
  fi
done

if [ "$STALE" -gt 0 ]; then
  echo "::warning::有 $STALE 个科学上网插件缺失或版本落后"
  echo "  修复：删除对应目录后重跑工作流即可拿到最新（脚本用 --depth=1 克隆默认取最新）"
else
  echo "  ✓ 科学上网插件全部为上游最新"
fi
echo ""
exit $FAILED
