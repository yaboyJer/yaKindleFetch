#!/bin/sh

# Search Anna's Archive through the official Open API
# (https://annas-archive.org/help/annas-api).
#
# The HTML frontend sits behind bot/DDoS protection that rejects plain
# curl, but the JSON API is explicitly provided for programmatic access
# and is not behind the challenge layer. The free API hosts enforce a
# strict per-IP rate limit (tens of requests per hour), so every call
# here must correspond to a real user action (a search page), never a
# probe or retry loop.

AA_API_MIRRORS="https://api.annas-archive.org https://api5.annas-archive.org https://300.annas-archive.org"

# Print the API base URLs to try: the user-configured one first (if set
# in the settings menu), then the public mirrors in preference order.
aa_api_hosts() {
    local h
    if [ -n "$AA_API_URL" ]; then
        echo "$AA_API_URL"
    fi
    for h in $AA_API_MIRRORS; do
        [ -n "$AA_API_URL" ] && [ "$h" = "$AA_API_URL" ] && continue
        echo "$h"
    done
}

# Search the Anna's Archive API and write search_results.json in the same
# JSON structure the HTML scraper produces (plus nothing extra, so the
# display and source-picker code work unchanged). Echoes the last page
# number on stdout. Returns 0 on success (including zero results) and 1
# when every API host is unreachable or errors.
aa_api_search() {
    local query="$1"
    local page="${2:-1}"

    local filters=""
    [ -f "$CURRENT_PARAMS_FILE" ] && filters="$(cat "$CURRENT_PARAMS_FILE")"

    local enc_query host resp_file http_code curl_exit resp status
    enc_query="$(urlencode "$query")"
    resp_file="$TMP_DIR"/aa_api_response.json

    for host in $(aa_api_hosts); do
        http_code="$(curl -s --max-time 45 \
            -o "$resp_file" \
            -w '%{http_code}' \
            -H "Accept: application/json" \
            -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64)" \
            "$host/v3/scrape/search?q=${enc_query}&page=${page}&response_type=json${filters}")"
        curl_exit=$?

        if [ "$curl_exit" -ne 0 ]; then
            echo "Anna's Archive API at $host unreachable (curl exit $curl_exit)." >&2
            rm -f "$resp_file"
            continue
        fi
        if [ "$http_code" != "200" ]; then
            echo "Anna's Archive API at $host returned HTTP $http_code." >&2
            head -c 300 "$resp_file" >&2 2>/dev/null
            echo >&2
            rm -f "$resp_file"
            continue
        fi

        resp="$(cat "$resp_file")"
        rm -f "$resp_file"
        status="$(get_json_value "$resp" "status")"
        if [ "$status" != "ok" ]; then
            echo "Anna's Archive API at $host reported an error:" >&2
            echo "$resp" | head -c 300 >&2
            echo >&2
            continue
        fi

        # Success: convert the API results into the shared JSON structure.
        local books book_count result_count last_page
        books="$(echo "$resp" | awk '
        BEGIN {
            RS = "}"
            count = 0
            in_results = 0
            print "["
        }
        # Extract a string value for "key" from a record, unescaping
        # JSON escapes and re-escaping quotes for our output format.
        function jget(rec, key,    pos, rest, val) {
            pos = index(rec, "\"" key "\"")
            if (pos == 0) return ""
            rest = substr(rec, pos + length(key) + 2)
            if (match(rest, /^[[:space:]]*:[[:space:]]*"/) == 0) return ""
            rest = substr(rest, RSTART + RLENGTH)
            if (substr(rest, 1, 1) == "\"") return ""
            if (match(rest, /(^|[^\\])"/) == 0) return ""
            val = substr(rest, 1, RSTART)
            gsub(/\\\"/, "\"", val)
            gsub(/\\n/, " ", val)
            gsub(/\\\\/, "\\", val)
            gsub(/\"/, "\\\"", val)
            return val
        }
        function jnum(rec, key,    pos, rest) {
            pos = index(rec, "\"" key "\"")
            if (pos == 0) return ""
            rest = substr(rec, pos + length(key) + 2)
            if (match(rest, /^[[:space:]]*:[[:space:]]*/) == 0) return ""
            rest = substr(rest, RSTART + RLENGTH)
            if (match(rest, /^[0-9]+/) == 0) return ""
            return substr(rest, 1, RLENGTH)
        }
        {
            if ($0 ~ /"results"[[:space:]]*:[[:space:]]*\[/) in_results = 1
            if (!in_results) next
            # "d_name" only appears on top-level results, which also
            # skips the nested per-result objects (e.g. "ia").
            if ($0 !~ /"d_name"/ || $0 !~ /"md5"/) next

            md5 = jget($0, "md5")
            if (md5 !~ /^[a-f0-9]{32}$/) next

            title = jget($0, "title")
            if (title == "") title = jget($0, "d_name")
            if (title == "") next

            author = jget($0, "author")
            format = jget($0, "content_type")
            publisher = jget($0, "publisher")
            year = jnum($0, "publish_year")
            if (year == "") year = jget($0, "publish_year")

            lang = ""
            if (match($0, /"languages"[[:space:]]*:[[:space:]]*\[[^]]*\]/)) {
                lang = substr($0, RSTART, RLENGTH)
                sub(/^[^\[]*\[/, "", lang)
                sub(/\].*$/, "", lang)
                gsub(/[" ,]/, "", lang)
            }

            desc = publisher
            if (year != "") { if (desc != "") desc = desc ", "; desc = desc year }
            if (lang != "") { if (desc != "") desc = desc ", "; desc = desc lang }

            if (count > 0) printf ",\n"
            printf "  {\"author\": \"%s\", \"format\": \"%s\", \"md5\": \"%s\", \"title\": \"%s\", \"description\": \"%s\"}", author, format, md5, title, desc
            count++
        }
        END { print "\n]" }
        ')"

        echo "$books" > "$TMP_DIR"/search_results.json
        persist_search_results

        book_count="$(echo "$books" | grep -o '"title":' | wc -l)"
        result_count="$(get_json_value "$resp" "result_count")"
        [ -z "$result_count" ] && result_count="$(get_json_value "$resp" "total_count")"
        case "$result_count" in
            ''|*[!0-9]*) result_count="$book_count" ;;
        esac

        # The API page size is whatever the host chose to return; derive
        # the last page from that so this stays correct across mirrors.
        if [ "$book_count" -gt 0 ]; then
            last_page=$(( (result_count + book_count - 1) / book_count ))
        else
            last_page=1
        fi
        [ "$last_page" -lt 1 ] && last_page=1

        echo "$last_page"
        return 0
    done

    return 1
}
