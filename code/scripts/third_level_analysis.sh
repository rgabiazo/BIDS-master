#!/bin/bash

# third_level_analysis.sh
# Author: Raphael Gabiazon
# Description:
# It allows users to select and organize higher-level .gfeat directories
# for group analysis. The script dynamically finds, validates, and processes the directories,
# ensuring compatibility with custom Z-thresholds, cluster P-thresholds, user-defined output folder names,
# and flexible higher-level modeling approaches (OLS, FLAME1, FLAME1+2).
# Additionally, it allows editing (adding or replacing) multiple subjects and ensures valid input 
# for naming and thresholds.

# Set the prompt for the select command
PS3="Please enter your choice: "

# Get the directory where the script is located
script_dir="$(cd "$(dirname "$0")" && pwd)"
# Set BASE_DIR to two levels up from the script directory
BASE_DIR="$(dirname "$(dirname "$script_dir")")"

# Define log file path
LOG_DIR="$BASE_DIR/code/logs"
mkdir -p "$LOG_DIR"
LOGFILE="$LOG_DIR/$(basename "$0" .sh)_$(date +'%Y%m%d_%H%M%S').log"

# Redirect stdout and stderr to the log file and console
exec > >(tee -a "$LOGFILE") 2>&1

# Define the full path to the level-1 and level-2 analysis directories
LEVEL_1_ANALYSIS_BASE_DIR="$BASE_DIR/derivatives/fsl/level-1"
LEVEL_2_ANALYSIS_BASE_DIR="$BASE_DIR/derivatives/fsl/level-2"
LEVEL_3_ANALYSIS_BASE_DIR="$BASE_DIR/derivatives/fsl/level-3"

# Function to check for available analysis directories with lower-level FEAT directories
find_lower_level_analysis_dirs() {
    local base_dir="$1"
    ANALYSIS_DIRS=()
    while IFS= read -r -d $'\0' dir; do
        if find "$dir" -type d -name "*.feat" -print -quit | grep -q .; then
            ANALYSIS_DIRS+=("$dir")
        fi
    done < <(find "$base_dir" -mindepth 1 -maxdepth 1 -type d -print0)
}

# Function to check for available analysis directories with higher-level .gfeat directories
find_higher_level_analysis_dirs() {
    local base_dir="$1"
    ANALYSIS_DIRS=()
    while IFS= read -r -d $'\0' dir; do
        if find "$dir" -type d -name "*.gfeat" -print -quit | grep -q .; then
            ANALYSIS_DIRS+=("$dir")
        fi
    done < <(find "$base_dir" -mindepth 1 -maxdepth 1 -type d -print0)
}

# Function to clear the terminal and display selections
display_selections() {
    clear
    echo -e "\n=== Confirm Your Selections for Mixed Effects Analysis ==="
    echo "Session: $SESSION"

    echo

    # Collect and sort subjects
    sorted_subjects=($(printf "%s\n" "${subjects[@]}" | sort))

    # Display sorted selections
    for subject in "${sorted_subjects[@]}"; do
        # Find the corresponding data for this subject
        for idx in "${!subjects[@]}"; do
            if [ "${subjects[$idx]}" == "$subject" ]; then
                directories_str="${directories[$idx]}"
                directory_types_str="${directory_types[$idx]}"
                session="${sessions[$idx]}"
                break
            fi
        done

        IFS='::' read -ra directories_list <<< "$directories_str"
        IFS='::' read -ra directory_types_list <<< "$directory_types_str"

        echo "Subject: $subject | Session: $session"
        echo "----------------------------------------"

        for idx2 in "${!directories_list[@]}"; do
            dir="${directories_list[$idx2]}"
            dir_type="${directory_types_list[$idx2]}"

            if [ "$dir_type" == "lower" ]; then
                echo "Selected Feat Directory:"
            else
                echo "Higher-level Feat Directory:"
            fi

            echo "  - ${dir#$BASE_DIR/}"
        done
        echo
    done

    echo "============================================"
    echo
    echo "Options:"
    echo "  • To exclude subjects, type '-' followed by subject IDs separated by spaces (e.g., '- sub-01 sub-02')."
    echo "  • To edit (add **new** or replace **existing**) directories for a specific subject, type 'edit'."
    echo "    (This lets you add new subjects or, if the subject already exists, change its currently selected directory.)"
    echo "  • Press Enter/Return to confirm and proceed with third-level mixed effects analysis if the selections are final."
    echo
    read -p "> " user_input
}

# Display the main menu
echo -e "\n=== Third Level Analysis  ==="

# Now, we assume INPUT_TYPE="higher"

# Check for higher-level .gfeat directories
find_higher_level_analysis_dirs "$LEVEL_2_ANALYSIS_BASE_DIR"
if [ ${#ANALYSIS_DIRS[@]} -eq 0 ]; then
    echo -e "\nNo available directories for higher-level analysis found."
    echo "Please ensure that second-level fixed-effects analysis has been completed and the directories exist in the specified path."
    echo -e "Exiting...\n"
    exit 1
fi

INPUT_TYPE="higher"

ANALYSIS_BASE_DIR="$LEVEL_2_ANALYSIS_BASE_DIR"
echo -e "\n---- Higher level FEAT directories ----"
echo "Select analysis directory containing 3D cope images"

echo
ANALYSIS_DIR_OPTIONS=()
for idx in "${!ANALYSIS_DIRS[@]}"; do
    echo "$((idx + 1))) ${ANALYSIS_DIRS[$idx]#$BASE_DIR/}"
    ANALYSIS_DIR_OPTIONS+=("$((idx + 1))")
done

echo ""
read -p "Please enter your choice: " analysis_choice

# Validation for analysis_choice
while ! [[ "$analysis_choice" =~ ^[0-9]+$ ]] || (( analysis_choice < 1 || analysis_choice > ${#ANALYSIS_DIRS[@]} )); do
    echo "Invalid selection. Please try again."
    read -p "Please enter your choice: " analysis_choice
done

ANALYSIS_DIR="${ANALYSIS_DIRS[$((analysis_choice - 1))]}"
echo -e "\nYou have selected the following analysis directory:"
echo "$ANALYSIS_DIR"

# Find available sessions in the selected analysis directory
SESSION_NAME_PATTERNS=("ses-*" "session-*" "ses_*" "session_*" "ses*" "session*" "baseline" "endpoint" "ses-001" "ses-002")
FIND_SESSION_EXPR=()
first_session_pattern=true
for pattern in "${SESSION_NAME_PATTERNS[@]}"; do
    if $first_session_pattern; then
        FIND_SESSION_EXPR+=( -name "$pattern" )
        first_session_pattern=false
    else
        FIND_SESSION_EXPR+=( -o -name "$pattern" )
    fi
done

# Find session directories
session_dirs=($(find "$ANALYSIS_DIR" -type d \( "${FIND_SESSION_EXPR[@]}" \)))
session_dirs=($(printf "%s\n" "${session_dirs[@]}" | sort))

# Extract unique session names
session_names=()
for session_dir in "${session_dirs[@]}"; do
    session_name=$(basename "$session_dir")
    if [[ ! " ${session_names[@]} " =~ " ${session_name} " ]]; then
        session_names+=("$session_name")
    fi
done

if [ ${#session_names[@]} -eq 0 ]; then
    echo "No sessions found in $ANALYSIS_DIR."
    exit 1
fi

echo -e "\n--- Select session ---"
echo "Higher level FEAT directories"
echo -e "\nSelect available sessions:\n"

SESSION_OPTIONS=()
for idx in "${!session_names[@]}"; do
    echo "$((idx + 1))) ${session_names[$idx]}"
    SESSION_OPTIONS+=("$((idx + 1))")
done

echo ""
read -p "Please enter your choice: " session_choice

# Validation for session_choice
while ! [[ "$session_choice" =~ ^[0-9]+$ ]] || (( session_choice < 1 || session_choice > ${#session_names[@]} )); do
    echo "Invalid selection. Please try again."
    read -p "Please enter your choice: " session_choice
done

SESSION="${session_names[$((session_choice - 1))]}"
echo -e "\nYou have selected session: $SESSION"

subjects=()
directories=()
directory_types=()
sessions=()

SUBJECT_NAME_PATTERNS=("sub-*" "subject-*" "pilot-*" "subj-*" "subjpilot-*")
FIND_SUBJECT_EXPR=()
first_pattern=true
for pattern in "${SUBJECT_NAME_PATTERNS[@]}"; do
    if $first_pattern; then
        FIND_SUBJECT_EXPR+=( -name "$pattern" )
        first_pattern=false
    else
        FIND_SUBJECT_EXPR+=( -o -name "$pattern" )
    fi
done

subject_dirs=($(find "$ANALYSIS_DIR" -mindepth 1 -maxdepth 1 -type d \( "${FIND_SUBJECT_EXPR[@]}" \)))
subject_dirs=($(printf "%s\n" "${subject_dirs[@]}" | sort))

if [ ${#subject_dirs[@]} -eq 0 ]; then
    echo "No subject directories found in session $SESSION."
    exit 1
fi

for subject_dir in "${subject_dirs[@]}"; do
    subject=$(basename "$subject_dir")
    session_dir="$subject_dir/$SESSION"
    if [ ! -d "$session_dir" ]; then
        continue
    fi

    directories_list=()
    directory_types_list=()
    gfeat_dirs=($(find "$session_dir" -mindepth 1 -maxdepth 1 -type d -name "*.gfeat"))
    gfeat_dirs=($(printf "%s\n" "${gfeat_dirs[@]}" | sort))
    if [ ${#gfeat_dirs[@]} -eq 0 ]; then
        continue
    fi
    directories_list+=("${gfeat_dirs[@]}")
    for ((i=0; i<${#gfeat_dirs[@]}; i++)); do
        directory_types_list+=("higher")
    done

    directories_list_filtered=()
    directory_types_list_filtered=()
    for idx in "${!directories_list[@]}"; do
        dir="${directories_list[$idx]}"
        if [ -n "$dir" ]; then
            directories_list_filtered+=("$dir")
            directory_types_list_filtered+=("${directory_types_list[$idx]}")
        fi
    done
    if [ ${#directories_list_filtered[@]} -gt 0 ]; then
        subjects+=("$subject")
        directories_str=$(printf "::%s" "${directories_list_filtered[@]}")
        directories_str="${directories_str:2}"
        directories+=("$directories_str")
        directory_types_str=$(printf "::%s" "${directory_types_list_filtered[@]}")
        directory_types_str="${directory_types_str:2}"
        directory_types+=("$directory_types_str")
        sessions+=("$SESSION")
    fi
done

while true; do
    display_selections

    # Convert user input to lowercase
    lower_input=$(echo "$user_input" | tr '[:upper:]' '[:lower:]')

    # If user just presses Enter, break out and move on
    if [ -z "$user_input" ]; then
        # CLEAR BEFORE FINAL OUTPUT
        clear
        break

    elif [[ "$lower_input" == "edit" ]]; then
        # "edit" or replace directories
        echo -e "\nSelect input options:\n"
        echo "1) Inputs are lower-level FEAT directories"
        echo "2) Inputs are higher-level .gfeat directories"
        echo "3) Cancel"
        echo ""
        read -p "Please enter your choice: " edit_choice

        # Validation for edit_choice
        while ! [[ "$edit_choice" =~ ^[0-9]+$ ]] || (( edit_choice < 1 || edit_choice > 3 )); do
            echo "Invalid selection. Please try again."
            read -p "Please enter your choice: " edit_choice
        done

        if [ "$edit_choice" == "3" ]; then
            continue
        elif [ "$edit_choice" == "1" ]; then
            ADD_INPUT_TYPE="lower"
            ADD_ANALYSIS_BASE_DIR="$LEVEL_1_ANALYSIS_BASE_DIR"
        elif [ "$edit_choice" == "2" ]; then
            ADD_INPUT_TYPE="higher"
            ADD_ANALYSIS_BASE_DIR="$LEVEL_2_ANALYSIS_BASE_DIR"
        else
            echo "Invalid selection. Please try again."
            continue
        fi

        if [ "$ADD_INPUT_TYPE" == "lower" ]; then
            find_lower_level_analysis_dirs "$ADD_ANALYSIS_BASE_DIR"
        else
            find_higher_level_analysis_dirs "$ADD_ANALYSIS_BASE_DIR"
        fi

        if [ ${#ANALYSIS_DIRS[@]} -eq 0 ]; then
            echo "No analysis directories found."
            continue
        fi

        echo
        ANALYSIS_DIR_OPTIONS=()
        for idx in "${!ANALYSIS_DIRS[@]}"; do
            echo "$((idx + 1))) ${ANALYSIS_DIRS[$idx]#$BASE_DIR/}"
            ANALYSIS_DIR_OPTIONS+=("$((idx + 1))")
        done

        echo ""
        read -p "Please enter your choice: " analysis_choice

        # Validation for analysis_choice
        while ! [[ "$analysis_choice" =~ ^[0-9]+$ ]] || (( analysis_choice < 1 || analysis_choice > ${#ANALYSIS_DIRS[@]} )); do
            echo "Invalid selection. Please try again."
            read -p "Please enter your choice: " analysis_choice
        done

        ADD_ANALYSIS_DIR="${ANALYSIS_DIRS[$((analysis_choice - 1))]}"
        echo -e "\nYou have selected the following analysis directory:"
        echo "$ADD_ANALYSIS_DIR"

        # Find sessions in the ADD_ANALYSIS_DIR
        session_dirs=($(find "$ADD_ANALYSIS_DIR" -type d \( "${FIND_SESSION_EXPR[@]}" \)))
        session_dirs=($(printf "%s\n" "${session_dirs[@]}" | sort))

        session_names=()
        for session_dir in "${session_dirs[@]}"; do
            session_name=$(basename "$session_dir")
            if [[ ! " ${session_names[@]} " =~ " ${session_name} " ]]; then
                session_names+=("$session_name")
            fi
        done

        if [ ${#session_names[@]} -eq 0 ]; then
            echo "No sessions found in $ADD_ANALYSIS_DIR."
            continue
        fi

        echo -e "\nSelect available sessions:\n"
        SESSION_OPTIONS=()
        for idx in "${!session_names[@]}"; do
            echo "$((idx + 1))) ${session_names[$idx]}"
            SESSION_OPTIONS+=("$((idx + 1))")
        done

        echo ""
        read -p "Please enter your choice: " session_choice

        # Validation for session_choice
        while ! [[ "$session_choice" =~ ^[0-9]+$ ]] || (( session_choice < 1 || session_choice > ${#session_names[@]} )); do
            echo "Invalid selection. Please try again."
            read -p "Please enter your choice: " session_choice
        done

        ADD_SESSION="${session_names[$((session_choice - 1))]}"
        echo -e "\nYou have selected session: $ADD_SESSION"

        echo -e "\nSelect subject to edit:\n"
        ADD_SUBJECT_OPTIONS=()
        ADD_SUBJECT_DIRS=()
        subject_dirs=($(find "$ADD_ANALYSIS_DIR" -mindepth 1 -maxdepth 1 -type d \( "${FIND_SUBJECT_EXPR[@]}" \)))
        subject_dirs=($(printf "%s\n" "${subject_dirs[@]}" | sort))

        idx=0
        for dir in "${subject_dirs[@]}"; do
            subject_name=$(basename "$dir")
            session_dir="$dir/$ADD_SESSION"
            if [ ! -d "$session_dir" ]; then
                continue
            fi
            # Align numbering
            idxpadded=$(printf "%2d" $((idx + 1)))
            echo "${idxpadded})  $subject_name"

            ADD_SUBJECT_OPTIONS+=("$((idx + 1))")
            ADD_SUBJECT_DIRS+=("$dir")
            idx=$((idx + 1))
        done

        if [ ${#ADD_SUBJECT_OPTIONS[@]} -eq 0 ]; then
            echo "No subjects found in session $ADD_SESSION."
            continue
        fi
        echo ""
        read -p "Please enter your choice: " subject_choice

        # Validation for subject_choice
        while ! [[ "$subject_choice" =~ ^[0-9]+$ ]] || (( subject_choice < 1 || subject_choice > ${#ADD_SUBJECT_OPTIONS[@]} )); do
            echo "Invalid selection. Please try again."
            read -p "Please enter your choice: " subject_choice
        done

        ADD_SUBJECT_DIR="${ADD_SUBJECT_DIRS[$((subject_choice - 1))]}"
        subject=$(basename "$ADD_SUBJECT_DIR")
        echo -e "\nListing directories for $subject in session $ADD_SESSION..."

        session_dir="$ADD_SUBJECT_DIR/$ADD_SESSION"

        directories_list=()
        directory_types_list=()

        if [ "$ADD_INPUT_TYPE" == "lower" ]; then
            func_dir="$session_dir/func"
            if [ ! -d "$func_dir" ]; then
                echo "  - No func directory found for $subject in session $ADD_SESSION."
                continue
            fi
            feat_dirs=($(find "$func_dir" -mindepth 1 -maxdepth 1 -type d -name "*.feat"))
            feat_dirs=($(printf "%s\n" "${feat_dirs[@]}" | sort))
            if [ ${#feat_dirs[@]} -eq 0 ]; then
                echo "  - No feat directories found for $subject in session $ADD_SESSION."
                continue
            fi
            echo -e "\nFeat Directories:\n"
            for idx in "${!feat_dirs[@]}"; do
                # Align numbering for FEAT directories
                idxpadded=$(printf "%2d" $((idx + 1)))
                echo "${idxpadded})  ${feat_dirs[$idx]#$BASE_DIR/}"
            done
            echo -e "\nSelect the run corresponding to the lower-level FEAT directory to edit,\nby entering its number (e.g., 1):"
            read -p "> " feat_choice

            # Validation for feat_choice
            while ! [[ "$feat_choice" =~ ^[0-9]+$ ]] || (( feat_choice < 1 || feat_choice > ${#feat_dirs[@]} )); do
                echo "Invalid selection. Please enter a single valid number in the available range."
                echo -n "> "
                read feat_choice
            done

            selected_feat="${feat_dirs[$((feat_choice - 1))]}"
            directories_list+=("$selected_feat")
            directory_types_list+=("lower")

        else
            gfeat_dirs=($(find "$session_dir" -mindepth 1 -maxdepth 1 -type d -name "*.gfeat"))
            gfeat_dirs=($(printf "%s\n" "${gfeat_dirs[@]}" | sort))
            if [ ${#gfeat_dirs[@]} -eq 0 ]; then
                echo "  - No .gfeat directories found for $subject in session $ADD_SESSION."
                continue
            fi
            echo -e "\ngfeat Directories:\n"
            for idx in "${!gfeat_dirs[@]}"; do
                idxpadded=$(printf "%2d" $((idx + 1)))
                echo "${idxpadded})  ${gfeat_dirs[$idx]#$BASE_DIR/}"
            done
            echo -e "\nSelect the number corresponding to the .gfeat directory to edit (e.g., 1):"
            read -p "> " gfeat_choice

            # Validation for gfeat_choice
            while ! [[ "$gfeat_choice" =~ ^[0-9]+$ ]] || (( gfeat_choice < 1 || gfeat_choice > ${#gfeat_dirs[@]} )); do
                echo "Invalid selection. Please enter a single valid number in the available range."
                echo -n "> "
                read gfeat_choice
            done

            selected_gfeat="${gfeat_dirs[$((gfeat_choice - 1))]}"
            directories_list+=("$selected_gfeat")
            directory_types_list+=("higher")
        fi

        directories_list_filtered=()
        directory_types_list_filtered=()
        for idx in "${!directories_list[@]}"; do
            dir="${directories_list[$idx]}"
            if [ -n "$dir" ]; then
                directories_list_filtered+=("$dir")
                directory_types_list_filtered+=("${directory_types_list[$idx]}")
            fi
        done

        directories_str=$(printf "::%s" "${directories_list_filtered[@]}")
        directories_str="${directories_str:2}"
        directory_types_str=$(printf "::%s" "${directory_types_list_filtered[@]}")
        directory_types_str="${directory_types_str:2}"

        subject_found=false
        for idx in "${!subjects[@]}"; do
            if [ "${subjects[$idx]}" == "$subject" ]; then
                directories[$idx]="$directories_str"
                directory_types[$idx]="$directory_types_str"
                sessions[$idx]="$ADD_SESSION"
                subject_found=true
                break
            fi
        done
        if [ "$subject_found" == false ]; then
            subjects+=("$subject")
            directories+=("$directories_str")
            directory_types+=("$directory_types_str")
            sessions+=("$ADD_SESSION")
        fi
    elif [[ "$user_input" =~ ^- ]]; then
        # Removing subjects
        # Split the input by spaces
        read -ra remove_args <<< "$user_input"
        # First arg is '-', subsequent are subjects to remove
        if [ ${#remove_args[@]} -lt 2 ]; then
            echo -e "\nError: No subjects provided to remove. Please try again."
            continue
        fi

        # Validate subjects and ensure no 'edit' keyword
        to_remove=("${remove_args[@]:1}")
        invalid_remove=false
        for sub in "${to_remove[@]}"; do
            # Check for 'edit'
            if [ "$sub" == "edit" ]; then
                echo -e "\nError: 'edit' keyword found while trying to remove subjects. Invalid input."
                invalid_remove=true
                break
            fi
            # Check subject name format and if it exists in subjects array
            if ! printf '%s\n' "${subjects[@]}" | grep -qx "$sub"; then
                echo -e "\nError: Subject '$sub' is not in the dataset or already excluded."
                invalid_remove=true
                break
            fi
        done
        if $invalid_remove; then
            continue
        fi

        # Remove the subjects
        new_subjects=()
        new_directories=()
        new_directory_types=()
        new_sessions=()
        for idx in "${!subjects[@]}"; do
            remove_this=false
            for rsub in "${to_remove[@]}"; do
                if [ "${subjects[$idx]}" == "$rsub" ]; then
                    remove_this=true
                    break
                fi
            done
            if ! $remove_this; then
                new_subjects+=("${subjects[$idx]}")
                new_directories+=("${directories[$idx]}")
                new_directory_types+=("${directory_types[$idx]}")
                new_sessions+=("${sessions[$idx]}")
            fi
        done
        subjects=("${new_subjects[@]}")
        directories=("${new_directories[@]}")
        directory_types=("${new_directory_types[@]}")
        sessions=("${new_sessions[@]}")
    else
        echo "Invalid input. Please try again."
    fi
done

# Check if at least 3 directories are selected
total_directories=0
for idx in "${!subjects[@]}"; do
    directories_str="${directories[$idx]}"
    IFS='::' read -a directories_list <<< "$directories_str"
    total_directories=$((total_directories + ${#directories_list[@]}))
done

if [ "$total_directories" -lt 3 ]; then
    echo -e "\nError: At least 3 directories are required for mixed effects analysis."
    echo "You have selected only $total_directories directories."
    exit 1
fi

# Collect cope numbers
cope_numbers_per_directory=()
all_cope_numbers=()

dir_index=0
for idx in "${!subjects[@]}"; do
    directories_str="${directories[$idx]}"
    directory_types_str="${directory_types[$idx]}"
    IFS='::' read -a directories_list <<< "$directories_str"
    IFS='::' read -a directory_types_list <<< "$directory_types_str"

    for dir_idx in "${!directories_list[@]}"; do
        dir="${directories_list[$dir_idx]}"
        dir_type="${directory_types_list[$dir_idx]}"

        if [ "$dir_type" == "lower" ]; then
            cope_files=($(find "$dir/stats" -maxdepth 1 -name "cope*.nii.gz"))
            cope_numbers=()
            for cope_file in "${cope_files[@]}"; do
                filename=$(basename "$cope_file")
                if [[ "$filename" =~ ^cope([0-9]+)\.nii\.gz$ ]]; then
                    cope_num="${BASH_REMATCH[1]}"
                    cope_numbers+=("$cope_num")
                fi
            done
        else
            cope_dirs=($(find "$dir" -maxdepth 1 -type d -name "cope*.feat"))
            cope_numbers=()
            for cope_dir in "${cope_dirs[@]}"; do
                dirname=$(basename "$cope_dir")
                if [[ "$dirname" =~ ^cope([0-9]+)\.feat$ ]]; then
                    cope_num="${BASH_REMATCH[1]}"
                    cope_numbers+=("$cope_num")
                fi
            done
        fi

        cope_numbers=($(printf "%s\n" "${cope_numbers[@]}" | sort -n | uniq))
        cope_numbers_str=$(printf "%s " "${cope_numbers[@]}")
        cope_numbers_per_directory[$dir_index]="$cope_numbers_str"
        all_cope_numbers+=("${cope_numbers[@]}")
        dir_index=$((dir_index + 1))
    done
done

unique_cope_numbers=($(printf "%s\n" "${all_cope_numbers[@]}" | sort -n | uniq))
common_cope_numbers=("${unique_cope_numbers[@]}")

dir_index=0
for cope_numbers_str in "${cope_numbers_per_directory[@]}"; do
    cope_numbers=($cope_numbers_str)
    temp_common=()
    for cope in "${common_cope_numbers[@]}"; do
        for dir_cope in "${cope_numbers[@]}"; do
            if [ "$cope" == "$dir_cope" ]; then
                temp_common+=("$cope")
                break
            fi
        done
    done
    common_cope_numbers=($(printf "%s\n" "${temp_common[@]}" | sort -n | uniq))
    dir_index=$((dir_index + 1))
done

if [ ${#common_cope_numbers[@]} -eq 0 ]; then
    echo -e "\nError: No common copes found across all selected directories."
    exit 1
fi

########################################################
# Display Final Selections (clean screen)
########################################################

echo -e "=== Final Selected Directories ===\n"

sorted_subjects=($(printf "%s\n" "${subjects[@]}" | sort))

for cope_num in "${common_cope_numbers[@]}"; do
    echo "=== Cope image: cope$cope_num ==="

    for subject in "${sorted_subjects[@]}"; do
        for idx in "${!subjects[@]}"; do
            if [ "${subjects[$idx]}" == "$subject" ]; then
                directories_str="${directories[$idx]}"
                directory_types_str="${directory_types[$idx]}"
                session="${sessions[$idx]}"
                break
            fi
        done

        IFS='::' read -a directories_list <<< "$directories_str"
        IFS='::' read -a directory_types_list <<< "$directory_types_str"

        # Sort pairs for consistent ordering
        sorted_pairs=($(paste -d ':' <(printf "%s\n" "${directories_list[@]}") <(printf "%s\n" "${directory_types_list[@]}") | sort))
        directories_list=()
        directory_types_list=()
        for pair in "${sorted_pairs[@]}"; do
            IFS=':' read -r dir dir_type <<< "$pair"
            directories_list+=("$dir")
            directory_types_list+=("$dir_type")
        done 

        echo
        echo "--- Subject: $subject | Session: $session ---"
        echo "Cope file:"
        for dir_idx in "${!directories_list[@]}"; do
            dir="${directories_list[$dir_idx]}"
            dir_type="${directory_types_list[$dir_idx]}"

            if [ "$dir_type" == "lower" ]; then
                cope_file="$dir/stats/cope${cope_num}.nii.gz"
                if [ ! -f "$cope_file" ]; then
                    echo "  - Cope file not found: $cope_file"
                    echo "Error: Missing cope$cope_num for subject $subject in directory $dir."
                    exit 1
                else
                    echo "  - $cope_file"
                fi
            else
                cope_dir="$dir/cope${cope_num}.feat"
                cope_file="$cope_dir/stats/cope1.nii.gz"
                if [ -d "$cope_dir" ] && [ -f "$cope_file" ]; then
                    echo "  - $cope_file"
                else
                    echo "  - Cope directory or file not found: $cope_dir"
                    echo "Error: Missing cope$cope_num for subject $subject in directory $dir."
                    exit 1
                fi
            fi
        done
    done
    echo
done

########################################################
# Prompt for Mixed Effects Type
########################################################

echo -e "\n=== Mixed Effects ==="
echo "Please select a higher-level modelling approach:"
echo
echo "1) Simple OLS (Ordinary Least Squares) - Does not account for variance differences across subjects."
echo "2) Mixed Effects: FLAME 1 - Accounts for variance differences across subjects, recommended for most analyses."
echo "3) Mixed Effects: FLAME 1+2 - Includes additional refinement for variance estimates but may take longer."
echo -n "> "
read mixed_choice

valid_mixed=false
while [ "$valid_mixed" = false ]; do
    case "$mixed_choice" in
        1)
            echo "You selected Mixed Effects: Simple OLS"
            fmri_mixed="0"
            mixed_label="OLS"
            valid_mixed=true
            ;;
        2)
            echo "You selected Mixed Effects: FLAME 1"
            fmri_mixed="2"
            mixed_label="FLAME1"
            valid_mixed=true
            ;;
        3)
            echo "You selected Mixed Effects: FLAME 1+2"
            fmri_mixed="1"
            mixed_label="FLAME1plus2"
            valid_mixed=true
            ;;
        *)
            echo "Invalid input. Please enter 1, 2, or 3."
            echo -n "> "
            read mixed_choice
            ;;
    esac
done

########################################################
# Customize Output Folder
########################################################

echo -e "\n=== Customize Output Folder Name (Optional) ==="
echo "Enter a task name to include in the group analysis output folder."
echo "Press Enter/Return to skip the task name."

valid_task=false
task_name=""
while [ "$valid_task" = false ]; do
    echo -en "\nTask name (leave blank for no task):\n> "
    read task_name
    # Allowed chars: alphanumeric, underscores, dashes
    if [[ -z "$task_name" ]]; then
        valid_task=true
    else
        if [[ "$task_name" =~ ^[A-Za-z0-9_-]+$ ]]; then
            valid_task=true
        else
            echo "Invalid task name. Only alphanumeric, underscores, and dashes are allowed. No spaces."
        fi
    fi
done

echo
echo "Enter a descriptor (e.g., \"postICA\" for post-ICA analysis) to customize the group analysis output folder."
echo "Press Enter/Return to use the default format."

# **Dynamic** default format logic:
if [ -n "$task_name" ]; then
    # If there's a task name, show something like:
    #   /level-3/task-${task_name}_desc-group-${mixed_label}/cope*.gfeat
    echo "Default format: /level-3/task-${task_name}_desc-group-${mixed_label}/cope*.gfeat"
else
    # If no task name, show:
    #   /level-3/desc-group-${mixed_label}/cope*.gfeat
    echo "Default format: /level-3/desc-group-${mixed_label}/cope*.gfeat"
fi
echo

valid_desc=false
custom_desc=""
while [ "$valid_desc" = false ]; do
    echo -en "Descriptor (e.g., postICA or leave blank for default):\n> "
    read custom_desc
    if [[ -z "$custom_desc" ]]; then
        valid_desc=true
    else
        if [[ "$custom_desc" =~ ^[A-Za-z0-9_-]+$ ]]; then
            valid_desc=true
        else
            echo "Invalid descriptor. Only alphanumeric, underscores, and dashes are allowed. No spaces."
        fi
    fi
done

# Construct the output directory name
output_subdir=""
if [ -n "$task_name" ] && [ -n "$custom_desc" ]; then
    # e.g. task-myTask_desc-postICA_group-FLAME1
    output_subdir="task-${task_name}_desc-${custom_desc}_group-${mixed_label}"
elif [ -n "$task_name" ] && [ -z "$custom_desc" ]; then
    # e.g. task-myTask_desc-group-FLAME1
    output_subdir="task-${task_name}_desc-group-${mixed_label}"
elif [ -z "$task_name" ] && [ -n "$custom_desc" ]; then
    # e.g. desc-postICA_group-FLAME1
    output_subdir="desc-${custom_desc}_group-${mixed_label}"
else
    # e.g. desc-group-FLAME1
    output_subdir="desc-group-${mixed_label}"
fi

OUTPUT_DIR="$LEVEL_3_ANALYSIS_BASE_DIR/$output_subdir"

echo -e "\nOutput directory will be set to:"
echo "  - $OUTPUT_DIR"

mkdir -p "$OUTPUT_DIR"

########################################################
# FEAT Thresholding Options
########################################################

echo -e "\n=== FEAT Thresholding Options ==="
echo "You can specify the Z threshold and Cluster P threshold for the mixed effects analysis."
echo "Press Enter/Return to use default values (Z threshold: 2.3, Cluster P threshold: 0.05)."

default_z=2.3
default_p=0.05

#
# Prompt for Z threshold
#
valid_z=false
while [ "$valid_z" = false ]; do
    echo -e "\nEnter Z threshold (default $default_z):"
    echo -n "> "
    read z_threshold_input

    #
    # Keep asking again if user typed something invalid
    #
    while [ -n "$z_threshold_input" ] && ! [[ "$z_threshold_input" =~ ^[0-9]*\.?[0-9]+$ ]]; do
        # They typed something non-numeric (e.g., "oi", "kpikp"), so show an error and prompt again
        echo "Invalid input. Please enter a numeric value or press Enter/Return to use default value of $default_z."
        echo -n "> "
        read z_threshold_input
    done

    # If user simply pressed Enter, use the default
    if [ -z "$z_threshold_input" ]; then
        z_threshold=$default_z
        valid_z=true
        echo "Using Z threshold of $z_threshold"

    # Otherwise, user typed a valid float (the 'while' above ensures it’s numeric)
    else
        z_threshold="$z_threshold_input"
        valid_z=true
        echo "Using Z threshold of $z_threshold"
    fi
done

#
# Prompt for Cluster P threshold
#
valid_p=false
while [ "$valid_p" = false ]; do
    echo -e "\nEnter Cluster P threshold (default $default_p):"
    echo -n "> "
    read cluster_p_input

    # Re-prompt if user typed something invalid
    while [ -n "$cluster_p_input" ] && ! [[ "$cluster_p_input" =~ ^[0-9]*\.?[0-9]+$ ]]; do
        echo "Invalid input. Please enter a numeric value or press Enter/Return to use default value of $default_p."
        echo -n "> "
        read cluster_p_input
    done

    # If user pressed Enter, use the default
    if [ -z "$cluster_p_input" ]; then
        cluster_p_threshold=$default_p
        valid_p=true
        echo "Using Cluster P threshold of $cluster_p_threshold"
    else
        cluster_p_threshold="$cluster_p_input"
        valid_p=true
        echo "Using Cluster P threshold of $cluster_p_threshold"
    fi
done

########################################################
# Robust Outlier Detection in FLAME
########################################################

echo -e "\n=== Robust Outlier Detection in FLAME ==="
echo "FLAME provides an option for robust outlier detection, which can help reduce the influence of extreme data points in group-level analysis."
echo "Would you like to enable robust outlier detection? (y/n)"

valid_robust=false
while [ "$valid_robust" = false ]; do
    echo -n "> "
    read robust_choice
    robust_choice=$(echo "$robust_choice" | tr '[:upper:]' '[:lower:]')
    if [ -z "$robust_choice" ]; then
        # Default to no if blank
        robust_choice="n"
    fi
    if [ "$robust_choice" == "y" ]; then
        fmri_robust=1
        echo "Robust outlier detection will be ENABLED."
        valid_robust=true
    elif [ "$robust_choice" == "n" ]; then
        fmri_robust=0
        echo "Robust outlier detection will be DISABLED."
        valid_robust=true
    else
        echo "Invalid input. Please enter 'y' or 'n'."
    fi
done

########################################################
# Run FEAT for each cope
########################################################

TEMPLATE="$BASE_DIR/derivatives/templates/MNI152_T1_2mm_brain.nii.gz"

for cope_num in "${common_cope_numbers[@]}"; do

    echo -e "\n--- Processing cope $cope_num ---"

    design_template="$BASE_DIR/code/design_files/mixed-effects_design.fsf"
    temp_design_file="$OUTPUT_DIR/cope${cope_num}_design.fsf"

    if [ ! -f "$design_template" ]; then
        echo "Error: Design template file not found at $design_template"
        exit 1
    fi

    cope_output_dir="$OUTPUT_DIR/cope${cope_num}"

    if [ -d "${cope_output_dir}.gfeat" ]; then
        echo "Output directory already exists at:"
        echo "  - ${cope_output_dir}.gfeat"
        echo -e "\nSkipping..."
        continue
    fi

    input_lines=""
    group_membership=""
    ev_values=""
    num_inputs=0
    input_index=0

    for subject in "${sorted_subjects[@]}"; do
        for idx in "${!subjects[@]}"; do
            if [ "${subjects[$idx]}" == "$subject" ]; then
                directories_str="${directories[$idx]}"
                directory_types_str="${directory_types[$idx]}"
                break
            fi
        done

        IFS='::' read -a directories_list <<< "$directories_str"
        IFS='::' read -a directory_types_list <<< "$directory_types_str"

        sorted_pairs=($(paste -d ':' <(printf "%s\n" "${directories_list[@]}") <(printf "%s\n" "${directory_types_list[@]}") | sort))
        directories_list=()
        directory_types_list=()
        for pair in "${sorted_pairs[@]}"; do
            IFS=':' read -r dir dir_type <<< "$pair"
            directories_list+=("$dir")
            directory_types_list+=("$dir_type")
        done 

        for dir_idx in "${!directories_list[@]}"; do
            dir="${directories_list[$dir_idx]}"
            dir_type="${directory_types_list[$dir_idx]}"
            input_index=$((input_index + 1))
            num_inputs=$((num_inputs + 1))

            if [ "$dir_type" == "lower" ]; then
                cope_file="$dir/stats/cope${cope_num}.nii.gz"
            else
                cope_file="$dir/cope${cope_num}.feat/stats/cope1.nii.gz"
            fi

            cope_file_escaped=$(printf '%s\n' "$cope_file" | sed 's/["\\]/\\&/g')
            input_lines+="set feat_files($input_index) \"$cope_file_escaped\"\n"
            group_membership+="set fmri(groupmem.$input_index) 1\n"
            ev_values+="set fmri(evg$input_index.1) 1\n"
        done
    done

    export COPE_OUTPUT_DIR="$cope_output_dir"
    export Z_THRESHOLD="$z_threshold"
    export CLUSTER_P_THRESHOLD="$cluster_p_threshold"
    export STANDARD_IMAGE="$TEMPLATE"
    export NUM_INPUTS="$num_inputs"
    export MIXED_YN="$fmri_mixed"
    export ROBUST_YN="$fmri_robust"

    # Use envsubst to replace environmental variables in the template
    envsubst < "$design_template" > "$temp_design_file"

    # Append input lines
    {
        echo -e "$input_lines"
        echo -e "$ev_values"
        echo -e "$group_membership"
    } >> "$temp_design_file"

    echo -e "Running FEAT for cope $cope_num with temporary design file:"
    echo "  - $temp_design_file"
    feat "$temp_design_file"

    echo -e "\nRemoving temporary design file:"
    echo -e "  - $temp_design_file"
    rm -f "$temp_design_file"

    echo -e "\nCompleted FEAT for cope $cope_num."
done

echo -e "\n=== Third-level analysis completed ===\n."
