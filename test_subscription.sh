#!/usr/bin/env bash
# 订阅链接流量头验证脚本
# 用法: ./test_subscription.sh "你的订阅链接"
# 说明: 用 GET 请求 + 完整伪装头遍历主流客户端 UA，找出哪个能返回 Subscription-Userinfo
set -uo pipefail

URL="${1:-}"
if [[ -z "$URL" ]]; then
  echo "用法: $0 \"订阅链接\""
  echo '示例: ./test_subscription.sh "https://example.com/api/v1/client/subscribe?token=xxxx"'
  exit 1
fi

# 主流代理客户端 User-Agent
UAs=(
  "clash"
  "clash-verge/v1.5.11"
  "clash.meta"
  "mihomo/v1.18.0"
  "ClashforWindows/0.20.39"
  "ClashX/1.117.1"
  "Surge/4.9.0 (iPhone; iOS 17.0; Scale/3.00)"
  "Quantumult%20X/1.2.0 (iPhone; iOS 17.0; Scale/3.00)"
  "shadowrocket"
  "sing-box"
)

echo "测试订阅链接: $URL"
echo "========================================"

found=0
hit_ua=""
hit_raw=""

for ua in "${UAs[@]}"; do
  printf "\n→ UA: %s\n" "$ua"
  # 关键: 用 GET 请求(-D - -o /dev/null), 而非 HEAD(-I)
  # 很多机场只在 GET 时返回 Subscription-Userinfo
  result=$(curl -sL -D - -o /dev/null \
    -H "User-Agent: $ua" \
    -H "Accept: */*" \
    -H "Accept-Language: zh-CN,zh;q=0.9" \
    --connect-timeout 10 \
    --max-time 20 \
    "$URL" 2>/dev/null | grep -i "subscription-userinfo" || true)

  if [[ -n "$result" ]]; then
    echo "  [命中] $result"
    found=1
    hit_ua="$ua"
    hit_raw="$result"
    break
  else
    echo "  [未返回] Subscription-Userinfo"
  fi
done

echo ""
echo "========================================"
if [[ $found -eq 1 ]]; then
  echo "结论: 订阅链接可返回流量头 ✅"
  echo "命中 UA: $hit_ua"
  echo "原始返回: $hit_raw"
  echo ""
  echo "解析字段(upload/download/total/expire, 单位字节/秒):"
  echo "$hit_raw" | tr ';' '\n' | sed 's/^[[:space:]]*//'
  echo ""
  echo "→ 走订阅链接数据源方案，可开始搭建 Swift 项目。"
else
  echo "结论: 所有 UA 均未返回流量头 ❌"
  echo "→ 可能原因: 机场屏蔽了 header / 需要特定 token / 链接已失效"
  echo "→ 建议改走官网面板数据源方案。"
fi
