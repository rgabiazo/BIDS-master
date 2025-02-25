#!/bin/bash

###############################################################################
# feat_first_level_analysis.sh
#
# Purpose:
#   This script sets up and runs FEAT first-level analysis in FSL for a BIDS-
#   formatted dataset. It can optionally apply ICA-AROMA, slice timing
#   correction, BBR registration, nuisance regression, and high-pass filtering.
#
# Usage:
#   1. Make the script executable:
#      chmod +x feat_first_level_analysis.sh
#   2. Run the script:
#      ./feat_first_level_analysis.sh
#
# Options:
#   - Prompts for various choices:
#       * Base directory (BIDS root).
#       * Whether to apply ICA-AROMA.
#       * Whether to use non-linear registration with ICA-AROMA.
#       * Whether to apply slice timing correction.
#       * Whether to use BBR for registration.
#       * Whether to apply nuisance regression after ICA-AROMA.
#       * Whether to run main analysis after ICA-AROMA.
#       * Whether to apply high-pass filtering and its cutoff.
#       * EV file details (names and number).
#       * Skull stripping method (BET or SynthStrip).
#       * Whether to use field map corrected runs.
#       * Which subjects, sessions, and runs to process.
#   - Calls run_feat_analysis.sh for actual FEAT runs
#
# Requirements:
#   - FSL installed and in your PATH.
#   - Python2.7 (if using ICA-AROMA) or a Python environment that can run ICA-AROMA.
#   - BIDS dataset with subject directories named like sub-01 or sub-002, etc.
#   - FSF templates with placeholders for substitution.
#
# Notes:
#   - Outputs are placed under derivatives/fsl/level-1, categorized by whether
#     ICA-AROMA and/or main stats are performed.
###############################################################################

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

# Prompt for ICA-AROMA
while true; do
  echo -ne "Do you want to apply ICA-AROMA? (y/n): "
  read apply_ica_aroma
  case "$apply_ica_aroma" in
    [Yy]* )
      ica_aroma=true
      while true; do
        echo -ne "Do you want to apply non-linear registration? (y/n): "
        read apply_nonlinear_reg
        case "$apply_nonlinear_reg" in
          [Yy]* )
            nonlinear_reg=true
            echo -e "Non-linear registration will be applied with ICA-AROMA.\n"
            break
            ;;
          [Nn]* )
            nonlinear_reg=false
            echo -e "Non-linear registration will not be applied with ICA-AROMA.\n"
            break
            ;;
          * ) echo "Invalid input, please enter y or n." ;;
        esac
      done
      break
      ;;
    [Nn]* )
      ica_aroma=false
      nonlinear_reg=false
      echo "Skipping ICA-AROMA application."
      break
      ;;
    * ) echo "Invalid input, please enter y or n." ;;
  esac
done

# Prompt for slice timing correction
while true; do
  echo -ne "Do you want to apply slice timing correction? (y/n): "
  read apply_slice_timing
  case "$apply_slice_timing" in
    [Yy]* )
      slice_timing_correction=true
      echo -e "Slice timing correction will be applied.\n"
      break
      ;;
    [Nn]* )
      slice_timing_correction=false
      echo -e "Skipping slice timing correction.\n"
      break
      ;;
    * ) echo "Invalid input, please enter y or n." ;;
  esac
done

# Prompt for BBR
while true; do
  echo -ne "Do you want to use Boundary-Based Registration (BBR)? (y/n): "
  read use_bbr_input
  case "$use_bbr_input" in
    [Yy]* )
      use_bbr=true
      echo -e "BBR will be used.\n"
      break
      ;;
    [Nn]* )
      use_bbr=false
      echo -e "Using default 12 DOF affine registration.\n"
      break
      ;;
    * ) echo "Invalid input, please enter y or n." ;;
  esac
done

# If ICA-AROMA, prompt nuisance regression & stats
apply_nuisance_regression=false
apply_aroma_stats=false
if [ "$ica_aroma" = true ]; then
  while true; do
    echo -ne "Do you want to apply nuisance regression after ICA-AROMA? (y/n): "
    read apply_nuisance_input
    case "$apply_nuisance_input" in
      [Yy]* )
        apply_nuisance_regression=true
        echo -e "Nuisance regression after ICA-AROMA will be applied.\n"
        break
        ;;
      [Nn]* )
        apply_nuisance_regression=false
        echo -e "Skipping nuisance regression after ICA-AROMA.\n"
        break
        ;;
      * ) echo "Invalid input, please enter y or n." ;;
    esac
  done

  while true; do
    echo -ne "Do you want to apply statistics (main FEAT analysis) after ICA-AROMA? (y/n): "
    read apply_aroma_stats_input
    case "$apply_aroma_stats_input" in
      [Yy]* )
        apply_aroma_stats=true
        echo -e "Statistics will be run after ICA-AROMA.\n"
        break
        ;;
      [Nn]* )
        apply_aroma_stats=false
        echo -e "Only ICA-AROMA preprocessing (no main FEAT analysis after ICA-AROMA).\n"
        break
        ;;
      * ) echo "Invalid input, please enter y or n." ;;
    esac
  done
fi

# Function to select a design file
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
    echo "No design files found with pattern '$search_pattern' in $DESIGN_FILES_DIR."
    exit 1
  elif [ ${#design_files[@]} -eq 1 ]; then
    DEFAULT_DESIGN_FILE="${design_files[0]}"
  else
    echo "Multiple design files found:"
    PS3="Select the design file (enter a number): "
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

# Decide design files
if [ "$ica_aroma" = true ]; then
  if [ "$apply_aroma_stats" = true ]; then
    select_design_file "*ICA-AROMA_stats_design.fsf"
    echo -e "\nPlease enter the path for the ICA-AROMA main analysis design.fsf or press Enter/Return for [$DEFAULT_DESIGN_FILE]:"
    echo -ne "> "
    read design_file_input
    [ -n "$design_file_input" ] && design_file="$design_file_input" || design_file="$DEFAULT_DESIGN_FILE"
    echo -e "\nUsing ICA-AROMA main analysis design file: $design_file"
  else
    design_file=""
  fi

  select_design_file "*ICA-AROMA_preproc_design.fsf"
  echo -e "\nPlease enter the path for the ICA-AROMA preprocessing design.fsf or press Enter/Return for [$DEFAULT_DESIGN_FILE]:"
  echo -ne "> "
  read preproc_design_file_input
  [ -n "$preproc_design_file_input" ] && preproc_design_file="$preproc_design_file_input" || preproc_design_file="$DEFAULT_DESIGN_FILE"
  echo -e "\nUsing ICA-AROMA preprocessing design file: $preproc_design_file"
else
  select_design_file "task-*.fsf" "*ICA-AROMA_stats*"
  echo -e "\nPlease enter the path for the main analysis design.fsf or press Enter/Return for [$DEFAULT_DESIGN_FILE]:"
  echo -ne "> "
  read design_file_input
  [ -n "$design_file_input" ] && design_file="$design_file_input" || design_file="$DEFAULT_DESIGN_FILE"
  echo -e "\nUsing main analysis design file: $design_file"
  preproc_design_file=""
fi

# Skull-stripped T1
while true; do
  echo -e "\nSelect the skull-stripped T1 images directory or press Enter/Return for [BET]:"
  echo "1. BET skull-stripped T1 images"
  echo "2. SynthStrip skull-stripped T1 images"
  echo -ne "> "
  read skull_strip_choice
  case "$skull_strip_choice" in
    "1" | "" )
      skull_strip_choice="1"
      echo -e "Using BET skull-stripped T1 images.\n"
      break
      ;;
    "2" )
      echo -e "Using SynthStrip skull-stripped T1 images.\n"
      break
      ;;
    * ) echo "Invalid input, please enter 1 or 2 (or Enter for default)." ;;
  esac
done

BET_DIR="${BASE_DIR}/derivatives/fsl"
SYNTHSTRIP_DIR="${BASE_DIR}/derivatives/freesurfer"
if [ "$skull_strip_choice" = "2" ]; then
  skull_strip_dir="$SYNTHSTRIP_DIR"
else
  skull_strip_dir="$BET_DIR"
fi

TOPUP_OUTPUT_BASE="${BASE_DIR}/derivatives/fsl/topup"
ICA_AROMA_DIR="${BASE_DIR}/derivatives/ICA_AROMA"
CUSTOM_EVENTS_DIR="${BASE_DIR}/derivatives/custom_events"
SLICE_TIMING_DIR="${BASE_DIR}/derivatives/slice_timing"

LOG_DIR="${BASE_DIR}/code/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/feat_first_level_analysis_$(date +%Y-%m-%d_%H-%M-%S).log"

# Prompt for field map corrected runs
fieldmap_corrected=false
while true; do
  echo -ne "Do you want to use field map corrected runs? (y/n): "
  read use_fieldmap
  case $use_fieldmap in
    [Yy]* )
      fieldmap_corrected=true
      echo -e "Using field map corrected runs.\n"
      break
      ;;
    [Nn]* )
      fieldmap_corrected=false
      echo -e "Skipping field map correction.\n"
      break
      ;;
    * ) echo "Invalid input, please enter y or n:" ;;
  esac
done

# Decide if need to prompt for EVs
prompt_for_evs=false
if [ "$ica_aroma" = false ]; then
  prompt_for_evs=true
elif [ "$ica_aroma" = true ] && [ "$apply_aroma_stats" = true ]; then
  prompt_for_evs=true
fi

# Prompt for high-pass filtering (only if doing main analysis)
highpass_filtering=false
highpass_cutoff=0
if [ "$prompt_for_evs" = true ]; then
  while true; do
    echo -ne "Do you want to apply high-pass filtering during the main FEAT analysis? (y/n): "
    read apply_highpass_filtering
    case "$apply_highpass_filtering" in
      [Yy]* )
        highpass_filtering=true
        echo -ne "Enter the high-pass filter cutoff value in seconds, or press Enter/Return to use the default cutoff of 100: "
        read hp_input
        [ -z "$hp_input" ] && hp_input=100
        if [[ "$hp_input" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
          highpass_cutoff="$hp_input"
          echo -e "High-pass filtering will be applied with a cutoff of $highpass_cutoff seconds.\n"
          break
        else
          echo "Invalid cutoff. Please enter a numeric value."
        fi
        ;;
      [Nn]* )
        highpass_filtering=false
        echo -e "Skipping high-pass filtering.\n"
        break
        ;;
      * ) echo "Invalid input, please enter y or n." ;;
    esac
  done
fi

# Prompt for EVs if needed
EV_NAMES=()
num_evs=0
if [ "$prompt_for_evs" = true ]; then
  while true; do
    echo -ne "Enter the number of EVs: "
    read num_evs
    if [[ "$num_evs" =~ ^[0-9]+$ ]] && [ "$num_evs" -gt 0 ]; then
      break
    else
      echo "Invalid integer. Please try again."
    fi
  done

  echo ""
  echo "Enter the condition names for the EVs in order."
  for ((i=1; i<=num_evs; i++)); do
    echo -ne "Condition name for EV$i: "
    read ev_name
    EV_NAMES+=("$ev_name")
  done
fi

# Prompt for template
DEFAULT_TEMPLATE="${BASE_DIR}/derivatives/templates/MNI152_T1_2mm_brain.nii.gz"
echo -e "\nEnter template path or press Enter/Return for [$DEFAULT_TEMPLATE]:"
echo -ne "> "
read template_input
[ -n "$template_input" ] && TEMPLATE="$template_input" || TEMPLATE="$DEFAULT_TEMPLATE"
if [ ! -f "$TEMPLATE" ]; then
  echo "Error: Template $TEMPLATE does not exist."
  exit 1
fi

# Prompt for subjects
echo -e "\nEnter subject IDs (e.g., sub-01 sub-02), or press Enter/Return for all in $BASE_DIR:"
echo -ne "> "
read subjects_input
if [ -n "$subjects_input" ]; then
  SUBJECTS_ARRAY=($subjects_input)
else
  SUBJECTS_ARRAY=($(find "$BASE_DIR" -maxdepth 1 -mindepth 1 -type d -name "sub-*" | sed 's|.*/||'))
fi
IFS=$'\n' SUBJECTS_ARRAY=($(sort -V <<<"${SUBJECTS_ARRAY[*]}"))
unset IFS

# Prompt for sessions
echo -e "\nEnter session IDs (e.g., ses-01 ses-02), or press Enter/Return for all sessions:"
echo -ne "> "
read sessions_input

# Prompt for runs
echo -e "\nEnter run numbers (e.g., 01 02), or press Enter/Return for all runs:"
echo -ne "> "
read runs_input

# Helper: find T1
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

# Helper: find bold
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

# Helper: slice timing
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

# Helper: EV text files
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

# Main processing
for subject in "${SUBJECTS_ARRAY[@]}"; do
  echo -e "\n=== PROCESSING SUBJECT: $subject ==="
  if [ -n "$sessions_input" ]; then
    SESSIONS_ARRAY=($sessions_input)
  else
    SESSIONS_ARRAY=($(find "$skull_strip_dir/$subject" -maxdepth 1 -type d -name "ses-*" -exec basename {} \; 2>/dev/null))
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
        [ "$task_name" = "rest" ] && { echo "Skipping rest task."; continue; }
      else
        task_name=""
      fi

      # EV files (if needed)
      EV_TXT_FILES=()
      if [ "$prompt_for_evs" = true ]; then
        ev_txt_files=($(get_ev_txt_files "$subject" "$session" "$run_label"))
        if [ "${#ev_txt_files[@]}" -ne "$num_evs" ]; then
          echo "EV files missing. Skipping run."
          continue
        fi
        EV_TXT_FILES=("${ev_txt_files[@]}")
      fi

      # slice timing
      use_slice_timing=false
      slice_timing_file=""
      if [ "$slice_timing_correction" = true ]; then
        slice_timing_file=$(get_slice_timing_file_path "$subject" "$session" "$run_label" "$task_name")
        [ -n "$slice_timing_file" ] && use_slice_timing=true
      fi

      # Build run_feat_analysis.sh command
      cmd="${BASE_DIR}/code/scripts/run_feat_analysis.sh"
      if [ "$ica_aroma" = true ]; then
        cmd+=" --preproc-design-file \"$preproc_design_file\""
        cmd+=" --t1-image \"$t1_image\" --func-image \"$func_image\" --template \"$TEMPLATE\" --ica-aroma"
        [ "$nonlinear_reg" = true ] && cmd+=" --nonlinear-reg"
        [ "$use_bbr" = true ] && cmd+=" --use-bbr"
        [ "$apply_nuisance_regression" = true ] && cmd+=" --apply-nuisance-reg"
        cmd+=" --subject \"$subject\" --session \"$session\""
        [ -n "$task_name" ] && cmd+=" --task \"$task_name\""
        cmd+=" --run \"$run_label\""
        [ "$use_slice_timing" = true ] && cmd+=" --slice-timing-file \"$slice_timing_file\""
        [ "$highpass_filtering" = true ] && cmd+=" --highpass-cutoff \"$highpass_cutoff\""

        if [ "$apply_aroma_stats" = false ]; then
          # Preproc only
          if [ -n "$task_name" ]; then
            preproc_output_dir="${BASE_DIR}/derivatives/fsl/level-1/preprocessing_preICA/${subject}/${session}/func/${subject}_${session}_task-${task_name}_${run_label}.feat"
          else
            preproc_output_dir="${BASE_DIR}/derivatives/fsl/level-1/preprocessing_preICA/${subject}/${session}/func/${subject}_${session}_${run_label}.feat"
          fi
          cmd+=" --preproc-output-dir \"$preproc_output_dir\""
          echo -e "\n--- FEAT Preprocessing (ICA-AROMA only) ---"
          echo "$cmd"
          eval "$cmd"
        else
          # Preproc + stats
          if [ -n "$task_name" ]; then
            preproc_output_dir="${BASE_DIR}/derivatives/fsl/level-1/preprocessing_preICA/${subject}/${session}/func/${subject}_${session}_task-${task_name}_${run_label}.feat"
            analysis_output_dir="${BASE_DIR}/derivatives/fsl/level-1/analysis_postICA/${subject}/${session}/func/${subject}_${session}_task-${task_name}_${run_label}.feat"
          else
            preproc_output_dir="${BASE_DIR}/derivatives/fsl/level-1/preprocessing_preICA/${subject}/${session}/func/${subject}_${session}_${run_label}.feat"
            analysis_output_dir="${BASE_DIR}/derivatives/fsl/level-1/analysis_postICA/${subject}/${session}/func/${subject}_${session}_${run_label}.feat"
          fi
          cmd+=" --preproc-output-dir \"$preproc_output_dir\" --analysis-output-dir \"$analysis_output_dir\""
          cmd+=" --design-file \"$design_file\""
          for ((i=0; i<num_evs; i++)); do
            cmd+=" --ev$((i+1)) \"${EV_TXT_FILES[$i]}\""
          done
          echo -e "\n--- FEAT Preprocessing + Main Analysis (ICA-AROMA) ---"
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
        cmd+=" --design-file \"$design_file\""
        cmd+=" --t1-image \"$t1_image\" --func-image \"$func_image\" --template \"$TEMPLATE\""
        cmd+=" --output-dir \"$output_dir\""
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
