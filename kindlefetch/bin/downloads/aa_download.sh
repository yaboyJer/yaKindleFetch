#!/bin/sh

# Download a book through the Anna's Archive Open API using its md5.
# Works for any md5 in AA's database, including books whose search
# result came from the HTML frontend or the Library Genesis fallback
# (AA indexes libgen), so this is offered as a source for every result
# and is the preferred download path.
aa_download() {
    local index="$1"

    if [ ! -f "$TMP_DIR/search_results.json" ]; then
        echo "No search results found" >&2
        return 1
    fi

    local book_info
    book_info="$(awk -v i="$index" 'BEGIN{RS="\\{"; FS="\\}"} NR==i+2{print $1}' "$TMP_DIR"/search_results.json)"
    if [ -z "$book_info" ]; then
        echo "Invalid book selection" >&2
        return 1
    fi

    local md5 title format
    md5="$(get_json_value "$book_info" "md5")"
    title="$(get_json_value "$book_info" "title")"
    format="$(get_json_value "$book_info" "format")"

    if [ -z "$md5" ] || [ "$md5" = "null" ]; then
        echo "Could not read md5 for the selected book (search results may be stale). Re-run the search and try again." >&2
        return 1
    fi

    format="$(printf '%s' "$format" | tr '[:upper:]' '[:lower:]')"
    format="${format:-pdf}"

    printf '\nDownloading: %s\n' "$title"

    local clean_title
    clean_title="$(sanitize_filename "$title" | tr -d ' ')"

    printf '\nDo you want to change filename? [y/N]: '
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        printf '\nEnter your custom filename: '
        read -r custom_filename
        if [ -n "$custom_filename" ]; then
            clean_title="$(sanitize_filename "$custom_filename" | tr -d ' ')"
        else
            echo "Invalid filename. Proceeding with original filename."
        fi
    else
        echo "Proceeding with original filename."
    fi

    if [ ! -w "$KINDLE_DOCUMENTS" ]; then
        echo "No write permission in $KINDLE_DOCUMENTS" >&2
        return 1
    fi

    local tmp_file="$TMP_DIR"/aa_download_tmp
    local host dl_code curl_exit dl_size final_url
    for host in $(aa_api_hosts); do
        printf '\nRequesting file from %s ...\n' "$host"

        # The API 302-redirects to the actual file on a CDN; -w captures
        # both the status and the final URL (whose filename carries the
        # real extension).
        dl_code="$(curl -# -L --max-time 600 -o "$tmp_file" \
            -w '%{http_code} %{url_effective}' \
            -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64)" \
            "$host/download/aa/$md5")"
        curl_exit=$?
        final_url="${dl_code#* }"
        dl_code="${dl_code%% *}"
        dl_size="$(wc -c < "$tmp_file" 2>/dev/null)"
        dl_size="${dl_size:-0}"

        if [ "$curl_exit" -ne 0 ] || [ "$dl_code" != "200" ]; then
            echo "Anna's Archive API at $host failed (curl exit $curl_exit, HTTP $dl_code)." >&2
            rm -f "$tmp_file"
            sleep 3
            continue
        fi

        # A real book file is never tiny and never starts with HTML
        # markup; challenge/error pages do.
        if [ "$dl_size" -le 2048 ] || head -c 64 "$tmp_file" | tr -d '\0' | grep -qi 'doctype\|<html'; then
            echo "Got $dl_size bytes that look like an error page, not a book." >&2
            rm -f "$tmp_file"
            sleep 3
            continue
        fi

        # Determine the extension from the redirected-to filename,
        # falling back to the format reported by the search result.
        local ext path base guess
        ext="$format"
        path="${final_url%%\?*}"
        base="${path##*/}"
        case "$base" in
            *.*)
                guess="$(printf '%s' "${base##*.}" | tr '[:upper:]' '[:lower:]')"
                case "$guess" in
                    epub|pdf|mobi|azw|azw3|txt|fb2|djvu|cbr|cbz) ext="$guess" ;;
                esac
                ;;
        esac

        if [ "$CREATE_SUBFOLDERS" = "true" ]; then
            local book_folder="$KINDLE_DOCUMENTS/$clean_title"
            if ! mkdir -p "$book_folder"; then
                echo "Failed to create folder '$book_folder'" >&2
                rm -f "$tmp_file"
                return 1
            fi
            local final_location="$book_folder/$clean_title.$ext"
        else
            local final_location="$KINDLE_DOCUMENTS/$clean_title.$ext"
        fi

        if [ -e "$final_location" ] && [ ! -w "$final_location" ]; then
            echo "No permission to overwrite $final_location" >&2
            rm -f "$tmp_file"
            return 1
        fi

        if mv "$tmp_file" "$final_location"; then
            printf '\nDownload successful!\n'
            echo "Saved to: $final_location"
            return 0
        else
            echo "Failed to move downloaded file into place." >&2
            rm -f "$tmp_file"
            return 1
        fi
    done

    rm -f "$tmp_file"
    echo "Failed to download from any Anna's Archive API host." >&2
    echo "The file may no longer be available - try another source or edition." >&2
    return 1
}
