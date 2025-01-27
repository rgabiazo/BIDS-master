#!/bin/bash

# run_feat_analysis.sh
#
# This script runs FEAT first-level analysis in FSL, handling optional ICA-AROMA preprocessing,
# non-linear registration, slice timing correction, and nuisance regression after ICA-AROMA.
# If ICA-AROMA is chosen without further statistics, it runs preprocessing + ICA-AROMA only.
# If ICA-AROMA and statistics are chosen, it runs preprocessing + ICA-AROMA + main analysis.
# If ICA-AROMA is not chosen, it just runs a standard FEAT analysis.
#
# Usage:
#   run_feat_analysis.sh [options]

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

while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        --preproc-design-file) PREPROC_DESIGN_FILE="$2"; shift; shift;;
        --design-file) DESIGN_FILE="$2"; shift; shift;;
        --t1-image) T1_IMAGE="$2"; shift; shift;;
        --func-image) FUNC_IMAGE="$2"; shift; shift;;
        --template) TEMPLATE="$2"; shift; shift;;
        --output-dir) OUTPUT_DIR="$2"; shift; shift;;
        --preproc-output-dir) PREPROC_OUTPUT_DIR="$2"; shift; shift;;
        --analysis-output-dir) ANALYSIS_OUTPUT_DIR="$2"; shift; shift;;
        --ev*) EV_FILES+=("$2"); shift; shift;;
        --ica-aroma) ICA_AROMA=true; shift;;
        --nonlinear-reg) NONLINEAR_REG=true; shift;;
        --subject) SUBJECT="$2"; shift; shift;;
        --session) SESSION="$2"; shift; shift;;
        --task) TASK="$2"; shift; shift;;
        --run) RUN="$2"; shift; shift;;
        --slice-timing-file) SLICE_TIMING_FILE="$2"; USE_SLICE_TIMING=true; shift; shift;;
        --highpass-cutoff) HIGHPASS_CUTOFF="$2"; APPLY_HIGHPASS_FILTERING=true; shift; shift;;
        --use-bbr) USE_BBR=true; shift;;
        --apply-nuisance-reg) APPLY_NUISANCE_REG=true; shift;;
        *)
            echo "Unknown option $1"
            exit 1;;
    esac
done

PREPROC_DESIGN_FILE=$(echo "$PREPROC_DESIGN_FILE" | tr -d "'\"")
DESIGN_FILE=$(echo "$DESIGN_FILE" | tr -d "'\"")
T1_IMAGE=$(echo "$T1_IMAGE" | tr -d "'\"")
FUNC_IMAGE=$(echo "$FUNC_IMAGE" | tr -d "'\"")
TEMPLATE=$(echo "$TEMPLATE" | tr -d "'\"")
OUTPUT_DIR=$(echo "$OUTPUT_DIR" | tr -d "'\"")
PREPROC_OUTPUT_DIR=$(echo "$PREPROC_OUTPUT_DIR" | tr -d "'\"")
ANALYSIS_OUTPUT_DIR=$(echo "$ANALYSIS_OUTPUT_DIR" | tr -d "'\"")

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
    echo "Error: Missing T1, FUNC, or TEMPLATE."
    exit 1
fi

npts=$(fslval "$FUNC_IMAGE" dim4 | xargs)
tr=$(fslval "$FUNC_IMAGE" pixdim4 | xargs)
tr=$(LC_NUMERIC=C printf "%.6f" "$tr")

adjust_slice_timing_settings() {
    local infile="$1"
    local outfile="$2"
    local slice_timing_file="$3"

    if [ "$USE_SLICE_TIMING" = true ] && [ -n "$slice_timing_file" ]; then
        # If slice timing is applied, we use mode 4
        sed -e "s|@SLICE_TIMING@|4|g" \
            -e "s|@SLICE_TIMING_FILE@|$slice_timing_file|g" \
            "$infile" > "$outfile"
    else
        # If no slice timing, we set to 0 and remove the slice timing file reference
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

apply_sed_replacement() {
    local file="$1"
    local find_expr="$2"
    local replace_expr="$3"
    local tmpfile=$(mktemp)
    sed "s|${find_expr}|${replace_expr}|g" "$file" > "$tmpfile"
    mv "$tmpfile" "$file"
}

if [ "$ICA_AROMA" = true ]; then
    if [ -z "$PREPROC_DESIGN_FILE" ] || [ -z "$PREPROC_OUTPUT_DIR" ]; then
        echo "Error: Missing ICA-AROMA preproc design or output dir."
        exit 1
    fi

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

        adjust_slice_timing_settings "$MODIFIED_PREPROC_DESIGN_FILE.tmp" "$MODIFIED_PREPROC_DESIGN_FILE" "$SLICE_TIMING_FILE"
        rm "$MODIFIED_PREPROC_DESIGN_FILE.tmp"

        if [ "$NONLINEAR_REG" = true ]; then
            apply_sed_replacement "$MODIFIED_PREPROC_DESIGN_FILE" "set fmri(regstandard_nonlinear_yn) .*" "set fmri(regstandard_nonlinear_yn) 1"
        else
            apply_sed_replacement "$MODIFIED_PREPROC_DESIGN_FILE" "set fmri(regstandard_nonlinear_yn) .*" "set fmri(regstandard_nonlinear_yn) 0"
        fi

        if [ "$USE_BBR" = true ]; then
            apply_sed_replacement "$MODIFIED_PREPROC_DESIGN_FILE" "set fmri(reghighres_dof) .*" "set fmri(reghighres_dof) BBR"
        else
            apply_sed_replacement "$MODIFIED_PREPROC_DESIGN_FILE" "set fmri(reghighres_dof) .*" "set fmri(reghighres_dof) 12"
        fi

        echo ""
        echo "[FEAT PREPROCESSING]"
        echo "Running FEAT preprocessing..."
        feat "$MODIFIED_PREPROC_DESIGN_FILE" || { echo "FEAT preprocessing failed."; exit 1; }
        rm -f "$MODIFIED_PREPROC_DESIGN_FILE"
        echo "- FEAT preprocessing completed at $PREPROC_OUTPUT_DIR"

        output_dir_name=$(basename "$PREPROC_OUTPUT_DIR" .feat)
        mask_output="${PREPROC_OUTPUT_DIR}/${output_dir_name}_example_func_mask.nii.gz"
        example_func="${PREPROC_OUTPUT_DIR}/example_func.nii.gz"
        echo ""
        echo "[MASK CREATION]"
        echo "Creating mask..."
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
            echo ""
            echo "[MASK CREATION]"
            echo "Creating mask..."
            bet "$example_func" "$mask_output" -f 0.3 || { echo "Mask creation failed."; exit 1; }
            echo "- Mask created at $mask_output"
        fi
    fi

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
            echo "Error: python2.7 not found in PATH."
            exit 1
        fi

        filtered_func_data="${PREPROC_OUTPUT_DIR}/filtered_func_data.nii.gz"
        mc_par="${PREPROC_OUTPUT_DIR}/mc/prefiltered_func_data_mcf.par"
        affmat="${PREPROC_OUTPUT_DIR}/reg/example_func2highres.mat"
        warp_file="${PREPROC_OUTPUT_DIR}/reg/highres2standard_warp.nii.gz"
        mask_file="${mask_output}"

        cmd="$PYTHON2 \"$ICA_AROMA_SCRIPT\" -in \"$filtered_func_data\" -out \"$ICA_AROMA_OUTPUT_DIR\" -mc \"$mc_par\" -m \"$mask_file\" -affmat \"$affmat\""
        if [ "$NONLINEAR_REG" = true ]; then
            cmd+=" -warp \"$warp_file\""
        fi

        echo "Running ICA-AROMA command:"
        echo "$cmd"
        eval "$cmd"
        if [ $? -ne 0 ]; then
            echo "Error: ICA-AROMA failed. Skipping this run."
            exit 0
        fi

        if [ ! -f "$denoised_func" ]; then
            echo "Error: denoised_func_data_nonaggr.nii.gz not created by ICA-AROMA. Skipping this run."
            exit 0
        fi
        echo "ICA-AROMA processed successfully."
        echo "- Denoised data at $denoised_func"
    else
        echo "ICA-AROMA already processed at $denoised_func"
    fi

    echo ""
    echo "[NUISANCE REGRESSION AFTER ICA-AROMA]"
    if [ "$APPLY_NUISANCE_REG" = true ]; then
        nuisance_regressed_func="${ICA_AROMA_OUTPUT_DIR}/denoised_func_data_nonaggr_nuis.nii.gz"
        if [ -f "$nuisance_regressed_func" ]; then
            echo "Nuisance regression already performed at $nuisance_regressed_func"
            denoised_func="$nuisance_regressed_func"
        else
            if [ ! -f "$denoised_func" ]; then
                echo "Denoised data missing before nuisance regression. Skipping this run."
                exit 0
            fi

            SEG_DIR="${ICA_AROMA_OUTPUT_DIR}/segmentation"
            mkdir -p "$SEG_DIR"

            echo -e "Segmenting structural image..."
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
            convert_xfm -inverse -omat ${PREPROC_OUTPUT_DIR}/reg/highres2example_func.mat ${PREPROC_OUTPUT_DIR}/reg/example_func2highres.mat
            flirt -in ${SEG_DIR}/WM_mask.nii.gz -ref ${PREPROC_OUTPUT_DIR}/example_func.nii.gz -applyxfm -init ${PREPROC_OUTPUT_DIR}/reg/highres2example_func.mat -out ${SEG_DIR}/WM_mask_func.nii.gz -interp nearestneighbour
            flirt -in ${SEG_DIR}/CSF_mask.nii.gz -ref ${PREPROC_OUTPUT_DIR}/example_func.nii.gz -applyxfm -init ${PREPROC_OUTPUT_DIR}/reg/highres2example_func.mat -out ${SEG_DIR}/CSF_mask_func.nii.gz -interp nearestneighbour
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
            paste ${SEG_DIR}/WM_timeseries.txt ${SEG_DIR}/CSF_timeseries.txt ${SEG_DIR}/linear_trend.txt > ${SEG_DIR}/nuisance_regressors.txt
            echo "  - Combined regressors at ${SEG_DIR}/nuisance_regressors.txt"

            echo -e "\nPerforming nuisance regression..."
            fsl_regfilt -i "$denoised_func" -d ${SEG_DIR}/nuisance_regressors.txt -f "1,2,3" -o "$nuisance_regressed_func"
            echo "  - Nuisance regression completed at ${nuisance_regressed_func}"

            denoised_func="$nuisance_regressed_func"
        fi
    else
        echo "Skipping nuisance regression."
    fi

    if [ -n "$ANALYSIS_OUTPUT_DIR" ] && [ -n "$DESIGN_FILE" ]; then
        echo ""
        echo "[FEAT MAIN ANALYSIS (POST-ICA)]"
        if [ -d "$ANALYSIS_OUTPUT_DIR" ]; then
            echo "FEAT main analysis (post-ICA) already exists at $ANALYSIS_OUTPUT_DIR"
        else
            if [ ! -f "$denoised_func" ]; then
                echo "Denoised data not found before main stats. Skipping this run."
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

            USE_SLICE_TIMING=false
            SLICE_TIMING_FILE=""
            adjust_slice_timing_settings "$MODIFIED_DESIGN_FILE.tmp" "$MODIFIED_DESIGN_FILE.hp" "$SLICE_TIMING_FILE"
            adjust_highpass_filter_settings "$MODIFIED_DESIGN_FILE.hp" "$MODIFIED_DESIGN_FILE" "$HIGHPASS_CUTOFF"
            rm "$MODIFIED_DESIGN_FILE.tmp" "$MODIFIED_DESIGN_FILE.hp"

            if [ "$NONLINEAR_REG" = true ]; then
                apply_sed_replacement "$MODIFIED_DESIGN_FILE" "set fmri(regstandard_nonlinear_yn) .*" "set fmri(regstandard_nonlinear_yn) 1"
            else
                apply_sed_replacement "$MODIFIED_DESIGN_FILE" "set fmri(regstandard_nonlinear_yn) .*" "set fmri(regstandard_nonlinear_yn) 0"
            fi

            if [ "$USE_BBR" = true ]; then
                apply_sed_replacement "$MODIFIED_DESIGN_FILE" "set fmri(reghighres_dof) .*" "set fmri(reghighres_dof) BBR"
            else
                apply_sed_replacement "$MODIFIED_DESIGN_FILE" "set fmri(reghighres_dof) .*" "set fmri(reghighres_dof) 12"
            fi

            for ((i=0; i<${#EV_FILES[@]}; i++)); do
                ev_num=$((i+1))
                apply_sed_replacement "$MODIFIED_DESIGN_FILE" "@EV${ev_num}@" "${EV_FILES[i]}"
            done

            echo "Running FEAT main analysis (post-ICA)..."
            feat "$MODIFIED_DESIGN_FILE" || { echo "FEAT main analysis failed."; exit 1; }
            rm -f "$MODIFIED_DESIGN_FILE"
            echo "- FEAT main analysis (post-ICA) completed at $ANALYSIS_OUTPUT_DIR"
        fi
    else
        echo ""
        echo "Preprocessing and ICA-AROMA completed (no main stats)."
    fi
else
    # Non-ICA-AROMA
    if [ -z "$DESIGN_FILE" ] || [ -z "$OUTPUT_DIR" ]; then
        echo "Error: Missing design file or output dir."
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

        adjust_slice_timing_settings "$MODIFIED_DESIGN_FILE.tmp" "$MODIFIED_DESIGN_FILE.hp" "$SLICE_TIMING_FILE"
        adjust_highpass_filter_settings "$MODIFIED_DESIGN_FILE.hp" "$MODIFIED_DESIGN_FILE" "$HIGHPASS_CUTOFF"
        rm "$MODIFIED_DESIGN_FILE.tmp" "$MODIFIED_DESIGN_FILE.hp"

        if [ "$NONLINEAR_REG" = true ]; then
            apply_sed_replacement "$MODIFIED_DESIGN_FILE" "set fmri(regstandard_nonlinear_yn) .*" "set fmri(regstandard_nonlinear_yn) 1"
        else
            apply_sed_replacement "$MODIFIED_DESIGN_FILE" "set fmri(regstandard_nonlinear_yn) .*" "set fmri(regstandard_nonlinear_yn) 0"
        fi

        if [ "$USE_BBR" = true ]; then
            apply_sed_replacement "$MODIFIED_DESIGN_FILE" "set fmri(reghighres_dof) .*" "set fmri(reghighres_dof) BBR"
        else
            apply_sed_replacement "$MODIFIED_DESIGN_FILE" "set fmri(reghighres_dof) .*" "set fmri(reghighres_dof) 12"
        fi

        for ((i=0; i<${#EV_FILES[@]}; i++)); do
            ev_num=$((i+1))
            apply_sed_replacement "$MODIFIED_DESIGN_FILE" "@EV${ev_num}@" "${EV_FILES[i]}"
        done

        echo ""
        echo "[FEAT MAIN ANALYSIS]"
        echo "Running FEAT main analysis..."
        feat "$MODIFIED_DESIGN_FILE" || { echo "FEAT failed."; exit 1; }
        rm -f "$MODIFIED_DESIGN_FILE"
        echo "- FEAT main analysis completed at $OUTPUT_DIR"
    fi
fi

find "$(dirname "$SCRIPT_DIR")" -type f -name "*''" -exec rm -f {} \; 2>/dev/null
