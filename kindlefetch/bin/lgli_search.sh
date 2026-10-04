#!/bin/sh

# Search Library Genesis and emit the same JSON structure as the Anna's
# Archive scraper (plus a "src" marker so the source picker routes to
# lgli_download). Echoes the last page number on success.
# search_results.json is written as a side effect.
lgli_search() {
    local query="$1"
    local page="${2:-1}"

    local enc_query
    enc_query="$(urlencode "$query")"
    local url="$LGLI_URL/index.php?req=${enc_query}&curtab=f&page=${page}"

    local http_code curl_exit html_content
    http_code="$(curl -s -L --max-time 30 \
        -o "$TMP_DIR"/lgli_search_page.html \
        -w '%{http_code}' \
        -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64)" \
        "$url")"
    curl_exit=$?
    html_content="$(cat "$TMP_DIR"/lgli_search_page.html 2>/dev/null)"
    rm -f "$TMP_DIR"/lgli_search_page.html

    if [ "$curl_exit" -ne 0 ]; then
        echo "Library Genesis request failed (curl exit code $curl_exit)" >&2
        return 1
    fi

    if [ "$http_code" != "200" ]; then
        echo "Library Genesis returned HTTP $http_code" >&2
        return 1
    fi

    if ! echo "$html_content" | grep -q 'new Paginator('; then
        echo "No results found on Library Genesis for '$query'." >&2
        echo "1"
        return 0
    fi

    # new Paginator("id", TOTAL, PER_PAGE, CURRENT, "url&prefix")
    local pag
    pag="$(echo "$html_content" | grep -oE 'new Paginator\("[^"]*", *[0-9]+, *[0-9]+' | head -1)"
    local nums
    nums="$(echo "$pag" | sed 's/^new Paginator("[^"]*", *//' | grep -oE '[0-9]+')"
    local total="$(echo "$nums" | sed -n 1p)"
    local per="$(echo "$nums" | sed -n 2p)"
    [ -z "$total" ] && total=0
    [ -z "$per" ] && per=25

    local last_page=$(( (total + per - 1) / per ))
    [ "$last_page" -lt 1 ] && last_page=1

    local books
    books="$(echo "$html_content" | awk '
        BEGIN { RS = "</tr>"; count = 0; print "[" }
        {
            if ($0 !~ /md5=[a-f0-9]{32}/) next

            # md5 (first download link in the row)
            md5 = ""
            if (match($0, /md5=[a-f0-9]{32}/)) md5 = substr($0, RSTART + 4, 32)

            # title (edition tooltip: "Add/Edit : ...; ID: N<br>EDITION TITLE")
            title = ""
            if (match($0, /Add\/Edit : [^"]*<br>[^"]*/)) {
                t = substr($0, RSTART, RLENGTH)
                if (match(t, /<br>[^"]*/)) title = substr(t, RSTART + 4, RLENGTH - 4)
            }
            if (title == "") next

            # fixed cell layout: 1=title, 2=author, 3=publisher, 4=year,
            # 5=language, 6=pages, 7=size, 8=extension, 9=mirrors
            n = split($0, c, "</td>")
            author = (n >= 2) ? c[2] : ""
            pub = (n >= 3) ? c[3] : ""
            yr = (n >= 4) ? c[4] : ""
            lang = (n >= 5) ? c[5] : ""
            size = (n >= 7) ? c[7] : ""
            ext = (n >= 8) ? c[8] : ""

            gsub(/<[^>]*>/, "", title)
            gsub(/<[^>]*>/, "", author)
            gsub(/<[^>]*>/, "", pub)
            gsub(/<[^>]*>/, "", yr)
            gsub(/<[^>]*>/, "", lang)
            gsub(/<[^>]*>/, "", size)
            gsub(/<[^>]*>/, "", ext)
            gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", title)
            gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", author)
            gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", pub)
            gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", yr)
            gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", lang)
            gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", size)
            gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", ext)

            gsub(/&lt;/, "<", title); gsub(/&gt;/, ">", title); gsub(/&quot;/, "\"", title); gsub(/&#39;/, "\x27", title); gsub(/&amp;/, "\\&", title)
            gsub(/&lt;/, "<", author); gsub(/&gt;/, ">", author); gsub(/&quot;/, "\"", author); gsub(/&#39;/, "\x27", author); gsub(/&amp;/, "\\&", author)
            gsub(/&lt;/, "<", pub); gsub(/&gt;/, ">", pub); gsub(/&quot;/, "\"", pub); gsub(/&#39;/, "\x27", pub); gsub(/&amp;/, "\\&", pub)

            # description: "Publisher, Year, Language (Size)"
            desc = pub
            if (yr != "") { if (desc != "") desc = desc ", "; desc = desc yr }
            if (lang != "") { if (desc != "") desc = desc ", "; desc = desc lang }
            if (size != "") { if (desc != "") desc = desc " ("; desc = desc size ")" }

            gsub(/"/, "\\\"", title)
            gsub(/"/, "\\\"", author)
            gsub(/"/, "\\\"", desc)

            if (count > 0) printf ",\n"
            printf "  {\"author\": \"%s\", \"format\": \"%s\", \"md5\": \"%s\", \"src\": \"lgli\", \"title\": \"%s\", \"description\": \"%s\"}", author, ext, md5, title, desc
            count++
        }
        END { print "\n]" }
    ')"

    echo "$books" > "$TMP_DIR"/search_results.json
    persist_search_results

    local book_count
    book_count="$(echo "$books" | grep -o '"title":' | wc -l)"
    if [ "$book_count" -eq 0 ]; then
        echo "No results found on Library Genesis for '$query'." >&2
    fi

    echo "$last_page"
}
