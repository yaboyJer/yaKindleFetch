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

    printf '\nFetching download page...\n'
    # libgen's servers are overloaded at times and answer with transient
    # errors (HTTP 500, "max_user_connections" DB errors). Retry a few
    # times before giving up, and check the HTTP status so a server error
    # page is never mistaken for a book page.
    local page_file="$TMP_DIR"/lgli_ads_page.html
    local http_code curl_exit attempt=1
    while [ "$attempt" -le 3 ]; do
        http_code="$(curl -s -L --max-time 60 -o "$page_file" -w '%{http_code}' \
            -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64)" \
            "$LGLI_URL/ads.php?md5=$md5")"
        curl_exit=$?
        if [ "$curl_exit" -eq 0 ] && [ "$http_code" = "200" ] && [ -s "$page_file" ]; then
            break
        fi
        if [ "$attempt" -lt 3 ]; then
            echo "Server error (HTTP $http_code, curl exit $curl_exit). Retrying in 10s..."
            sleep 10
        fi
        attempt=$((attempt + 1))
    done

    if [ "$attempt" -gt 3 ]; then
        echo "Failed to fetch book page (last HTTP status: $http_code)." >&2
        echo "Library Genesis is likely overloaded - try again in a few minutes." >&2
        rm -f "$page_file"
        return 1
    fi

    local lgli_content
    lgli_content="$(cat "$page_file")"
    rm -f "$page_file"

    local download_link
    download_link="$(echo "$lgli_content" | grep -o -m 1 'href="[^"]*get\.php[^"]*"' | cut -d'"' -f2)"

    if [ -z "$download_link" ]; then
        echo "No download link found for this md5 (book may not be on this mirror)." >&2
        return 1
    fi

    local download_url="$LGLI_URL/$download_link"
    echo "Downloading from: $download_url"
    
    printf '\nProgress (Press Ctrl + c to stop):\n'

    if curl -# -L -o "$final_location" "$download_url"; then
        printf '\nDownload successful!\n'
        echo "Saved to: $final_location"
        return 0
    
    else
        printf '\nDownload failed.' >&2
        return 1
    fi
}