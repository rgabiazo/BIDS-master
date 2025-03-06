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
#                           Process one or more anatomical scans (t1w, t2w, hipp)
#   -diff, --diffusion      Process diffusion scans
#   -h, --help              Show this help message and exit
#
#   sub-XXX, ses-YYY        Specify subject(s) & session(s); or 'all' for all discovered subjects.
#
# Requirements:
#   - dcm2niix installed and on your PATH.
#   - A DICOM folder structure like:
#        sourcedata/dicom/sub-01/ses-01/*.zip
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

dcm_dir="${BASE_DIR}/sourcedata/dicom"
nifti_dir="${BASE_DIR}/sourcedata/nifti"
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

remove_archives=true   # Set this to "true" to remove the subject session directory with .zip / .tar.* files after conversion

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
    # Find sub-* directories in Dicom that contain .zip or .tar* files
    subjects=($(find "$dcm_dir" -type d -name "sub-*" -exec bash -c '
        for dir; do
            # Check each ses-* folder in sub-XX for any .zip, .tar, .tar.gz, .tgz, .tar.bz2
            if find "$dir" -type d -name "ses-*" \
                -exec find {} -maxdepth 1 -type f \
                    \( -name "*.zip" -o -name "*.tar" -o -name "*.tar.gz" -o -name "*.tgz" -o -name "*.tar.bz2" \) \; \
                | grep -q .; then
                basename "$dir"
            fi
        done
    ' _ {} + | sort))

    if [ ${#subjects[@]} -eq 0 ]; then
        log "\nNo subjects with .zip or .tar files found in $dcm_dir."
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
                local direction=""
                if [[ "$rd" == *"AP" ]]; then
                    direction="AP"
                else
                    direction="PA"
                fi

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
        ap_file=$(find "$ap_dir" -type f -name "*.nii.gz" | sort -V | tail -1)
        if [ -n "$ap_file" ]; then
            local base="${subj}_${session}_dir-AP_dwi.nii.gz"
            local new_ap="$dwi_out/$base"
            log ""
            if [ ! -f "$new_ap" ]; then
                log "Moving AP DWI: $ap_file → $new_ap"
                mv "$ap_file" "$new_ap"

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
    log "\n=== Processing subject: $subj ==="

    local_subj_dir="$dcm_dir/$subj"      # e.g. /path/to/dicom/sub-01
    nifti_subj_dir="$nifti_dir/$subj"    # e.g. /path/to/nifti/sub-01

    # -------------------------------------------
    # (A) Gather session folders from DICOM
    # -------------------------------------------
    sessions_to_process=()
    if [ -d "$local_subj_dir" ]; then
        mapfile -t dicom_ses < <(find "$local_subj_dir" -maxdepth 1 -type d -name "ses-*" -exec bash -c '
            for sdir; do
                # If this ses-* folder has .zip/.tar.* files, consider it
                if find "$sdir" -maxdepth 1 -type f \
                   \( -name "*.zip" -o -name "*.tar" -o -name "*.tar.gz" -o -name "*.tgz" -o -name "*.tar.bz2" \) \
                   | grep -q .; then
                    basename "$sdir"
                fi
            done
        ' _ {} + | sort)
        sessions_to_process+=( "${dicom_ses[@]}" )
    else
        log "\nNo DICOM folder for $subj at: $local_subj_dir"
    fi

    # -------------------------------------------
    # (B) If no sessions found in DICOM, see if
    #     NIfTI has any sub-XX/ses-XX directories
    # -------------------------------------------
    if [ ${#sessions_to_process[@]} -eq 0 ]; then
        if [ -d "$nifti_subj_dir" ]; then
            mapfile -t nifti_ses < <(find "$nifti_subj_dir" -maxdepth 1 -type d -name "ses-*" -exec basename {} \;)
            if [ ${#nifti_ses[@]} -gt 0 ]; then
                log "Found sessions in NIfTI: ${nifti_ses[*]}"
                sessions_to_process+=( "${nifti_ses[@]}" )
            fi
        fi
    fi

    # If still no sessions, skip
    if [ ${#sessions_to_process[@]} -eq 0 ]; then
        log "No sessions found for $subj (neither in DICOM nor NIfTI). Skipping."
        continue
    fi

    log "Sessions to process for $subj: ${sessions_to_process[*]}"

    # -------------------------------------------
    # (C) Loop over each session
    # -------------------------------------------
    for ses in "${sessions_to_process[@]}"; do
        log "\n--- $subj $ses ---"

        # Potential DICOM session path
        subj_ses_dcm="$local_subj_dir/$ses"

        # NIfTI session path
        nifti_subj_ses_dir="$nifti_subj_dir/$ses"

        # BIDS session path
        bids_subj_ses_dir="$bids_dir/$subj/$ses"

        # -------------------------------------------------
        # (C1) If DICOM→NIfTI, check if
        #      DICOM session folder still exists
        # -------------------------------------------------
        if [ "$dcm2Nifti" = true ]; then
            log "\n--- DICOM to NIfTI Conversion ---"
            
            # Find dcm2niix in the PATH
            dcm2niix_cmd="$(command -v dcm2niix)"
            
            # If not found, exit with error
            if [[ -z "$dcm2niix_cmd" ]]; then
                log "ERROR: dcm2niix not found on your PATH. Please install or specify the full path."
                exit 1
            fi
            
            # Skip if already have non-empty NIfTI
            if [ -d "$nifti_subj_ses_dir" ] && [ "$(ls -A "$nifti_subj_ses_dir")" ]; then
                log "\nNIfTI dir $nifti_subj_ses_dir already populated, skipping conversion."
            else
                if [ ! -d "${subj_ses_dcm}/DICOM" ]; then
                    # Look for any zip/tar/tar.gz/tgz/tar.bz2 in $subj_ses_dcm
                    mapfile -t archives < <(find "$subj_ses_dcm" -maxdepth 1 -type f \
                                            \( -name "*.zip" \
                                               -o -name "*.tar" \
                                               -o -name "*.tar.gz" \
                                               -o -name "*.tgz" \
                                               -o -name "*.tar.bz2" \))
                    if [ ${#archives[@]} -eq 0 ]; then
                        log "\nNo new DICOM archive found in $subj_ses_dcm."
                        log "Will check if existing NIfTI can be moved to BIDS..."
                    fi

                    # Unpack each archive found
                    for arch in "${archives[@]}"; do
                        case "$arch" in
                            *.zip)
                                log "\nUnzipping: $arch"
                                unzip -o "$arch" -d "$subj_ses_dcm"
                                ;;
                            *.tar)
                                log "\nExtracting .tar: $arch"
                                tar -xf "$arch" -C "$subj_ses_dcm"
                                ;;
                            *.tar.gz|*.tgz)
                                log "\nExtracting .tar.gz: $arch"
                                tar -xzf "$arch" -C "$subj_ses_dcm"
                                ;;
                            *.tar.bz2)
                                log "\nExtracting .tar.bz2: $arch"
                                tar -xjf "$arch" -C "$subj_ses_dcm"
                                ;;
                        esac
                    done
                    
                    # Find any *.dcm file
                    dcmdir="$(find "$subj_ses_dcm" -type f -name '*.dcm' -exec dirname {} \; | sort -u | head -n 1)"
                    
                    # Take that directory's *parent* as the one to rename, to rename e.g. "1.DD06792A" → "DICOM" (following .tar)
                    parentdir="$(dirname "$(dirname "$(dirname "$(dirname "$(dirname "$dcmdir")")")")")"
                    
                    # Take that directory's parent as the one to rename, to rename e.g. "1.DD06792A" → "DICOM"
                    # Rename only if it isn't already "DICOM"
                    if [[ -n "$parentdir" && "$parentdir" != "$subj_ses_dcm/DICOM" ]]; then
                        log "Renaming '$parentdir' → '$subj_ses_dcm/DICOM'"
                        mv "$parentdir" "$subj_ses_dcm/DICOM"
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
                        "$dcm2niix_cmd" \
                            -f "${subj}_%p_%s" -p y -z y -o "$tmp_out" "$dirX"
                    fi
                done

                log ""
                # Gather .nii.gz, .bval, etc. in tmp_out and put in subfolders
                mapfile -t candidate_files < <(find "$tmp_out" -maxdepth 1 -type f \( -name "*.nii.gz" -o -name "*.bval" -o -name "*.bvec" -o -name "*.json" \))
                for fpath in "${candidate_files[@]}"; do
                    baseNF=$(basename "$fpath")
                    core="${baseNF%.nii.gz}"
                    core="${core%.bval}"
                    core="${core%.bvec}"
                    core="${core%.json}"

                    folder="UNSORTED"
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

                mkdir -p "$nifti_subj_ses_dir"
                mv "$tmp_out"/* "$nifti_subj_ses_dir/"
                log "\nOrganized NIfTI into $nifti_subj_ses_dir"

                rm -rf "$tmp_out"
                log "Removed temp $tmp_out"

                # Check if subject directory is empty
                if [ "$remove_archives" = true ]; then
                    # 1) Remove the just-processed session directory
                    rm -rf "$subj_ses_dcm"
                    log "Removed the session folder for $subj_ses_dcm" >> "$log_file"
                    
                    # 2) Check if ANY ses-* folders remain in sub-XXX
                    remaining_sessions=($(find "$local_subj_dir" -mindepth 1 -maxdepth 1 -type d -name 'ses-*' | sort))
                    
                    if [ ${#remaining_sessions[@]} -eq 0 ]; then
                        rm -rf "$local_subj_dir" # If zero sessions remain => remove entire subject folder
                        log "Removed the entire directory for $subj: $local_subj_dir" >> "$log_file"
                    fi
                    
                else
                    # If not removing archives, just remove the DICOM/ subfolder
                    rm -rf "${subj_ses_dcm}/DICOM"
                    log "Removed DICOM folder in $subj_ses_dcm" >> $log_file
                    
                fi
                
            fi
        else
            # Not converting
            if [ ! -d "$nifti_subj_ses_dir" ] || [ ! "$(ls -A "$nifti_subj_ses_dir")" ]; then
                log "\nEmpty NIfTI dir: $nifti_subj_ses_dir (skip scans)"
                continue
            else
                log "\nNIfTI directory found: $nifti_subj_ses_dir. Moving scans to BIDS..."
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

log "\n=== Updating participants.tsv ===" >> $log_file

participants_tsv="${BASE_DIR}/participants.tsv"

# Collect current subjects (directories named sub-*)
current_subjs=($(find "$BASE_DIR" -maxdepth 1 -type d -name "sub-*" -exec basename {} \; | sort))

if [ ${#current_subjs[@]} -eq 0 ]; then
    log "No sub-* directories found in $BASE_DIR; skipping participants.tsv update." >> $log_file
    exit 0
fi

# Attempt to read dicom_metadata.json to add 'age' and 'sex' columns
dicom_metadata="${dcm_dir}/dicom_metadata.json"


if [ -f "$dicom_metadata" ]; then
    log "\nFound dicom_metadata.json, adding 'age' and 'sex' columns to participants.tsv..." >> $log_file

    # Build arrays with the same ordering as current_subjs
    declare -a ages
    declare -a sexes

    for s in "${current_subjs[@]}"; do
        subject_age=$(jq -r ".[\"$s\"].age // \"\"" "$dicom_metadata")
        subject_sex=$(jq -r ".[\"$s\"].sex // \"\"" "$dicom_metadata")
        ages+=( "$subject_age" )
        sexes+=( "$subject_sex" )
    done

    ##############################################################################
    # Build row strings for each subject, so each TSV row looks like:
    # "sub-01 79 M"
    # "sub-02 82 F"
    # etc.
    ##############################################################################
    declare -a row_data=()
    for i in "${!current_subjs[@]}"; do
        row_data+=("${current_subjs[i]}\t${ages[i]}\t${sexes[i]}")
    done

    ##############################################################################
    # Call create_tsv.sh, passing one row string per element in 'row_data[@]'
    ##############################################################################
    bash "${script_dir}/create_tsv.sh" \
         "$participants_tsv" \
         3 \
         "participant_id" "age" "sex" \
         "${row_data[@]}"

else
    # Original 1-column mode...
    bash "${script_dir}/create_tsv.sh" \
         "$participants_tsv" \
         1 \
         "participant_id" \
         "${current_subjs[@]}"
fi

log "\nBIDS setup Complete.\n"
