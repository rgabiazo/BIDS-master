#!/bin/bash

# fmri_preprocessing.sh
#
# Description:
# This script orchestrates fMRI preprocessing steps including:
#   - Skull stripping (BET or SynthStrip)
#   - Field map correction (topup)
#   - Conversion of events from TSV to TXT for FEAT (task-based only)
#   - Slice timing extraction from BOLD JSON files
#
# It leverages modular helper scripts:
#   - run_bet_extraction.sh
#   - run_synthstrip_extraction.sh
#   - run_fieldmap_correction.sh
#   - create_event_files.sh
#   - extract_slice_timing.sh
#
# Requirements:
#   - Homebrew for managing packages
#   - FSL (installed at /usr/local/fsl)
#   - FreeSurfer (if using SynthStrip)
#   - jq for JSON parsing (brew install jq)
#
# Usage:
#   1. Place this script in `code/scripts` of your BIDS project.
#   2. Run: ./fmri_preprocessing.sh
#   3. Follow interactive prompts.
#
# Outputs:
#   - Logs in `code/logs`.
#   - Skull-stripped images in `derivatives/fsl` or `derivatives/freesurfer`.
#   - Field map corrected data in `derivatives/fsl/topup`.
#   - Event files in `derivatives/custom_events`.
#   - Slice timing files in `derivatives/slice_timing`.

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
BASE_DIR_DEFAULT="$(dirname "$(dirname "$SCRIPT_DIR")")"

echo -e "\n=== fMRI Preprocessing Pipeline ==="

# Prompt for base directory
echo -e "\nPlease enter the base directory for the project or hit Enter/Return to use the default [$BASE_DIR_DEFAULT]:"
read -p "> " BASE_DIR_INPUT

if [ -z "$BASE_DIR_INPUT" ]; then
    BASE_DIR="$BASE_DIR_DEFAULT"
else
    BASE_DIR="$BASE_DIR_INPUT"
fi

echo -e "Using base directory: $BASE_DIR\n"

LOG_DIR="${BASE_DIR}/code/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/task_fmri_preprocessing_$(date '+%Y-%m-%d_%H-%M-%S').log"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "Starting preprocessing pipeline at $(date)" >> "$LOG_FILE"
echo "Base directory: $BASE_DIR" >> "$LOG_FILE"
echo "Script directory: $SCRIPT_DIR" >> "$LOG_FILE"
echo "Log file: $LOG_FILE" >> "$LOG_FILE"

# Preprocessing type
while true; do
    echo "Is the preprocessing for task-based fMRI or resting-state fMRI?"
    echo "1. Task-based"
    echo "2. Resting-state"
    read -p "Enter the number corresponding to your choice: " PREPROC_CHOICE
    case $PREPROC_CHOICE in
        1 )
            PREPROCESSING_TYPE="task"
            break;;
        2 )
            PREPROCESSING_TYPE="rest"
            break;;
        * )
            echo "Please enter 1 or 2."
            ;;
    esac
done

# Skull stripping?
while true; do
    echo ""
    read -p "Apply skull stripping? (y/n): " APPLY_SKULL_STRIP
    case $APPLY_SKULL_STRIP in
        [Yy]* ) APPLY_SKULL_STRIP="yes"; break;;
        [Nn]* ) APPLY_SKULL_STRIP="no"; break;;
        * ) echo "Please answer y or n.";;
    esac
done

if [ "$APPLY_SKULL_STRIP" == "yes" ]; then
    echo "Please select a skull stripping tool:"
    echo "1. BET (FSL)"
    echo "2. SynthStrip (FreeSurfer)"
    read -p "Enter your choice: " SKULL_STRIP_TOOL_CHOICE
    case $SKULL_STRIP_TOOL_CHOICE in
        1 ) SKULL_STRIP_TOOL="BET";;
        2 ) SKULL_STRIP_TOOL="SynthStrip";;
        * ) echo "Invalid choice. Defaulting to BET."; SKULL_STRIP_TOOL="BET";;
    esac

    if [ "$SKULL_STRIP_TOOL" == "BET" ]; then
        echo "Select a BET option:"
        echo "1. Standard (bet2)"
        echo "2. Robust center (-R)"
        echo "3. Eye cleanup (-S)"
        echo "4. Bias/neck cleanup (-B)"
        echo "5. Small FOV fix (-Z)"
        echo "6. Apply to 4D fMRI (-F)"
        echo "7. bet2 + betsurf (-A)"
        while true; do
            read -p "Enter your choice: " BET_OPTION_CHOICE
            case $BET_OPTION_CHOICE in
                1 ) BET_OPTION=""; BET_OPTION_DESC="Standard"; break;;
                2 ) BET_OPTION="-R"; BET_OPTION_DESC="Robust center"; break;;
                3 ) BET_OPTION="-S"; BET_OPTION_DESC="Eye cleanup"; break;;
                4 ) BET_OPTION="-B"; BET_OPTION_DESC="Bias/neck cleanup"; break;;
                5 ) BET_OPTION="-Z"; BET_OPTION_DESC="Small FOV fix"; break;;
                6 ) BET_OPTION="-F"; BET_OPTION_DESC="4D fMRI"; break;;
                7 ) BET_OPTION="-A"; BET_OPTION_DESC="bet2+betsurf"; break;;
                * ) echo "Invalid choice.";;
            esac
        done

        while true; do
            read -p "Fractional intensity threshold (0 to 1, default 0.5): " FRAC_INTENSITY
            if [[ -z "$FRAC_INTENSITY" ]]; then
                FRAC_INTENSITY=0.5
                break
            elif [[ "$FRAC_INTENSITY" =~ ^0(\.[0-9]+)?$|^1(\.0+)?$ ]]; then
                break
            else
                echo "Please enter a number between 0 and 1."
            fi
        done
        echo "Using frac intensity: $FRAC_INTENSITY"
    fi
fi

# Reorient?
while true; do
    echo ""
    read -p "Apply fslreorient2std to all T1w images? (y/n): " APPLY_REORIENT_ALL
    case $APPLY_REORIENT_ALL in
        [Yy]* ) APPLY_REORIENT_ALL="yes"; break;;
        [Nn]* ) APPLY_REORIENT_ALL="no"; break;;
        * ) echo "Please answer y or n.";;
    esac
done

# Fieldmap correction
while true; do
    echo ""
    read -p "Apply fieldmap correction using topup? (y/n): " APPLY_TOPUP
    case $APPLY_TOPUP in
        [Yy]* ) APPLY_TOPUP="yes"; break;;
        [Nn]* ) APPLY_TOPUP="no"; break;;
        * ) echo "Please answer y or n.";;
    esac
done

# Task-based specific
if [ "$PREPROCESSING_TYPE" == "task" ]; then
    while true; do
        echo ""
        read -p "Create .txt event files from .tsv? (y/n): " CREATE_TXT_EVENTS
        case $CREATE_TXT_EVENTS in
            [Yy]* ) CREATE_TXT_EVENTS="yes"; break;;
            [Nn]* ) CREATE_TXT_EVENTS="no"; break;;
            * ) echo "Please answer y or n.";;
        esac
    done
    if [ "$CREATE_TXT_EVENTS" == "yes" ]; then
        read -p "Enter number of runs: " NUM_RUNS
        while ! [[ "$NUM_RUNS" =~ ^[0-9]+$ ]]; do
            echo "Invalid number."
            read -p "Enter number of runs: " NUM_RUNS
        done
        echo "Enter trial types (e.g., encoding_pair recog_pair):"
        read -a TRIAL_TYPES_ARRAY
    fi

    while true; do
        echo ""
        read -p "Extract slice timing from BOLD JSON? (y/n): " EXTRACT_SLICE_TIMING
        case $EXTRACT_SLICE_TIMING in
            [Yy]* ) EXTRACT_SLICE_TIMING="yes"; break;;
            [Nn]* ) EXTRACT_SLICE_TIMING="no"; break;;
            * ) echo "Please answer y or n.";;
        esac
    done
else
    CREATE_TXT_EVENTS="no"
    EXTRACT_SLICE_TIMING="no"
fi

# Subjects/sessions
echo -e "\nEnter subject IDs (e.g., sub-01 sub-02) or press Enter for all:"
read -p "> " -a SUBJECTS_ARRAY

echo -e "\nEnter session IDs (e.g., ses-01 ses-02) or press Enter for all:"
read -p "> " -a SESSIONS_ARRAY

# Run skull stripping
if [ "$APPLY_SKULL_STRIP" == "yes" ]; then
    if [ "$SKULL_STRIP_TOOL" == "BET" ]; then
        echo -e "\n=== Running BET skull stripping ===\n"
        BET_ARGS=("--base-dir" "$BASE_DIR")
        [ "$APPLY_REORIENT_ALL" == "yes" ] && BET_ARGS+=("--reorient")
        [ -n "$BET_OPTION" ] && BET_ARGS+=("--bet-option" "$BET_OPTION")
        [ -n "$FRAC_INTENSITY" ] && BET_ARGS+=("--frac" "$FRAC_INTENSITY")
        for session in "${SESSIONS_ARRAY[@]}"; do
            BET_ARGS+=("--session" "$session")
        done
        if [ ${#SUBJECTS_ARRAY[@]} -gt 0 ]; then
            BET_ARGS+=("--")
            BET_ARGS+=("${SUBJECTS_ARRAY[@]}")
        fi
        "${SCRIPT_DIR}/run_bet_extraction.sh" "${BET_ARGS[@]}"
    else
        echo -e "\n=== Running SynthStrip skull stripping ===\n"
        SYNTHSTRIP_ARGS=("--base-dir" "$BASE_DIR")
        [ "$APPLY_REORIENT_ALL" == "yes" ] && SYNTHSTRIP_ARGS+=("--reorient")
        for session in "${SESSIONS_ARRAY[@]}"; do
            SYNTHSTRIP_ARGS+=("--session" "$session")
        done
        if [ ${#SUBJECTS_ARRAY[@]} -gt 0 ]; then
            SYNTHSTRIP_ARGS+=("--")
            SYNTHSTRIP_ARGS+=("${SUBJECTS_ARRAY[@]}")
        fi
        "${SCRIPT_DIR}/run_synthstrip_extraction.sh" "${SYNTHSTRIP_ARGS[@]}"
    fi
fi

# Fieldmap correction
if [ "$APPLY_TOPUP" == "yes" ]; then
    echo -e "\n=== Applying fieldmap correction ===\n"
    TOPUP_ARGS=("--base-dir" "$BASE_DIR" "--preproc-type" "$PREPROCESSING_TYPE")
    for session in "${SESSIONS_ARRAY[@]}"; do
        TOPUP_ARGS+=("--session" "$session")
    done
    if [ ${#SUBJECTS_ARRAY[@]} -gt 0 ]; then
        TOPUP_ARGS+=("--")
        TOPUP_ARGS+=("${SUBJECTS_ARRAY[@]}")
    fi
    "${SCRIPT_DIR}/run_fieldmap_correction.sh" "${TOPUP_ARGS[@]}"
fi

# Events
if [ "$CREATE_TXT_EVENTS" == "yes" ]; then
    echo -e "\n=== Creating event files ==="
    EVENT_ARGS=("--base-dir" "$BASE_DIR" "--num-runs" "$NUM_RUNS")
    for ttype in "${TRIAL_TYPES_ARRAY[@]}"; do
        EVENT_ARGS+=("--trial-type" "$ttype")
    done
    for session in "${SESSIONS_ARRAY[@]}"; do
        EVENT_ARGS+=("--session" "$session")
    done
    if [ ${#SUBJECTS_ARRAY[@]} -gt 0 ]; then
        EVENT_ARGS+=("--")
        EVENT_ARGS+=("${SUBJECTS_ARRAY[@]}")
    fi
    "${SCRIPT_DIR}/create_event_files.sh" "${EVENT_ARGS[@]}"
fi

# Slice timing
if [ "$EXTRACT_SLICE_TIMING" == "yes" ]; then
    echo -e "\n=== Extracting slice timing ==="
    ST_ARGS=("--base-dir" "$BASE_DIR")
    for session in "${SESSIONS_ARRAY[@]}"; do
        ST_ARGS+=("--session" "$session")
    done
    if [ ${#SUBJECTS_ARRAY[@]} -gt 0 ]; then
        ST_ARGS+=("--")
        ST_ARGS+=("${SUBJECTS_ARRAY[@]}")
    fi
    "${SCRIPT_DIR}/extract_slice_timing.sh" "${ST_ARGS[@]}"
fi

echo -e "\n=== Preprocessing pipeline completed ===\n"
echo -e "\n=== Preprocessing pipeline completed at $(date) ===\n" >> "$LOG_FILE"
