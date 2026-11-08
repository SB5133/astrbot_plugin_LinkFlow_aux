#!/bin/sh
# 在平板上修复生效 config.yaml 的 sniffer.enable
# 精确匹配: 只改 sniffer: 段之后的第一个 "enable: false" -> "enable: true"
# (不能用 sed 全局替换, 会误伤 dns.enable / mitm.enable 等)
# 注意: su 下 /tmp 可能不存在, 一律用 /data/local/tmp
CFG=/data/data/com.follow.clash/files/config.yaml
WORK=/data/local/tmp

[ -f "$CFG" ] || { echo "CFG_MISSING=1"; exit 0; }

awk '
BEGIN { in_sniffer = 0; fixed = 0 }
/^sniffer:/ { in_sniffer = 1; print; next }
/^[a-zA-Z]/ { if (in_sniffer) in_sniffer = 0 }
{
  if (in_sniffer && !fixed && $0 ~ /^  enable:[ \t]*false/) {
    print "  enable: true"
    fixed = 1
    next
  }
  print
}
END { printf "SNIFF_FIXED=%d\n", fixed > "'"$WORK"'/sniffer_fix.log" }
' "$CFG" > "$WORK/config.new"

if [ -s "$WORK/config.new" ]; then
  cat "$WORK/config.new" > "$CFG"
fi
cat "$WORK/sniffer_fix.log" 2>/dev/null
rm -f "$WORK/config.new" "$WORK/sniffer_fix.log"
