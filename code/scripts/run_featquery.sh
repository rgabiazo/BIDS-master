#!/usr/bin/env bash
#
#################################################################################
# run_featquery.sh
#
# Purpose:
#   A companion script that receives FEAT directories and ROI masks, calls FSL’s
#   featquery, and parses the resulting "report.txt" to produce CSV output(s).
#
# Usage:
#   run_featquery.sh dir1 dir2 ... :: roi1.nii.gz roi2.nii.gz ...
#
# Options:
#   - None (positional arguments are the FEAT directories, then "::", then ROI masks).
#
# Usage Examples:
#   ./run_featquery.sh sub-02_ses-01.feat sub-03_ses-01.feat :: /path/to/roi.nii.gz
#
# Requirements:
#   - BASH shell
#   - FSL installed (with featquery in PATH)
#   - The .feat or .gfeat directories must be valid FSL outputs
#   - Binarized ROI mask(s) containing "binarized" in the filename
#
# Notes:
#   - This script logs full details to code/logs/run_featquery_<timestamp>.log
#   - It writes separate CSV files per session in derivatives/fsl/featquery/data/<ses-XX>
#
#################################################################################

script_dir="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(dirname "$(dirname "$script_dir")")"

# Create a timestamped log file in the same directory as the script
LOGFILE="$BASE_DIR/code/logs/run_featquery_$(date +'%Y%m%d_%H%M%S').log"

# Redirect ALL output (stdout & stderr) through tee, so everything goes to
# the console AND the log file by default
exec > >(tee -a "$LOGFILE") 2>&1

echo
echo "=== Initializing run_featquery.sh ===" >> $LOGFILE
echo "Log file: $LOGFILE" >> $LOGFILE
echo >> $LOGFILE

###############################################################################
# 1) Locate 'featquery' in PATH
###############################################################################
FEATQ="$(command -v featquery)"
if [ -z "$FEATQ" ]; then
    echo "[ERROR] Could not find 'featquery' in PATH. Please ensure FSL is loaded or your PATH is set."
    exit 1
fi

echo "featquery found at: $FEATQ" >> $LOGFILE
echo >> $LOGFILE

###############################################################################
# 2) Separate arguments into FEAT_DIRS (before "::") vs. ROI_MASKS (after "::")
###############################################################################
FEAT_DIRS=()
ROI_MASKS=()

while [ $# -gt 0 ]; do
    if [ "$1" = "::" ]; then
        shift  # consume the "::" token
        break
    fi
    FEAT_DIRS+=( "$1" )
    shift
done

while [ $# -gt 0 ]; do
    ROI_MASKS+=( "$1" )
    shift
done

###############################################################################
# 3) Print a short summary to the console & log
#    (But we will direct certain lines ONLY to the log, not the console.)
###############################################################################
echo "=== Featquery input directories and ROI mask(s) ==="
echo
echo "FEAT directories (${#FEAT_DIRS[@]}):"
for fidx in "${!FEAT_DIRS[@]}"; do
    echo "  $((fidx+1))) ${FEAT_DIRS[$fidx]}"
done

echo
echo "ROI masks (${#ROI_MASKS[@]}):"
for midx in "${!ROI_MASKS[@]}"; do
    echo "  $((midx+1))) ${ROI_MASKS[$midx]}"
done

echo "----------------------------------------------------"
echo

###############################################################################
# 4) Quick checks
###############################################################################
if [ ${#FEAT_DIRS[@]} -eq 0 ]; then
    echo "[WARNING] No FEAT directories were passed. Exiting..."
    exit 1
fi
if [ ${#ROI_MASKS[@]} -eq 0 ]; then
    echo "[WARNING] No ROI masks were passed. Exiting..."
    exit 1
fi

###############################################################################
# 5) Define a helper function to log certain lines ONLY to the log file.
###############################################################################
function log_only() {
    # This echoes to the log file ONLY (not to the console),
    # because everything currently goes to console & log by default.
    echo "$@" >> "$LOGFILE"
}

###############################################################################
# 6) For each ROI mask, do partial skipping if the final output folder exists,
#    then parse "report.txt" => subject + mean => CSV
###############################################################################
CSV_DATA_DIR="$BASE_DIR/derivatives/fsl/featquery/data"
mkdir -p "$CSV_DATA_DIR"

for mask_path in "${ROI_MASKS[@]}"; do

    # Log these lines ONLY to the log file:
    log_only "Preparing featquery call for ROI mask:"
    log_only "  $mask_path"
    log_only ""

    # Extract 'copeXX' or 'copeNNN' from parent folder name
    roi_parent="$(dirname "$mask_path")"
    cope_name="$(basename "$roi_parent")"  # e.g. 'cope12'

    # ROI name (strip .nii/.nii.gz, also remove any trailing "_binarized_mask")
    roi_file="$(basename "$mask_path")"
    roi_noext="${roi_file%.nii*}"
    roi_noext="$(echo "$roi_noext" | sed -E 's/(_binarized_mask)?$//I')"

    # If FEAT dir ends with .gfeat => append "/copeXX.feat" so featquery knows the sub-cope
    FIXED_FEAT_DIRS=()
    for fdir in "${FEAT_DIRS[@]}"; do
        fdir="${fdir%/}"
        if [[ "$fdir" =~ \.gfeat$ ]]; then
            FIXED_FEAT_DIRS+=( "$fdir/${cope_name}.feat" )
        else
            FIXED_FEAT_DIRS+=( "$fdir" )
        fi
    done

    # Adjust subfolder name => e.g. "cope12_ROI-LOcinferior_space-MNI152_desc-sphere5mm_featquery"
    label="${cope_name}_ROI-${roi_noext}_featquery"

    # Store data lines by session in an associative array:
    #   PERROI_SESSIONS_DATA["ses-01"] -> "ID,Mean\nsub-02,0.234\nsub-03,0.567\n..."
    declare -A PERROI_SESSIONS_DATA=()

    # Identify which FEAT dirs don't have a final featquery folder
    MISSING_FEAT_DIRS=()
    for fdir in "${FIXED_FEAT_DIRS[@]}"; do
        rel_path="${fdir#$BASE_DIR/}"
        rel_path="${rel_path#derivatives/fsl}"
        rel_path="derivatives/fsl/featquery${rel_path}"

        base_dirname="$(dirname "$rel_path")"
        final_out_dir="$BASE_DIR/$base_dirname/$label"

        if [ ! -d "$final_out_dir" ]; then
            MISSING_FEAT_DIRS+=( "$fdir" )
        fi
    done

    if [ ${#MISSING_FEAT_DIRS[@]} -eq 0 ]; then
        echo "[INFO] All FEAT directories already have outputs for: ${roi_noext}"
        echo "       => Skipping featquery for this ROI: $label"
        echo
        continue
    fi

    # Remove any old partial subfolder if present
    for fdir in "${MISSING_FEAT_DIRS[@]}"; do
        subfolder="$fdir/$label"
        if [ -d "$subfolder" ]; then
            log_only "[INFO] Removing old subfolder: $subfolder"
            rm -rf "$subfolder"
        fi
    done

    # Build featquery command
    num_missing=${#MISSING_FEAT_DIRS[@]}
    CMD=( "$FEATQ" "$num_missing" )
    for missing_dir in "${MISSING_FEAT_DIRS[@]}"; do
        CMD+=( "$missing_dir" )
    done
    CMD+=( "1" "stats/pe1" "$label" "-p" "-s" "-b" "$mask_path" )

    echo ">>> ${CMD[@]}"
    echo

    log_only "Calling featquery with $num_missing FEAT directories..."
    log_only "Label: $label"
    log_only ""

    # Run featquery command
    "${CMD[@]}"

    # Parse the results
    for fdir in "${MISSING_FEAT_DIRS[@]}"; do
        source_dir="$fdir/$label"
        if [ ! -d "$source_dir" ]; then
            log_only "[WARNING] featquery output not found at: $source_dir"
            continue
        fi

        rel_path="${fdir#$BASE_DIR/}"
        rel_path="${rel_path#derivatives/fsl}"
        rel_path="derivatives/fsl/featquery${rel_path}"

        base_dirname="$(dirname "$rel_path")"
        final_out_dir="$BASE_DIR/$base_dirname/$label"

        log_only "Moving featquery results -> $final_out_dir"
        mkdir -p "$(dirname "$final_out_dir")"
        mv "$source_dir" "$final_out_dir"

        report_file="$final_out_dir/report.txt"
        if [ ! -f "$report_file" ]; then
            log_only "[WARNING] No report.txt found in $final_out_dir"
            continue
        fi

        # Grab the 'Mean' from the first line of report.txt
        mapfile -t lines < "$report_file"
        if [ ${#lines[@]} -gt 0 ]; then
            fields=(${lines[0]})
            mean_val="${fields[5]:-0.0}"
        else
            mean_val="NaN"
        fi

        # Extract subject & session from path
        subject="$(echo "$fdir" | sed -nE 's@.*(sub-[^_/]+).*@\1@p')"
        [ -z "$subject" ] && subject="sub-unknown"

        session_name="$(echo "$fdir" | sed -nE 's@.*(ses-[^_/]+).*@\1@p')"
        [ -z "$session_name" ] && session_name="ses-unknown"

        # Initialize CSV header if needed
        if [ -z "${PERROI_SESSIONS_DATA["$session_name"]+exists}" ]; then
            PERROI_SESSIONS_DATA["$session_name"]="ID,Mean"
        fi

        # Append new line
        PERROI_SESSIONS_DATA["$session_name"]+=$'\n'"${subject},${mean_val}"

    done

    # Make separate CSVs per session
    date_str="$(date +'%Y%m%d_%H%M')"

    for s in "${!PERROI_SESSIONS_DATA[@]}"; do
        session_data_dir="$CSV_DATA_DIR/$s"
        mkdir -p "$session_data_dir"

        csv_name="${label}_${s}_${date_str}.csv"
        csv_path="$session_data_dir/$csv_name"

        printf "%s\n" "${PERROI_SESSIONS_DATA["$s"]}" > "$csv_path"

        echo "CSV created at:"
        echo "  $csv_path"
        log_only "[INFO] Writing CSV to: $csv_path"
        echo
    done

done

echo "Featquery Complete."
echo "========================================"
echo "=== Finished run_featquery.sh ===" >> $LOGFILE


