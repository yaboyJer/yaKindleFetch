#!/bin/sh

lgli_download() {
    local index="$1"
    
    if [ ! -f "$TMP_DIR/search_results.json" ]; then
        echo "No search results found" >&2
        return 1
    fi
    
    local book_info="$(awk -v i="$index" 'BEGIN{RS="\\{"; FS="\\}"} NR==i+2{print $1}' "$TMP_DIR"/search_results.json)"
    if [ -z "$book_info" ]; then
        echo "Invalid book selection"
        return 1
    fi
    
    local md5="$(get_json_value "$book_info" "md5")"
    local title="$(get_json_value "$book_info" "title")"
    local format="$(get_json_value "$book_info" "format")"

    if [ -z "$md5" ] || [ "$md5" = "null" ]; then
        echo "Could not read md5 for the selected book (search results may be stale). Re-run the search and try again."
        return 1
    fi
    
    printf "\nDownloading: $title"

    local clean_title="$(sanitize_filename "$title" | tr -d ' ')"

    printf '\nDo you want to change filename? [y/N]: '
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        echo -n "Enter your custom filename: "
        read -r custom_filename
        if [ -n "$custom_filename" ]; then
            local clean_title="$(sanitize_filename "$custom_filename" | tr -d ' ')"
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

    if [ "$CREATE_SUBFOLDERS" = "true" ]; then
        local book_folder="$KINDLE_DOCUMENTS/$clean_title"
        if ! mkdir -p "$book_folder"; then
            echo "Failed to create folder '$book_folder'" >&2
            return 1
        fi
        local final_location="$book_folder/$clean_title.$format"
    else
        local final_location="$KINDLE_DOCUMENTS/$clean_title.$format"
    fi

    if [ -e "$final_location" ] && [ ! -w "$final_location" ]; then
        echo "No permission to overwrite $final_location" >&2
        return 1
    fi

    # libgen's mirrors run independent backends and fail independently
    # (DB connection limits, per-mirror CDN issues). Try the configured
    # mirror first, then fall back to the other known mirrors.
    local mirror_list="$LGLI_URL"
    local m
    for m in "https://libgen.li" "https://libgen.la" "https://libgen.gl"; do
        case " $mirror_list " in
            *" $m "*) ;;
            *) mirror_list="$mirror_list $m" ;;
        esac
    done

    local download_url=""
    local mirror http_code curl_exit attempt
    for mirror in $mirror_list; do
        printf '\nFetching download page from %s ...\n' "$mirror"
        local page_file="$TMP_DIR"/lgli_ads_page.html
        attempt=1
        while [ "$attempt" -le 2 ]; do
            http_code="$(curl -s -L --max-time 60 -o "$page_file" -w '%{http_code}' \
                -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64)" \
                "$mirror/ads.php?md5=$md5")"
            curl_exit=$?
            if [ "$curl_exit" -eq 0 ] && [ "$http_code" = "200" ] && [ -s "$page_file" ]; then
                break
            fi
            if [ "$attempt" -lt 2 ]; then
                echo "Server error (HTTP $http_code, curl exit $curl_exit). Retrying in 5s..."
                sleep 5
            fi
            attempt=$((attempt + 1))
        done

        local lgli_content download_link
        lgli_content="$(cat "$page_file" 2>/dev/null)"
        rm -f "$page_file"
        download_link="$(echo "$lgli_content" | grep -o -m 1 'href="[^"]*get\.php[^"]*"' | cut -d'"' -f2)"

        if [ -n "$download_link" ]; then
            download_url="$mirror/$download_link"
            break
        fi
        echo "No usable page from $mirror (HTTP $http_code), trying next mirror..."
    done

    if [ -z "$download_url" ]; then
        echo "Failed to fetch book page from any mirror (last HTTP status: $http_code)." >&2
        echo "Library Genesis is likely overloaded - try again in a few minutes." >&2
        return 1
    fi

    echo "Downloading from: $download_url"
    
    printf '\nProgress (Press Ctrl + c to stop):\n'

    # The file CDN (e.g. cdn3.booksdl.lc) is flaky: depending on node and
    # timing it can answer HTTP 503, or even its raw nginx welcome page with
    # a "successful" 200. Validate what was actually saved and retry when
    # it is not a real book file.
    local dl_code dl_size dl_attempt=1
    while [ "$dl_attempt" -le 3 ]; do
        dl_code="$(curl -# -L -o "$final_location" -w '%{http_code}' "$download_url")"
        dl_size=$(wc -c < "$final_location" 2>/dev/null)
        dl_size=${dl_size:-0}

        if [ "$dl_code" = "200" ] && [ "$dl_size" -gt 2048 ]; then
            local first_bytes
            first_bytes="$(head -c 15 "$final_location" | tr -d '\0')"
            case "$first_bytes" in
                "<!DOCTYPE"*|"<html"*|"<HTML"*)
                    echo "Downloaded file is an HTML error page, not the book."
                    ;;
                *)
                    printf '\nDownload successful!\n'
                    echo "Saved to: $final_location"
                    return 0
                    ;;
            esac
        else
            echo "Download failed (HTTP $dl_code, $dl_size bytes)."
        fi

        rm -f "$final_location"
        if [ "$dl_attempt" -lt 3 ]; then
            echo "Retrying in 10s..."
            sleep 10
        fi
        dl_attempt=$((dl_attempt + 1))
    done

    printf '\nDownload failed after 3 attempts. The file CDN may be overloaded - try again later or pick a different edition.' >&2
    rm -f "$final_location"
    return 1
}