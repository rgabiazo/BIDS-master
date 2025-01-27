#!/bin/bash

# Field Map Correction Script (run_fieldmap_correction.sh)

BASE_DIR=""
SESSIONS=()
SUBJECTS=()
PREPROCESSING_TYPE=""
SUBJECT_PREFIXES=("sub" "pilot")

usage() {
    echo "Usage: $0 --base-dir BASE_DIR [options] [--session SESSIONS...] [--preproc-type task|rest] [SUBJECTS...]"
    exit 1
}

# Parse arguments
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
        --session )
            shift
            if [[ "$1" == "" || "$1" == --* ]]; then
                echo "Error: --session requires an argument"
                usage
            fi
            SESSIONS+=("$1")
            ;;
        --preproc-type )
            shift
            if [[ "$1" != "task" && "$1" != "rest" ]]; then
                echo "Error: --preproc-type must be 'task' or 'rest'"
                usage
            fi
            PREPROCESSING_TYPE="$1"
            ;;
        -h | --help )
            usage
            ;;
        --* )
            echo "Unknown option: $1"
            usage
            ;;
        * )
            SUBJECTS+=("$1")
            ;;
    esac
    shift
done

while [[ "$1" != "" ]]; do
    SUBJECTS+=("$1")
    shift
done

if [ -z "$BASE_DIR" ]; then
    echo "Error: --base-dir is required"
    usage
fi

if [ -z "$PREPROCESSING_TYPE" ]; then
    echo "Error: --preproc-type is required and must be 'task' or 'rest'"
    usage
fi

while [ ! -d "$BASE_DIR" ]; do
    echo "Error: Base directory '$BASE_DIR' does not exist."
    read -p "Please enter a valid base directory: " BASE_DIR
done

LOG_DIR="${BASE_DIR}/code/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/run_fieldmap_correction_$(date '+%Y-%m-%d_%H-%M-%S').log"

shopt -s extglob

{
    if [ ${#SUBJECTS[@]} -eq 0 ]; then
        SUBJECTS=()
        for prefix in "${SUBJECT_PREFIXES[@]}"; do
            for subj_dir in "$BASE_DIR"/${prefix}-*; do
                [ -d "$subj_dir" ] && SUBJECTS+=("$(basename "$subj_dir")")
            done
        done
        IFS=$'\n' SUBJECTS=($(printf "%s\n" "${SUBJECTS[@]}" | sort -uV))
    fi

    SUBJECT_COUNT=${#SUBJECTS[@]}
    echo "Found $SUBJECT_COUNT subject directories."
    echo ""

    for SUBJ_ID in "${SUBJECTS[@]}"; do
        echo "=== Processing subject: $SUBJ_ID ==="

        SESSION_DIRS=()
        if [ ${#SESSIONS[@]} -gt 0 ]; then
            for ses in "${SESSIONS[@]}"; do
                if [ -d "$BASE_DIR/$SUBJ_ID/$ses" ]; then
                    SESSION_DIRS+=("$BASE_DIR/$SUBJ_ID/$ses")
                fi
            done
        else
            for ses_dir in "$BASE_DIR/$SUBJ_ID"/ses-*; do
                [ -d "$ses_dir" ] && SESSION_DIRS+=("$ses_dir")
            done
            IFS=$'\n' SESSION_DIRS=($(printf "%s\n" "${SESSION_DIRS[@]}" | sort -V))
        fi

        if [ ${#SESSION_DIRS[@]} -eq 0 ]; then
            echo "No sessions found for subject $SUBJ_ID"
            continue
        fi

        for SES_DIR in "${SESSION_DIRS[@]}"; do
            SES_ID="$(basename "$SES_DIR")"
            FUNC_DIR="$SES_DIR/func"
            [ ! -d "$FUNC_DIR" ] && continue

            BOLD_FILES=()
            if [ "$PREPROCESSING_TYPE" == "task" ]; then
                while IFS= read -r line; do
                    BOLD_FILES+=("$line")
                done < <(find "$FUNC_DIR" -type f -name "*_task-*_bold.nii.gz" ! -name "*_task-rest_bold.nii.gz" | sort -V)
            else
                while IFS= read -r line; do
                    BOLD_FILES+=("$line")
                done < <(find "$FUNC_DIR" -type f -name "*_task-rest_bold.nii.gz" | sort -V)
            fi

            DERIV_TOPUP_DIR="$BASE_DIR/derivatives/fsl/topup/$SUBJ_ID/$SES_ID"
            FUNC_DERIV_DIR="$DERIV_TOPUP_DIR/func"
            FMAP_DERIV_DIR="$DERIV_TOPUP_DIR/fmap"
            mkdir -p "$FUNC_DERIV_DIR" "$FMAP_DERIV_DIR"

            for BOLD_FILE in "${BOLD_FILES[@]}"; do
                BOLD_BASENAME="$(basename "$BOLD_FILE" .nii.gz)"
                # Determine run number only if task-based and not rest
                if [ "$PREPROCESSING_TYPE" == "task" ]; then
                    RUN_NUMBER=$(echo "$BOLD_BASENAME" | grep -o 'run-[0-9]\+')
                    [ -z "$RUN_NUMBER" ] && RUN_NUMBER="run-01"
                    RUN_NUMBER_ENTITY="_${RUN_NUMBER}"
                else
                    RUN_NUMBER=""
                    RUN_NUMBER_ENTITY=""
                fi

                TASK_NAME=$(echo "$BOLD_BASENAME" | grep -o 'task-[^_]\+' | sed 's/task-//')
                if [ "$PREPROCESSING_TYPE" == "rest" ]; then
                    DISPLAY_LINE="--- Session: $SES_ID (rest) ---"
                else
                    DISPLAY_LINE="--- Session: $SES_ID | ${RUN_NUMBER:-run-01} ---"
                fi

                echo "$DISPLAY_LINE"
                echo "BOLD file: $BOLD_FILE"
                echo ""

                CORRECTED_BOLD="$FUNC_DERIV_DIR/${BOLD_BASENAME/_bold/_desc-topupcorrected_bold}.nii.gz"
                if [ -f "$CORRECTED_BOLD" ]; then
                    echo "Topup correction already applied for $SUBJ_ID $SES_ID $RUN_NUMBER. Skipping."
                    echo ""
                    continue
                fi

                echo "Correcting BOLD data for susceptibility distortions using topup for $SUBJ_ID $SES_ID $RUN_NUMBER."

                if [ -n "$TASK_NAME" ]; then
                    TASK_ENTITY="_task-${TASK_NAME}"
                else
                    TASK_ENTITY=""
                fi

                AP_IMAGE="$FMAP_DERIV_DIR/${SUBJ_ID}_${SES_ID}${TASK_ENTITY}${RUN_NUMBER_ENTITY}_acq-AP_epi.nii.gz"
                PA_IMAGE="$FMAP_DERIV_DIR/${SUBJ_ID}_${SES_ID}${TASK_ENTITY}${RUN_NUMBER_ENTITY}_acq-PA_epi.nii.gz"
                ACQ_PARAMS_FILE="$FMAP_DERIV_DIR/${SUBJ_ID}_${SES_ID}${TASK_ENTITY}${RUN_NUMBER_ENTITY}_acq-params.txt"
                MERGED_AP_PA="$FMAP_DERIV_DIR/${SUBJ_ID}_${SES_ID}${TASK_ENTITY}${RUN_NUMBER_ENTITY}_acq-AP_PA_merged.nii.gz"
                TOPUP_OUTPUT_BASE="$FMAP_DERIV_DIR/${SUBJ_ID}_${SES_ID}${TASK_ENTITY}${RUN_NUMBER_ENTITY}_topup"

                echo ""
                echo "[Step 1] Extracting first volume of BOLD (AP):"
                echo "  - Input BOLD file: $BOLD_FILE"
                echo "  - Output AP image: $AP_IMAGE"
                fslroi "$BOLD_FILE" "$AP_IMAGE" 0 1

                BOLD_JSON="${BOLD_FILE%.nii.gz}.json"
                PHASE_DIR=$(jq -r '.PhaseEncodingDirection' "$BOLD_JSON")
                READOUT_TIME=$(jq -r '.TotalReadoutTime' "$BOLD_JSON")

                # Find PA file
                if [ "$PREPROCESSING_TYPE" == "task" ]; then
                    if [ -n "$TASK_NAME" ]; then
                        PA_FILE=$(find "$FUNC_DIR" -type f -name "*task-${TASK_NAME}_dir-PA_epi.nii.gz" ! -name "*rest*" | sort -V | head -n 1)
                    fi
                    if [ -z "$PA_FILE" ]; then
                        PA_FILE=$(find "$FUNC_DIR" -type f -name "*_dir-PA_epi.nii.gz" ! -name "*rest*" | sort -V | head -n 1)
                    fi
                else
                    PA_FILE=$(find "$FUNC_DIR" -type f -name "*_task-rest_dir-PA_epi.nii.gz" | sort -V | head -n 1)
                    if [ -z "$PA_FILE" ]; then
                        PA_FILE=$(find "$FUNC_DIR" -type f -name "*_dir-PA_epi.nii.gz" | sort -V | head -n 1)
                    fi
                fi

                echo ""
                echo "[Step 2] Extracting first volume of PA:"
                if [ -z "$PA_FILE" ]; then
                    echo "  - No PA image found. Skipping topup for this run."
                    echo ""
                    continue
                else
                    echo "  - Input PA image: $PA_FILE"
                    echo "  - Output PA image: $PA_IMAGE"
                    fslroi "$PA_FILE" "$PA_IMAGE" 0 1
                fi

                PA_JSON="${PA_FILE%.nii.gz}.json"
                PA_PHASE_DIR=$(jq -r '.PhaseEncodingDirection' "$PA_JSON")
                PA_READOUT_TIME=$(jq -r '.TotalReadoutTime' "$PA_JSON")

                if [[ "$PHASE_DIR" == "j-" ]]; then
                    echo "0 -1 0 $READOUT_TIME" > "$ACQ_PARAMS_FILE"
                elif [[ "$PHASE_DIR" == "j" ]]; then
                    echo "0 1 0 $READOUT_TIME" > "$ACQ_PARAMS_FILE"
                else
                    echo "Unsupported PhaseEncodingDirection: $PHASE_DIR. Skipping."
                    continue
                fi

                if [[ "$PA_PHASE_DIR" == "j" ]]; then
                    echo "0 1 0 $PA_READOUT_TIME" >> "$ACQ_PARAMS_FILE"
                elif [[ "$PA_PHASE_DIR" == "j-" ]]; then
                    echo "0 -1 0 $PA_READOUT_TIME" >> "$ACQ_PARAMS_FILE"
                else
                    echo "Unsupported PhaseEncodingDirection for PA: $PA_PHASE_DIR. Skipping."
                    continue
                fi

                echo ""
                echo "[Step 3] Merging AP and PA images:"
                echo "  - Input AP: $AP_IMAGE"
                echo "  - Input PA: $PA_IMAGE"
                echo "  - Output: $MERGED_AP_PA"
                fslmerge -t "$MERGED_AP_PA" "$AP_IMAGE" "$PA_IMAGE"

                echo ""
                echo "[Step 4] Estimating susceptibility (topup):"
                echo "  - Input (merged AP and PA): $MERGED_AP_PA"
                echo "  - Acquisition parameters file: $ACQ_PARAMS_FILE"
                echo "  - Output base: ${TOPUP_OUTPUT_BASE}_results"
                echo "  - Fieldmap output: ${TOPUP_OUTPUT_BASE}_fieldmap.nii.gz"
                topup --imain="$MERGED_AP_PA" --datain="$ACQ_PARAMS_FILE" --config=b02b0.cnf \
                      --out="${TOPUP_OUTPUT_BASE}_results" --fout="${TOPUP_OUTPUT_BASE}_fieldmap.nii.gz"

                echo ""
                echo "[Step 5] Applying topup to BOLD data:"
                echo "  - Input: $BOLD_FILE"
                echo "  - Output: $CORRECTED_BOLD"
                applytopup --imain="$BOLD_FILE" --topup="${TOPUP_OUTPUT_BASE}_results" \
                           --datain="$ACQ_PARAMS_FILE" --inindex=1 --method=jac --out="$CORRECTED_BOLD"

                if [ "$PREPROCESSING_TYPE" == "task" ]; then
                    if [ -n "$TASK_NAME" ]; then
                        FIELD_MAP="$FMAP_DERIV_DIR/${SUBJ_ID}_${SES_ID}_task-${TASK_NAME}${RUN_NUMBER_ENTITY}_fieldmap.nii.gz"
                    else
                        FIELD_MAP="$FMAP_DERIV_DIR/${SUBJ_ID}_${SES_ID}${RUN_NUMBER_ENTITY}_fieldmap.nii.gz"
                    fi
                else
                    FIELD_MAP="$FMAP_DERIV_DIR/${SUBJ_ID}_${SES_ID}_task-rest_fieldmap.nii.gz"
                fi
                mv "${TOPUP_OUTPUT_BASE}_fieldmap.nii.gz" "$FIELD_MAP"

                # Cleanup
                rm -f "$AP_IMAGE" "$PA_IMAGE" "$MERGED_AP_PA" "${TOPUP_OUTPUT_BASE}_results_fieldcoef.nii.gz" "${TOPUP_OUTPUT_BASE}_results_movpar.txt"
                echo ""
            done
        done
    done

    echo "Fieldmap correction completed."
    echo "------------------------------------------------------------------------------"
} 2>&1 | tee -a "$LOG_FILE"
