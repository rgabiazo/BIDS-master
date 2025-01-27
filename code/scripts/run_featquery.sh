#!/usr/bin/env bash
###############################################################################
# run_featquery.sh
# -----------------------------------------------------------------------------
# This script is called by featquery_input.sh, receiving two lists:
#   1) FEAT directories (any level: .feat or .gfeat)
#   2) ROI mask files (with 'binarized' in the name)
#
# They are passed in as:
#   run_featquery.sh dir1 dir2 ... :: roi1.nii.gz roi2.nii.gz ...
#
# For each ROI mask, we:
#   a) Parse "copeXX" from the mask's parent folder.
#   b) If a FEAT directory ends in ".gfeat", we append "/copeXX.feat" so that
#      featquery knows which sub-.feat to query (typical for level-2).
#   c) Build a label like "cope10-OccipitalPole_space-MNI152_desc-sphere5_featquery".
#   d) Skip any FEAT directory that already has the final output (partial re-run).
#   e) Actually run featquery on only the "missing" directories, move the
#      resulting subfolders, parse "report.txt" for the mean, and write a CSV
#      containing "ID,Mean" lines.
#
# Additionally:
#   - We do NOT hardcode 'featquery' but locate it with `command -v featquery`.
#   - We produce a log file in the script's directory, capturing everything.
#   - Some lines go ONLY to the log file (not shown in the terminal).
#   - The console sees a shorter summary plus the final command + CSV info.
###############################################################################

script_dir="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(dirname "$(dirname "$script_dir")")"

# Create a timestamped log file in the same directory as the script
LOGFILE="$BASE_DIR/code/logs/run_featquery_$(date +'%Y%m%d_%H%M%S').log"

# Redirect ALL output (stdout & stderr) through tee, so everything goes to
# the console AND the log file by default
exec > >(tee -a "$LOGFILE") 2>&1

echo
echo "=== Initializing run_featquery.sh ===" >> $LOGFILE
echo "Log file: $LOGFILE" >> $LOGFILE >> $LOGFILE
echo >> $LOGFILE

###############################################################################
# 1) Locate 'featquery' in the user's PATH
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
# 5) We'll define a helper function to log certain lines ONLY to the log file.
###############################################################################
function log_only() {
    # This echoes to the log file ONLY (not to the console),
    # because everything currently goes to console & log by default.
    # We'll temporarily disable tee for these lines by redirecting them.
    echo "$@" >> "$LOGFILE"
}

###############################################################################
# 6) For each ROI mask, do partial skipping if the final output folder exists,
#    then parse "report.txt" => subject + mean => CSV
###############################################################################
CSV_DATA_DIR="$BASE_DIR/derivatives/fsl/featquery/data"
mkdir -p "$CSV_DATA_DIR"

for mask_path in "${ROI_MASKS[@]}"; do

    # We'll log these lines ONLY to the log file:
    log_only "Preparing featquery call for ROI mask:"
    log_only "  $mask_path"
    log_only ""

    # (a) Extract 'copeXX'
    roi_parent="$(dirname "$mask_path")"
    cope_name="$(basename "$roi_parent")"

    # (b) ROI name
    roi_file="$(basename "$mask_path")"
    roi_noext="${roi_file%.nii*}"
    roi_noext="$(echo "$roi_noext" | sed -E 's/(_binarized_mask)?$//I')"

    # (c) If FEAT dir ends with .gfeat => append "/copeXX.feat"
    FIXED_FEAT_DIRS=()
    for fdir in "${FEAT_DIRS[@]}"; do
        fdir="${fdir%/}"
        if [[ "$fdir" =~ \.gfeat$ ]]; then
            FIXED_FEAT_DIRS+=( "$fdir/${cope_name}.feat" )
        else
            FIXED_FEAT_DIRS+=( "$fdir" )
        fi
    done

    label="${cope_name}-${roi_noext}_featquery"

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
        echo "       => Skipping featquery for this ROI."
        echo
        continue
    fi

    for fdir in "${MISSING_FEAT_DIRS[@]}"; do
        subfolder="$fdir/$label"
        if [ -d "$subfolder" ]; then
            log_only "[INFO] Removing old subfolder to ensure a clean re-run: $subfolder"
            rm -rf "$subfolder"
        fi
    done

    num_missing=${#MISSING_FEAT_DIRS[@]}
    CMD=( "$FEATQ" "$num_missing" )
    for missing_dir in "${MISSING_FEAT_DIRS[@]}"; do
        CMD+=( "$missing_dir" )
    done
    CMD+=( "1" "stats/pe1" "$label" "-p" "-s" "-b" "$mask_path" )

    echo ">>> ${CMD[@]}"
    echo

    # We'll log to the file that we're "calling featquery with X directories" etc.:
    log_only "Calling featquery with $num_missing FEAT directories..."
    log_only "Label: $label"
    log_only ""

    # Run featquery
    "${CMD[@]}"

    DATA_LINES=()
    DATA_LINES+=( "ID,Mean" )

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

        # Log the "moving featquery results" line only to the log:
        log_only "Moving featquery results -> $final_out_dir"

        mkdir -p "$(dirname "$final_out_dir")"
        mv "$source_dir" "$final_out_dir"

        report_file="$final_out_dir/report.txt"
        if [ ! -f "$report_file" ]; then
            log_only "[WARNING] No report.txt found in $final_out_dir"
            continue
        fi

        mapfile -t lines < "$report_file"
        if [ ${#lines[@]} -gt 0 ]; then
            fields=(${lines[0]})
            mean_val="${fields[5]:-0.0}"
        else
            mean_val="NaN"
        fi

        subject="$(echo "$fdir" | sed -nE 's@.*(sub-[^_/]+).*@\1@p')"
        if [ -z "$subject" ]; then
            subject="UnknownID"
        fi

        DATA_LINES+=( "$subject,$mean_val" )
    done

    date_str="$(date +'%Y%m%d_%H%M')"
    csv_name="${label}_${date_str}.csv"
    csv_path="$CSV_DATA_DIR/$csv_name"

    if [ ${#DATA_LINES[@]} -gt 1 ]; then
        mkdir -p "$(dirname "$csv_path")"
        printf "%s\n" "${DATA_LINES[@]}" > "$csv_path"

        echo "CSV created at:"
        echo "  $csv_path"

        # In the log, let's also note [INFO] Writing CSV to ...
        log_only "[INFO] Writing CSV to: $csv_path"
    else
        log_only "[INFO] No new data lines for $label, skipping CSV creation."
    fi

    echo
done

echo "Featquery Complete."
echo "========================================"
echo "=== Finished run_featquery.sh ===" >> $LOGFILE

