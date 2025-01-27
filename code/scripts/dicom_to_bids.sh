#!/bin/bash

# DICOM to BIDS Conversion Script
# --------------------------------
# This script converts DICOM files for neuroimaging studies into a 
# BIDS-compliant directory structure. It supports processing task-based fMRI 
# scans, phase-encoded PA scans, resting-state scans, and anatomical scans 
# (T1w and/or T2w). Outputs are organized into a clean, BIDS-compliant directory.

# HOW TO USE THIS SCRIPT:
# -----------------------
# 1. **Place the script** in your project directory:
#    Example directory structure:
#       - BASE_DIR/code/scripts/dicom_to_bids.sh
#       - BASE_DIR/sourcedata/Dicom/  (Raw DICOM files organized by subject/session)
#       - BASE_DIR/sourcedata/Nifti/  (Temporary NIfTI storage)
#       - BASE_DIR/                   (Root directory for BIDS output)
#
# 2. **Ensure prerequisites are installed**:
#    - Install `dcm2niix` for DICOM-to-NIfTI conversion: https://github.com/rordenlab/dcm2niix
#    - Ensure `dcm2niix` is in your PATH.
#
# 3. **Prepare your DICOM directory**:
#    - Organize raw DICOM files under `BASE_DIR/sourcedata/Dicom/` in a structure like:
#         sub-01/ses-01/
#         sub-02/ses-01/
#         sub-02/ses-02/
#
# 4. **Run the script**:
#    - Use `dcm2Nifti` argument to perform DICOM to NIfTI conversion.
#    - Use flags to specify scan types and provide subject IDs or `all` to process all subjects.
#    - Example: `bash dicom_to_bids.sh dcm2Nifti -t assocmemory -pa -anat both sub-01 sub-02 ses-01`
#
# Available Arguments and Flags:
# ------------------------------
# - `dcm2Nifti` or `-dcm2Nifti`:
#       Perform DICOM to NIfTI conversion and organize NIfTI files.
#
# - `-t <task_name>` or `--task <task_name>`:
#       Process task-based fMRI scans with a specified task name (e.g., `assocmemory`).
#
# - `-pa [<task_name>]` or `--process-pa [<task_name>]`:
#       Process phase-encoded PA scans for fieldmap correction.
#       Optionally provide a task name to associate with the PA scan.
#
# - `-rest` or `--resting-state`:
#       Process resting-state fMRI scans.
#
# - `-anat <type>` or `--anatomical <type>`:
#       Process anatomical scans. Options:
#       - `t1w`: Only process T1-weighted scans.
#       - `t2w`: Only process T2-weighted scans.
#       - `both`: Process both T1w and T2w scans.
#
# - Subjects and Sessions:
#       Provide subject IDs (e.g., `sub-01`, `sub-02`) and optionally session IDs
#       (e.g., `ses-01`, `ses-baseline`). If no sessions are specified, all available
#       sessions for the subject will be processed.
#
# Examples:
# ---------
# 1. Perform DICOM to NIfTI conversion and process task-based fMRI scans for specific subjects and sessions:
#       bash dicom_to_bids.sh dcm2Nifti -t assocmemory sub-01 sub-02 ses-01
#
# 2. Process PA scans with a task name and T1w anatomical scans for a subject:
#       bash dicom_to_bids.sh -pa assocmemory -anat t1w sub-03
#
# 3. Process all scans for all subjects:
#       bash dicom_to_bids.sh dcm2Nifti -t assocmemory -pa -rest -anat both all
#
# Output Details:
# ---------------
# - Outputs are written into a BIDS-compliant directory under `BASE_DIR/`:
#       BASE_DIR/sub-01/ses-01/func/  (for functional scans)
#       BASE_DIR/sub-01/ses-01/anat/  (for anatomical scans)
#
# - Temporary NIfTI files are stored in `BASE_DIR/sourcedata/Nifti/` during processing.
#
# - The DICOM directory is removed after successful conversion to NIfTI.
#
# Logging:
# --------
# - A detailed log file is created in `code/logs/` to record all actions and errors.
#
# Requirements:
# -------------
# - `dcm2niix` for DICOM-to-NIfTI conversion.
# - DICOM files organized into a `sub-XX/ses-XX` structure.
# - Proper permissions to create directories and write files.
#
# Tips:
# -----
# - **Always verify your DICOM structure**: Ensure each subject/session folder is correctly organized.
# - **Test with a single subject** before processing all data.
# - **Check logs**: Use the generated log file to debug any issues.
# - **Combine options**: For example, `-t assocmemory -pa -anat both` to process multiple scan types at once.
#
# Script Name:
# ------------
# **`dicom_to_bids.sh`**
# Clearly reflects the script's purpose of converting DICOM files to BIDS format.

# Base directories
script_dir="$(dirname "$(realpath "$0")")"
BASE_DIR="$(dirname "$(dirname "$script_dir")")"

dcm_dir="${BASE_DIR}/sourcedata/Dicom"
nifti_dir="${BASE_DIR}/sourcedata/Nifti"
bids_dir="${BASE_DIR}"
log_dir="${BASE_DIR}/code/logs"

# Default options
dcm2Nifti=false
process_task=false
task_name=""
process_pa=false
pa_task_name=""
process_anat=""
process_resting_state=false
subjects=()
sessions=()

# Create log directory if it doesn't exist
mkdir -p "$log_dir"
log_file="${log_dir}/$(basename $0)_$(date +%Y-%m-%d_%H-%M-%S).log"

# Log function
log() {
    echo -e "$1" | tee -a "$log_file"
}

# Check for 'dcm2Nifti' as the first argument
if [[ "$1" == "dcm2Nifti" || "$1" == "-dcm2Nifti" ]]; then
    dcm2Nifti=true
    shift
fi

# Parse options and arguments
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -t|--task)
            process_task=true
            task_name="$2"
            # Validate task_name
            if [[ "$task_name" == -* ]] || [[ -z "$task_name" ]]; then
                log "Warning: Task name is missing or invalid. Skipping task processing."
                task_name="" # Reset task_name if the next value is another flag or empty
                shift # Only shift once if no task name is provided
            else
                shift # Past argument
                shift # Past value
            fi
            ;;
        -rest|--resting-state)
            process_resting_state=true
            shift # Past flag
            ;;
        -pa|--process-pa)
            process_pa=true
            # Check if next argument is not another option
            if [[ "$2" != "" && "$2" != -* ]]; then
                pa_task_name="$2"
                shift # Past argument
                shift # Past value
            else
                pa_task_name="" # No task name provided
                shift # Past flag
            fi
            ;;
        -anat|--anatomical)
            process_anat="$2"
            # Validate process_anat
            if [[ "$process_anat" != "t1w" && "$process_anat" != "t2w" && "$process_anat" != "both" ]]; then
                log "Warning: Invalid anatomical option provided: $process_anat. Valid options are 't1w', 't2w', or 'both'."
                process_anat="" # Reset to prevent further processing
            fi
            shift # Past argument
            shift # Past value
            ;;
        *)
            # Could be a subject or a session
            if [[ "$key" == sub-* ]]; then
                subjects+=("$key")
            elif [[ "$key" == ses-* ]]; then
                sessions+=("$key")
            elif [[ "$key" == "all" ]]; then
                subjects+=("$key")
            else
                log "Warning: Unrecognized argument: $key"
                shift
                continue
            fi
            shift # Past argument
            ;;
    esac
done

# Function to process task-based functional scans
process_task_scans() {
    local subj="$1"
    local session="$2"
    local nifti_subj_ses_dir="$3"
    local bids_subj_ses_dir="$4"
    local task_name="$5"

    # Correct the output directory to point to the BIDS-compliant func directory
    local output_dir="$bids_subj_ses_dir/func"

    log ""
    log "=== Processing Functional Task Runs ==="
    log "Subject: $subj"
    log "Session: $session"
    log "NIfTI Directory: $nifti_subj_ses_dir"
    log "BIDS Output Directory: $output_dir"
    log ""

    # Locate functional task-based NIfTI files
    func_files=($(find "$nifti_subj_ses_dir/rfMRI_TASK_AP" -type f -name "*.nii.gz" -size +390M | sort -t_ -k4,4n))
    num_runs=${#func_files[@]}

    log "Found $num_runs functional task-based run(s) for processing."
    log ""

    if [ $num_runs -ge 1 ]; then
        mkdir -p "$output_dir"
        for ((i = 0; i < $num_runs; i++)); do
            run_num=$(printf "%02d" $((i + 1)))
            old_nii_file="${func_files[$i]}"
            base_filename="${subj}_${session}"
            if [ -n "$task_name" ]; then
                new_filename="${base_filename}_task-${task_name}_run-${run_num}_bold.nii.gz"
            else
                new_filename="${base_filename}_run-${run_num}_bold.nii.gz"
            fi
            new_nii_file="$output_dir/$new_filename"

            if [ -f "$new_nii_file" ]; then
                log "File already exists in destination: $new_nii_file"
                log "Skipping moving $old_nii_file"
                continue
            fi

            log "--- Processing Run $run_num ---"
            log "Moving $old_nii_file to $new_nii_file"
            mv "$old_nii_file" "$new_nii_file"

            old_json_file="${old_nii_file%.nii.gz}.json"
            new_json_file="${new_nii_file%.nii.gz}.json"

            if [ -f "$old_json_file" ]; then
                mv "$old_json_file" "$new_json_file"
                log "Moved JSON file to $new_json_file"
            else
                log "Warning: JSON file $old_json_file not found for $old_nii_file"
            fi

            log ""
        done
    else
        log "No functional task-based runs found for $subj $session."
    fi

    log ""
    log "=== Functional Task Runs Processing Complete ==="
    log ""
}

process_pa_scans() {
    local subj="$1"
    local session="$2"
    local nifti_subj_ses_dir="$3"
    local bids_subj_ses_dir="$4"
    local pa_task_name="$5"

    local output_dir="$bids_subj_ses_dir/func"

    log ""
    log "=== Processing Phase-Encoded PA Scans ==="
    log "Subject: $subj"
    log "Session: $session"
    log "NIfTI Directory: $nifti_subj_ses_dir"
    log "BIDS Output Directory: $output_dir"
    log ""

    # Check if the rfMRI_PA directory exists
    local pa_dir="$nifti_subj_ses_dir/rfMRI_PA"
    if [ ! -d "$pa_dir" ]; then
        log "Warning: Directory $pa_dir does not exist for $subj $session."
        log "Skipping PA scan processing."
        log ""
        log "=== PA Scan Processing Complete ==="
        log ""
        return
    fi

    # Locate the latest .nii.gz file in the rfMRI_PA directory
    local rfmri_pa_file=$(find "$pa_dir" -type f -name "*.nii.gz" | sort -V | tail -1)

    # Check if a PA scan file was found
    if [ -n "$rfmri_pa_file" ]; then
        mkdir -p "$output_dir"

        log "--- Processing Phase-Encoded PA File ---"
        log "File: $rfmri_pa_file"

        # Determine the new file name based on the presence of the task name
        base_filename="${subj}_${session}"
        if [ -n "$pa_task_name" ]; then
            local new_filename="${base_filename}_task-${pa_task_name}_dir-PA_epi.nii.gz"
        else
            local new_filename="${base_filename}_dir-PA_epi.nii.gz"
        fi
        local new_rfmri_pa_file="$output_dir/$new_filename"

        if [ -f "$new_rfmri_pa_file" ]; then
            log "File already exists in destination: $new_rfmri_pa_file"
            log "Skipping moving $rfmri_pa_file"
        else
            # Move the PA NIfTI file
            mv "$rfmri_pa_file" "$new_rfmri_pa_file"
            log "Moved $rfmri_pa_file to $new_rfmri_pa_file"

            # Locate and move the corresponding JSON file
            local old_rfmri_pa_json_file="${rfmri_pa_file%.nii.gz}.json"
            local new_rfmri_pa_json_file="${new_rfmri_pa_file%.nii.gz}.json"

            if [ -f "$old_rfmri_pa_json_file" ]; then
                mv "$old_rfmri_pa_json_file" "$new_rfmri_pa_json_file"
                log "Moved JSON file to $new_rfmri_pa_json_file"
            else
                log "Warning: JSON file not found for $rfmri_pa_file"
            fi
        fi
    else
        log "No rfMRI_PA files found in $pa_dir for sub-$subj ses-$session."
    fi

    log ""
    log "=== PA Scan Processing Complete ==="
    log ""
}

process_resting_state_scans() {
    local subj="$1"
    local session="$2"
    local nifti_subj_ses_dir="$3"
    local bids_subj_ses_dir="$4"

    local output_dir="$bids_subj_ses_dir/func"

    log ""
    log "=== Processing Resting-State Functional Scans ==="
    log "Subject: $subj"
    log "Session: $session"
    log "NIfTI Directory: $nifti_subj_ses_dir"
    log "BIDS Output Directory: $output_dir"
    log ""

    # Locate the resting-state NIfTI file
    local resting_state_file=$(find "$nifti_subj_ses_dir/rfMRI_REST_AP" -type f -name "*.nii.gz" | sort -V | tail -1)

    if [ -n "$resting_state_file" ]; then
        mkdir -p "$output_dir"
        local new_resting_state_file="$output_dir/${subj}_${session}_task-rest_bold.nii.gz"

        if [ -f "$new_resting_state_file" ]; then
            log "File already exists in destination: $new_resting_state_file"
            log "Skipping moving $resting_state_file"
        else
            log "--- Processing Resting-State File ---"
            log "Moving $resting_state_file to $new_resting_state_file"
            mv "$resting_state_file" "$new_resting_state_file"

            local old_resting_state_json_file="${resting_state_file%.nii.gz}.json"
            local new_resting_state_json_file="${new_resting_state_file%.nii.gz}.json"

            if [ -f "$old_resting_state_json_file" ]; then
                mv "$old_resting_state_json_file" "$new_resting_state_json_file"
                log "Moved JSON file to $new_resting_state_json_file"
            else
                log "Warning: JSON file not found for $resting_state_file"
            fi
        fi
    else
        log "No resting-state files found in $nifti_subj_ses_dir/rfMRI_REST_AP for sub-$subj ses-$session."
    fi

    log ""
    log "=== Resting-State Scans Processing Complete ==="
    log ""
}

process_anatomical_scans() {
    local subj="$1"
    local session="$2"
    local nifti_subj_ses_dir="$3"
    local bids_subj_ses_dir="$4"
    local process_anat="$5"

    local output_dir="$bids_subj_ses_dir/anat"

    log ""
    log "=== Processing Anatomical Scans ==="
    log "Subject: $subj"
    log "Session: $session"
    log "NIfTI Directory: $nifti_subj_ses_dir"
    log "BIDS Output Directory: $output_dir"
    log ""

    # Check if anatomical processing is specified
    if [[ -z "$process_anat" ]]; then
        log "Warning: Anatomical processing skipped for sub-$subj ses-$session. No '-anat' option provided."
        return
    fi

    # Process T1w scans
    if [[ "$process_anat" == "t1w" ]] || [[ "$process_anat" == "both" ]]; then
        local t1w_dir="$nifti_subj_ses_dir/T1w_mprage_800iso_vNav"
        if [ -d "$t1w_dir" ]; then
            t1w_file=$(find "$t1w_dir" -type f -name "*.nii.gz" | sort -V | tail -1)
            if [ -n "$t1w_file" ]; then
                mkdir -p "$output_dir"
                new_t1w_file="$output_dir/${subj}_${session}_T1w.nii.gz"

                if [ -f "$new_t1w_file" ]; then
                    log "File already exists in destination: $new_t1w_file"
                    log "Skipping moving $t1w_file"
                else
                    log "--- Processing T1w Scan ---"
                    log "Moving $t1w_file to $new_t1w_file"
                    mv "$t1w_file" "$new_t1w_file"

                    old_t1w_json_file="${t1w_file%.nii.gz}.json"
                    new_t1w_json_file="${new_t1w_file%.nii.gz}.json"
                    if [ -f "$old_t1w_json_file" ]; then
                        mv "$old_t1w_json_file" "$new_t1w_json_file"
                        log "Moved JSON file to $new_t1w_json_file"
                    else
                        log "Warning: JSON file not found for $t1w_file"
                    fi
                fi
            else
                log "No T1w file found in $t1w_dir for sub-$subj ses-$session."
            fi
        else
            log "Warning: T1w directory $t1w_dir does not exist for sub-$subj ses-$session."
        fi
    fi

    # Process T2w scans
    if [[ "$process_anat" == "t2w" ]] || [[ "$process_anat" == "both" ]]; then
        local t2w_dir="$nifti_subj_ses_dir/T2w_space_800iso_vNav"
        if [ -d "$t2w_dir" ]; then
            t2w_file=$(find "$t2w_dir" -type f -name "*.nii.gz" | sort -V | tail -1)
            if [ -n "$t2w_file" ]; then
                mkdir -p "$output_dir"
                new_t2w_file="$output_dir/${subj}_${session}_T2w.nii.gz"

                if [ -f "$new_t2w_file" ]; then
                    log "File already exists in destination: $new_t2w_file"
                    log "Skipping moving $t2w_file"
                else
                    log "--- Processing T2w Scan ---"
                    log "Moving $t2w_file to $new_t2w_file"
                    mv "$t2w_file" "$new_t2w_file"

                    old_t2w_json_file="${t2w_file%.nii.gz}.json"
                    new_t2w_json_file="${new_t2w_file%.nii.gz}.json"
                    if [ -f "$old_t2w_json_file" ]; then
                        mv "$old_t2w_json_file" "$new_t2w_json_file"
                        log "Moved JSON file to $new_t2w_json_file"
                    else
                        log "Warning: JSON file not found for $t2w_file"
                    fi
                fi
            else
                log "No T2w file found in $t2w_dir for sub-$subj ses-$session."
            fi
        else
            log "Warning: T2w directory $t2w_dir does not exist for sub-$subj ses-$session."
        fi
    fi

    # Log a message if an invalid option is provided
    if [[ "$process_anat" != "t1w" && "$process_anat" != "t2w" && "$process_anat" != "both" ]]; then
        log "Warning: Invalid '-anat' option specified: $process_anat. Skipping anatomical scans for sub-$subj ses-$session."
    fi

    log ""
    log "=== Anatomical Scans Processing Complete ==="
    log ""
}

if [[ " ${subjects[@]} " =~ " all " ]]; then
    log ""
    log "=== Processing all subjects ==="
    # Find all subjects in the DICOM directory with at least one .zip file
    subjects=($(find "$dcm_dir" -type d -name "sub-*" -exec bash -c '
        for dir; do
            if find "$dir" -type d -name "ses-*" -exec find {} -maxdepth 1 -name "*.zip" \; | grep -q .; then
                basename "$dir"
            fi
        done
    ' _ {} + | sort))

    if [ ${#subjects[@]} -eq 0 ]; then
        log ""
        log "No subjects with .zip files found in $dcm_dir."
        exit 1
    fi
    log ""
    log "Found the following subjects for processing: ${subjects[*]}"
    log ""
fi

# Main processing loop
for subj in "${subjects[@]}"; do
    subj_dcm_dir="$dcm_dir/$subj"
    if [ ! -d "$subj_dcm_dir" ]; then
        log ""
        log "=== Processing $subj ==="
        log "DICOM directory does not exist:"
        log "  $subj_dcm_dir"
        continue
    fi

    if [ ${#sessions[@]} -gt 0 ]; then
        # Sessions are specified
        sessions_to_process=()
        for ses in "${sessions[@]}"; do
            if [ -d "$subj_dcm_dir/$ses" ]; then
                sessions_to_process+=("$ses")
            else
                log "Warning: Session $ses does not exist for subject $subj."
            fi
        done
    else
        # Find all sessions under the subject DICOM directory that contain .zip files
        sessions_to_process=($(find "$subj_dcm_dir" -type d -name "ses-*" -exec bash -c '
            for session_dir; do
                if find "$session_dir" -maxdepth 1 -name "*.zip" | grep -q .; then
                    basename "$session_dir"
                fi
            done
        ' _ {} + | sort))
    fi

    # Check if any valid sessions were found
    if [ ${#sessions_to_process[@]} -eq 0 ]; then
        log "=== Processing $subj ==="
        log "No sessions with .zip files found in DICOM directory:"
        log "  $subj_dcm_dir"
        continue
    fi

    log ""
    log "=== Processing $subj ==="
    log "Found the following sessions for processing: ${sessions_to_process[*]}"

    for session in "${sessions_to_process[@]}"; do
        bids_subj_ses_dir="${bids_dir}/${subj}/${session}"
        nifti_subj_ses_dir="${nifti_dir}/${subj}/${session}"
        subj_folder="$dcm_dir/$subj/$session"
        output_dir="${subj_folder}/nifti_output"

        log ""
        log "=== Processing $subj $session ==="

        if [ "$dcm2Nifti" = true ]; then
            # DICOM to NIfTI conversion requested
            log ""
            log "--- DICOM to NIfTI Conversion ---"
            # Check if NIfTI directory already exists and is not empty
            if [ -d "$nifti_subj_ses_dir" ] && [ "$(ls -A "$nifti_subj_ses_dir")" ]; then
                log "NIfTI directory already exists and is not empty:"
                log "  $nifti_subj_ses_dir"
                log "Skipping DICOM to NIfTI conversion for $subj $session."
            else
                # Check and handle DICOM directory
                if [ ! -d "${subj_folder}/DICOM" ]; then
                    # Unzip DICOM files
                    if ls "${subj_folder}"/*.zip 1> /dev/null 2>&1; then
                        unzip "${subj_folder}"/*.zip -d "$subj_folder" && \
                        log "Unzipped DICOM files successfully for $subj $session." || \
                        log "Error unzipping DICOM files for $subj $session."
                    else
                        log "No DICOM zip files found in $subj_folder for $subj $session."
                        continue
                    fi
                else
                    log "DICOM directory already exists:"
                    log "  ${subj_folder}/DICOM"
                fi

                # Convert DICOM to NIfTI
                log "Starting DICOM to NIfTI conversion for $subj $session..."
                mkdir -p "$output_dir"
                dicom_dirs=$(find "${subj_folder}/DICOM" -type d)
                for dir in $dicom_dirs; do
                    if ls "$dir"/*.dcm 1> /dev/null 2>&1; then
                        log "Converting DICOM in directory:"
                        log "  $dir"
                        /Applications/MRIcron.app/Contents/Resources/dcm2niix -f "${subj}_%p_%s" -p y -z y -o "$output_dir" "$dir" && \
                        log "Conversion completed for $dir."
                    fi
                done

                # Organize files into folders
                folders=("AAHScout" "localizer" "rfMRI_PA" "rfMRI_REST_AP" "rfMRI_TASK_AP" "T1w_mprage_800iso_vNav" "T1w_vNav_setter" "T2w_space_800iso_vNav" "T2w_vNav_setter")
                for folder in "${folders[@]}"; do
                    mkdir -p "$output_dir/$folder"
                done

                for file in "$output_dir"/*.nii.gz; do
                    filename=$(basename "$file")
                    for folder in "${folders[@]}"; do
                        if [[ "$filename" == *"$folder"* ]]; then
                            mv "$file" "$output_dir/$folder/"
                            json_file="${file%.nii.gz}.json"
                            if [ -f "$json_file" ]; then
                                mv "$json_file" "$output_dir/$folder/"
                                log "Moved $filename and associated JSON to $output_dir/$folder/"
                            fi
                        fi
                    done
                done

                mkdir -p "$nifti_subj_ses_dir"
                mv "$output_dir"/* "$nifti_subj_ses_dir/"
                log "Organized files moved to $nifti_subj_ses_dir"

                # Delete the temporary output directory
                rm -rf "$output_dir"
                log "Deleted temporary directory: $output_dir"

                # Remove the DICOM directory
                rm -rf "${subj_folder}/DICOM"
                log "Deleted DICOM directory: ${subj_folder}/DICOM"
            fi
        else
            # DICOM to NIfTI conversion not requested
            # Check if NIfTI directory exists and is not empty
            if [ ! -d "$nifti_subj_ses_dir" ] || [ ! "$(ls -A "$nifti_subj_ses_dir")" ]; then
                log "NIfTI directory does not exist or is empty for $subj $session:"
                log "  $nifti_subj_ses_dir"
                continue
            fi
        fi

        # Ensure BIDS directory exists
        log ""
        log "--- BIDS Directory ---"
        if [ ! -d "$bids_subj_ses_dir" ]; then
            mkdir -p "$bids_subj_ses_dir"
            log "Status: Created new directory"
            log "Location:"
            log "  $bids_subj_ses_dir"
            log ""
        else
            log "Status: Already exists"
            log "Location:"
            log "  $bids_subj_ses_dir"
            log ""
        fi

        # Process requested scans
        if [ "$process_task" = true ]; then
            log "--- Task-Based Scans ---"
            process_task_scans "$subj" "$session" "$nifti_subj_ses_dir" "$bids_subj_ses_dir" "$task_name"
        fi

        if [ "$process_pa" = true ]; then
            log "--- PA Scans ---"
            process_pa_scans "$subj" "$session" "$nifti_subj_ses_dir" "$bids_subj_ses_dir" "$pa_task_name"
        fi

        if [ "$process_resting_state" = true ]; then
            log "--- Resting-State Scans ---"
            process_resting_state_scans "$subj" "$session" "$nifti_subj_ses_dir" "$bids_subj_ses_dir"
        fi

        if [ -n "$process_anat" ]; then
            log "--- Anatomical Scans ---"
            process_anatomical_scans "$subj" "$session" "$nifti_subj_ses_dir" "$bids_subj_ses_dir" "$process_anat"
        fi

    done
done
