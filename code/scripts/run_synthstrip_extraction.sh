#!/bin/bash
#
###############################################################################
# run_synthstrip_extraction.sh
#
# Purpose:
#   Applies SynthStrip (from FreeSurfer) to T1w images, optionally reorienting
#   them with fslreorient2std first. Outputs go to `derivatives/freesurfer/`.
#
# Usage:
#   run_synthstrip_extraction.sh --base-dir <dir> [options] [SUBJECTS...]
#
# Options:
#   --base-dir <dir>     Base directory of the project (required)
#   --reorient           Apply fslreorient2std to T1w images
#   --session <ses>      Session(s) to process (e.g., ses-01 ses-02)
#   -h, --help           Show usage info and exit
#
# Usage Examples:
#   1) run_synthstrip_extraction.sh --base-dir /myproj sub-01 sub-02
#   2) run_synthstrip_extraction.sh --base-dir /myproj --reorient
#   3) run_synthstrip_extraction.sh --base-dir /myproj --session ses-01
#
# Requirements:
#   - FreeSurfer's `mri_synthstrip` in your PATH
#   - T1w files named <sub>_<ses>_T1w.nii.gz in anat/
#
# Notes:
#   - If no SUBJECTS are provided, searches subject directories with known prefixes
#     (sub, subj, participant, etc.).
#   - Outputs go in <base-dir>/derivatives/freesurfer/<sub>/<ses>/anat
#   - Creates logs in <base-dir>/code/logs.
#
###############################################################################

BASE_DIR=""
REORIENT="no"
SESSIONS=()
SUBJECTS=()
SUBJECT_PREFIXES=("sub" "subj" "participant" "P" "pilot" "pilsub")

usage() {
    echo "Usage: $0 --base-dir <BASE_DIR> [options] [--session SESSIONS...] [SUBJECTS...]"
    echo ""
    echo "Options:"
    echo "  --base-dir <dir>  Base directory of the project (required)"
    echo "  --reorient        Apply fslreorient2std to T1w images"
    echo "  --session <ses>   Process specific session(s) (e.g. ses-01)"
    echo "  -h, --help        Show this help message"
    exit 1
}

# Parse CLI
POSITIONAL_ARGS=()
while [[ "$1" != "" ]]; do
    case $1 in
        -- )
            shift
            break
            ;;
        --base-dir )
            shift
            BASE_DIR="$1"
            ;;
        --reorient )
            REORIENT="yes"
            ;;
        --session )
            shift
            if [[ "$1" == "" || "$1" == --* ]]; then
                echo "Error: --session requires an argument"
                usage
            fi
            SESSIONS+=("$1")
            ;;
        -h|--help )
            usage
            ;;
        -* )
            echo "Unknown option: $1"
            usage
            ;;
        * )
            break
            ;;
    esac
    shift
done

while [[ "$1" != "" ]]; do
    POSITIONAL_ARGS+=("$1")
    shift
done
SUBJECTS=("${POSITIONAL_ARGS[@]}")

if [ -z "$BASE_DIR" ]; then
    echo "Error: --base-dir is required"
    usage
fi

while [ ! -d "$BASE_DIR" ]; do
    echo "Error: Base directory '$BASE_DIR' does not exist."
    read -p "Please enter a valid base directory: " BASE_DIR
done

LOG_DIR="${BASE_DIR}/code/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/run_synthstrip_extraction_$(date '+%Y-%m-%d_%H-%M-%S').log"

{
    echo "Base directory: $BASE_DIR" >> "$LOG_FILE"
    echo "Reorient: $REORIENT" >> "$LOG_FILE"
    if [ ${#SESSIONS[@]} -gt 0 ]; then
        echo "Sessions: ${SESSIONS[@]}" >> "$LOG_FILE"
    fi
    if [ ${#SUBJECTS[@]} -gt 0 ]; then
        echo "Subjects: ${SUBJECTS[@]}" >> "$LOG_FILE"
    fi
    echo "Logging to $LOG_FILE" >> "$LOG_FILE"

    SUBJECT_DIRS=()
    if [ ${#SUBJECTS[@]} -gt 0 ]; then
        for subj in "${SUBJECTS[@]}"; do
            SUBJ_DIR="$BASE_DIR/$subj"
            if [ -d "$SUBJ_DIR" ]; then
                SUBJECT_DIRS+=("$SUBJ_DIR")
            else
                echo -e "\nWarning: Subject directory not found: $SUBJ_DIR" | tee -a "$LOG_FILE"
            fi
        done
    else
        # If no subjects specified, auto-detect
        for prefix in "${SUBJECT_PREFIXES[@]}"; do
            for subj_dir in "$BASE_DIR"/${prefix}-*; do
                [ -d "$subj_dir" ] && SUBJECT_DIRS+=("$subj_dir")
            done
        done
        IFS=$'\n' SUBJECT_DIRS=($(printf "%s\n" "${SUBJECT_DIRS[@]}" | sort -uV))
    fi

    if [ ${#SUBJECT_DIRS[@]} -eq 0 ]; then
        echo -e "\nNo subject directories found."
        exit 1
    fi

    echo -e "Found ${#SUBJECT_DIRS[@]} subject directories.\n" | tee -a "$LOG_FILE"

    for SUBJ_DIR in "${SUBJECT_DIRS[@]}"; do
        SUBJ_ID="$(basename "$SUBJ_DIR")"
        echo "=== Processing Subject: $SUBJ_ID ===" | tee -a "$LOG_FILE"

        SESSION_DIRS=()
        if [ ${#SESSIONS[@]} -gt 0 ]; then
            # If specific sessions were requested
            for ses in "${SESSIONS[@]}"; do
                SES_DIR="$SUBJ_DIR/$ses"
                if [ -d "$SES_DIR" ]; then
                    SESSION_DIRS+=("$SES_DIR")
                else
                    echo "Warning: Session directory not found: $SES_DIR" | tee -a "$LOG_FILE"
                fi
            done
        else
            # Otherwise auto-detect all ses-*
            for ses_dir in "$SUBJ_DIR"/ses-*; do
                [ -d "$ses_dir" ] && SESSION_DIRS+=("$ses_dir")
            done
            IFS=$'\n' SESSION_DIRS=($(printf "%s\n" "${SESSION_DIRS[@]}" | sort -V))
        fi

        if [ ${#SESSION_DIRS[@]} -eq 0 ]; then
            echo "No sessions found for subject $SUBJ_ID" | tee -a "$LOG_FILE"
            continue
        fi

        for SES_DIR in "${SESSION_DIRS[@]}"; do
            SES_ID="$(basename "$SES_DIR")"
            echo "---Session: $SES_ID ---" | tee -a "$LOG_FILE"

            ANAT_DIR="$SES_DIR/anat"
            if [ -d "$ANAT_DIR" ]; then
                T1W_FILE="$ANAT_DIR/${SUBJ_ID}_${SES_ID}_T1w.nii.gz"
                if [ ! -f "$T1W_FILE" ]; then
                    echo "T1w image not found: $T1W_FILE" | tee -a "$LOG_FILE"
                    continue
                fi

                echo "T1w Image:  $T1W_FILE" | tee -a "$LOG_FILE"
                
                DERIV_ANAT_DIR="$BASE_DIR/derivatives/freesurfer/$SUBJ_ID/$SES_ID/anat"
                mkdir -p "$DERIV_ANAT_DIR"
                OUTPUT_FILE="$DERIV_ANAT_DIR/${SUBJ_ID}_${SES_ID}_desc-synthstrip_T1w_brain.nii.gz"

                STEP=1
                # Reorient if requested
                if [ "$REORIENT" == "yes" ]; then
                    if [ -f "$OUTPUT_FILE" ]; then
                        echo "Skull-stripped T1w image already exists: $OUTPUT_FILE" | tee -a "$LOG_FILE"
                        echo "Skipping reorientation." | tee -a "$LOG_FILE"
                        echo ""
                    else
                        echo ""
                        echo "[Step $STEP] Applying fslreorient2std:" | tee -a "$LOG_FILE"
                        echo "  - Input: $T1W_FILE" | tee -a "$LOG_FILE"
                        REORIENTED_T1W_FILE="${ANAT_DIR}/${SUBJ_ID}_${SES_ID}_desc-reoriented_T1w.nii.gz"
                        echo "  - Output (Reoriented): $REORIENTED_T1W_FILE" | tee -a "$LOG_FILE"
                        echo ""
                        
                        fslreorient2std "$T1W_FILE" "$REORIENTED_T1W_FILE"
                        if [ $? -ne 0 ]; then
                            echo "Error applying fslreorient2std for $SUBJ_ID $SES_ID" | tee -a "$LOG_FILE"
                            continue
                        fi
                        # Update T1W_FILE to point to the newly reoriented file
                        T1W_FILE="$REORIENTED_T1W_FILE"
                        STEP=$((STEP+1))
                        
                        
                    fi
                        
                        
                        
                fi

                echo "[Step $STEP] Running SynthStrip:" | tee -a "$LOG_FILE"
                echo "  - Input: $T1W_FILE" | tee -a "$LOG_FILE"


                echo "  - Command: mri_synthstrip --i \"$T1W_FILE\" --o \"$OUTPUT_FILE\"" | tee -a "$LOG_FILE"
                echo ""

                if [ -f "$OUTPUT_FILE" ]; then
                    echo "SynthStrip T1w image already exists: $OUTPUT_FILE" | tee -a "$LOG_FILE"
                    echo "" 
                else
                    mri_synthstrip --i "$T1W_FILE" --o "$OUTPUT_FILE"
                    if [ $? -ne 0 ]; then
                        echo "Error during SynthStrip skull stripping for $SUBJ_ID $SES_ID" | tee -a "$LOG_FILE"
                        echo ""
                        continue
                    fi

                    if [ "$REORIENT" == "yes" ]; then
                        STEP=$((STEP+1))
                        echo "[Step $STEP] Cleaning Up Temporary Files:" | tee -a "$LOG_FILE"
                        echo "  - Removed: $REORIENTED_T1W_FILE" | tee -a "$LOG_FILE"
                        rm "$REORIENTED_T1W_FILE"
                        echo ""
                    fi

                    echo "SynthStrip completed at:" | tee -a "$LOG_FILE"
                    echo "  - Output: $OUTPUT_FILE" | tee -a "$LOG_FILE"
                    echo "" | tee -a "$LOG_FILE"
                fi
            else
                echo "Anatomical directory not found: $ANAT_DIR" | tee -a "$LOG_FILE"
            fi
        done
    done

    echo "SynthStrip skull stripping completed."
    echo "------------------------------------------------------------------------------"
} 2>&1 | tee -a "$LOG_FILE"
