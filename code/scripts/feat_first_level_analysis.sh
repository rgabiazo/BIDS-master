#!/bin/bash

# feat_first_level_analysis.sh
#
# This script sets up and runs FEAT first-level analysis in FSL. It prompts the user for:
# - The base directory for a BIDS-formatted dataset.
# - Whether to apply ICA-AROMA for denoising.
# - Whether to apply slice timing correction (if yes, `set fmri(st) 4`, if no, `set fmri(st) 0`).
# - Whether to apply BBR registration.
# - Whether to apply nuisance regression after ICA-AROMA (if ICA-AROMA is applied).
# - Whether to run main FEAT analysis after ICA-AROMA (if ICA-AROMA is applied).
# - If main FEAT analysis is to be run, whether to apply high-pass filtering. If the user doesn't specify a cutoff, it defaults to 100 seconds.
# - If main FEAT analysis is to be run, prompts for EVs and condition names.
#
# Usage:
#   1. Make sure the script is executable: chmod +x feat_first_level_analysis.sh
#   2. Run the script: ./feat_first_level_analysis.sh
#   3. Follow the prompts.
#
# Outputs are placed under derivatives/fsl/level-1, categorized according to whether ICA-AROMA
# and/or main stats are performed.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR_DEFAULT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo -e "\n=== First-Level Analysis: Preprocessing & Statistics ===\n"
echo -ne "Please enter the base directory or press Enter/Return to use the default [${BASE_DIR_DEFAULT}]: \n> "
read base_dir_input
if [ -n "$base_dir_input" ]; then
    BASE_DIR="$base_dir_input"
else
    BASE_DIR="$BASE_DIR_DEFAULT"
fi
echo -e "\nUsing base directory: $BASE_DIR\n"

DESIGN_FILES_DIR="${BASE_DIR}/code/design_files"

echo -ne "Do you want to apply ICA-AROMA? (y/n): "
read apply_ica_aroma
if [[ "$apply_ica_aroma" =~ ^[Yy]$ ]]; then
    ica_aroma=true
    echo -ne "Do you want to apply non-linear registration? (y/n): "
    read apply_nonlinear_reg
    if [[ "$apply_nonlinear_reg" =~ ^[Yy]$ ]]; then
        nonlinear_reg=true
        echo "Non-linear registration will be applied with ICA-AROMA."
    else
        nonlinear_reg=false
        echo "Non-linear registration will not be applied with ICA-AROMA."
    fi
else
    ica_aroma=false
    nonlinear_reg=false
    echo "Skipping ICA-AROMA application."
fi

echo ""
echo -ne "Do you want to apply slice timing correction? (y/n): "
read apply_slice_timing
if [[ "$apply_slice_timing" =~ ^[Yy]$ ]]; then
    slice_timing_correction=true
    echo "Slice timing correction will be applied."
else
    slice_timing_correction=false
    echo "Skipping slice timing correction."
fi

echo ""
echo -ne "Do you want to use Boundary-Based Registration (BBR) for functional to structural registration? (y/n): "
read use_bbr_input
if [[ "$use_bbr_input" =~ ^[Yy]$ ]]; then
    use_bbr=true
    echo "Boundary-Based Registration (BBR) will be used."
else
    use_bbr=false
    echo "Using default 12 DOF affine registration."
fi

if [ "$ica_aroma" = true ]; then
    echo ""
    echo -ne "Do you want to apply nuisance regression after ICA-AROMA? (y/n): "
    read apply_nuisance_input
    if [[ "$apply_nuisance_input" =~ ^[Yy]$ ]]; then
        apply_nuisance_regression=true
        echo "Nuisance regression after ICA-AROMA will be applied."
    else
        apply_nuisance_regression=false
        echo "Skipping nuisance regression after ICA-AROMA."
    fi

    echo ""
    echo -ne "Do you want to apply statistics (main FEAT analysis) after ICA-AROMA preprocessing? (y/n): "
    read apply_aroma_stats_input
    if [[ "$apply_aroma_stats_input" =~ ^[Yy]$ ]]; then
        apply_aroma_stats=true
        echo "Statistics will be run after ICA-AROMA."
    else
        apply_aroma_stats=false
        echo "Only ICA-AROMA preprocessing (no main FEAT analysis after ICA-AROMA)."
    fi
else
    apply_nuisance_regression=false
    apply_aroma_stats=false
fi

select_design_file() {
    local search_pattern="$1"
    local exclude_pattern="$2"
    local design_files=()

    if [ -n "$exclude_pattern" ]; then
        design_files=($(find "$DESIGN_FILES_DIR" -type f -name "$search_pattern" ! -name "$exclude_pattern"))
    else
        design_files=($(find "$DESIGN_FILES_DIR" -type f -name "$search_pattern"))
    fi

    if [ ${#design_files[@]} -eq 0 ]; then
        echo "No design files matching the pattern '$search_pattern' found in $DESIGN_FILES_DIR."
        exit 1
    elif [ ${#design_files[@]} -eq 1 ]; then
        DEFAULT_DESIGN_FILE="${design_files[0]}"
    else
        echo "Multiple design files found:"
        PS3="Select the design file: "
        select selected_design_file in "${design_files[@]}"; do
            if [ -n "$selected_design_file" ]; then
                DEFAULT_DESIGN_FILE="$selected_design_file"
                break
            else
                echo "Invalid selection."
            fi
        done
    fi
}

if [ "$ica_aroma" = true ]; then
    if [ "$apply_aroma_stats" = true ]; then
        select_design_file "*ICA-AROMA_stats_design.fsf"
        echo -e "\nPlease enter the path for the ICA-AROMA main analysis design.fsf or press Enter/Return to use the default [$DEFAULT_DESIGN_FILE]:"
        echo -ne "> "
        read design_file_input
        if [ -n "$design_file_input" ]; then
            design_file="$design_file_input"
        else
            design_file="$DEFAULT_DESIGN_FILE"
        fi
        echo -e "\nUsing ICA-AROMA main analysis design file: $design_file"
    else
        design_file=""
    fi

    select_design_file "*ICA-AROMA_preproc_design.fsf"
    echo -e "\nPlease enter the path for the ICA-AROMA preprocessing design.fsf or press Enter/Return to use the default [$DEFAULT_DESIGN_FILE]:"
    echo -ne "> "
    read preproc_design_file_input
    if [ -n "$preproc_design_file_input" ]; then
        preproc_design_file="$preproc_design_file_input"
    else
        preproc_design_file="$DEFAULT_DESIGN_FILE"
    fi
    echo -e "\nUsing ICA-AROMA preprocessing design file: $preproc_design_file"
else
    select_design_file "task-*.fsf" "*ICA-AROMA_stats*"
    echo -e "\nPlease enter the path for the main analysis design.fsf or press Enter/Return to use the default [$DEFAULT_DESIGN_FILE]:"
    echo -ne "> "
    read design_file_input
    if [ -n "$design_file_input" ]; then
        design_file="$design_file_input"
    else
        design_file="$DEFAULT_DESIGN_FILE"
    fi
    echo -e "\nUsing main analysis design file: $design_file"
    preproc_design_file=""
fi

echo -e "\nSelect the skull-stripped T1 images directory or press Enter/Return for default [BET]:"
echo "1. BET skull-stripped T1 images"
echo "2. SynthStrip skull-stripped T1 images"
echo -ne "> "
read skull_strip_choice

BET_DIR="${BASE_DIR}/derivatives/fsl"
SYNTHSTRIP_DIR="${BASE_DIR}/derivatives/freesurfer"

if [ "$skull_strip_choice" = "2" ]; then
    skull_strip_dir="$SYNTHSTRIP_DIR"
    echo "Using SynthStrip skull-stripped T1 images."
else
    skull_strip_dir="$BET_DIR"
    echo "Using BET skull-stripped T1 images."
fi

TOPUP_OUTPUT_BASE="${BASE_DIR}/derivatives/fsl/topup"
ICA_AROMA_DIR="${BASE_DIR}/derivatives/ICA_AROMA"
CUSTOM_EVENTS_DIR="${BASE_DIR}/derivatives/custom_events"
SLICE_TIMING_DIR="${BASE_DIR}/derivatives/slice_timing"

LOG_DIR="${BASE_DIR}/code/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/feat_first_level_analysis_$(date +%Y-%m-%d_%H-%M-%S).log"

echo ""
echo -ne "Do you want to use field map corrected runs? (y/n): "
while true; do
    read use_fieldmap
    case $use_fieldmap in
        [Yy]* )
            fieldmap_corrected=true
            echo "Using field map corrected runs."
            break
            ;;
        [Nn]* )
            fieldmap_corrected=false
            echo "Skipping field map correction."
            break
            ;;
        * )
            echo "Invalid input, please enter y or n:"
            echo -ne "> "
            ;;
    esac
done

prompt_for_evs=false
if [ "$ica_aroma" = false ]; then
    prompt_for_evs=true
elif [ "$ica_aroma" = true ] && [ "$apply_aroma_stats" = true ]; then
    prompt_for_evs=true
fi

if [ "$prompt_for_evs" = true ]; then
    echo ""
    echo -ne "Do you want to apply high-pass filtering during the main FEAT analysis? (y/n): "
    read apply_highpass_filtering
    if [[ "$apply_highpass_filtering" =~ ^[Yy]$ ]]; then
        highpass_filtering=true
        echo -ne "Enter the high-pass filter cutoff value in seconds, or press Enter/Return to use the default cutoff of 100: "
        read highpass_cutoff
        if [ -z "$highpass_cutoff" ]; then
            highpass_cutoff=100
        fi
        echo "High-pass filtering will be applied with a cutoff of $highpass_cutoff seconds."
    else
        highpass_filtering=false
        echo "Skipping high-pass filtering during the main FEAT analysis."
    fi
else
    highpass_filtering=false
fi

EV_NAMES=()
if [ "$prompt_for_evs" = true ]; then
    while true; do
        echo ""
        echo -ne "Enter the number of EVs: "
        read num_evs
        if [[ "$num_evs" =~ ^[0-9]+$ ]] && [ "$num_evs" -gt 0 ]; then
            break
        else
            echo "Invalid integer. Please try again."
        fi
    done

    echo ""
    echo "Please enter the condition names for the EVs in order."
    echo "These names must match the corresponding text files in your custom_events directory."
    for ((i=1; i<=num_evs; i++)); do
        echo -ne "Condition name for EV$i: "
        read ev_name
        EV_NAMES+=("$ev_name")
    done
else
    num_evs=0
fi

DEFAULT_TEMPLATE="${BASE_DIR}/derivatives/templates/MNI152_T1_2mm_brain.nii.gz"
echo -e "\nEnter template path or press Enter/Return for default [$DEFAULT_TEMPLATE]:"
echo -ne "> "
read template_input

if [ -n "$template_input" ]; then
    TEMPLATE="$template_input"
else
    TEMPLATE="$DEFAULT_TEMPLATE"
fi

if [ ! -f "$TEMPLATE" ]; then
    echo "Error: Template $TEMPLATE does not exist."
    exit 1
fi

echo -e "\nEnter the subject IDs to process (e.g., sub-01 sub-02), or press Enter/Return to process all subjects:"
echo -ne "> "
read subjects_input
if [ -n "$subjects_input" ]; then
    SUBJECTS_ARRAY=($subjects_input)
else
    SUBJECTS_ARRAY=($(find "$BASE_DIR" -maxdepth 1 -mindepth 1 -type d ! -name "derivatives" | sed 's|.*/||' | grep -E '^(sub|subject|pilot|subj|subjpilot)'))
fi

IFS=$'\n' SUBJECTS_ARRAY=($(sort -V <<<"${SUBJECTS_ARRAY[*]}"))
unset IFS

echo -e "\nEnter the session IDs to process (e.g., ses-01 ses-02), or press Enter/Return to process all sessions:"
echo -ne "> "
read sessions_input

echo -e "\nEnter the run numbers to process (e.g., 01 02), or press Enter/Return to process all runs:"
echo -ne "> "
read runs_input

get_t1_image_path() {
    local subject=$1
    local session=$2
    local t1_image=""
    if [ "$skull_strip_choice" = "2" ]; then
        t1_image=$(find "${SYNTHSTRIP_DIR}/${subject}/${session}/anat" -type f -name "${subject}_${session}_*synthstrip*_brain.nii.gz" | head -n 1)
    else
        t1_image=$(find "${BET_DIR}/${subject}/${session}/anat" -type f -name "${subject}_${session}_*_brain.nii.gz" | head -n 1)
    fi
    echo "$t1_image"
}

get_functional_image_path() {
    local subject=$1
    local session=$2
    local run=$3
    local func_image=""
    local found=false

    if [ "$fieldmap_corrected" = true ]; then
        func_image_paths=("${TOPUP_OUTPUT_BASE}/${subject}/${session}/func/${subject}_${session}_task-*_run-${run}_desc-topupcorrected_bold.nii.gz"
                          "${TOPUP_OUTPUT_BASE}/${subject}/${session}/func/${subject}_${session}_run-${run}_desc-topupcorrected_bold.nii.gz")
    else
        func_image_paths=("${BASE_DIR}/${subject}/${session}/func/${subject}_${session}_task-*_run-${run}_bold.nii.gz"
                          "${BASE_DIR}/${subject}/${session}/func/${subject}_${session}_run-${run}_bold.nii.gz")
    fi

    for potential_path in "${func_image_paths[@]}"; do
        for expanded_path in $(ls $potential_path 2>/dev/null); do
            if [[ "$expanded_path" == *"task-rest"* ]]; then
                continue
            fi
            func_image="$expanded_path"
            found=true
            break 2
        done
    done

    if [ "$found" = false ]; then
        echo ""
        return
    fi

    local task_in_filename=false
    if [[ "$func_image" == *"task-"* ]]; then
        task_in_filename=true
    fi
    echo "$func_image|$task_in_filename"
}

get_slice_timing_file_path() {
    local subject=$1
    local session=$2
    local run_label=$3
    local task_name=$4
    local slice_timing_file=""
    slice_timing_paths=()
    if [ -n "$task_name" ]; then
        slice_timing_paths+=("${SLICE_TIMING_DIR}/${subject}/${session}/func/${subject}_${session}_task-${task_name}_${run_label}_bold_slice_timing.txt")
    fi
    slice_timing_paths+=("${SLICE_TIMING_DIR}/${subject}/${session}/func/${subject}_${session}_${run_label}_bold_slice_timing.txt")
    for potential_path in "${slice_timing_paths[@]}"; do
        if [ -f "$potential_path" ]; then
            slice_timing_file="$potential_path"
            break
        fi
    done
    echo "$slice_timing_file"
}

get_ev_txt_files() {
    local subject=$1
    local session=$2
    local run_label=$3
    local ev_txt_files=()
    local txt_dir="${CUSTOM_EVENTS_DIR}/${subject}/${session}"
    for ev_name in "${EV_NAMES[@]}"; do
        local txt_file="${txt_dir}/${subject}_${session}_${run_label}_desc-${ev_name}_events.txt"
        if [ ! -f "$txt_file" ]; then
            return
        fi
        ev_txt_files+=("$txt_file")
    done
    echo "${ev_txt_files[@]}"
}

for subject in "${SUBJECTS_ARRAY[@]}"; do
    echo -e "\n=== PROCESSING SUBJECT: $subject ==="
    if [ -n "$sessions_input" ]; then
        SESSIONS_ARRAY=($sessions_input)
    else
        SESSIONS_ARRAY=($(ls -d "$skull_strip_dir/$subject/"*/ 2>/dev/null | xargs -n 1 basename))
    fi

    if [ ${#SESSIONS_ARRAY[@]} -eq 0 ]; then
        echo "No sessions found for $subject."
        continue
    fi

    IFS=$'\n' SESSIONS_ARRAY=($(sort -V <<<"${SESSIONS_ARRAY[*]}"))
    unset IFS

    for session in "${SESSIONS_ARRAY[@]}"; do
        if [ -n "$runs_input" ]; then
            RUNS_ARRAY=($runs_input)
        else
            if [ "$fieldmap_corrected" = true ]; then
                func_dir="${TOPUP_OUTPUT_BASE}/${subject}/${session}/func"
            else
                func_dir="${BASE_DIR}/${subject}/${session}/func"
            fi
            RUNS_ARRAY=($(find "$func_dir" -type f -name "${subject}_${session}_task-*_run-*_bold.nii.gz" ! -name "*task-rest*_bold.nii.gz" 2>/dev/null | grep -o 'run-[0-9][0-9]*' | sed 's/run-//' | sort | uniq))
            if [ ${#RUNS_ARRAY[@]} -eq 0 ]; then
                RUNS_ARRAY=($(find "$func_dir" -type f -name "${subject}_${session}_run-*_bold.nii.gz" ! -name "*task-rest*_bold.nii.gz" 2>/dev/null | grep -o 'run-[0-9][0-9]*' | sed 's/run-//' | sort | uniq))
            fi
        fi

        if [ ${#RUNS_ARRAY[@]} -eq 0 ]; then
            echo "No task-based runs found for $subject $session."
            continue
        fi

        IFS=$'\n' RUNS_ARRAY=($(sort -V <<<"${RUNS_ARRAY[*]}"))
        unset IFS

        for run in "${RUNS_ARRAY[@]}"; do
            run_label="run-${run}"
            echo -e "\n--- SESSION: $session | RUN: $run_label ---"
            t1_image=$(get_t1_image_path "$subject" "$session")
            if [ -z "$t1_image" ]; then
                echo "T1 image not found. Skipping run."
                continue
            fi

            func_image_and_task_flag=$(get_functional_image_path "$subject" "$session" "$run")
            func_image=$(echo "$func_image_and_task_flag" | cut -d '|' -f 1)
            task_in_filename=$(echo "$func_image_and_task_flag" | cut -d '|' -f 2)

            if [ -z "$func_image" ]; then
                echo "Functional image not found. Skipping."
                continue
            fi

            if [ "$task_in_filename" = "true" ]; then
                task_name=$(basename "$func_image" | grep -o 'task-[^_]*' | sed 's/task-//')
                if [ "$task_name" = "rest" ]; then
                    echo "Skipping rest task."
                    continue
                fi
            else
                task_name=""
            fi

            EV_TXT_FILES=()
            if [ "$prompt_for_evs" = true ]; then
                ev_txt_files=($(get_ev_txt_files "$subject" "$session" "$run_label"))
                if [ "${#ev_txt_files[@]}" -ne "$num_evs" ]; then
                    echo "EV files missing. Skipping run."
                    continue
                fi
                EV_TXT_FILES=("${ev_txt_files[@]}")
            fi

            if [ "$slice_timing_correction" = true ]; then
                slice_timing_file=$(get_slice_timing_file_path "$subject" "$session" "$run_label" "$task_name")
                [ -n "$slice_timing_file" ] && use_slice_timing=true || use_slice_timing=false
            else
                use_slice_timing=false
            fi

            cmd="${BASE_DIR}/code/scripts/run_feat_analysis.sh"
            if [ "$ica_aroma" = true ]; then
                cmd+=" --preproc-design-file \"$preproc_design_file\" --t1-image \"$t1_image\" --func-image \"$func_image\" --template \"$TEMPLATE\" --ica-aroma"
                [ "$nonlinear_reg" = true ] && cmd+=" --nonlinear-reg"
                [ "$use_bbr" = true ] && cmd+=" --use-bbr"
                [ "$apply_nuisance_regression" = true ] && cmd+=" --apply-nuisance-reg"
                cmd+=" --subject \"$subject\" --session \"$session\""
                [ -n "$task_name" ] && cmd+=" --task \"$task_name\""
                cmd+=" --run \"$run_label\""
                [ "$use_slice_timing" = true ] && cmd+=" --slice-timing-file \"$slice_timing_file\""
                [ "$highpass_filtering" = true ] && cmd+=" --highpass-cutoff \"$highpass_cutoff\""

                if [ "$apply_aroma_stats" = false ]; then
                    if [ -n "$task_name" ]; then
                        preproc_output_dir="${BASE_DIR}/derivatives/fsl/level-1/preprocessing_preICA/${subject}/${session}/func/${subject}_${session}_task-${task_name}_${run_label}.feat"
                    else
                        preproc_output_dir="${BASE_DIR}/derivatives/fsl/level-1/preprocessing_preICA/${subject}/${session}/func/${subject}_${session}_${run_label}.feat"
                    fi
                    cmd+=" --preproc-output-dir \"$preproc_output_dir\""

                    echo -e "\n--- FEAT Preprocessing (ICA-AROMA only) ---"
                    echo "    T1 Image: $t1_image"
                    echo "    Functional Image: $func_image"
                    echo "    Preprocessing design file: $preproc_design_file"
                    echo -e "\nRunning ICA-AROMA preprocessing command:"
                    echo "$cmd"
                    eval "$cmd"
                else
                    if [ -n "$task_name" ]; then
                        preproc_output_dir="${BASE_DIR}/derivatives/fsl/level-1/preprocessing_preICA/${subject}/${session}/func/${subject}_${session}_task-${task_name}_${run_label}.feat"
                        analysis_output_dir="${BASE_DIR}/derivatives/fsl/level-1/analysis_postICA/${subject}/${session}/func/${subject}_${session}_task-${task_name}_${run_label}.feat"
                    else
                        preproc_output_dir="${BASE_DIR}/derivatives/fsl/level-1/preprocessing_preICA/${subject}/${session}/func/${subject}_${session}_${run_label}.feat"
                        analysis_output_dir="${BASE_DIR}/derivatives/fsl/level-1/analysis_postICA/${subject}/${session}/func/${subject}_${session}_${run_label}.feat"
                    fi
                    cmd+=" --preproc-output-dir \"$preproc_output_dir\" --analysis-output-dir \"$analysis_output_dir\" --design-file \"$design_file\""
                    for ((i=0; i<num_evs; i++)); do
                        cmd+=" --ev$((i+1)) \"${EV_TXT_FILES[$i]}\""
                    done
                    echo -e "\n--- FEAT Preprocessing + Main Analysis (ICA-AROMA) ---"
                    echo "    T1 Image: $t1_image"
                    echo "    Functional Image: $func_image"
                    echo "    Preprocessing design file: $preproc_design_file"
                    echo "    Main analysis design file: $design_file"
                    echo -e "\nRunning ICA-AROMA preprocessing + main analysis command:"
                    echo "$cmd"
                    eval "$cmd"
                fi
            else
                # Non-ICA-AROMA
                if [ -n "$task_name" ]; then
                    output_dir="${BASE_DIR}/derivatives/fsl/level-1/analysis/${subject}/${session}/func/${subject}_${session}_task-${task_name}_${run_label}.feat"
                else
                    output_dir="${BASE_DIR}/derivatives/fsl/level-1/analysis/${subject}/${session}/func/${subject}_${session}_${run_label}.feat"
                fi
                cmd+=" --design-file \"$design_file\" --t1-image \"$t1_image\" --func-image \"$func_image\" --template \"$TEMPLATE\" --output-dir \"$output_dir\""
                [ "$use_bbr" = true ] && cmd+=" --use-bbr"
                [ "$nonlinear_reg" = true ] && cmd+=" --nonlinear-reg"
                for ((i=0; i<num_evs; i++)); do
                    cmd+=" --ev$((i+1)) \"${EV_TXT_FILES[$i]}\""
                done
                cmd+=" --subject \"$subject\" --session \"$session\""
                [ -n "$task_name" ] && cmd+=" --task \"$task_name\""
                cmd+=" --run \"$run_label\""
                [ "$use_slice_timing" = true ] && cmd+=" --slice-timing-file \"$slice_timing_file\""
                [ "$highpass_filtering" = true ] && cmd+=" --highpass-cutoff \"$highpass_cutoff\""

                echo -e "\n--- FEAT Main Analysis ---"
                echo "    T1 Image: $t1_image"
                echo "    Functional Image: $func_image"
                echo "    Main analysis design file: $design_file"
                echo -e "\nRunning FEAT analysis command:"
                echo "$cmd"
                eval "$cmd"
            fi
        done
    done
done

echo "FEAT FSL level 1 analysis setup complete." >> "$LOG_FILE"
echo "Base Directory: $BASE_DIR" >> "$LOG_FILE"
echo "Skull-stripped Directory: $skull_strip_dir" >> "$LOG_FILE"
echo "Field Map Corrected Directory: $TOPUP_OUTPUT_BASE" >> "$LOG_FILE"
echo "ICA-AROMA Directory: $ICA_AROMA_DIR" >> "$LOG_FILE"
echo "Log File: $LOG_FILE" >> "$LOG_FILE"
