#!/bin/sh

change_dns () {
    RESOLV_FILE="/var/run/resolv.conf"
    
    if [ ! -f "$RESOLV_FILE" ]; then
        exit 1
    fi

    sed -i '/^nameserver/d' "$RESOLV_FILE"

    echo "nameserver 1.1.1.1" >> "$RESOLV_FILE"
    echo "nameserver 1.0.0.1" >> "$RESOLV_FILE"
}

load_config() {
    eval "$(base64 -d "$LINK_CONFIG_FILE")"
    if [ -f "$CONFIG_FILE" ]; then
        . "$CONFIG_FILE"
    else
        first_time_setup
    fi
}

load_version() {
    if [ -f "$VERSION_FILE" ]; then
        cat "$VERSION_FILE"
    else
        echo "Version file wasn't found!"
        sleep 2
        echo "Creating version file"
        sleep 2
        get_version
    fi
}

sanitize_filename() {
    echo "$1" | sed -e 's/[^[:alnum:]\._-]/_/g' -e 's/ /_/g'
}

urlencode() {
    local LC_ALL=C
    local s="$1" out="" c i=0
    while [ "$i" -lt "${#s}" ]; do
        c="${s:$i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) out="$out$c" ;;
            ' ') out="$out+" ;;
            "'") out="$out%27" ;;
            *) out="$out$(printf '%%%02X' "'$c")" ;;
        esac
        i=$((i + 1))
    done
    printf '%s' "$out"
}

get_json_value() {
    echo "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | sed "s/\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\"/\1/" || \
    echo "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*[^,}]*" | sed "s/\"$2\"[[:space:]]*:[[:space:]]*\([^,}]*\)/\1/"
}

ensure_config_dir() {
    local config_dir="$(dirname "$CONFIG_FILE")"
    if [ ! -d "$config_dir" ]; then
        mkdir -p "$config_dir"
    fi
}

cleanup() {
    rm -f "$TMP_DIR"/kindle_books.list \
          "$TMP_DIR"/kindle_folders.list \
          "$TMP_DIR"/search_results.json \
          "$TMP_DIR"/last_search_* \
          "$TMP_DIR"/lgli_search_page.html \
          "$TMP_DIR"/dup_targets
}

get_version() {
    local api_response="$(curl -s --max-time 10 -H "Accept: application/vnd.github.v3+json" "https://api.github.com/repos/yaboyJer/yaKindleFetch/commits")" || {
        echo "Failed to fetch version from GitHub API" >&2
        echo "unknown"
        return
    }

    local latest_sha="$(echo "$api_response" | grep -m1 '"sha":' | cut -d'"' -f4 | cut -c1-7)"
    
    echo "$latest_sha" > "$VERSION_FILE"
    load_version
}

check_for_updates() {
    local current_sha="$(load_version)"
    
    local latest_sha="$(curl -s --max-time 10 -H "Accept: application/vnd.github.v3+json" \
        -H "Cache-Control: no-cache" \
        "https://api.github.com/repos/yaboyJer/yaKindleFetch/commits?per_page=1" | \
        grep -oE '"sha": "[0-9a-f]+"' | head -1 | cut -d'"' -f4 | cut -c1-7)"
    
    if [ -n "$latest_sha" ] && [ "$current_sha" != "$latest_sha" ]; then
        UPDATE_AVAILABLE=true
        return 0
    else
        return 1
    fi
}

save_config() {
    {
        echo "KINDLE_DOCUMENTS=\"$KINDLE_DOCUMENTS\""
        echo "CREATE_SUBFOLDERS=\"$CREATE_SUBFOLDERS\""
        echo "DEBUG_MODE=\"$DEBUG_MODE\""
        echo "COMPACT_OUTPUT=\"$COMPACT_OUTPUT\""
        echo "ENFORCE_DNS=\"$ENFORCE_DNS\""
        echo "ZLIB_AUTH=\"$ZLIB_AUTH\""
        echo "ZLIB_USERNAME=\"$ZLIB_USERNAME\""
        echo "RESULTS_PER_PAGE=\"$RESULTS_PER_PAGE\""
        echo "ANNAS_URL=\"$ANNAS_URL\""
        echo "LGLI_URL=\"$LGLI_URL\""
        echo "ZLIB_URL=\"$ZLIB_URL\""
    } > "$CONFIG_FILE"
}

zlib_login() {
    local zlib_login="$1"
    local zlib_password="$2"

    printf '\nLogging in to Z-Library...'

    local response="$(curl -s -c "$ZLIB_COOKIES_FILE" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -H "Accept: application/json" \
        -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64)" \
        -X POST -d "email=$zlib_login&password=$zlib_password" \
        "$ZLIB_URL/eapi/user/login")"

    local zlib_username="$(get_json_value "$response" "name" | tr -d '\r\n')"

    if [ -n "$zlib_username" ]; then
        printf "\nSuccessfully logged in as $zlib_username!"
        ZLIB_USERNAME="$zlib_username"
        sleep 2
    else
        printf "\nLogin failed." >&2
        printf "\n$response" | head -n1
        sleep 2
        return 1
    fi
}

normalize_name() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | \
        sed -e 's/[^a-z0-9 ]//g' -e 's/  */ /g' -e 's/^ //;s/ $//'
}

find_local_books() {
    # Print every file in $KINDLE_DOCUMENTS (depth <= 2) whose name
    # (without extension) contains the normalized title. Prints nothing
    # when there are no matches.
    local norm_title
    norm_title="$(normalize_name "$1")"
    # Skip trivially short titles: they'd match almost every file.
    [ ${#norm_title} -lt 4 ] && return 0
    [ -d "$KINDLE_DOCUMENTS" ] || return 0

    local f base norm_name
    for f in "$KINDLE_DOCUMENTS"/* "$KINDLE_DOCUMENTS"/*/*; do
        [ -f "$f" ] || continue
        base="$(basename "$f")"
        base="${base%.*}"
        norm_name="$(normalize_name "$base")"
        case "$norm_name" in
            *"$norm_title"*) echo "$f" ;;
        esac
    done
    return 0
}

find_working_url() {
    for url in "$@"; do
        code=$(curl -s -o /dev/null -w '%{http_code}' \
               --max-time 5 -L \
               -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64)" \
               "$url")

        [ "$code" = "000" ] && continue
        [ "$code" -ge 500 ] && continue

        echo "$url"
        return 0
    done
    return 1
}