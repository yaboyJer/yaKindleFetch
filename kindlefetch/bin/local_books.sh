#!/bin/sh

delete_book() {
    index="$1"
    book_file="$(sed -n "${index}p" "$TMP_DIR"/kindle_books.list 2>/dev/null)"
    
    if [ -z "$book_file" ]; then
        echo "Invalid selection" >&2
        return 1
    fi

    echo -n "Are you sure you want to delete '$book_file'? [y/N] "
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if rm -f "$book_file"; then
            echo "Book deleted successfully"
        else
            echo "Failed to delete book"
        fi
    else
        echo "Deletion canceled"
    fi
}

delete_directory() {
    index="$1"
    dir_path="$(sed -n "${index}p" "$TMP_DIR"/kindle_folders.list 2>/dev/null)"
    
    if [ -z "$dir_path" ]; then
        echo "Invalid selection"
        return 1
    fi

    echo -n "Are you sure you want to delete '$dir_path' and all its contents? [y/N] "
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if rm -rf "$dir_path"; then
            echo "Directory deleted successfully"
        else
            echo "Failed to delete directory"
        fi
    else
        echo "Deletion canceled"
    fi
}

list_local_books() {
    while true; do
        local current_dir="${1:-$KINDLE_DOCUMENTS}"
        clear
        echo -e "
 ____              _        
|  _ \            | |       
| |_) | ___   ___ | | _____ 
|  _ < / _ \ / _ \| |/ / __|
| |_) | (_) | (_) |   <\__ \\
|____/ \___/ \___/|_|\_\___/
"
        echo "Current directory: $current_dir"
        echo "--------------------------------"
        echo ""
        
        i=1
        : > "$TMP_DIR"/kindle_books.list
        : > "$TMP_DIR"/kindle_folders.list

        if [ ! -d "$current_dir" ]; then
            echo "Directory '$current_dir' does not exist." >&2
            return 1
        fi

        for item in "$current_dir"/*; do
            if [ -d "$item" ]; then
                foldername=$(basename "$item")
                echo "$i. $foldername/"
                echo "$item" >> "$TMP_DIR"/kindle_folders.list
                i=$((i+1))
            fi
        done

        for item in "$current_dir"/*; do
            if [ -f "$item" ]; then
                filename=$(basename "$item")
                # extension="${filename##*.}"
                echo "$i. $filename"
                echo "$item" >> "$TMP_DIR"/kindle_books.list
                i=$((i+1))
            fi
        done
        
        if [ $i -eq 1 ]; then
            echo "No books or folders found."
            return 1
        fi
        
        echo ""
        echo "--------------------------------"
        echo "d[n]: Delete item n (book or folder)"
        echo "n: Go up to parent directory"
        echo "number: Open folder"
        echo "q: Back to main menu"
        echo ""

        total_items=$(( $(wc -l < "$TMP_DIR"/kindle_folders.list 2>/dev/null) + $(wc -l < "$TMP_DIR"/kindle_books.list 2>/dev/null) ))
        
        echo -n "Enter choice: "
        read -r choice
        
        case "$choice" in
            [qQ])
                return 0
                ;;
            [nN])
                current_dir=$(dirname "$current_dir")
                ;;
            [dD][0-9]*)
                del_num="${choice#[dD]}"
                if echo "$del_num" | grep -qE '^[0-9]+$' && [ "$del_num" -ge 1 ] && [ "$del_num" -le "$total_items" ]; then
                    if [ "$del_num" -le $(wc -l < "$TMP_DIR"/kindle_folders.list 2>/dev/null) ]; then
                        delete_directory "$del_num"
                    else
                        file_index=$((del_num - $(wc -l < "$TMP_DIR"/kindle_folders.list 2>/dev/null)))
                        delete_book "$file_index"
                    fi
                else
                    echo "Invalid selection (must be d1 to d$total_items)"
                    sleep 2
                fi
                ;;
            [0-9]*)
                if echo "$choice" | grep -qE '^[0-9]+$' && [ "$choice" -ge 1 ] && [ "$choice" -le "$total_items" ]; then
                    if [ "$choice" -le $(wc -l < "$TMP_DIR"/kindle_folders.list 2>/dev/null) ]; then
                        current_dir=$(sed -n "${choice}p" "$TMP_DIR"/kindle_folders.list)
                    else
                        echo "That's a file. Use d$choice to delete it."
                        sleep 2
                    fi
                else
                    echo "Invalid selection (must be between 1 and $total_items)"
                    sleep 2
                fi
                ;;
            *)
                echo "Invalid input"
                sleep 2
                ;;
        esac

        set -- "$current_dir"
    done
}