#!/bin/bash

# A Bash script to validate and clean M3U playlists in parallel.
# It removes non-working and duplicate links for optimal performance on large lists.

set -o pipefail

# --- Color Definitions ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

# --- Default Configuration ---
THROTTLE_LIMIT=50
TIMEOUT_SECONDS=5
USER_AGENT='VLC/3.0.x LibVLC/3.0.x'
KEEP_SERVER_ERRORS=false
OUTPUT_FILE=""

# --- Usage Information ---
usage() {
    echo "Usage: $0 -i <input_file> [-o <output_file>] [-t <throttle>] [-s <timeout>] [-u <user_agent>] [-k]"
    echo ""
    echo "Options:"
    echo "  -i <path>     Mandatory. Path to the input M3U playlist file."
    echo "  -o <path>     Optional. Path to save the cleaned output file. If not provided, the input file is overwritten."
    echo "  -t <num>      Optional. The maximum number of links to check simultaneously. Default: 50."
    echo "  -s <num>      Optional. The timeout for each web request in seconds. Default: 5."
    echo "  -u <string>   Optional. The User-Agent string for web requests. Default: 'VLC/...'"
    echo "  -k            Optional. Keep links that return HTTP server errors (500-599)."
    echo "  -h            Display this help message."
    exit 1
}

# --- Argument Parsing ---
while getopts "i:o:t:s:u:kh" opt; do
    case ${opt} in
        i) INPUT_FILE="$OPTARG" ;;
        o) OUTPUT_FILE="$OPTARG" ;;
        t) THROTTLE_LIMIT=$OPTARG ;;
        s) TIMEOUT_SECONDS=$OPTARG ;;
        u) USER_AGENT="$OPTARG" ;;
        k) KEEP_SERVER_ERRORS=true ;;
        h) usage ;;
        \?) usage ;;
    esac
done

# Validate mandatory input file
if [ -z "$INPUT_FILE" ]; then
    echo -e "${RED}Error: Input file (-i) is a mandatory argument.${NC}"
    usage
fi

if [ ! -f "$INPUT_FILE" ]; then
    echo -e "${RED}Error: The file '$INPUT_FILE' was not found.${NC}"
    exit 1
fi

# Set output file path. If not provided, use the input file.
if [ -z "$OUTPUT_FILE" ]; then
    OUTPUT_FILE="$INPUT_FILE"
fi

# --- Main Logic ---

# This function checks a single URL. It's designed to be called by xargs in parallel.
# Input: A single string argument in the format "URL|#EXTINF line"
# Output: If the link is working, it prints the #EXTINF line (if present) followed by the URL.
check_url() {
    local input_line="$1"
    local url="${input_line%%|*}" # Everything before the first |
    local extinf_line="${input_line#*|}" # Everything after the first |

    # Perform a HEAD request with curl, capturing only the HTTP status code.
    # -s: Silent mode
    # -I: HEAD request
    # -L: Follow redirects
    # --max-time: Timeout
    # -o /dev/null: Discard the body
    # -w '%{http_code}': Write out only the status code
    http_code=$(curl -s -I -L --max-time "$TIMEOUT_SECONDS" -A "$USER_AGENT" -o /dev/null -w '%{http_code}' "$url")
    local curl_exit_code=$?

    local is_working=false
    # Check for successful curl execution (exit code 0) and valid HTTP status
    if [ $curl_exit_code -eq 0 ]; then
        if (( http_code >= 200 && http_code < 400 )); then
            is_working=true
        elif [ "$KEEP_SERVER_ERRORS" = true ] && (( http_code >= 500 )); then
            is_working=true
        fi
    fi

    if [ "$is_working" = true ]; then
        # If the link works, print the lines to be included in the final file.
        # The mutex ensures that writes from parallel processes don't get garbled.
        if [ -n "$extinf_line" ]; then
            echo -e "$extinf_line\n$url"
        else
            echo "$url"
        fi
    fi
}

# Export the function and variables so they are available to the subshells created by xargs.
export -f check_url
export TIMEOUT_SECONDS
export USER_AGENT
export KEEP_SERVER_ERRORS

# --- Phase 1: Parse Playlist and Identify Unique Links ---
echo -e "${CYAN}--- Phase 1: Parsing playlist and identifying unique links... ---${NC}"

declare -A SEEN_URLS # Associative array for tracking duplicates
declare -a LINK_JOBS # Regular array to hold the jobs for xargs

has_extm3u_header=$(head -n 1 "$INPUT_FILE" | grep -q "#EXTM3U" && echo "true" || echo "false")
duplicate_links_count=0
extinf_cache=""

# Read file line by line
while IFS= read -r line || [[ -n "$line" ]]; do
    line=$(echo "$line" | tr -d '\r') # Remove carriage returns for cross-platform compatibility
    if [ -z "$line" ]; then
        continue
    fi

    current_url=""
    # If line is an #EXTINF line, cache it for the next line
    if [[ "$line" == '#EXTINF'* ]]; then
        extinf_cache="$line"
        continue
    fi

    # If line is a URL
    if [[ "$line" =~ ^https?:// ]]; then
        current_url="$line"
    fi

    if [ -n "$current_url" ]; then
        if [[ -z "${SEEN_URLS[$current_url]}" ]]; then
            SEEN_URLS["$current_url"]=1
            # Format as "URL|#EXTINF" for passing to the check_url function
            LINK_JOBS+=("$current_url|$extinf_cache")
        else
            ((duplicate_links_count++))
        fi
    fi
    # Reset cache after processing a URL or a non-URL line
    extinf_cache=""
done < "$INPUT_FILE"

total_unique_links=${#LINK_JOBS[@]}
echo "Found $total_unique_links unique links to check."
echo -e "Skipped $duplicate_links_count duplicate links during parsing."

# --- Phase 2: Parallel Link Validation ---
echo -e "${CYAN}\n--- Phase 2: Checking $total_unique_links unique links in parallel (Throttle: $THROTTLE_LIMIT)... ---${NC}"

# Use printf to feed jobs to xargs, which handles newlines correctly.
# xargs -P runs commands in parallel.
# The bash -c construct allows us to call our exported shell function.
working_lines_output=$(printf "%s\n" "${LINK_JOBS[@]}" | xargs -P "$THROTTLE_LIMIT" -I {} bash -c 'check_url "$@"' _ {})
if [ $? -ne 0 ] && [ -n "$working_lines_output" ]; then
    echo -e "${YELLOW}Warning: One or more checker processes may have failed. Results may be incomplete.${NC}"
fi


# --- Phase 3: Assemble Cleaned Playlist and Write to File ---
echo -e "${CYAN}\n--- Phase 3: Assembling and saving the cleaned playlist... ---${NC}"

# Create temporary file to handle overwriting the source safely
TEMP_FILE=$(mktemp)

# Add header if it existed
if [ "$has_extm3u_header" = true ]; then
    echo "#EXTM3U" > "$TEMP_FILE"
fi

# Add the working links collected from xargs
if [ -n "$working_lines_output" ]; then
    echo "$working_lines_output" >> "$TEMP_FILE"
fi

# Move the temporary file to the final destination
mv "$TEMP_FILE" "$OUTPUT_FILE"

# --- Final Summary ---
working_links_count=$(echo "$working_lines_output" | grep -c -E "^https?://")
non_working_links_count=$((total_unique_links - working_links_count))

echo -e "\n--- Summary ---"
echo -e "${YELLOW}Total unique links checked: $total_unique_links${NC}"
echo -e "${GREEN}Working links found: $working_links_count${NC}"
echo -e "${RED}Non-working links removed: $non_working_links_count${NC}"
echo -e "${GRAY}Duplicate links skipped: $duplicate_links_count${NC}"
echo -e "${GREEN}Cleaned playlist saved to: '$OUTPUT_FILE'${NC}"
