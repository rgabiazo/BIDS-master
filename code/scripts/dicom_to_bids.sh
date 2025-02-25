#!/bin/bash
#
###############################################################################
# dicom_to_bids.sh
#
# Purpose:
#   Convert and organize DICOM files for neuroimaging studies into a
#   BIDS-compliant directory structure. Unzips and runs dcm2niix, then
#   rearranges scans (task fMRI, PA fieldmaps, resting-state, anatomical
#   (T1w, T2w, hippocampus), diffusion) into standard BIDS subfolders.
#   Creates/updates a participants.tsv file of available subjects.
#
# Usage:
#   dicom_to_bids.sh [dcm2Nifti] [options] sub-XX [sub-YY ...] [ses-XX ...] or 'all'
#
# Usage Examples:
#   1) bash dicom_to_bids.sh dcm2Nifti -t assocmemory sub-01 sub-02 ses-01
#      -> Converts DICOM → NIfTI, organizes task-fMRI for sub-01 and sub-02 (session 01).
#
#   2) bash dicom_to_bids.sh -pa -anat t1w sub-003
#      -> Organizes a PA fieldmap and T1w anatomical, skipping DICOM → NIfTI conversion
#         for sub-003 (all sessions that contain .zip).
#
#   3) bash dicom_to_bids.sh -dcm2Nifti -t assocmemory -pa -rest -anat t1w t2w all
#      -> For ALL subjects, converts DICOM → NIfTI, organizes tasks, PA, resting-state,
#         T1w and T2w anatomicals for each subject/session containing .zip DICOM data.
#
#   4) bash dicom_to_bids.sh dcm2Nifti -diff -anat hipp sub-001
#      -> Converts DICOM → NIfTI and organizes diffusion + high-res hippocampus scans
#         for sub-001 (all sessions that contain .zip).
#
# Options:
#   dcm2Nifti               Perform DICOM→NIfTI conversion before organizing
#   -t,  --task  NAME       Process task-based fMRI scans (task=<NAME>)
#   -pa, --process-pa [T]   Process phase-encoded PA scans, optional <task_name>
#   -rest, --resting-state  Process resting-state scans
#   -anat, --anatomical A1 [A2 ...]
#                           Process one or more anatomical scans:
#                               t1w, t2w, hipp
#   -diff, --diffusion      Process diffusion scans
#   -h, --help              Show this help message and exit
#
#   sub-XXX, ses-YYY        Specify subject(s) & session(s); or 'all' for all discovered subjects.
#
# Requirements:
#   - dcm2niix installed and on your PATH.
#   - A DICOM folder structure like:
#        sourcedata/Dicom/sub-01/ses-01/*.zip
#     or pre-unzipped subfolders.
#   - Write permissions to create BIDS subfolders in the project root.
#
# Notes:
#   - The script writes temporary NIfTI files to sourcedata/Nifti/
#     and final BIDS output to sub-XX/ses-XX/<func|anat|dwi>.
#   - A log is always created under code/logs.
#   - Calls create_tsv.sh to create participants.tsv
################################################################################

usage() {
  cat <<EOM

Usage: $(basename "$0") [dcm2Nifti] [options] [sub-XX [sub-YY ...]] [ses-XX ...] or 'all'

Examples:
  1) $(basename "$0") dcm2Nifti -t assocmemory sub-01 sub-02 ses-01
  2) $(basename "$0") -pa -anat t1w sub-03
  3) $(basename "$0") dcm2Nifti -t assocmemory -pa -rest -anat t1w t2w all
  4) $(basename "$0") dcm2Nifti -diff -anat hipp sub-01

Options:
  dcm2Nifti               Perform DICOM→NIfTI conversion before organizing
  -t,  --task  NAME       Process task-based fMRI scans (task=<NAME>)
  -pa, --process-pa [T]   Process phase-encoded PA scans, optional <task_name>
  -rest, --resting-state  Process resting-state scans
  -anat, --anatomical A1 [A2 ...]
                          Process one or more anatomical scans (t1w, t2w, hipp)
  -diff, --diffusion      Process diffusion scans
  -h, --help              Show this help message and exit

EOM
}

# Base directories
script_dir="$(dirname "$(realpath "$0")")"
BASE_DIR="$(dirname "$(dirname "$script_dir")")"

dcm_dir="${BASE_DIR}/sourcedata/Dicom"
nifti_dir="${BASE_DIR}/sourcedata/Nifti"
bids_dir="${BASE_DIR}"
log_dir="${BASE_DIR}/code/logs"

# Default booleans
dcm2Nifti=false
process_task=false
task_name=""
process_pa=false
pa_task_name=""
process_resting_state=false
process_diff=false

# Anatomical types to process (array)
anat_types=()

subjects=()
sessions=()

# Create log directory if it doesn't exist
mkdir -p "$log_dir"
log_file="${log_dir}/$(basename "$0")_$(date +%Y-%m-%d_%H-%M-%S).log"

# Simple logging function
log() {
    echo -e "$1" | tee -a "$log_file"
}

########################################
# 1) Check if first argument is "dcm2Nifti"
########################################
if [[ "$1" == "dcm2Nifti" || "$1" == "-dcm2Nifti" ]]; then
    dcm2Nifti=true
    shift
fi

########################################
# 2) Parse remaining options/arguments
########################################
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -h|--help)
            usage
            exit 0
            ;;
        -t|--task)
            process_task=true
            task_name="$2"
            # Validate
            if [[ "$task_name" == -* ]] || [[ -z "$task_name" ]]; then
                log "\nWarning: Task name is missing/invalid; skipping -t option."
                task_name=""
                shift
            else
                shift 2
            fi
            ;;
        -rest|--resting-state)
            process_resting_state=true
            shift
            ;;
        -pa|--process-pa)
            process_pa=true
            # If next token is not another dash-arg, treat it as the PA "task" name
            if [[ "$2" != "" && "$2" != -* && "$2" != sub-* && "$2" != ses-* && "$2" != all ]]; then
                pa_task_name="$2"
                shift 2
            else
                pa_task_name=""
                shift
            fi
            ;;
        -anat|--anatomical)
            shift
            # Collect all subsequent arguments until another dash option or sub-/ses-/all is given
            while [[ $# -gt 0 && "$1" != -* && "$1" != sub-* && "$1" != ses-* && "$1" != "all" ]]; do
                anat_types+=("$1")
                shift
            done
            ;;
        -diff|--diffusion)
            process_diff=true
            shift
            ;;
        *)
            # Could be subject or session or 'all'
            if [[ "$key" == sub-* ]]; then
                subjects+=("$key")
            elif [[ "$key" == ses-* ]]; then
                sessions+=("$key")
            elif [[ "$key" == "all" ]]; then
                subjects+=("$key")
            else
                log "\nWarning: Unrecognized argument: $key"
            fi
            shift
            ;;
    esac
done

########################################
# 3) Expand "all" subjects option
########################################
if [[ " ${subjects[@]} " =~ " all " ]]; then
    log "\n=== Processing all subjects ==="
    # Find sub-* directories in Dicom that contain .zip or some DICOM content
    subjects=($(find "$dcm_dir" -type d -name "sub-*" -exec bash -c '
        for dir; do
            if find "$dir" -type d -name "ses-*" -exec find {} -maxdepth 1 -name "*.zip" \; | grep -q .; then
                basename "$dir"
            fi
        done
    ' _ {} + | sort))

    if [ ${#subjects[@]} -eq 0 ]; then
        log "\nNo subjects with .zip files found in $dcm_dir."
        exit 1
    fi
    log "\nFound subjects: ${subjects[*]}\n"
fi

########################################
# 4) Functions to process each scan type
########################################

process_task_scans() {
    local subj="$1"
    local session="$2"
    local nifti_subj_ses_dir="$3"
    local bids_subj_ses_dir="$4"
    local task_name="$5"

    local output_dir="$bids_subj_ses_dir/func"
    mkdir -p "$output_dir"

    log "\n=== Processing Functional Task Runs for $subj $session ==="

    # Finds any .nii.gz in 'rfMRI_TASK_AP' if it exists
    if [ ! -d "$nifti_subj_ses_dir/rfMRI_TASK_AP" ]; then
        log "No 'rfMRI_TASK_AP' folder found; skipping tasks."
        return
    fi

    local func_files=($(find "$nifti_subj_ses_dir/rfMRI_TASK_AP" -type f -name "*.nii.gz" -size +100M | sort -V))
    local num_runs=${#func_files[@]}

    log "Found $num_runs functional run(s)."

    for ((i = 0; i < num_runs; i++)); do
        run_num=$(printf "%02d" $((i + 1)))
        old_nii="${func_files[$i]}"
        base="${subj}_${session}"
        if [ -n "$task_name" ]; then
            new_nii="$output_dir/${base}_task-${task_name}_run-${run_num}_bold.nii.gz"
        else
            new_nii="$output_dir/${base}_run-${run_num}_bold.nii.gz"
        fi

        log ""
        if [ -f "$new_nii" ]; then
            log "Already exists: $new_nii (skipping)."
            continue
        fi

        log "Moving: $old_nii → $new_nii"
        mv "$old_nii" "$new_nii"

        # Move JSON if it exists
        local old_json="${old_nii%.nii.gz}.json"
        local new_json="${new_nii%.nii.gz}.json"
        if [ -f "$old_json" ]; then
            log "Moved JSON to $new_json"
            mv "$old_json" "$new_json"
        fi
    done

    log "\nDone with functional tasks."
}

process_pa_scans() {
    local subj="$1"
    local session="$2"
    local nifti_subj_ses_dir="$3"
    local bids_subj_ses_dir="$4"
    local pa_task_name="$5"

    local output_dir="$bids_subj_ses_dir/func"
    mkdir -p "$output_dir"

    log "\n=== Processing Phase-Encoded PA Scans for $subj $session ==="

    local pa_dir="$nifti_subj_ses_dir/rfMRI_PA"
    [ ! -d "$pa_dir" ] && log "No 'rfMRI_PA' directory found (skipping)." && return

    # Find the latest .nii.gz
    local pa_file
    pa_file=$(find "$pa_dir" -type f -name "*.nii.gz" | sort -V | tail -1)
    if [ -z "$pa_file" ]; then
        log "No PA NIfTI found (skipping)."
        return
    fi

    local base="${subj}_${session}"
    local new_pa="$output_dir/${base}"
    if [ -n "$pa_task_name" ]; then
        new_pa+="_task-${pa_task_name}"
    fi
    new_pa+="_dir-PA_epi.nii.gz"

    log ""
    if [ -f "$new_pa" ]; then
        log "Already exists: $new_pa (skipping)."
        return
    fi

    log "Moving PA scan: $pa_file → $new_pa"
    mv "$pa_file" "$new_pa"

    local old_json="${pa_file%.nii.gz}.json"
    local new_json="${new_pa%.nii.gz}.json"
    if [ -f "$old_json" ]; then
        log "Moved JSON to $new_json"
        mv "$old_json" "$new_json"
    fi

    log "\nDone with PA scans."
}

##
## Resting-state function to look in both 'rfMRI_REST_AP' and 'rfMRI_REST_PA'
## and handles "PA" versions of rest scans.
##
process_resting_state_scans() {
    local subj="$1"
    local session="$2"
    local nifti_subj_ses_dir="$3"
    local bids_subj_ses_dir="$4"

    local output_dir="$bids_subj_ses_dir/func"
    mkdir -p "$output_dir"

    log "\n=== Processing Resting-State Scans for $subj $session ==="

    # Check for "rfMRI_REST_AP" *or* "rfMRI_REST_PA" folders
    local rest_dirs=("rfMRI_REST_AP" "rfMRI_REST_PA")
    local found_rest=false
    for rd in "${rest_dirs[@]}"; do
        local rd_path="$nifti_subj_ses_dir/$rd"
        if [ -d "$rd_path" ]; then
            found_rest=true
            # Handle the last .nii.gz in that folder (can adapt if multiple runs)
            local rest_file
            rest_file=$(find "$rd_path" -type f -name "*.nii.gz" | sort -V | tail -1)
            if [ -n "$rest_file" ]; then
                # Name the BOLD file according to whether it's AP or PA
                local direction=""
                if [[ "$rd" == *"AP" ]]; then
                    direction="AP"
                else
                    direction="PA"
                fi

                # sub-XX_ses-YY_task-rest_dir-AP_bold.nii.gz  OR  _dir-PA_bold.nii.gz
                local new_rest="$output_dir/${subj}_${session}_task-rest_dir-${direction}_bold.nii.gz"
                log ""
                if [ -f "$new_rest" ]; then
                    log "Already exists: $new_rest (skipping)."
                else
                    log "Moving REST file: $rest_file → $new_rest"
                    mv "$rest_file" "$new_rest"

                    local old_json="${rest_file%.nii.gz}.json"
                    local new_json="${new_rest%.nii.gz}.json"
                    if [ -f "$old_json" ]; then
                        log "Moved JSON to $new_json"
                        mv "$old_json" "$new_json"
                    fi
                fi
            else
                log "No .nii.gz found in $rd_path (skipping)."
            fi
        fi
    done

    if [ "$found_rest" = false ]; then
        log "No 'rfMRI_REST_AP' or 'rfMRI_REST_PA' folder found; skipping resting-state."
    fi

    log "\nDone with resting-state scans."
}

process_anatomical_scans() {
    local subj="$1"
    local session="$2"
    local nifti_subj_ses_dir="$3"
    local bids_subj_ses_dir="$4"
    shift 4
    local requested_anat_types=("$@")  # e.g. t1w, t2w, hipp

    local output_dir="$bids_subj_ses_dir/anat"
    mkdir -p "$output_dir"

    log "\n=== Processing Anatomical for $subj $session ==="
    if [ ${#requested_anat_types[@]} -eq 0 ]; then
        log "No anatomical type specified (skipping)."
        return
    fi

    for anat_type in "${requested_anat_types[@]}"; do
        case "$anat_type" in
            t1w)
                local t1_dir="$nifti_subj_ses_dir/T1w_mprage_800iso_vNav"
                if [ -d "$t1_dir" ]; then
                    local t1_file
                    t1_file=$(find "$t1_dir" -type f -name "*.nii.gz" | sort -V | tail -1)
                    if [ -n "$t1_file" ]; then
                        local new_t1="$output_dir/${subj}_${session}_T1w.nii.gz"

                        log ""
                        if [ -f "$new_t1" ]; then
                            log "Already exists: $new_t1 (skip)."
                        else
                            log "Moving T1w: $t1_file → $new_t1"
                            mv "$t1_file" "$new_t1"

                            local old_json="${t1_file%.nii.gz}.json"
                            local new_json="${new_t1%.nii.gz}.json"
                            if [ -f "$old_json" ]; then
                                log "Moved JSON to $new_json"
                                mv "$old_json" "$new_json"
                            fi
                        fi
                    else
                        log "No T1w file found in $t1_dir."
                    fi
                else
                    log "T1w dir not found: $t1_dir."
                fi
                ;;
            t2w)
                local t2_dir="$nifti_subj_ses_dir/T2w_space_800iso_vNav"
                if [ -d "$t2_dir" ]; then
                    local t2_file
                    t2_file=$(find "$t2_dir" -type f -name "*.nii.gz" | sort -V | tail -1)
                    if [ -n "$t2_file" ]; then
                        local new_t2="$output_dir/${subj}_${session}_T2w.nii.gz"

                        log ""
                        if [ -f "$new_t2" ]; then
                            log "Already exists: $new_t2 (skip)."
                        else
                            log "Moving T2w: $t2_file → $new_t2"
                            mv "$t2_file" "$new_t2"

                            local old_json="${t2_file%.nii.gz}.json"
                            local new_json="${new_t2%.nii.gz}.json"
                            if [ -f "$old_json" ]; then
                                log "Moved JSON to $new_json"
                                mv "$old_json" "$new_json"
                            fi
                        fi
                    else
                        log "No T2w file found in $t2_dir."
                    fi
                else
                    log "T2w dir not found: $t2_dir."
                fi
                ;;
            hipp)
                log "\n=== Processing High-Resolution Hippocampus ==="
                local hip_dir="$nifti_subj_ses_dir/HighResHippocampus"
                if [ ! -d "$hip_dir" ]; then
                    log "No HighResHippocampus folder: $hip_dir"
                    continue
                fi

                local hip_file
                hip_file=$(find "$hip_dir" -type f -name "*.nii.gz" | sort -V | tail -1)
                if [ -z "$hip_file" ]; then
                    log "No .nii.gz found in HighResHippocampus (skipping)."
                    continue
                fi

                log ""
                local new_hip="$output_dir/${subj}_${session}_acq-highreshipp_T2w.nii.gz"
                if [ -f "$new_hip" ]; then
                    log "Already exists: $new_hip (skipping)."
                    continue
                fi

                log "Moving: $hip_file → $new_hip"
                mv "$hip_file" "$new_hip"

                local old_json="${hip_file%.nii.gz}.json"
                local new_json="${new_hip%.nii.gz}.json"
                if [ -f "$old_json" ]; then
                    log "Moved JSON to $new_json"
                    mv "$old_json" "$new_json"
                fi

                log "Done with HighResHippocampus."
                ;;
            *)
                log "\nWarning: Unknown anatomical type '$anat_type' (skipping)."
                ;;
        esac
    done

    log "\nDone with anatomical scans."
}

process_diffusion_scans() {
    local subj="$1"
    local session="$2"
    local nifti_subj_ses_dir="$3"
    local bids_subj_ses_dir="$4"

    log "\n=== Processing Diffusion Scans for $subj $session ==="
    local dwi_out="$bids_subj_ses_dir/dwi"
    mkdir -p "$dwi_out"

    # AP diffusion: diff_mb3_95dir_b2000_AP
    local ap_dir="$nifti_subj_ses_dir/diff_mb3_95dir_b2000_AP"
    if [ -d "$ap_dir" ]; then
        local ap_file
        # For convenience, just grab the last .nii.gz
        ap_file=$(find "$ap_dir" -type f -name "*.nii.gz" | sort -V | tail -1)
        if [ -n "$ap_file" ]; then
            local base="${subj}_${session}_dir-AP_dwi.nii.gz"
            local new_ap="$dwi_out/$base"
            log ""
            if [ ! -f "$new_ap" ]; then
                log "Moving AP DWI: $ap_file → $new_ap"
                mv "$ap_file" "$new_ap"

                # Move sidecars if they exist
                local old_root="${ap_file%.nii.gz}"
                local new_root="${new_ap%.nii.gz}"

                [ -f "${old_root}.bval" ] && mv "${old_root}.bval" "${new_root}.bval" && log "Moved bval → ${new_root}.bval"
                [ -f "${old_root}.bvec" ] && mv "${old_root}.bvec" "${new_root}.bvec" && log "Moved bvec → ${new_root}.bvec"
                [ -f "${old_root}.json" ] && mv "${old_root}.json" "${new_root}.json" && log "Moved JSON → ${new_root}.json"
            else
                log "Already exists: $new_ap (skipping)."
            fi
        fi
    else
        log "No AP diffusion folder: $ap_dir"
    fi

    # PA diffusion: diff_mb3_6dir_b2000_PA
    local pa_dir="$nifti_subj_ses_dir/diff_mb3_6dir_b2000_PA"
    if [ -d "$pa_dir" ]; then
        local pa_file
        pa_file=$(find "$pa_dir" -type f -name "*.nii.gz" | sort -V | tail -1)
        if [ -n "$pa_file" ]; then
            local base="${subj}_${session}_dir-PA_dwi.nii.gz"
            local new_pa="$dwi_out/$base"
            log ""
            if [ ! -f "$new_pa" ]; then
                log "Moving PA DWI: $pa_file → $new_pa"
                mv "$pa_file" "$new_pa"

                local old_root="${pa_file%.nii.gz}"
                local new_root="${new_pa%.nii.gz}"

                [ -f "${old_root}.bval" ] && mv "${old_root}.bval" "${new_root}.bval" && log "Moved bval → ${new_root}.bval"
                [ -f "${old_root}.bvec" ] && mv "${old_root}.bvec" "${new_root}.bvec" && log "Moved bvec → ${new_root}.bvec"
                [ -f "${old_root}.json" ] && mv "${old_root}.json" "${new_root}.json" && log "Moved JSON → ${new_root}.json"
            else
                log "Already exists: $new_pa (skipping)."
            fi
        fi
    else
        log "No PA diffusion folder: $pa_dir"
    fi

    log "\nDone with diffusion scans."
}

########################################
# 5) Main processing loop
########################################
for subj in "${subjects[@]}"; do
    local_subj_dir="$dcm_dir/$subj"
    if [ ! -d "$local_subj_dir" ]; then
        log "\n=== $subj ==="
        log "DICOM directory not found: $local_subj_dir"
        continue
    fi

    # Determine sessions to process
    if [ ${#sessions[@]} -gt 0 ]; then
        # Specified sessions
        sessions_to_process=()
        for ses in "${sessions[@]}"; do
            [ -d "$local_subj_dir/$ses" ] && sessions_to_process+=("$ses") || \
                log "\nWarning: $subj has no $ses in DICOM."
        done
    else
        # auto-detect
        sessions_to_process=($(find "$local_subj_dir" -type d -name "ses-*" -exec bash -c '
            for sdir; do
                if find "$sdir" -maxdepth 1 -name "*.zip" | grep -q .; then
                    basename "$sdir"
                fi
            done
        ' _ {} + | sort))
    fi

    [ ${#sessions_to_process[@]} -eq 0 ] && log "\nNo valid sessions for $subj" && continue

    log "\n=== Processing $subj ==="
    log "Sessions: ${sessions_to_process[*]}"

    for ses in "${sessions_to_process[@]}"; do
        subj_ses_dcm="$local_subj_dir/$ses"
        nifti_subj_ses_dir="$nifti_dir/$subj/$ses"
        bids_subj_ses_dir="$bids_dir/$subj/$ses"

        log "\n--- $subj $ses ---"

        ############################
        # 5a) DICOM → NIfTI if requested
        ############################
        if [ "$dcm2Nifti" = true ]; then
            log "\n--- DICOM to NIfTI Conversion ---"

            # Skip if already have non-empty NIfTI
            if [ -d "$nifti_subj_ses_dir" ] && [ "$(ls -A "$nifti_subj_ses_dir")" ]; then
                log "\nNIfTI dir $nifti_subj_ses_dir already populated, skipping conversion."
            else
                # Unzip DICOM if needed
                if [ ! -d "${subj_ses_dcm}/DICOM" ]; then
                    if ls "${subj_ses_dcm}"/*.zip &>/dev/null; then
                        unzip "${subj_ses_dcm}"/*.zip -d "$subj_ses_dcm" \
                            && log "\nUnzipped DICOM for $subj $ses." \
                            || log "\nError unzipping for $subj $ses."
                    else
                        log "\nNo DICOM zip in $subj_ses_dcm; skipping."
                        continue
                    fi
                else
                    log "\nDICOM folder already exists: ${subj_ses_dcm}/DICOM"
                fi

                # Convert
                tmp_out="${subj_ses_dcm}/nifti_output"
                mkdir -p "$tmp_out"
                dicom_dirs=$(find "${subj_ses_dcm}/DICOM" -type d)
                for dirX in $dicom_dirs; do
                    if ls "$dirX"/*.dcm &>/dev/null; then
                        log ""
                        log "Converting $dirX with dcm2niix..."
                        /Applications/MRIcron.app/Contents/Resources/dcm2niix \
                            -f "${subj}_%p_%s" -p y -z y -o "$tmp_out" "$dirX"
                    fi
                done

                log ""

                # ----------------------------------------------------------------
                # Gather .nii.gz, .bval, .bvec, .json in tmp_out and put them in subfolders
                # based on the scan naming patterns. Does a single loop to also
                # move sidecar files consistently.
                # ----------------------------------------------------------------
                mapfile -t candidate_files < <(find "$tmp_out" -maxdepth 1 -type f \( -name "*.nii.gz" -o -name "*.bval" -o -name "*.bvec" -o -name "*.json" \))
                for fpath in "${candidate_files[@]}"; do
                    baseNF=$(basename "$fpath")
                    # Strip off any recognized extension to parse the core name
                    core="${baseNF%.nii.gz}"
                    core="${core%.bval}"
                    core="${core%.bvec}"
                    core="${core%.json}"

                    folder="UNSORTED"

                    # Simple substring checks to decide the folder:
                    if [[ "$core" =~ rfMRI_TASK_AP ]]; then
                        folder="rfMRI_TASK_AP"
                    elif [[ "$core" =~ rfMRI_REST_AP ]]; then
                        folder="rfMRI_REST_AP"
                    elif [[ "$core" =~ rfMRI_REST_PA ]]; then
                        folder="rfMRI_REST_PA"
                    elif [[ "$core" =~ rfMRI_PA ]]; then
                        folder="rfMRI_PA"
                    elif [[ "$core" =~ T1w_mprage_800iso_vNav ]]; then
                        folder="T1w_mprage_800iso_vNav"
                    elif [[ "$core" =~ T1w_vNav_setter ]]; then
                        folder="T1w_vNav_setter"
                    elif [[ "$core" =~ T2w_space_800iso_vNav ]]; then
                        folder="T2w_space_800iso_vNav"
                    elif [[ "$core" =~ T2w_vNav_setter ]]; then
                        folder="T2w_vNav_setter"
                    elif [[ "$core" =~ diff_mb3_95dir_b2000_AP ]]; then
                        folder="diff_mb3_95dir_b2000_AP"
                    elif [[ "$core" =~ diff_mb3_6dir_b2000_PA ]]; then
                        folder="diff_mb3_6dir_b2000_PA"
                    elif [[ "$core" =~ HighResHippocampus ]]; then
                        folder="HighResHippocampus"
                    elif [[ "$core" =~ AAHScout ]]; then
                        folder="AAHScout"
                    elif [[ "$core" =~ localizer ]]; then
                        folder="localizer"
                    fi

                    mkdir -p "$tmp_out/$folder"
                    mv "$fpath" "$tmp_out/$folder/"
                    log "Moved $baseNF → $folder"
                done

                # Move everything from tmp_out/* to the final NIfTI directory
                mkdir -p "$nifti_subj_ses_dir"
                mv "$tmp_out"/* "$nifti_subj_ses_dir/"
                log "\nOrganized NIfTI into $nifti_subj_ses_dir"

                rm -rf "$tmp_out"
                log "Removed temp $tmp_out"

                rm -rf "${subj_ses_dcm}/DICOM"
                log "Removed ${subj_ses_dcm}/DICOM"
            fi
        else
            # Not converting
            if [ ! -d "$nifti_subj_ses_dir" ] || [ ! "$(ls -A "$nifti_subj_ses_dir")" ]; then
                log "\nEmpty NIfTI dir: $nifti_subj_ses_dir (skip scans)"
                continue
            fi
        fi

        # Ensure BIDS subject/session folder
        mkdir -p "$bids_subj_ses_dir"

        ############################
        # 5b) Process each requested scan type
        ############################
        [ "$process_task" = true ] && process_task_scans "$subj" "$ses" "$nifti_subj_ses_dir" "$bids_subj_ses_dir" "$task_name"
        [ "$process_pa" = true ] && process_pa_scans "$subj" "$ses" "$nifti_subj_ses_dir" "$bids_subj_ses_dir" "$pa_task_name"
        [ "$process_resting_state" = true ] && process_resting_state_scans "$subj" "$ses" "$nifti_subj_ses_dir" "$bids_subj_ses_dir"

        if [ ${#anat_types[@]} -gt 0 ]; then
            process_anatomical_scans "$subj" "$ses" "$nifti_subj_ses_dir" "$bids_subj_ses_dir" "${anat_types[@]}"
        fi

        [ "$process_diff" = true ] && process_diffusion_scans "$subj" "$ses" "$nifti_subj_ses_dir" "$bids_subj_ses_dir"
    done
done

log "\n=== Updating participants.tsv ==="

participants_tsv="${BASE_DIR}/participants.tsv"

# Find all existing sub-* directories in the BIDS root
current_subjs=($(find "$BASE_DIR" -maxdepth 1 -type d -name "sub-*" -exec basename {} \; | sort))

if [ ${#current_subjs[@]} -eq 0 ]; then
    log "No sub-* directories found in $BASE_DIR; skipping participants.tsv update."
else
    # Call create_tsv.sh.
    #    - Pass: <TSV_FILE> <NUM_COLUMNS> <COLUMN1> <list-of-rows>
    #    - Each subject ID (like sub-01, sub-02) is given as one row.
    bash "${script_dir}/create_tsv.sh" \
         "${participants_tsv}" \
         1 participant_id \
         "${current_subjs[@]}"
fi

log "\nBIDS setup Complete.\n"
