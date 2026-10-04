#!/bin/sh
#
# lgli_diag.sh (v3 - exhaustive) - full connection-stack diagnostic
#
# Tests EVERY layer between the Kindle and libgen, layer by layer,
# makes no assumptions, and replicates the exact curl commands the
# yaKindleFetch downloader uses.
#
# Use: copy to /mnt/us/lgli_diag.sh on the Kindle, run:
#   sh /mnt/us/lgli_diag.sh [md5 ...]
# Send back lgli_diag_out.txt.
#
# Privacy: the full report contains personal fields (config values like
# the zlib username and library folder, local IPs/DNS servers, and the
# titles/md5s of your last searches). For sharing with third parties,
# run in redacted mode:
#   sh /mnt/us/lgli_diag.sh --redacted [md5 ...]
# which masks those fields (all network diagnostics stay intact).

OUT="/mnt/us/downloads/lgli_diag_out.txt"
if [ ! -d "/mnt/us/downloads" ]; then
    OUT="/mnt/us/lgli_diag_out.txt"
fi

REDACTED=false
case "${1:-}" in
    --redacted|-r) REDACTED=true; shift ;;
esac

if [ "$REDACTED" = true ]; then
    RAW_OUT="$OUT.raw"
    echo "Diagnostic starting (redacted mode). Report: $OUT"
    echo "This runs a LOT of network tests - it may take a few minutes."
    exec >"$RAW_OUT" 2>&1
else
    echo "Diagnostic starting. Report will be written to: $OUT"
    echo "This runs a LOT of network tests - it may take a few minutes."
    exec >"$OUT" 2>&1
fi

hr() { echo; echo "================================================================"; echo "$1"; echo "================================================================"; }

UA_BROWSER="Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
TIMING='%{time_namelookup} connect=%{time_connect} tls=%{time_appconnect} ttfb=%{time_starttransfer} total=%{time_total} httpver=%{http_version} ip=%{remote_ip}'

# md5s to use for download-stage tests (from search results if available,
# else the known "Shadow & Claw" mobi)
DEFAULT_MD5="570a965a515be4e72b5c7cf3fa0f8b65"

# ---------------------------------------------------------------------------
hr "1. SYSTEM INFO"
echo "Date (local):  $(date)"
echo "Date (UTC):    $(date -u)"
echo "uname:         $(uname -a)"
[ -f /etc/prettyversion.txt ] && echo "Kindle model:  $(cat /etc/prettyversion.txt)"
echo "curl version:  $(curl --version 2>/dev/null | head -1)"
echo "curl features: $(curl -V 2>/dev/null | head -1 | cut -c1-300)"
echo
echo "--- proxy env vars (empty = none) ---"
env | grep -i proxy || echo "(none)"
echo
echo "--- /etc/resolv.conf ---"
cat /etc/resolv.conf 2>/dev/null || echo "(not readable)"
echo
echo "--- /etc/hosts ---"
cat /etc/hosts 2>/dev/null || echo "(not readable)"
echo
echo "--- routing / interfaces ---"
if command -v ip >/dev/null 2>&1; then
    ip -4 addr 2>/dev/null | grep -E 'inet|^[0-9]'
    ip route 2>/dev/null
elif command -v netstat >/dev/null 2>&1; then
    netstat -rn 2>/dev/null
else
    echo "(neither ip nor netstat available)"
fi
echo
echo "--- md5sum available? ---"
command -v md5sum >/dev/null 2>&1 && echo "yes" || echo "NO (file integrity check will be skipped)"

# ---------------------------------------------------------------------------
hr "2. YA KINDLEFETCH INSTALLATION / CONFIG"
KF_DIR=""
for d in /mnt/us/extensions/kindlefetch /mnt/us/downloads/kindlefetch /mnt/us/kindlefetch; do
    [ -d "$d/bin" ] && KF_DIR="$d" && break
done
[ -n "$KF_DIR" ] && { echo "Install dir: $KF_DIR"; [ -f "$KF_DIR/bin/.version" ] && echo "Version:     $(cat "$KF_DIR/bin/.version")"; }
CFG="$KF_DIR/bin/kindlefetch_config"
if [ -f "$CFG" ]; then
    echo "--- config ---"; cat "$CFG"
    LGLI_URL=$(sed -n 's/^LGLI_URL=//p' "$CFG" | tr -d '"')
    ANNAS_URL=$(sed -n 's/^ANNAS_URL=//p' "$CFG" | tr -d '"')
fi
[ -n "$LGLI_URL" ] || LGLI_URL="https://libgen.li"
[ -n "$ANNAS_URL" ] || ANNAS_URL="https://annas-archive.gl"
echo "LGLI_URL: $LGLI_URL"
echo "ANNAS_URL: $ANNAS_URL"

# ---------------------------------------------------------------------------
hr "3. LAST SEARCH RESULTS"
RESULTS_FILE="/tmp/search_results.json"
if [ ! -f "$RESULTS_FILE" ] && [ -f /mnt/us/.kindlefetch/last_search_results.json ]; then
    echo "NOTE: using persistent copy /mnt/us/.kindlefetch/last_search_results.json"
    RESULTS_FILE="/mnt/us/.kindlefetch/last_search_results.json"
fi
MD5S=""
if [ -f "$RESULTS_FILE" ]; then
    echo "Using: $RESULTS_FILE (modified $(ls -l "$RESULTS_FILE" | awk '{print $6, $7, $8}'))"
    MD5S=$(grep -o '"md5": "[a-f0-9]\{32\}"' "$RESULTS_FILE" | cut -d'"' -f4 | sort -u | head -5)
    echo "md5s: $MD5S" | tr '\n' ' '; echo
    echo "--- first 1500 bytes ---"; head -c 1500 "$RESULTS_FILE"; echo
else
    echo "WARNING: no search results available."
fi
for a in "$@"; do
    case "$a" in *[!a-f0-9]*|"") : ;; *) MD5S="$MD5S
$a" ;; esac
done
MD5S=$(echo "$MD5S" | sed '/^[[:space:]]*$/d' | sort -u)
TEST_MD5=$(echo "$MD5S" | head -1)
[ -n "$TEST_MD5" ] || TEST_MD5="$DEFAULT_MD5"
echo "Primary md5 for download-stage tests: $TEST_MD5"

LGLI_HOST="${LGLI_URL#https://}"
LGLI_HOST="${LGLI_HOST%%/*}"

# ---------------------------------------------------------------------------
hr "4. DNS RESOLUTION"
echo "--- getent hosts (all records) ---"
for h in "$LGLI_HOST" "libgen.la" "libgen.gl" "cdn3.booksdl.lc" "booksdl.lc" "$(echo "$ANNAS_URL" | sed 's#https://##;s#/##')"; do
    echo "host: $h"
    if command -v getent >/dev/null 2>&1; then
        getent hosts "$h" 2>&1 || echo "  (getent: lookup failed)"
    else
        echo "  (getent not available)"
    fi
done
echo
echo "--- consistency: 5 repeated lookups of $LGLI_HOST ---"
i=1
while [ $i -le 5 ]; do
    echo "  try $i: $(getent hosts "$LGLI_HOST" 2>&1 | awk '{print $1}' | tr '\n' ' ')"
    i=$((i+1))
done

# ---------------------------------------------------------------------------
hr "5. TCP + TLS HANDSHAKE (verbose, first 120 lines)"
curl -v --max-time 20 -o /dev/null "https://$LGLI_HOST/" 2>&1 | head -120

# ---------------------------------------------------------------------------
hr "6. TIMING METRICS (default vs HTTP/1.1 vs IPv4-only)"
echo "--- default ---"
curl -s --max-time 30 -o /dev/null -w "$TIMING\n" "https://$LGLI_HOST/" 2>&1
echo "--- forced HTTP/1.1 ---"
curl -s --http1.1 --max-time 30 -o /dev/null -w "$TIMING\n" "https://$LGLI_HOST/" 2>&1
echo "--- forced IPv4 only ---"
curl -s -4 --max-time 30 -o /dev/null -w "$TIMING\n" "https://$LGLI_HOST/" 2>&1
echo "--- forced IPv6 only (expected to fail if no AAAA route) ---"
curl -s -6 --max-time 10 -o /dev/null -w "$TIMING\n" "https://$LGLI_HOST/" 2>&1
echo "    (curl exit: $?)"

# ---------------------------------------------------------------------------
hr "7. FULL RESPONSE HEADERS (GET / and GET ads.php)"
echo "--- GET https://$LGLI_HOST/ ---"
curl -s -D - -o /dev/null --max-time 20 "https://$LGLI_HOST/" 2>&1
echo
echo "--- GET https://$LGLI_HOST/ads.php?md5=$TEST_MD5 ---"
curl -s -D - -o /dev/null --max-time 30 "https://$LGLI_HOST/ads.php?md5=$TEST_MD5" 2>&1

# ---------------------------------------------------------------------------
hr "8. USER-AGENT SENSITIVITY (ads.php)"
echo "--- default curl UA ---"
curl -s --max-time 30 -o /dev/null -w 'http=%{http_code} size=%{size_download}\n' "https://$LGLI_HOST/ads.php?md5=$TEST_MD5"
echo "--- browser UA ---"
curl -s -A "$UA_BROWSER" --max-time 30 -o /dev/null -w 'http=%{http_code} size=%{size_download}\n' "https://$LGLI_HOST/ads.php?md5=$TEST_MD5"
echo "--- empty UA ---"
curl -s -A "" --max-time 30 -o /dev/null -w 'http=%{http_code} size=%{size_download}\n' "https://$LGLI_HOST/ads.php?md5=$TEST_MD5"

# ---------------------------------------------------------------------------
hr "9. STABILITY: ads.php 10x in a row"
i=1
while [ $i -le 10 ]; do
    r=$(curl -s -A "$UA_BROWSER" --max-time 30 -o /dev/null -w 'http=%{http_code} size=%{size_download} total=%{time_total}' "https://$LGLI_HOST/ads.php?md5=$TEST_MD5" 2>&1)
    echo "  attempt $i: $r (exit $?)"
    i=$((i+1))
done

# ---------------------------------------------------------------------------
hr "10. FULL DOWNLOAD PIPELINE (ads.php -> get.php -> file), 5x"
# Replicates the downloader's stages. The browser-UA request is what the
# downloader sends; the no-UA request is a control that detects the CDN's
# User-Agent filtering (it used to serve nginx pages to bare curl).
p_ok=0
p_fail=0
i=1
while [ $i -le 5 ]; do
    echo "--- pipeline attempt $i ---"
    page="/tmp/lgli_diag_p.html"
    code=$(curl -s -L --max-time 60 -o "$page" -w '%{http_code}' \
        -H "User-Agent: $UA_BROWSER" "https://$LGLI_HOST/ads.php?md5=$TEST_MD5")
    echo "  ads.php: http=$code size=$(wc -c < "$page" 2>/dev/null)"
    link=$(grep -o 'href="[^"]*get\.php[^"]*"' "$page" 2>/dev/null | head -1 | cut -d'"' -f2)
    if [ -z "$link" ]; then
        echo "  NO get.php link (server error page?) - skipping file stage"
        head -c 300 "$page" 2>/dev/null; echo
        p_fail=$((p_fail + 1))
    else
        # What the current downloader sends: browser UA
        curl -# -L -A "$UA_BROWSER" -o /tmp/lgli_diag_f.bin -w '  file(browser UA): http=%{http_code} size=%{size_download} final=%{url_effective}\n' "https://$LGLI_HOST/$link" 2>/dev/null
        if command -v md5sum >/dev/null 2>&1; then
            got=$(md5sum /tmp/lgli_diag_f.bin 2>/dev/null | cut -d' ' -f1)
            if [ "$got" = "$TEST_MD5" ]; then
                echo "  INTEGRITY: OK - file md5 matches expected $TEST_MD5"
                p_ok=$((p_ok + 1))
            else
                echo "  INTEGRITY: MISMATCH! expected=$TEST_MD5 got=$got"
                p_fail=$((p_fail + 1))
            fi
        elif head -c 64 /tmp/lgli_diag_f.bin 2>/dev/null | tr -d '\0' | grep -qi 'doctype\|<html'; then
            echo "  INTEGRITY: file is an HTML error page"
            p_fail=$((p_fail + 1))
        else
            echo "  (md5sum unavailable - size/HTML check only)"
            p_ok=$((p_ok + 1))
        fi
        # Control: bare curl (no UA) - detects CDN User-Agent filtering
        curl -s -L -o /tmp/lgli_diag_f2.bin -w '  control(no UA):   http=%{http_code} size=%{size_download}\n' "https://$LGLI_HOST/$link" 2>/dev/null
        if head -c 64 /tmp/lgli_diag_f2.bin 2>/dev/null | tr -d '\0' | grep -qi 'doctype\|<html'; then
            echo "  NOTE: no-UA control received an HTML page - CDN is filtering by User-Agent"
        fi
        rm -f /tmp/lgli_diag_f.bin /tmp/lgli_diag_f2.bin
    fi
    rm -f "$page"
    i=$((i+1))
    sleep 2
done
echo
echo "PIPELINE SUMMARY: $p_ok ok, $p_fail failed (of 5)"

# ---------------------------------------------------------------------------
hr "11. VERBOSE FULL DOWNLOAD (one complete -v -L capture)"
page="/tmp/lgli_diag_p.html"
curl -s -L --max-time 60 -o "$page" -H "User-Agent: $UA_BROWSER" "https://$LGLI_HOST/ads.php?md5=$TEST_MD5"
link=$(grep -o 'href="[^"]*get\.php[^"]*"' "$page" 2>/dev/null | head -1 | cut -d'"' -f2)
if [ -n "$link" ]; then
    curl -v -L --max-time 120 -o /tmp/lgli_diag_f.bin "https://$LGLI_HOST/$link" 2>&1 | head -200
    echo "saved size: $(wc -c < /tmp/lgli_diag_f.bin 2>/dev/null)"
    rm -f /tmp/lgli_diag_f.bin
else
    echo "no get.php link this time (ads.php failed) - raw page head:"
    head -c 300 "$page"; echo
fi
rm -f "$page"

# ---------------------------------------------------------------------------
hr "12. MIRROR PROBE (each mirror: / , ads.php, timing)"
for url in "https://libgen.li" "https://libgen.la" "https://libgen.gl"; do
    echo "--- $url ---"
    curl -s -A "$UA_BROWSER" --max-time 20 -o /dev/null -w '  GET /: http=%{http_code} '"$TIMING"'\n' "$url/" 2>&1
    mp="/tmp/lgli_diag_m.html"
    curl -s -A "$UA_BROWSER" --max-time 30 -o "$mp" -w '  GET ads.php: http=%{http_code} size=%{size_download}\n' "$url/ads.php?md5=$TEST_MD5" 2>&1
    grep -o 'href="[^"]*get\.php[^"]*"' "$mp" 2>/dev/null | head -1 | sed 's/^/  get.php: /'
    grep -o 'alert-danger[^<]*' "$mp" 2>/dev/null | head -1 | sed 's/^/  SERVER ERROR: /'
    rm -f "$mp"
done

# ---------------------------------------------------------------------------
hr "13. ANNA'S ARCHIVE STATUS"
curl -s -A "$UA_BROWSER" --max-time 20 -o /dev/null -w 'GET /: http=%{http_code}\n' "$ANNAS_URL/" 2>&1
curl -s -A "$UA_BROWSER" -L --max-time 30 -o /tmp/lgli_diag_aa.html -w 'GET /search: http=%{http_code} final=%{url_effective}\n' "$ANNAS_URL/search?q=shadow+and+claw" 2>&1
grep -oiE 'DDoS-Guard|just a moment|captcha' /tmp/lgli_diag_aa.html 2>/dev/null | head -1 | sed 's/^/marker: /'
rm -f /tmp/lgli_diag_aa.html

# ---------------------------------------------------------------------------
hr "14. RAW NETWORK CAPABILITY CHECKS"
echo "--- plain HTTP (port 80) to $LGLI_HOST ---"
curl -s --max-time 15 -o /dev/null -w 'http=%{http_code}\n' "http://$LGLI_HOST/" 2>&1
echo "(exit $?)"
echo
echo "--- TLS to file CDN host directly (cdn3.booksdl.lc) ---"
cdn_host="cdn3.booksdl.lc"
echo "CDN host: $cdn_host"
curl -v --max-time 20 -o /dev/null "https://$cdn_host/" 2>&1 | head -60

# ---------------------------------------------------------------------------
hr "15. HOW TO READ THIS"
cat <<'EOF'
Compare each section against the same tests run from a known-good machine.
Key things to look for:

- S4: does DNS return the SAME IPs a normal machine gets? Repeated lookups
  consistent? (poisoning / wrong resolver would change this)
- S5: TLS handshake complete? which TLS version, ALPN (h2 vs http/1.1)?
  Any certificate warnings? (wrong system clock in S1 breaks cert dates)
- S6: huge time_namelookup = DNS problem; huge tls = handshake problem;
  httpver: is the Kindle getting HTTP/2 while other machines get 1.1?
- S7: which Server/CDN headers come back (Cloudflare ray, nginx version)?
  Do they match a normal machine? Content-Encoding present?
- S8: does the response change with User-Agent? (bot filtering)
- S9: failure rate of ads.php over 10 tries (baseline for flakiness)
- S10: THE important one - file integrity. Healthy result: "PIPELINE
      SUMMARY: 5 ok, 0 failed" with every INTEGRITY line OK. A MISMATCH
      means the bytes arriving are NOT the real file (proxy/CDN problem).
      The NOTE about the no-UA control means the CDN is filtering by
      User-Agent (the downloader sends a browser UA, so this alone is not
      fatal - but combined with INTEGRITY failures it is).
- S11: the full verbose transcript of one download - shows every hop,
      every header, redirect by redirect.
- S14: can the Kindle even reach port 80 / the CDN host directly?
EOF
hr "END OF REPORT"
echo "Finished: $(date)"

if [ "$REDACTED" = true ]; then
    # Mask personal fields; keep all network diagnostics intact.
    {
        echo "NOTE: redacted mode - personal fields are masked with ***"
        sed -E \
            -e 's/("title": ")[^"]*/\1***/g' \
            -e 's/("author": ")[^"]*/\1***/g' \
            -e 's/[a-f0-9]{32}/***/g' \
            -e 's/^(ZLIB_USERNAME=).*/\1"**"/' \
            -e 's/^(KINDLE_DOCUMENTS=).*/\1"**"/' \
            -e 's/^(KINDLE_DOCUMENTS: ).*/\1***/' \
            -e 's/(inet )[0-9]{1,3}(\.[0-9]{1,3}){3}.*/\1***/g' \
            -e 's/(nameserver )[0-9.]+/\1***/g' \
            -e 's/^([0-9]{1,3}\.){3}[0-9]{1,3}\/[0-9]+ dev .*/route entry ***/' \
            -e 's/^default via [0-9.]+.*/default via ***/' \
            "$RAW_OUT"
    } > "$OUT"
    rm -f "$RAW_OUT"
    echo "Redacted report written to: $OUT" > /dev/tty 2>/dev/null
fi

exit 0
