#!/bin/bash

# BET Skull Stripping Script (run_bet_extraction.sh)

# Default values
BASE_DIR=""
REORIENT="no"
BET_OPTION=""
FRAC_INTENSITY="0.5"
SESSIONS=()
SUBJECTS=()
SUBJECT_PREFIXES=("sub" "subj" "participant" "P" "pilot" "pilsub")

usage() {
    echo "Usage: $0 --base-dir BASE_DIR [options] [SUBJECTS...]"
    echo ""
    echo "Options:"
    echo "  --base-dir BASE_DIR       Base directory of the project (required)"
    echo "  --reorient                Apply fslreorient2std to T1w images"
    echo "  --bet-option BET_OPTION   BET option flag (e.g., -R, -S, etc.)"
    echo "  --frac FRAC_INTENSITY     Fractional intensity threshold (default: 0.5)"
    echo "  --session SESSION         Session(s) to process (e.g., --session ses-01)"
    echo "  SUBJECTS                  Subjects (e.g., sub-01 sub-02)"
    exit 1
}

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
        --bet-option )
            shift
            BET_OPTION="$1"
            ;;
        --frac )
            shift
            FRAC_INTENSITY="$1"
            ;;
        --session )
            shift
            if [[ "$1" == "" || "$1" == --* ]]; then
                echo "Error: --session requires an argument"
                usage
            fi
            SESSIONS+=("$1")
            ;;
        -h | --help )
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
    echo -e "\nError: Base directory '$BASE_DIR' does not exist."
    read -p "Please enter a valid base directory: " BASE_DIR
done

LOG_DIR="${BASE_DIR}/code/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/run_bet_extraction_$(date '+%Y-%m-%d_%H-%M-%S').log"

{
    # NOTE: We do not print "=== Running BET skull stripping ===" here to avoid duplication.
    # It is printed by fmri_preprocessing.sh.

    echo "Base directory: $BASE_DIR" >> $LOG_FILE
    echo "Reorient: $REORIENT" >> $LOG_FILE
    echo "BET option: $BET_OPTION" >> $LOG_FILE
    echo "Fractional intensity threshold: $FRAC_INTENSITY" >> $LOG_FILE
    if [ ${#SESSIONS[@]} -gt 0 ]; then
        echo "Sessions: ${SESSIONS[@]}" >> $LOG_FILE
    fi
    if [ ${#SUBJECTS[@]} -gt 0 ]; then
        echo "Subjects: ${SUBJECTS[@]}" >> $LOG_FILE
    fi
    echo "Logging to: $LOG_FILE" >> $LOG_FILE

    SUBJECT_DIRS=()
    if [ ${#SUBJECTS[@]} -gt 0 ]; then
        for subj in "${SUBJECTS[@]}"; do
            SUBJ_DIR="$BASE_DIR/$subj"
            if [ -d "$SUBJ_DIR" ]; then
                SUBJECT_DIRS+=("$SUBJ_DIR")
            else
                echo -e "Warning: Subject directory not found:\n  - $SUBJ_DIR" | tee -a "$LOG_FILE"
            fi
        done
    else
        for prefix in "${SUBJECT_PREFIXES[@]}"; do
            for subj_dir in "$BASE_DIR"/${prefix}-*; do
                if [ -d "$subj_dir" ]; then
                    SUBJECT_DIRS+=("$subj_dir")
                fi
            done
        done
        IFS=$'\n' SUBJECT_DIRS=($(printf "%s\n" "${SUBJECT_DIRS[@]}" | sort -uV))
    fi

    if [ ${#SUBJECT_DIRS[@]} -eq 0 ]; then
        echo -e "\nNo subject directories found.\n" | tee -a "$LOG_FILE"
        exit 1
    fi

    echo -e "Found ${#SUBJECT_DIRS[@]} subject directories.\n" | tee -a "$LOG_FILE"

    for SUBJ_DIR in "${SUBJECT_DIRS[@]}"; do
        SUBJ_ID="$(basename "$SUBJ_DIR")"
        echo "=== Processing Subject: $SUBJ_ID ===" | tee -a "$LOG_FILE"

        SESSION_DIRS=()
        if [ ${#SESSIONS[@]} -gt 0 ]; then
            for ses in "${SESSIONS[@]}"; do
                SES_DIR="$SUBJ_DIR/$ses"
                if [ -d "$SES_DIR" ]; then
                    SESSION_DIRS+=("$SES_DIR")
                else
                    echo -e "Warning: Session directory not found:\n  - $SES_DIR" | tee -a "$LOG_FILE"
                fi
            done
        else
            for ses_dir in "$SUBJ_DIR"/ses-*; do
                if [ -d "$ses_dir" ]; then
                    SESSION_DIRS+=("$ses_dir")
                fi
            done
            IFS=$'\n' SESSION_DIRS=($(printf "%s\n" "${SESSION_DIRS[@]}" | sort -V))
        fi

        if [ ${#SESSION_DIRS[@]} -eq 0 ]; then
            echo -e "No sessions found for subject: $SUBJ_ID\n" | tee -a "$LOG_FILE"
            continue
        fi

        for SES_DIR in "${SESSION_DIRS[@]}"; do
            SES_ID="$(basename "$SES_DIR")"
            echo "--- Session: $SES_ID ---" | tee -a "$LOG_FILE"

            ANAT_DIR="$SES_DIR/anat"
            if [ -d "$ANAT_DIR" ]; then
                T1W_FILE="$ANAT_DIR/${SUBJ_ID}_${SES_ID}_T1w.nii.gz"
                if [ ! -f "$T1W_FILE" ]; then
                    echo -e "\nT1w image not found:\n  - $T1W_FILE\n" | tee -a "$LOG_FILE"
                    continue
                fi

                echo "T1w Image:  $T1W_FILE" | tee -a "$LOG_FILE"

                STEP=1
                if [ "$REORIENT" == "yes" ]; then
                    echo ""
                    echo "[Step $STEP] Applying fslreorient2std:" | tee -a "$LOG_FILE"
                    echo "  - Input: $T1W_FILE" | tee -a "$LOG_FILE"
                    REORIENTED_T1W_FILE="${ANAT_DIR}/${SUBJ_ID}_${SES_ID}_T1w_reoriented.nii.gz"
                    echo "  - Output (Reoriented): $REORIENTED_T1W_FILE" | tee -a "$LOG_FILE"
                    fslreorient2std "$T1W_FILE" "$REORIENTED_T1W_FILE"
                    if [ $? -ne 0 ]; then
                        echo -e "Error applying fslreorient2std for $SUBJ_ID $SES_ID\n" | tee -a "$LOG_FILE"
                        continue
                    fi
                    T1W_FILE="$REORIENTED_T1W_FILE"
                    STEP=$((STEP+1))
                    echo ""
                fi

                echo "[Step $STEP] Running BET Brain Extraction:" | tee -a "$LOG_FILE"
                echo "  - Input: $T1W_FILE" | tee -a "$LOG_FILE"

                DERIV_ANAT_DIR="$BASE_DIR/derivatives/fsl/$SUBJ_ID/$SES_ID/anat"
                mkdir -p "$DERIV_ANAT_DIR"

                cp "$T1W_FILE" "$DERIV_ANAT_DIR/"

                BET_SUFFIX=""
                if [ -n "$BET_OPTION" ]; then
                    BET_SUFFIX="${BET_OPTION:1}"
                fi
                FRAC_INT_SUFFIX="f$(echo $FRAC_INTENSITY | sed 's/\.//')"

                OUTPUT_FILE="$DERIV_ANAT_DIR/${SUBJ_ID}_${SES_ID}_desc-${BET_SUFFIX}${FRAC_INT_SUFFIX}_T1w_brain.nii.gz"

                echo "  - Command: bet \"$T1W_FILE\" \"$OUTPUT_FILE\" $BET_OPTION -f \"$FRAC_INTENSITY\"" | tee -a "$LOG_FILE"

                if [ -f "$OUTPUT_FILE" ]; then
                    echo -e "\nSkull-stripped T1w image already exists:\n  - $OUTPUT_FILE\n" | tee -a "$LOG_FILE"
                else
                    bet "$T1W_FILE" "$OUTPUT_FILE" $BET_OPTION -f "$FRAC_INTENSITY"
                    if [ $? -ne 0 ]; then
                        echo -e "Error during BET skull stripping for $SUBJ_ID $SES_ID\n" | tee -a "$LOG_FILE"
                        continue
                    fi

                    STEP=$((STEP+1))
                    echo "" | tee -a "$LOG_FILE"
                    echo "[Step $STEP] Cleaning Up Temporary Files:" | tee -a "$LOG_FILE"
                    if [ "$REORIENT" == "yes" ]; then
                        echo "  - Removed: $DERIV_ANAT_DIR/${SUBJ_ID}_${SES_ID}_T1w_reoriented.nii.gz" | tee -a "$LOG_FILE"
                        rm "$DERIV_ANAT_DIR/${SUBJ_ID}_${SES_ID}_T1w_reoriented.nii.gz"
                    else
                        echo "  - Removed: $DERIV_ANAT_DIR/${SUBJ_ID}_${SES_ID}_T1w.nii.gz" | tee -a "$LOG_FILE"
                        rm "$DERIV_ANAT_DIR/${SUBJ_ID}_${SES_ID}_T1w.nii.gz"
                    fi

                    echo "" | tee -a "$LOG_FILE"
                    echo "BET Brain Extraction completed at:" | tee -a "$LOG_FILE"
                    echo "  - Output: $OUTPUT_FILE" | tee -a "$LOG_FILE"
                    echo "" | tee -a "$LOG_FILE"
                fi
            else
                echo -e "Anatomical directory not found:\n  - $ANAT_DIR\n" | tee -a "$LOG_FILE"
            fi
        done
    done

    echo -e "\nBET skull stripping completed."
    echo "------------------------------------------------------------------------------"

} 2>&1 | tee -a "$LOG_FILE"
