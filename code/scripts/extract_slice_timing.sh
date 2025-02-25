#!/bin/bash
#
###############################################################################
# extract_slice_timing.sh
#
# Purpose:
#   Extracts slice timing info from BOLD JSON files using `jq` and writes
#   them to a simple text file, one slice timing value per line.
#
# Usage:
#   extract_slice_timing.sh --base-dir <dir> [options] [SUBJECTS...]
#
# Options:
#   --base-dir <dir>    Base directory of the project (required)
#   --session <ses>     One or more sessions to process (e.g., ses-01)
#   -h, --help          Show usage info and exit
#
# Usage Examples:
#   1) extract_slice_timing.sh --base-dir /myproj sub-01 sub-02
#   2) extract_slice_timing.sh --base-dir /myproj --session ses-02
#   3) extract_slice_timing.sh --base-dir /myproj
#      (auto-detects sub-* or pilot-* directories, processes all sessions).
#
# Requirements:
#   - `jq` for parsing JSON
#   - BOLD JSON sidecars containing a 'SliceTiming' array
#
# Notes:
#   - Writes the slice timing as one value per line to <base-dir>/derivatives/slice_timing/<sub>/<ses>/func.
#   - If no SUBJECTS are provided, it scans sub-* and pilot-* directories at the top level.
#
###############################################################################

BASE_DIR=""
SUBJECTS=()
SESSIONS=()
SUBJECT_PREFIXES=("sub" "pilot")

usage() {
    echo "Usage: $0 --base-dir <dir> [--session SESSIONS...] [SUBJECTS...]"
    exit 1
}

POSITIONAL=()
while [[ "$1" != "" ]]; do
    case $1 in
        --base-dir )
            shift
            BASE_DIR="$1"
            ;;
        --session )
            shift
            SESSIONS+=("$1")
            ;;
        -h|--help )
            usage
            ;;
        -- )
            shift
            while [[ "$1" != "" ]]; do
                POSITIONAL+=("$1")
                shift
            done
            ;;
        -* )
            echo "Unknown option: $1"
            usage
            ;;
        * )
            POSITIONAL+=("$1")
            ;;
    esac
    shift
done

SUBJECTS=("${POSITIONAL[@]}")

if [ -z "$BASE_DIR" ]; then
    echo "Error: --base-dir is required."
    usage
fi

while [ ! -d "$BASE_DIR" ]; do
    echo "Base dir '$BASE_DIR' not found."
    read -p "Enter valid base dir: " BASE_DIR
done

LOG_DIR="${BASE_DIR}/code/logs"
mkdir -p "$LOG_DIR"
SCRIPT_NAME=$(basename "$0")
LOG_FILE="${LOG_DIR}/${SCRIPT_NAME%.*}_$(date '+%Y-%m-%d_%H-%M-%S').log"

exec > >(tee -i "$LOG_FILE") 2>&1

if ! command -v jq &> /dev/null; then
    echo "Error: jq not found. Please install jq to proceed."
    exit 1
fi

if [ ${#SUBJECTS[@]} -eq 0 ]; then
    # auto-detect sub-* or pilot-*
    SUBJECTS=($(find "$BASE_DIR" -maxdepth 1 -type d -name "sub-*" -exec basename {} \;))
    PILOT_SUBJS=($(find "$BASE_DIR" -maxdepth 1 -type d -name "pilot-*" -exec basename {} \;))
    SUBJECTS+=("${PILOT_SUBJS[@]}")
    IFS=$'\n' SUBJECTS=($(printf "%s\n" "${SUBJECTS[@]}" | sort -uV))
fi

echo -e "\nFound ${#SUBJECTS[@]} subject directories."
echo ""

DERIV_DIR="${BASE_DIR}/derivatives/slice_timing"

for subj in "${SUBJECTS[@]}"; do
    echo "=== Processing subject: $subj ==="

    SESSION_DIRS=()
    if [ ${#SESSIONS[@]} -gt 0 ]; then
        for ses in "${SESSIONS[@]}"; do
            [ -d "$BASE_DIR/$subj/$ses" ] && SESSION_DIRS+=("$BASE_DIR/$subj/$ses") || echo "Warning: $subj/$ses not found"
        done
    else
        for ses_dir in "$BASE_DIR/$subj"/ses-*; do
            [ -d "$ses_dir" ] && SESSION_DIRS+=("$ses_dir")
        done
        IFS=$'\n' SESSION_DIRS=($(printf "%s\n" "${SESSION_DIRS[@]}" | sort -V))
    fi

    if [ ${#SESSION_DIRS[@]} -eq 0 ]; then
        echo "No sessions for $subj."
        echo ""
        continue
    fi

    for sess_dir in "${SESSION_DIRS[@]}"; do
        sess=$(basename "$sess_dir")
        func_dir="$sess_dir/func"
        [ ! -d "$func_dir" ] && continue

        json_files=($(find "$func_dir" -type f -name "*_bold.json" | sort -V))
        if [ ${#json_files[@]} -eq 0 ]; then
            echo "No BOLD JSON files for $subj $sess."
            echo ""
            continue
        fi

        for json_file in "${json_files[@]}"; do
            json_filename=$(basename "$json_file" .json)
            RUN_NUMBER=$(echo "$json_filename" | grep -o 'run-[0-9]\+' || echo "run-01")

            echo "--- Session: $sess | Run: $RUN_NUMBER ---"
            echo "BOLD JSON: $json_file"
            echo ""

            out_dir="${DERIV_DIR}/${subj}/${sess}/func"
            mkdir -p "$out_dir"
            slice_file="${out_dir}/${json_filename}_slice_timing.txt"

            echo "Creating slice timing file:"
            echo "  - Input: $json_file"
            echo "  - Output: $slice_file"

            if [ -f "$slice_file" ]; then
                echo "  File exists, skipping."
                echo ""
                continue
            fi

            jq '.SliceTiming[]' "$json_file" > "$slice_file"
            if [[ ! -s "$slice_file" ]]; then
                echo "SliceTiming field missing or empty in $json_file"
                rm -f "$slice_file"
            fi
            echo ""
        done
    done
done

echo "Slice timing extraction completed."
echo "------------------------------------------------------------------------------"
