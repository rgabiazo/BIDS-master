#!/bin/bash

###############################################################################
# run_feat_analysis.sh
#
# Purpose:
#   This script runs FEAT first-level analysis in FSL, handling optional
#   ICA-AROMA preprocessing, non-linear registration, slice timing correction,
#   nuisance regression, and main analysis (stats). After analysis, it calls
#   create_dataset_description.sh to generate or update the BIDS
#   dataset_description.json in the top-level derivative directory (e.g.,
#   /path/to/derivatives/fsl/level-1/analysis, analysis_postICA etc.).
#
# Usage:
#   run_feat_analysis.sh [options]
#
# Options:
#   --preproc-design-file <file> : Path to the .fsf design for ICA-AROMA preprocessing
#   --design-file <file>         : Path to the main .fsf design (for stats)
#   --t1-image <file>            : Path to the skull-stripped T1
#   --func-image <file>          : Path to the functional data (BOLD)
#   --template <file>            : Path to the MNI template
#   --output-dir <path>          : Where to put the output for standard FEAT
#   --preproc-output-dir <path>  : Where to put the output for ICA-AROMA preprocessing
#   --analysis-output-dir <path> : Where to put the post-ICA analysis results
#   --ev1 <file>, --ev2 <file>   : Event files (text) for each EV
#   --ica-aroma                  : Boolean flag to enable ICA-AROMA
#   --nonlinear-reg              : Use non-linear registration
#   --subject <string>           : Subject ID (e.g. sub-001)
#   --session <string>           : Session ID (e.g. ses-01)
#   --task <string>              : Task name (e.g. memtask)
#   --run <string>               : Run label (e.g. run-01)
#   --slice-timing-file <file>   : Slice timing file (if slice timing correction is used)
#   --highpass-cutoff <value>    : High-pass filter cutoff in seconds
#   --use-bbr                    : Use BBR registration
#   --apply-nuisance-reg         : Apply nuisance regression after ICA-AROMA
#   --help, -h                   : Display this help text
#
# Notes:
#   Steps:
#       1. Preprocess (FEAT) + optional ICA-AROMA
#       2. (Optional) Nuisance regression
#       3. (Optional) Main stats
#       4. Creates/updates dataset_description.json in the top-level derivative dir
#
#   Additional environment:
#       - FSLDIR: The root of your FSL installation (used to get FSL version).
#
###############################################################################

usage() {
  cat <<EOF
Usage: run_feat_analysis.sh [options]

Runs FEAT first-level analysis in FSL, optionally with ICA-AROMA.

Options:
  --preproc-design-file <file> : Path to the .fsf design for ICA-AROMA preprocessing
  --design-file <file>         : Path to the main .fsf design (for stats)
  --t1-image <file>            : Path to the skull-stripped T1
  --func-image <file>          : Path to the functional data (BOLD)
  --template <file>            : Path to the MNI template
  --output-dir <path>          : Where to put the output for standard FEAT
  --preproc-output-dir <path>  : Where to put the output for ICA-AROMA preprocessing
  --analysis-output-dir <path> : Where to put the post-ICA analysis results
  --ev1 <file>, --ev2 <file>   : Event files (text) for each EV
  --ica-aroma                  : Boolean flag to enable ICA-AROMA
  --nonlinear-reg              : Use non-linear registration
  --subject <string>           : Subject ID (e.g. sub-001)
  --session <string>           : Session ID (e.g. ses-01)
  --task <string>              : Task name (e.g. memtask)
  --run <string>               : Run label (e.g. run-01)
  --slice-timing-file <file>   : Slice timing file (if slice timing correction is used)
  --highpass-cutoff <value>    : High-pass filter cutoff in seconds
  --use-bbr                    : Use BBR registration
  --apply-nuisance-reg         : Apply nuisance regression after ICA-AROMA
  --help, -h                   : Display this help text

EOF
  exit 1
}

if [ $# -eq 0 ]; then
  usage
fi

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
BASE_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
ICA_AROMA_SCRIPT="$BASE_DIR/code/ICA-AROMA-master/ICA_AROMA.py"

EV_FILES=()
ICA_AROMA=false
NONLINEAR_REG=false
OUTPUT_DIR=""
PREPROC_OUTPUT_DIR=""
ANALYSIS_OUTPUT_DIR=""
SUBJECT=""
SESSION=""
TASK=""
RUN=""
PREPROC_DESIGN_FILE=""
DESIGN_FILE=""
SLICE_TIMING_FILE=""
USE_SLICE_TIMING=false
HIGHPASS_CUTOFF=""
APPLY_HIGHPASS_FILTERING=false
USE_BBR=false
APPLY_NUISANCE_REG=false
T1_IMAGE=""
FUNC_IMAGE=""
TEMPLATE=""

###############################################################################
# Parse command-line arguments
###############################################################################
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    --help|-h)
      usage
      ;;
    --preproc-design-file)
      PREPROC_DESIGN_FILE="$2"
      shift; shift
      ;;
    --design-file)
      DESIGN_FILE="$2"
      shift; shift
      ;;
    --t1-image)
      T1_IMAGE="$2"
      shift; shift
      ;;
    --func-image)
      FUNC_IMAGE="$2"
      shift; shift
      ;;
    --template)
      TEMPLATE="$2"
      shift; shift
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift; shift
      ;;
    --preproc-output-dir)
      PREPROC_OUTPUT_DIR="$2"
      shift; shift
      ;;
    --analysis-output-dir)
      ANALYSIS_OUTPUT_DIR="$2"
      shift; shift
      ;;
    --ev*)
      EV_FILES+=("$2")
      shift; shift
      ;;
    --ica-aroma)
      ICA_AROMA=true
      shift
      ;;
    --nonlinear-reg)
      NONLINEAR_REG=true
      shift
      ;;
    --subject)
      SUBJECT="$2"
      shift; shift
      ;;
    --session)
      SESSION="$2"
      shift; shift
      ;;
    --task)
      TASK="$2"
      shift; shift
      ;;
    --run)
      RUN="$2"
      shift; shift
      ;;
    --slice-timing-file)
      SLICE_TIMING_FILE="$2"
      USE_SLICE_TIMING=true
      shift; shift
      ;;
    --highpass-cutoff)
      HIGHPASS_CUTOFF="$2"
      APPLY_HIGHPASS_FILTERING=true
      shift; shift
      ;;
    --use-bbr)
      USE_BBR=true
      shift
      ;;
    --apply-nuisance-reg)
      APPLY_NUISANCE_REG=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      usage
      ;;
  esac
done

# Remove any stray quotes
PREPROC_DESIGN_FILE=$(echo "$PREPROC_DESIGN_FILE" | tr -d "'\"")
DESIGN_FILE=$(echo "$DESIGN_FILE" | tr -d "'\"")
T1_IMAGE=$(echo "$T1_IMAGE" | tr -d "'\"")
FUNC_IMAGE=$(echo "$FUNC_IMAGE" | tr -d "'\"")
TEMPLATE=$(echo "$TEMPLATE" | tr -d "'\"")
OUTPUT_DIR=$(echo "$OUTPUT_DIR" | tr -d "'\"")
PREPROC_OUTPUT_DIR=$(echo "$PREPROC_OUTPUT_DIR" | tr -d "'\"")
ANALYSIS_OUTPUT_DIR=$(echo "$ANALYSIS_OUTPUT_DIR" | tr -d "'\"")

###############################################################################
# Quick validations
###############################################################################
if [ "$ICA_AROMA" = false ]; then
  if [ -n "$DESIGN_FILE" ] && [ ${#EV_FILES[@]} -eq 0 ]; then
    echo "Error: No EV files provided for main analysis."
    exit 1
  fi
else
  if [ -n "$DESIGN_FILE" ] && [ ${#EV_FILES[@]} -eq 0 ] && [ -n "$ANALYSIS_OUTPUT_DIR" ]; then
    echo "Error: No EV files for post-ICA-AROMA stats."
    exit 1
  fi
fi

if [ -z "$T1_IMAGE" ] || [ -z "$FUNC_IMAGE" ] || [ -z "$TEMPLATE" ]; then
  echo "Error: Missing --t1-image, --func-image, or --template."
  exit 1
fi

###############################################################################
# Helper functions
###############################################################################
apply_sed_replacement() {
  local file="$1"
  local find_expr="$2"
  local replace_expr="$3"
  local tmpfile
  tmpfile=$(mktemp)
  sed "s|${find_expr}|${replace_expr}|g" "$file" > "$tmpfile"
  mv "$tmpfile" "$file"
}

adjust_slice_timing_settings() {
  local infile="$1"
  local outfile="$2"
  local slice_timing_file="$3"

  if [ "$USE_SLICE_TIMING" = true ] && [ -n "$slice_timing_file" ]; then
    # If slice timing is applied, use mode 4
    sed -e "s|@SLICE_TIMING@|4|g" \
        -e "s|@SLICE_TIMING_FILE@|$slice_timing_file|g" \
        "$infile" > "$outfile"
  else
    # If no slice timing, set to 0 and remove the reference
    sed -e "s|@SLICE_TIMING@|0|g" \
        -e "s|@SLICE_TIMING_FILE@||g" \
        "$infile" > "$outfile"
  fi
}

adjust_highpass_filter_settings() {
  local infile="$1"
  local outfile="$2"
  local highpass_cutoff="$3"
  if [ "$APPLY_HIGHPASS_FILTERING" = true ] && [ -n "$highpass_cutoff" ]; then
    sed "s|@HIGHPASS_CUTOFF@|$highpass_cutoff|g" "$infile" > "$outfile"
  else
    sed "s|@HIGHPASS_CUTOFF@|0|g" "$infile" > "$outfile"
  fi
}

###############################################################################
# Acquire FSL version (if possible)
###############################################################################
FSL_VERSION="Unknown"
if [ -n "$FSLDIR" ] && [ -f "$FSLDIR/etc/fslversion" ]; then
  FSL_VERSION=$(cat "$FSLDIR/etc/fslversion" | cut -d'%' -f1)
fi

BIDS_VERSION="1.10.0"          # Adjust as you wish or pass in from environment
ICA_AROMA_VERSION="0.4.4-beta" # Example

###############################################################################
# Main logic
###############################################################################
npts=$(fslval "$FUNC_IMAGE" dim4 | xargs)
tr=$(fslval "$FUNC_IMAGE" pixdim4 | xargs)
tr=$(LC_NUMERIC=C printf "%.6f" "$tr")

##########################################################################
# Function to get the top-level "analysis" or "analysis_postICA" directory
# (or similarly structured directories) from a deeper .feat path.
# just do 4x `dirname`.
##########################################################################
get_top_level_analysis_dir() {
  local feat_path="$1"
  local dir1 dir2 dir3 dir4
  dir1="$(dirname "$feat_path")"      # e.g. .../sub-01/ses-01/func
  dir2="$(dirname "$dir1")"           # e.g. .../sub-01/ses-01
  dir3="$(dirname "$dir2")"           # e.g. .../sub-01
  dir4="$(dirname "$dir3")"           # e.g. .../analysis_postICA
  echo "$dir4"
}

if [ "$ICA_AROMA" = true ]; then
  # --------------------------------------------------------------
  # 1. ICA-AROMA route
  # --------------------------------------------------------------
  if [ -z "$PREPROC_DESIGN_FILE" ] || [ -z "$PREPROC_OUTPUT_DIR" ]; then
    echo "Error: Missing --preproc-design-file or --preproc-output-dir for ICA-AROMA."
    exit 1
  fi

  # 1A. FEAT Preprocessing
  if [ ! -d "$PREPROC_OUTPUT_DIR" ]; then
    MODIFIED_PREPROC_DESIGN_FILE="$(dirname "$PREPROC_OUTPUT_DIR")/modified_${SUBJECT}_${SESSION}_${RUN}_$(basename "$PREPROC_DESIGN_FILE")"
    mkdir -p "$(dirname "$MODIFIED_PREPROC_DESIGN_FILE")"

    sed -e "s|@OUTPUT_DIR@|$PREPROC_OUTPUT_DIR|g" \
        -e "s|@FUNC_IMAGE@|$FUNC_IMAGE|g" \
        -e "s|@T1_IMAGE@|$T1_IMAGE|g" \
        -e "s|@TEMPLATE@|$TEMPLATE|g" \
        -e "s|@NPTS@|$npts|g" \
        -e "s|@TR@|$tr|g" \
        "$PREPROC_DESIGN_FILE" > "$MODIFIED_PREPROC_DESIGN_FILE.tmp"

    adjust_slice_timing_settings \
      "$MODIFIED_PREPROC_DESIGN_FILE.tmp" \
      "$MODIFIED_PREPROC_DESIGN_FILE" \
      "$SLICE_TIMING_FILE"

    rm "$MODIFIED_PREPROC_DESIGN_FILE.tmp"

    # Non-linear registration
    if [ "$NONLINEAR_REG" = true ]; then
      apply_sed_replacement "$MODIFIED_PREPROC_DESIGN_FILE" \
        "set fmri(regstandard_nonlinear_yn) .*" \
        "set fmri(regstandard_nonlinear_yn) 1"
    else
      apply_sed_replacement "$MODIFIED_PREPROC_DESIGN_FILE" \
        "set fmri(regstandard_nonlinear_yn) .*" \
        "set fmri(regstandard_nonlinear_yn) 0"
    fi

    # BBR or 12 DOF
    if [ "$USE_BBR" = true ]; then
      apply_sed_replacement "$MODIFIED_PREPROC_DESIGN_FILE" \
        "set fmri(reghighres_dof) .*" \
        "set fmri(reghighres_dof) BBR"
    else
      apply_sed_replacement "$MODIFIED_PREPROC_DESIGN_FILE" \
        "set fmri(reghighres_dof) .*" \
        "set fmri(reghighres_dof) 12"
    fi

    echo ""
    echo "[FEAT PREPROCESSING]"
    feat "$MODIFIED_PREPROC_DESIGN_FILE" || { echo "FEAT preprocessing failed."; exit 1; }
    rm -f "$MODIFIED_PREPROC_DESIGN_FILE"
    echo "- FEAT preprocessing completed at $PREPROC_OUTPUT_DIR"

    # [ADDED CODE START: Create dataset_description.json in preprocessing_preICA top-level]
    PREPROC_TOP_DIR="$(get_top_level_analysis_dir "$PREPROC_OUTPUT_DIR")"
    "$SCRIPT_DIR/create_dataset_description.sh" \
      --analysis-dir "$PREPROC_TOP_DIR" \
      --ds-name "FSL_FEAT_Preprocessing_ICA_AROMA" \
      --dataset-type "derivative" \
      --description "FSL FEAT-based preprocessing prior to ICA-AROMA." \
      --bids-version "$BIDS_VERSION" \
      --generatedby "Name=FSL,Version=${FSL_VERSION},Description=Preprocessing pipeline for ICA-AROMA"
    # [ADDED CODE END]

    output_dir_name=$(basename "$PREPROC_OUTPUT_DIR" .feat)
    mask_output="${PREPROC_OUTPUT_DIR}/${output_dir_name}_example_func_mask.nii.gz"
    example_func="${PREPROC_OUTPUT_DIR}/example_func.nii.gz"

    echo ""
    echo "[MASK CREATION]"
    bet "$example_func" "$mask_output" -f 0.3 || { echo "Mask creation failed."; exit 1; }
    echo "- Mask created at $mask_output"
  else
    echo ""
    echo "[FEAT PREPROCESSING]"
    echo "FEAT preprocessing already completed at $PREPROC_OUTPUT_DIR"
    output_dir_name=$(basename "$PREPROC_OUTPUT_DIR" .feat)
    mask_output="${PREPROC_OUTPUT_DIR}/${output_dir_name}_example_func_mask.nii.gz"
    example_func="${PREPROC_OUTPUT_DIR}/example_func.nii.gz"
    if [ ! -f "$mask_output" ]; then
      bet "$example_func" "$mask_output" -f 0.3 || { echo "Mask creation failed."; exit 1; }
      echo "- Mask created at $mask_output"
    fi
  fi

  # 1B. ICA-AROMA
  echo -e "\n[ICA-AROMA PROCESSING]"
  ICA_AROMA_OUTPUT_DIR="${BASE_DIR}/derivatives/fsl/level-1/aroma/${SUBJECT}/${SESSION}/func"
  if [ -n "$TASK" ]; then
    ICA_AROMA_OUTPUT_DIR="${ICA_AROMA_OUTPUT_DIR}/${SUBJECT}_${SESSION}_task-${TASK}_${RUN}.feat"
  else
    ICA_AROMA_OUTPUT_DIR="${ICA_AROMA_OUTPUT_DIR}/${SUBJECT}_${SESSION}_${RUN}.feat"
  fi

  denoised_func="${ICA_AROMA_OUTPUT_DIR}/denoised_func_data_nonaggr.nii.gz"
  if [ ! -f "$denoised_func" ]; then
    PYTHON2=$(which python2.7)
    if [ -z "$PYTHON2" ]; then
      echo "Error: python2.7 not found in PATH (required for ICA-AROMA)."
      exit 1
    fi

    filtered_func_data="${PREPROC_OUTPUT_DIR}/filtered_func_data.nii.gz"
    mc_par="${PREPROC_OUTPUT_DIR}/mc/prefiltered_func_data_mcf.par"
    affmat="${PREPROC_OUTPUT_DIR}/reg/example_func2highres.mat"
    warp_file="${PREPROC_OUTPUT_DIR}/reg/highres2standard_warp.nii.gz"
    mask_file="$mask_output"

    cmd="$PYTHON2 \"$ICA_AROMA_SCRIPT\" -in \"$filtered_func_data\" -out \"$ICA_AROMA_OUTPUT_DIR\" -mc \"$mc_par\" -m \"$mask_file\" -affmat \"$affmat\""

    if [ "$NONLINEAR_REG" = true ]; then
      cmd+=" -warp \"$warp_file\""
    fi

    echo "Running ICA-AROMA command:"
    echo "$cmd"
    eval "$cmd" || { echo "ICA-AROMA failed. Skipping this run."; exit 0; }
    if [ ! -f "$denoised_func" ]; then
      echo "Error: denoised_func_data_nonaggr.nii.gz not created by ICA-AROMA. Skipping."
      exit 0
    fi
    echo "ICA-AROMA processed successfully."
    echo "- Denoised data at $denoised_func"

    # [ADDED CODE START: Create dataset_description.json in aroma top-level]
    AROMA_TOP_DIR="$(get_top_level_analysis_dir "$ICA_AROMA_OUTPUT_DIR")"
    "$SCRIPT_DIR/create_dataset_description.sh" \
      --analysis-dir "$AROMA_TOP_DIR" \
      --ds-name "ICA_AROMA_preprocessing" \
      --dataset-type "derivative" \
      --description "ICA-AROMA decomposition and denoising applied to FEAT-preprocessed data." \
      --bids-version "$BIDS_VERSION" \
      --generatedby "Name=ICA-AROMA,Version=${ICA_AROMA_VERSION},Description=Automatic removal of motion-related ICA components"
    # [ADDED CODE END]

  else
    echo "ICA-AROMA already processed at $denoised_func"
  fi

  # 1C. Optional nuisance regression
  echo ""
  echo "[NUISANCE REGRESSION AFTER ICA-AROMA]"
  if [ "$APPLY_NUISANCE_REG" = true ]; then
    nuisance_regressed_func="${ICA_AROMA_OUTPUT_DIR}/denoised_func_data_nonaggr_nuis.nii.gz"
    if [ -f "$nuisance_regressed_func" ]; then
      echo "Nuisance regression already performed at $nuisance_regressed_func"
      denoised_func="$nuisance_regressed_func"
    else
      if [ ! -f "$denoised_func" ]; then
        echo "Denoised data missing before nuisance regression. Skipping."
        exit 0
      fi

      SEG_DIR="${ICA_AROMA_OUTPUT_DIR}/segmentation"
      mkdir -p "$SEG_DIR"

      echo -e "Segmenting structural image (FAST)..."
      fast -t 1 -n 3 -H 0.1 -I 4 -l 20.0 -o ${SEG_DIR}/T1w_brain "$T1_IMAGE"
      echo "  - Segmentation completed at:"
      echo "    ${SEG_DIR}/T1w_brain_pve_2.nii.gz"
      echo "    ${SEG_DIR}/T1w_brain_pve_1.nii.gz"
      echo "    ${SEG_DIR}/T1w_brain_pve_0.nii.gz"
      
      fslmaths ${SEG_DIR}/T1w_brain_pve_2.nii.gz -thr 0.8 -bin ${SEG_DIR}/WM_mask.nii.gz
      fslmaths ${SEG_DIR}/T1w_brain_pve_0.nii.gz -thr 0.8 -bin ${SEG_DIR}/CSF_mask.nii.gz
      echo "  - WM and CSF masks created at:"
      echo "    WM Mask: ${SEG_DIR}/WM_mask.nii.gz"
      echo "    CSF Mask: ${SEG_DIR}/CSF_mask.nii.gz"

      echo -e "\nTransforming masks to functional space..."
      convert_xfm -inverse -omat ${PREPROC_OUTPUT_DIR}/reg/highres2example_func.mat \
        ${PREPROC_OUTPUT_DIR}/reg/example_func2highres.mat

      flirt -in ${SEG_DIR}/WM_mask.nii.gz \
        -ref ${PREPROC_OUTPUT_DIR}/example_func.nii.gz \
        -applyxfm -init ${PREPROC_OUTPUT_DIR}/reg/highres2example_func.mat \
        -out ${SEG_DIR}/WM_mask_func.nii.gz -interp nearestneighbour

      flirt -in ${SEG_DIR}/CSF_mask.nii.gz \
        -ref ${PREPROC_OUTPUT_DIR}/example_func.nii.gz \
        -applyxfm -init ${PREPROC_OUTPUT_DIR}/reg/highres2example_func.mat \
        -out ${SEG_DIR}/CSF_mask_func.nii.gz -interp nearestneighbour
      
      echo "  - Masks transformed to functional space:"
      echo "    ${SEG_DIR}/WM_mask_func.nii.gz"
      echo "    ${SEG_DIR}/CSF_mask_func.nii.gz"

      echo -e "\nExtracting WM and CSF time series..."
      fslmeants -i "$denoised_func" -o ${SEG_DIR}/WM_timeseries.txt -m ${SEG_DIR}/WM_mask_func.nii.gz
      fslmeants -i "$denoised_func" -o ${SEG_DIR}/CSF_timeseries.txt -m ${SEG_DIR}/CSF_mask_func.nii.gz
      echo "  - WM timeseries: ${SEG_DIR}/WM_timeseries.txt"
      echo "  - CSF timeseries: ${SEG_DIR}/CSF_timeseries.txt"

      echo -e "\nCreating linear trend regressor..."
      npts=$(fslval "$denoised_func" dim4)
      seq 0 $((npts - 1)) > ${SEG_DIR}/linear_trend.txt
      echo "  - Linear trend regressor created at ${SEG_DIR}/linear_trend.txt"


      echo -e "\nCombining regressors..."
      paste ${SEG_DIR}/WM_timeseries.txt \
            ${SEG_DIR}/CSF_timeseries.txt \
            ${SEG_DIR}/linear_trend.txt > ${SEG_DIR}/nuisance_regressors.txt
      echo "  - Combined regressors at ${SEG_DIR}/nuisance_regressors.txt"

      echo -e "\nPerforming nuisance regression..."
      fsl_regfilt -i "$denoised_func" \
                  -d ${SEG_DIR}/nuisance_regressors.txt \
                  -f "1,2,3" \
                  -o "$nuisance_regressed_func"
      echo "  - Nuisance regression completed at ${nuisance_regressed_func}"

      denoised_func="$nuisance_regressed_func"
    fi
  else
    echo "Skipping nuisance regression."
  fi

  # 1D. Main Analysis (stats) after ICA-AROMA if requested
  if [ -n "$ANALYSIS_OUTPUT_DIR" ] && [ -n "$DESIGN_FILE" ]; then
    echo ""
    echo "[FEAT MAIN ANALYSIS (POST-ICA)]"
    if [ -d "$ANALYSIS_OUTPUT_DIR" ]; then
      echo "FEAT main analysis (post-ICA) already exists at $ANALYSIS_OUTPUT_DIR"
    else
      if [ ! -f "$denoised_func" ]; then
        echo "Denoised data not found before main stats. Skipping."
        exit 0
      fi

      npts=$(fslval "$denoised_func" dim4 | xargs)
      tr=$(fslval "$denoised_func" pixdim4 | xargs)
      tr=$(LC_NUMERIC=C printf "%.6f" "$tr")

      MODIFIED_DESIGN_FILE="$(dirname "$ANALYSIS_OUTPUT_DIR")/modified_${SUBJECT}_${SESSION}_${RUN}_$(basename "$DESIGN_FILE")"
      mkdir -p "$(dirname "$MODIFIED_DESIGN_FILE")"

      sed -e "s|@OUTPUT_DIR@|$ANALYSIS_OUTPUT_DIR|g" \
          -e "s|@FUNC_IMAGE@|$denoised_func|g" \
          -e "s|@T1_IMAGE@|$T1_IMAGE|g" \
          -e "s|@TEMPLATE@|$TEMPLATE|g" \
          -e "s|@NPTS@|$npts|g" \
          -e "s|@TR@|$tr|g" \
          "$DESIGN_FILE" > "$MODIFIED_DESIGN_FILE.tmp"

      # Post-ICA: do NOT re-apply slice timing
      USE_SLICE_TIMING=false
      SLICE_TIMING_FILE=""

      adjust_slice_timing_settings \
        "$MODIFIED_DESIGN_FILE.tmp" \
        "$MODIFIED_DESIGN_FILE.hp" \
        "$SLICE_TIMING_FILE"

      adjust_highpass_filter_settings \
        "$MODIFIED_DESIGN_FILE.hp" \
        "$MODIFIED_DESIGN_FILE" \
        "$HIGHPASS_CUTOFF"

      rm "$MODIFIED_DESIGN_FILE.tmp" "$MODIFIED_DESIGN_FILE.hp"

      # Non-linear registration
      if [ "$NONLINEAR_REG" = true ]; then
        apply_sed_replacement "$MODIFIED_DESIGN_FILE" \
          "set fmri(regstandard_nonlinear_yn) .*" \
          "set fmri(regstandard_nonlinear_yn) 1"
      else
        apply_sed_replacement "$MODIFIED_DESIGN_FILE" \
          "set fmri(regstandard_nonlinear_yn) .*" \
          "set fmri(regstandard_nonlinear_yn) 0"
      fi

      # BBR or 12 DOF
      if [ "$USE_BBR" = true ]; then
        apply_sed_replacement "$MODIFIED_DESIGN_FILE" \
          "set fmri(reghighres_dof) .*" \
          "set fmri(reghighres_dof) BBR"
      else
        apply_sed_replacement "$MODIFIED_DESIGN_FILE" \
          "set fmri(reghighres_dof) .*" \
          "set fmri(reghighres_dof) 12"
      fi

      # Insert EV files
      for ((i=0; i<${#EV_FILES[@]}; i++)); do
        ev_num=$((i+1))
        apply_sed_replacement "$MODIFIED_DESIGN_FILE" \
          "@EV${ev_num}@" \
          "${EV_FILES[i]}"
      done

      echo "Running FEAT main analysis (post-ICA)..."
      feat "$MODIFIED_DESIGN_FILE" || { echo "FEAT main analysis failed."; exit 1; }
      rm -f "$MODIFIED_DESIGN_FILE"
      echo "- FEAT main analysis (post-ICA) completed at $ANALYSIS_OUTPUT_DIR"
    fi

    ########################################################################
    # Create or update dataset_description.json in the TOP-LEVEL folder
    ########################################################################
    TOP_ANALYSIS_DIR="$(get_top_level_analysis_dir "$ANALYSIS_OUTPUT_DIR")"
    "$SCRIPT_DIR/create_dataset_description.sh" \
      --analysis-dir "$TOP_ANALYSIS_DIR" \
      --ds-name "FSL_FEAT_with_ICA_AROMA" \
      --dataset-type "derivative" \
      --description "A first-level fMRI analysis pipeline using custom shell scripts (feat_first_level_analysis.sh & run_feat_analysis.sh) to run FSL FEAT, with optional slice-timing correction, BBR, non-linear registration, ICA-AROMA, and nuisance regression." \
      --bids-version "$BIDS_VERSION" \
      --generatedby "Name=FSL,Version=${FSL_VERSION},Description=Used for motion correction, registration, and FEAT-based statistics." \
      --generatedby "Name=ICA-AROMA,Version=${ICA_AROMA_VERSION},Description=Used for automatic removal of motion-related components."

  else
    echo ""
    echo "Preprocessing and ICA-AROMA completed (no main stats)."
  fi

else
  # --------------------------------------------------------------
  # 2. Non-ICA-AROMA route
  # --------------------------------------------------------------
  if [ -z "$DESIGN_FILE" ] || [ -z "$OUTPUT_DIR" ]; then
    echo "Error: Missing --design-file or --output-dir."
    exit 1
  fi

  if [ -d "$OUTPUT_DIR" ]; then
    echo ""
    echo "FEAT analysis already exists at $OUTPUT_DIR"
  else
    MODIFIED_DESIGN_FILE="$(dirname "$OUTPUT_DIR")/modified_${SUBJECT}_${SESSION}_${RUN}_$(basename "$DESIGN_FILE")"
    mkdir -p "$(dirname "$MODIFIED_DESIGN_FILE")"

    sed -e "s|@OUTPUT_DIR@|$OUTPUT_DIR|g" \
        -e "s|@FUNC_IMAGE@|$FUNC_IMAGE|g" \
        -e "s|@T1_IMAGE@|$T1_IMAGE|g" \
        -e "s|@TEMPLATE@|$TEMPLATE|g" \
        -e "s|@NPTS@|$npts|g" \
        -e "s|@TR@|$tr|g" \
        "$DESIGN_FILE" > "$MODIFIED_DESIGN_FILE.tmp"

    adjust_slice_timing_settings \
      "$MODIFIED_DESIGN_FILE.tmp" \
      "$MODIFIED_DESIGN_FILE.hp" \
      "$SLICE_TIMING_FILE"

    adjust_highpass_filter_settings \
      "$MODIFIED_DESIGN_FILE.hp" \
      "$MODIFIED_DESIGN_FILE" \
      "$HIGHPASS_CUTOFF"

    rm "$MODIFIED_DESIGN_FILE.tmp" "$MODIFIED_DESIGN_FILE.hp"

    # Non-linear registration
    if [ "$NONLINEAR_REG" = true ]; then
      apply_sed_replacement "$MODIFIED_DESIGN_FILE" \
        "set fmri(regstandard_nonlinear_yn) .*" \
        "set fmri(regstandard_nonlinear_yn) 1"
    else
      apply_sed_replacement "$MODIFIED_DESIGN_FILE" \
        "set fmri(regstandard_nonlinear_yn) .*" \
        "set fmri(regstandard_nonlinear_yn) 0"
    fi

    # BBR or 12 DOF
    if [ "$USE_BBR" = true ]; then
      apply_sed_replacement "$MODIFIED_DESIGN_FILE" \
        "set fmri(reghighres_dof) .*" \
        "set fmri(reghighres_dof) BBR"
    else
      apply_sed_replacement "$MODIFIED_DESIGN_FILE" \
        "set fmri(reghighres_dof) .*" \
        "set fmri(reghighres_dof) 12"
    fi

    # Insert EV files
    for ((i=0; i<${#EV_FILES[@]}; i++)); do
      ev_num=$((i+1))
      apply_sed_replacement "$MODIFIED_DESIGN_FILE" \
        "@EV${ev_num}@" \
        "${EV_FILES[i]}"
    done

    echo ""
    echo "[FEAT MAIN ANALYSIS]"
    feat "$MODIFIED_DESIGN_FILE" || { echo "FEAT failed."; exit 1; }
    rm -f "$MODIFIED_DESIGN_FILE"
    echo "- FEAT main analysis completed at $OUTPUT_DIR"
  fi

  ########################################################################
  # Create or update dataset_description.json in the TOP-LEVEL folder
  ########################################################################
  TOP_ANALYSIS_DIR="$(get_top_level_analysis_dir "$OUTPUT_DIR")"
  "$SCRIPT_DIR/create_dataset_description.sh" \
    --analysis-dir "$TOP_ANALYSIS_DIR" \
    --ds-name "FSL_FEAT_FirstLevel" \
    --dataset-type "derivative" \
    --description "A first-level fMRI analysis pipeline using custom shell scripts (feat_first_level_analysis.sh & run_feat_analysis.sh) to run FSL FEAT. Optional steps include slice-timing correction, boundary-based registration, non-linear registration, and high-pass filtering." \
    --bids-version "$BIDS_VERSION" \
    --generatedby "Name=FSL,Version=${FSL_VERSION},Description=Used for motion correction, registration, and FEAT-based statistics."
fi

# Cleanup extraneous files
find "$(dirname "$SCRIPT_DIR")" -type f -name "*''" -exec rm -f {} \; 2>/dev/null
