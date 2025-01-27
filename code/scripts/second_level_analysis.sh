#!/bin/bash

#
# second_level_analysis.sh
#
# PURPOSE:
#   This script performs second-level fixed effects analysis using FSL's FEAT tool.
#   It lets you interactively select first-level analysis directories, subjects, sessions,
#   and runs, then generates and runs the required design files for fixed effects.

# USAGE:
#   1) Run this script (e.g., ./second_level_analysis.sh).
#   2) Select a first-level analysis directory from the presented options.
#   3) Review and optionally filter which subject/session/run combinations are included.
#   4) Optionally specify a custom task name for output directories.
#   5) Specify (or accept default) thresholding values (Z and Cluster P).
#   6) Confirm to begin running second-level FEAT analyses.

# SELECTION SYNTAX & EXAMPLES:
#   Syntax:
#     subject[:session[:runs]]   (for INCLUSION)
#     -subject[:session[:runs]]  (for EXCLUSION)
#
#   Available patterns (generic examples):
#     1) 'sub-XX'                  => Include subject sub-XX (all sessions, all runs)
#     2) '-sub-XX'                 => Exclude subject sub-XX (all sessions, all runs)
#     3) 'sub-XX:ses-YY'           => Include subject sub-XX, session ses-YY (all runs)
#     4) '-sub-XX:ses-YY'          => Exclude subject sub-XX in session ses-YY (all runs)
#     5) 'sub-XX:ses-YY:01,02'     => Include runs 01 and 02 for subject sub-XX, session ses-YY
#     6) '-sub-XX:ses-YY:01,02'    => Exclude runs 01 and 02 for subject sub-XX, session ses-YY
#     7) 'ses-YY' / '-ses-YY'      => Include/Exclude session ses-YY for all subjects
#     8) 'sub-XX sub-ZZ'           => Multiple inclusions in one line
#     9) '-sub-XX sub-ZZ:ses-YY:02'=> Exclude sub-XX entirely, exclude only run 02 for
#                                     subject sub-ZZ in session ses-YY.

# OUTPUTS & INTERACTIONS:
#   - Creates second-level fixed effects .gfeat directories in derivatives/fsl/level-2.
#   - Interacts via prompts to include/exclude subjects, sessions, and runs.
#   - Generates a temporary design file (modified_fixed-effects_design.fsf) for each subject-session
#     and calls 'feat' to run the fixed-effects analysis.

# REQUIREMENTS:
#   - FSL (and FEAT) must be installed and available in your PATH.
#   - Bash (v3.2+ works, as it avoids associative arrays).
#   - The generate_fixed_effects_design_fsf.sh script must be in the expected location.
#   - The base design file (fixed-effects_design.fsf) must exist.

# NOTES:
#   - This script checks for presence of .feat directories and ensures consistent cope counts 
#     across runs to avoid errors in fixed-effects analysis.
#   - If you want to see extended instructions at any input step, type 'help'.
#   - Press Enter/Return at a prompt to accept defaults or skip optional steps.

###############################################################################
#                          INITIAL SETUP AND LOGGING
###############################################################################

# Determine the directory of this script and set BASE_DIR two levels up.
script_dir="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(dirname "$(dirname "$script_dir")")"

# Create a log directory (if not already existing) to store log files.
LOG_DIR="$BASE_DIR/code/logs"
mkdir -p "$LOG_DIR"

# Create a timestamped logfile for this specific run.
LOGFILE="$LOG_DIR/$(basename "$0" .sh)_$(date +'%Y%m%d_%H%M%S').log"

# Redirect stdout and stderr to both console and log file (tee).
exec > >(tee -a "$LOGFILE") 2>&1

# The base directory containing first-level analysis outputs.
ANALYSIS_BASE_DIR="$BASE_DIR/derivatives/fsl/level-1"

# The base design template for fixed effects to copy/modify per subject-session.
BASE_DESIGN_FSF="$BASE_DIR/code/design_files/fixed-effects_design.fsf"

# Path to a brain template for higher-level registration (should be standard MNI).
TEMPLATE="$BASE_DIR/derivatives/templates/MNI152_T1_2mm_brain.nii.gz"

# Verify the required files exist before proceeding.
if [ ! -f "$BASE_DESIGN_FSF" ]; then
    echo "Error: Base design file not found at $BASE_DESIGN_FSF"
    exit 1
fi

if [ ! -f "$TEMPLATE" ]; then
    echo "Error: Template not found at $TEMPLATE"
    exit 1
fi

###############################################################################
#                          HELPER FUNCTIONS
###############################################################################

# Adds an item to an array only if not already present.
# Usage: add_unique_item ARRAY_NAME ITEM
add_unique_item() {
    local arr_name=$1
    local item=$2
    eval "local arr=(\"\${$arr_name[@]}\")"

    for existing in "${arr[@]}"; do
        if [ "$existing" = "$item" ]; then
            return 0
        fi
    done
    eval "$arr_name+=(\"$item\")"
}

# Checks if the first argument is found among subsequent array items.
# Returns 0 if found, 1 otherwise.
array_contains() {
    local seeking=$1
    shift
    for elem in "$@"; do
        if [ "$elem" = "$seeking" ]; then
            return 0
        fi
    done
    return 1
}

###############################################################################
# 1) PROMPT USER FOR FIRST-LEVEL ANALYSIS DIRECTORY
###############################################################################

# Locate potential first-level analysis directories that end with *analysis*.
ANALYSIS_DIRS=($(find "$ANALYSIS_BASE_DIR" -maxdepth 1 -type d -name "*analysis*"))
if [ ${#ANALYSIS_DIRS[@]} -eq 0 ]; then
    echo "No analysis directories found in $ANALYSIS_BASE_DIR."
    exit 1
fi

# Sort the list of analysis directories for a consistent user prompt order.
ANALYSIS_DIRS=($(printf "%s\n" "${ANALYSIS_DIRS[@]}" | sort))

echo -e "\n=== First-Level Analysis Directory Selection ==="
echo "Please select a first-level analysis directory for second-level fixed effects processing from the options below:"
echo
i=1
for dir in "${ANALYSIS_DIRS[@]}"; do
    echo "$i) $dir"
    ((i++))
done
echo

# Prompt user to select one of these directories by index.
valid_choice=false
while [ "$valid_choice" = false ]; do
    echo -n "Please enter your choice: "
    read choice

    if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
        echo "Invalid selection. Please try again."
        continue
    fi

    if [ "$choice" -lt 1 ] || [ "$choice" -gt ${#ANALYSIS_DIRS[@]} ]; then
        echo "Invalid selection. Please try again."
        continue
    fi

    ANALYSIS_DIR="${ANALYSIS_DIRS[$((choice-1))]}"
    valid_choice=true
done

echo
echo "You have selected the following analysis directory for fixed effects:"
echo "$ANALYSIS_DIR"
echo

# This is where the second-level outputs will be stored (replicating the structure).
LEVEL_2_ANALYSIS_DIR="${BASE_DIR}/derivatives/fsl/level-2/$(basename "$ANALYSIS_DIR")"

# BASE_PATH is used to truncate paths when printing.
BASE_PATH="$ANALYSIS_DIR"

###############################################################################
#                      FIND SUBJECT & SESSION DIRECTORIES
###############################################################################

# Look for possible subject directories by name patterns (sub-*, subj-*, etc.).
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

# Locate potential subject directories immediately inside the chosen analysis directory.
subject_dirs=($(find "$ANALYSIS_DIR" -mindepth 1 -maxdepth 1 -type d \( "${FIND_SUBJECT_EXPR[@]}" \)))
subject_dirs=($(printf "%s\n" "${subject_dirs[@]}" | sort))
if [ ${#subject_dirs[@]} -eq 0 ]; then
    echo "No subject directories found in $ANALYSIS_DIR."
    exit 1
fi

# Global arrays to keep track of all discovered subjects, sessions, and valid .feat directories.
ALL_SUBJECTS=()
ALL_SESSIONS=()
SUBJECT_SESSION_LIST=()

subject_session_keys=()
subject_session_cope_counts=()
all_valid_feat_dirs=()
available_subject_sessions=()

###############################################################################
#                    COUNT COPE FILES
###############################################################################
# This function returns the number of cope*.nii.gz files found in the stats folder
# of a given FEAT directory. Ensure consistent cope counts.
count_cope_files() {
    local feat_dir="$1"
    local stats_dir="$feat_dir/stats"
    local cope_count=0

    if [ -d "$stats_dir" ]; then
        cope_count=$(find "$stats_dir" -mindepth 1 -maxdepth 1 -type f -name "cope*.nii.gz" | wc -l | xargs)
    else
        echo "$feat_dir (Stats directory not found)"
    fi
    echo "$cope_count"
}

###############################################################################
#                CHECK COMMON COPE COUNT
###############################################################################
# Given a list of feat_dirs, determine if they share a common cope count (e.g., 3).
# If there's a mismatch (like some runs have 3 copes, others 4), exclude
# those that don't match the most frequent cope count. If there's still a tie, the
# entire subject-session is excluded from second-level analysis.
check_common_cope_count() {
    local feat_dirs=("$@")
    local cope_counts=()
    local valid_feat_dirs=()
    local warning_messages=""
    local total_runs=${#feat_dirs[@]}

    # Collect cope counts from each feat directory
    for feat_dir in "${feat_dirs[@]}"; do
        local c
        c=$(count_cope_files "$feat_dir")
        cope_counts+=("$c")
    done

    unique_cope_counts=()
    cope_counts_freq=()

    # Count frequency of each distinct cope count
    for c in "${cope_counts[@]}"; do
        local found=false
        for ((i=0; i<${#unique_cope_counts[@]}; i++)); do
            if [ "${unique_cope_counts[i]}" -eq "$c" ]; then
                cope_counts_freq[i]=$(( cope_counts_freq[i] + 1 ))
                found=true
                break
            fi
        done
        if [ "$found" = false ]; then
            unique_cope_counts+=("$c")
            cope_counts_freq+=(1)
        fi
    done

    # Identify the cope count with highest frequency
    local max_freq=0
    local common_cope_counts=()
    for ((i=0; i<${#unique_cope_counts[@]}; i++)); do
        local freq=${cope_counts_freq[i]}
        if [ "$freq" -gt "$max_freq" ]; then
            max_freq=$freq
            common_cope_counts=("${unique_cope_counts[i]}")
        elif [ "$freq" -eq "$max_freq" ]; then
            # Ties
            common_cope_counts+=("${unique_cope_counts[i]}")
        fi
    done

    # If there's more than one cope count tied for max frequency, exclude everything (tie).
    if [ ${#common_cope_counts[@]} -gt 1 ]; then
        warning_messages="  - Unequal cope counts found across runs (${unique_cope_counts[*]})."
        echo "UNEQUAL_COPES_TIE"
        echo -e "$warning_messages"
        return
    fi

    # If there's a single most common cope count, keep directories that match it, exclude others.
    local common_cope_count="${common_cope_counts[0]}"

    if [ "$max_freq" -gt $((total_runs / 2)) ]; then
        for idx in "${!feat_dirs[@]}"; do
            if [ "${cope_counts[$idx]}" -eq "$common_cope_count" ]; then
                valid_feat_dirs+=("${feat_dirs[$idx]}")
            else
                if [ -n "$warning_messages" ]; then
                    warning_messages="${warning_messages}\n  - $(basename "${feat_dirs[$idx]}") does not have the common cope count $common_cope_count and will be excluded."
                else
                    warning_messages="  - $(basename "${feat_dirs[$idx]}") does not have the common cope count $common_cope_count and will be excluded."
                fi
            fi
        done

        echo "$common_cope_count"
        for dir in "${valid_feat_dirs[@]}"; do
            echo "$dir"
        done

        if [ -n "$warning_messages" ]; then
            echo "WARNINGS_START"
            echo -e "$warning_messages"
        fi
    else
        warning_messages="  - Unequal cope counts found across runs (${unique_cope_counts[*]}). Excluding this subject-session."
        echo "UNEQUAL_COPES"
        echo -e "$warning_messages"
    fi
}

###############################################################################
#       CAPTURE FIRST-LEVEL FEAT DIRECTORY LISTING IN A VARIABLE
###############################################################################

LISTING_OUTPUT=""

LISTING_OUTPUT+="=== Listing First-Level Feat Directories ===\n"
LISTING_OUTPUT+="The following feat directories will be used as inputs for the second-level fixed effects analysis:\n\n"

# Patterns that define potential session directories (e.g., ses-01, session-01, etc.).
SESSION_NAME_PATTERNS=("ses-*" "session-*" "ses_*" "session_*" "ses*" "session*" "baseline" "endpoint" "ses-001" "ses-002")

# Loop over each subject directory to find session directories, then .feat directories within func/.
for subject_dir in "${subject_dirs[@]}"; do
    subject=$(basename "$subject_dir")
    add_unique_item ALL_SUBJECTS "$subject"

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

    session_dirs=($(find "$subject_dir" -mindepth 1 -maxdepth 1 -type d \( "${FIND_SESSION_EXPR[@]}" \) | sort))

    for session_dir in "${session_dirs[@]}"; do
        session=$(basename "$session_dir")
        add_unique_item ALL_SESSIONS "$session"
        add_unique_item SUBJECT_SESSION_LIST "${subject}|${session}"

        key="$subject:$session"
        available_subject_sessions+=("$key")

        feat_dirs=()
        if [ -d "$session_dir/func" ]; then
            feat_dirs=($(find "$session_dir/func" -mindepth 1 -maxdepth 1 -type d -name "*.feat" | sort))
        fi

        LISTING_OUTPUT+="--- Subject: $subject | Session: $session ---\n\n"

        if [ ${#feat_dirs[@]} -eq 0 ]; then
            LISTING_OUTPUT+="No feat directories found.\n\n"
            continue
        fi

        # Check cope counts to ensure consistency.
        check_result=()
        while IFS= read -r line; do
            check_result+=("$line")
        done < <(check_common_cope_count "${feat_dirs[@]}")

        common_cope_count=""
        valid_feat_dirs=()
        warnings=()
        parsing_warnings=false
        unequal_copes=false
        unequal_copes_tie=false

        # Process the output of check_common_cope_count, capturing warnings.
        for line in "${check_result[@]}"; do
            if [ "$parsing_warnings" = false ]; then
                case "$line" in
                    "UNEQUAL_COPES")
                        unequal_copes=true
                        parsing_warnings=true
                        ;;
                    "UNEQUAL_COPES_TIE")
                        unequal_copes_tie=true
                        parsing_warnings=true
                        ;;
                    "WARNINGS_START")
                        parsing_warnings=true
                        ;;
                    *)
                        # Set cope count if not set.
                        # Otherwise, treat the line as a valid feat dir.
                        if [ -z "$common_cope_count" ]; then
                            common_cope_count="$line"
                        else
                            valid_feat_dirs+=("$line")
                        fi
                        ;;
                esac
            else
                warnings+=("$line")
            fi
        done

        if [ "$unequal_copes" = true ] || [ "$unequal_copes_tie" = true ]; then
            LISTING_OUTPUT+="Warnings:\n"
            for warning in "${warnings[@]}"; do
                LISTING_OUTPUT+="  [Warning] $warning\n"
            done
            if [ "$unequal_copes_tie" = true ]; then
                LISTING_OUTPUT+="\nExcluding subject-session $subject:$session due to tie in cope counts.\n\n"
            else
                LISTING_OUTPUT+="\nExcluding subject-session $subject:$session due to insufficient runs with the same cope count.\n\n"
            fi
            continue
        fi

        if [ ${#valid_feat_dirs[@]} -gt 0 ]; then
            LISTING_OUTPUT+="Valid Feat Directories:\n"
            for feat_dir in "${valid_feat_dirs[@]}"; do
                # Trim the base path so it's easier to read for the user.
                trimmed="${feat_dir#$BASE_PATH/}"
                LISTING_OUTPUT+="  • $trimmed\n"
            done

            # Keep track of this subject-session if it passed the cope count check.
            subject_session_keys+=("$key")
            subject_session_cope_counts+=("$common_cope_count")
            all_valid_feat_dirs+=("${valid_feat_dirs[@]}")

            if [ ${#warnings[@]} -gt 0 ]; then
                LISTING_OUTPUT+="\nWarnings:\n"
                for w in "${warnings[@]}"; do
                    LISTING_OUTPUT+="  [Warning] $w\n"
                done
            fi
            LISTING_OUTPUT+="\n"
        else
            LISTING_OUTPUT+="  - No valid feat directories after cope count check.\n\n"
        fi
    done
done

# Sort the final list of valid feat directories for a consistent order.
all_valid_feat_dirs=($(printf "%s\n" "${all_valid_feat_dirs[@]}" | sort))

###############################################################################
#                      SIMPLE MEMBERSHIP CHECKS
###############################################################################

# Check if a given subject name is in the master list of subjects discovered.
is_valid_subject() {
    local subj="$1"
    array_contains "$subj" "${ALL_SUBJECTS[@]}"
    return $?
}

# Check if a given session name is in the master list of sessions discovered.
is_valid_session() {
    local sess="$1"
    array_contains "$sess" "${ALL_SESSIONS[@]}"
    return $?
}

# Check if the subject-session combination is recognized.
is_valid_subject_session() {
    local subj="$1"
    local sess="$2"
    local pair="${subj}|${sess}"
    array_contains "$pair" "${SUBJECT_SESSION_LIST[@]}"
    return $?
}

###############################################################################
#             CHECK IF A SPECIFIC RUN EXISTS
###############################################################################
# Check if "run-XX.feat" exists under the subject/session path in our list of
# valid feat directories. The leading zeros in run numbers are handled to match naming.
is_valid_run() {
    local subj="$1"
    local sess="$2"
    local run_input="$3"
    local run_stripped="${run_input#0}"
    local rgx=".*$subj/$sess/func/.*run-0*$run_stripped\.feat$"

    for fdir in "${all_valid_feat_dirs[@]}"; do
        if [[ "$fdir" =~ $rgx ]]; then
            return 0
        fi
    done

    return 1
}

###############################################################################
# 2) PRINT THE LISTING, THEN PROMPT FOR SELECTION
###############################################################################
echo -e "$LISTING_OUTPUT"

# Tracks whether to show short instructions or extended instructions in the prompt.
PROMPT_MODE="short"

show_selection_prompt() {
    if [ "$PROMPT_MODE" = "extended" ]; then
        clear
        echo -e "$LISTING_OUTPUT"
        echo "=== Subject, Session, and Run Selection ==="
        echo "Specify patterns like:"
        echo "  subject[:session[:runs]] for inclusion   (e.g.,  sub-01, or sub-01:ses-02:01,02)"
        echo "  -subject[:session[:runs]] for exclusion  (e.g., -sub-01, or -sub-01:ses-02:01,02)"
        echo
        echo "Multiple entries can be on one line. Enter 'help' for these instructions again."
        echo "If you press Enter/Return with no input, all valid directories are used."
    else
        echo "=== Subject, Session, and Run Selection ==="
        echo "Enter your selections to include or exclude subjects, sessions, or runs."
        echo "Use 'subject[:session[:runs]]' for inclusion, '-subject[:session[:runs]]' for exclusion."
        echo "Enter 'help' for more info, or press Enter/Return for all."
    fi

    echo -n "> "
}

show_selection_prompt

# Store the user's inclusion/exclusion rules in these arrays.
inclusion_map_keys=()
inclusion_map_values=()
exclusion_map_keys=()
exclusion_map_values=()

# Continuously read user input until they press Enter with no input or valid input is acquired.
while true; do
    read selection_input

    # If user just presses Enter, no filtering => use all valid directories.
    if [ -z "$selection_input" ]; then
        break
    fi

    # If user types 'help', switch to extended instructions.
    if [ "$selection_input" = "help" ]; then
        PROMPT_MODE="extended"
        show_selection_prompt
        continue
    fi

    # Split the line on spaces to handle multiple entries.
    IFS=' ' read -ra entries <<< "$selection_input"
    invalid_selections=()
    temp_incl_keys=()
    temp_incl_vals=()
    temp_excl_keys=()
    temp_excl_vals=()

    for selection in "${entries[@]}"; do
        exclude=false
        # If the selection starts with '-', treat it as an exclusion.
        if [[ "$selection" == -* ]]; then
            exclude=true
            selection="${selection#-}"
        fi

        # Parse the selection by splitting on ':'
        IFS=':' read -ra parts <<< "$selection"
        sel_subj=""
        sel_sess=""
        sel_runs=""

        case ${#parts[@]} in
            1)
                # Could be just a subject or a session.
                if is_valid_subject "${parts[0]}"; then
                    sel_subj="${parts[0]}"
                elif is_valid_session "${parts[0]}"; then
                    sel_sess="${parts[0]}"
                else
                    invalid_selections+=("${parts[0]}")
                    continue
                fi
                ;;
            2)
                # Either subject + session, or session + runs
                if is_valid_subject "${parts[0]}"; then
                    sel_subj="${parts[0]}"
                    sel_sess="${parts[1]}"
                    if ! is_valid_subject_session "$sel_subj" "$sel_sess"; then
                        invalid_selections+=("${parts[0]}:${parts[1]}")
                        continue
                    fi
                elif is_valid_session "${parts[0]}"; then
                    sel_sess="${parts[0]}"
                    sel_runs="${parts[1]}"
                else
                    invalid_selections+=("${parts[0]}:${parts[1]}")
                    continue
                fi
                ;;
            3)
                # Subject + session + runs
                sel_subj="${parts[0]}"
                sel_sess="${parts[1]}"
                sel_runs="${parts[2]}"
                if ! is_valid_subject_session "$sel_subj" "$sel_sess"; then
                    invalid_selections+=("${parts[0]}:${parts[1]}")
                    continue
                fi
                ;;
            *)
                invalid_selections+=("$selection")
                continue
                ;;
        esac

        # If runs are specified, ensure they exist in our valid directory list for that sub/ses.
        if [ -n "$sel_runs" ]; then
            IFS=',' read -ra runs_list <<< "$sel_runs"
            for run_val in "${runs_list[@]}"; do
                if [ -n "$sel_subj" ] && [ -n "$sel_sess" ]; then
                    if ! is_valid_run "$sel_subj" "$sel_sess" "$run_val"; then
                        invalid_selections+=("$run_val")
                    fi
                fi
            done
        fi

        # Store inclusion or exclusion rule
        if $exclude; then
            temp_excl_keys+=("${sel_subj}:${sel_sess}")
            temp_excl_vals+=("$sel_runs")
        else
            temp_incl_keys+=("${sel_subj}:${sel_sess}")
            temp_incl_vals+=("$sel_runs")
        fi
    done

    # If any parts of the user selection are invalid, prompt again.
    if [ ${#invalid_selections[@]} -gt 0 ]; then
        joined_invalid=$(printf ", %s" "${invalid_selections[@]}")
        joined_invalid="${joined_invalid:2}"
        echo "The following selections are invalid: $joined_invalid. Please try again."
        echo -n "> "
    else
        # Commit the newly parsed rules to the main inclusion/exclusion arrays.
        inclusion_map_keys=("${temp_incl_keys[@]}")
        inclusion_map_values=("${temp_incl_vals[@]}")
        exclusion_map_keys=("${temp_excl_keys[@]}")
        exclusion_map_values=("${temp_excl_vals[@]}")
        break
    fi
done

###############################################################################
# 3) PROMPT FOR OPTIONAL TASK NAME
###############################################################################
echo
echo "=== Customize Output Filename (Optional) ==="
echo "Enter a task name to include in the output directories (e.g., 'taskname')."
echo "If left blank, output will use the default: 'desc-fixed-effects.gfeat'."
echo

valid_task=false
task_name=""

echo "Enter task name (or press Enter/Return for default):"
while [ "$valid_task" = false ]; do
    echo -n "> "
    read user_input

    if [ -z "$user_input" ]; then
        task_name=""
        valid_task=true
        break
    fi

    # Accept only alphanumeric, underscores, or dashes
    if [[ "$user_input" =~ ^[A-Za-z0-9_-]+$ ]]; then
        task_name="$user_input"
        valid_task=true
    else
        echo "Invalid task name. Use letters, numbers, underscores, or dashes. No spaces."
    fi
done

###############################################################################
# 4) PROMPT FOR Z THRESHOLD AND CLUSTER P THRESHOLD
###############################################################################
echo -e "\n=== FEAT Thresholding Options ==="
echo "Specify Z threshold and Cluster P threshold, or press Enter/Return to use defaults (2.3, 0.05)."

default_z=2.3
default_p=0.05

z_threshold=""
cluster_p_threshold=""

# Prompt for Z threshold
valid_z=false
while [ "$valid_z" = false ]; do
    echo -e "\nEnter Z threshold (default $default_z):"
    echo -n "> "
    read z_threshold_input

    # Validate numeric input (including decimals)
    while [ -n "$z_threshold_input" ] && ! [[ "$z_threshold_input" =~ ^[0-9]*\.?[0-9]+$ ]]; do
        echo "Invalid numeric value. Try again."
        echo -n "> "
        read z_threshold_input
    done

    if [ -z "$z_threshold_input" ]; then
        z_threshold=$default_z
        valid_z=true
        echo "Using Z threshold of $z_threshold"
    else
        z_threshold="$z_threshold_input"
        valid_z=true
        echo "Using Z threshold of $z_threshold"
    fi
done

# Prompt for Cluster P threshold
valid_p=false
while [ "$valid_p" = false ]; do
    echo -e "\nEnter Cluster P threshold (default $default_p):"
    echo -n "> "
    read cluster_p_threshold_input

    while [ -n "$cluster_p_threshold_input" ] && ! [[ "$cluster_p_threshold_input" =~ ^[0-9]*\.?[0-9]+$ ]]; do
        echo "Invalid numeric value. Try again."
        echo -n "> "
        read cluster_p_threshold_input
    done

    if [ -z "$cluster_p_threshold_input" ]; then
        cluster_p_threshold=$default_p
        valid_p=true
        echo "Using Cluster P threshold of $cluster_p_threshold"
    else
        cluster_p_threshold="$cluster_p_threshold_input"
        valid_p=true
        echo "Using Cluster P threshold of $cluster_p_threshold"
    fi
done

###############################################################################
#         CHECK IF SUBJECT-SESSION SHOULD BE INCLUDED
###############################################################################
# Return 1 (exclude) if user typed a broad exclusion (e.g., -sub-01 or -sub-01:ses-02),
# or if the user has inclusion rules that do not match this subject-session.
# Return 0 (include) otherwise.
should_include_subject_session() {
    local subject="$1"
    local session="$2"

    # Check if there's an exclusion rule for this subject or session with no runs specified.
    for idx in "${!exclusion_map_keys[@]}"; do
        local excl_key="${exclusion_map_keys[$idx]}"
        local excl_runs="${exclusion_map_values[$idx]}"

        IFS=':' read -ra eparts <<< "$excl_key"
        local excl_subj="${eparts[0]}"
        local excl_sess="${eparts[1]}"

        if [ -n "$excl_subj" ] && [ "$excl_subj" != "$subject" ]; then
            continue
        fi
        if [ -n "$excl_sess" ] && [ "$excl_sess" != "$session" ]; then
            continue
        fi

        # If runs are specified, only exclude those runs, not the entire session.
        if [ -n "$excl_runs" ]; then
            return 0  # Means "don't exclude the entire session"
        fi
        return 1      # Exclude entire subject-session
    done

    # If user gave inclusion rules but this sub-ses doesn't appear among them, exclude it.
    if [ ${#inclusion_map_keys[@]} -gt 0 ]; then
        local found_inclusion=false
        for idx in "${!inclusion_map_keys[@]}"; do
            local incl_key="${inclusion_map_keys[$idx]}"

            IFS=':' read -ra iparts <<< "$incl_key"
            local incl_subj="${iparts[0]}"
            local incl_sess="${iparts[1]}"

            if [ -n "$incl_subj" ] && [ "$incl_subj" != "$subject" ]; then
                continue
            fi
            if [ -n "$incl_sess" ] && [ "$incl_sess" != "$session" ]; then
                continue
            fi

            found_inclusion=true
            break
        done

        if ! $found_inclusion; then
            return 1
        fi
    fi

    return 0
}

###############################################################################
#      DEFINE PATH TO generate_fixed_effects_design_fsf.sh & CHECK IT
###############################################################################
GENERATE_DESIGN_SCRIPT="$BASE_DIR/code/scripts/generate_fixed_effects_design_fsf.sh"
if [ ! -f "$GENERATE_DESIGN_SCRIPT" ]; then
    echo "Error: generate_fixed_effects_design_fsf.sh script not found at $GENERATE_DESIGN_SCRIPT"
    exit 1
fi

###############################################################################
#   CONFIRM SELECTIONS, GENERATE DESIGN FILES, PREPARE FOR FIXED-EFFECTS
###############################################################################
echo
echo "=== Confirm Your Selections for Fixed Effects Analysis ==="

generated_design_files=()

# Loop through each subject-session to see if it should be included, 
# gather their .feat directories, and generate the design files if needed.
for subject_dir in "${subject_dirs[@]}"; do
    subject=$(basename "$subject_dir")

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

    session_dirs=($(find "$subject_dir" -mindepth 1 -maxdepth 1 -type d \( "${FIND_SESSION_EXPR[@]}" \) | sort))

    for session_dir in "${session_dirs[@]}"; do
        session=$(basename "$session_dir")

        # If the user included/excluded this subject-session, decide if to skip it.
        if ! should_include_subject_session "$subject" "$session"; then
            echo
            echo "Subject: $subject | Session: $session"
            echo "----------------------------------------"
            echo "  - Excluded based on your selections."
            continue
        fi

        sel_key="$subject:$session"
        specific_runs=""
        # Check if there's a subject-session inclusion for specific runs
        for idx in "${!inclusion_map_keys[@]}"; do
            if [ "${inclusion_map_keys[$idx]}" = "$sel_key" ]; then
                specific_runs="${inclusion_map_values[$idx]}"
                break
            fi
        done

        exclude_runs=""
        # Check if there's a subject-session exclusion for specific runs
        for idx in "${!exclusion_map_keys[@]}"; do
            if [ "${exclusion_map_keys[$idx]}" = "$sel_key" ]; then
                exclude_runs="${exclusion_map_values[$idx]}"
                break
            fi
        done

        echo
        echo "Subject: $subject | Session: $session"
        echo "----------------------------------------"

        # Gather valid .feat directories for this subject-session from our earlier checks.
        feat_dirs=()
        for d in "${all_valid_feat_dirs[@]}"; do
            if [[ "$d" == *"/$subject/$session/"* ]]; then
                feat_dirs+=("$d")
            fi
        done

        # If the user explicitly included runs (e.g., sub-01:ses-02:01,02), keep only those.
        if [ -n "$specific_runs" ]; then
            selected_feat_dirs=()
            IFS=',' read -ra sruns <<< "$specific_runs"
            for r in "${sruns[@]}"; do
                r="${r//run-/}"  # remove "run-" if present
                r_no0=$(echo "$r" | sed 's/^0*//')  # remove leading zeros
                rgx=".*run-0*${r_no0}\.feat$"
                for fdir in "${feat_dirs[@]}"; do
                    [[ "$fdir" =~ $rgx ]] && selected_feat_dirs+=("$fdir")
                done
            done
            feat_dirs=("${selected_feat_dirs[@]}")
        fi

        # If the user excluded runs (e.g., -sub-01:ses-02:01), remove those from feat_dirs.
        if [ -n "$exclude_runs" ]; then
            IFS=',' read -ra eruns <<< "$exclude_runs"
            for r in "${eruns[@]}"; do
                r="${r//run-/}"
                r_no0=$(echo "$r" | sed 's/^0*//')
                rgx=".*run-0*${r_no0}\.feat$"
                for i2 in "${!feat_dirs[@]}"; do
                    if [[ "${feat_dirs[$i2]}" =~ $rgx ]]; then
                        unset 'feat_dirs[$i2]'
                    fi
                done
            done
            feat_dirs=("${feat_dirs[@]}")
        fi

        feat_dirs=($(printf "%s\n" "${feat_dirs[@]}" | sort))
        if [ ${#feat_dirs[@]} -eq 0 ]; then
            echo "  - No matching directories found."
            continue
        elif [ ${#feat_dirs[@]} -lt 2 ]; then
            echo "  - Not enough runs for fixed effects analysis (need >= 2). Skipping."
            continue
        fi

        echo "Selected Feat Directories:"
        for f in "${feat_dirs[@]}"; do
            # Print a short version of the path
            echo "  • ${f#$BASE_PATH/}"
        done

        # Identify how many copes each run has from earlier computations.
        subject_session_key="${subject}:${session}"
        common_cope_count=""
        array_length=${#subject_session_keys[@]}
        idx=0
        while [ $idx -lt $array_length ]; do
            if [ "${subject_session_keys[$idx]}" = "$subject_session_key" ]; then
                common_cope_count="${subject_session_cope_counts[$idx]}"
                break
            fi
            idx=$((idx+1))
        done

        if [ -z "$common_cope_count" ]; then
            echo "Common cope count for $subject_session_key not found. Skipping."
            continue
        fi

        # Build the output directory name, optionally including the custom task_name.
        if [ -n "$task_name" ]; then
            output_filename="${subject}_${session}_task-${task_name}_desc-fixed-effects"
        else
            output_filename="${subject}_${session}_desc-fixed-effects"
        fi

        output_path="$LEVEL_2_ANALYSIS_DIR/$subject/$session/$output_filename"

        echo
        echo "Output Directory:"
        echo "- ${output_path}.gfeat"

        # If the .gfeat directory already exists, skip (so does not overwrite).
        if [ -d "${output_path}.gfeat" ]; then
            echo
            echo "[Notice] Output directory already exists. Skipping fixed effects for this subject-session."
            continue
        fi

        # Call our companion script to generate the design .fsf file for this subject-session.
        "$GENERATE_DESIGN_SCRIPT" "$output_path" "$common_cope_count" "$z_threshold" "$cluster_p_threshold" "${feat_dirs[@]}"
        echo
        echo "Generated FEAT fixed-effects design file at:"
        echo "- ${output_path}/modified_fixed-effects_design.fsf"

        # Record the path to the newly generated design file to run 'feat' on it below.
        generated_design_files+=("$output_path/modified_fixed-effects_design.fsf")
    done
done

# If ended up not generating any design files, there's nothing to run.
if [ ${#generated_design_files[@]} -eq 0 ]; then
    echo
    echo "=== No new analyses to run. All specified outputs already exist or were excluded. ==="
    echo
    exit 0
fi

echo
echo "Press Enter/Return to confirm and proceed with second-level fixed effects analysis, or Ctrl+C to cancel and restart."

###############################################################################
#                        CLEANUP TRAP ON CTRL+C
###############################################################################
# If the user presses Ctrl+C while the script is waiting or while FEAT runs,
# remove any design directories were created before exiting to keep the filesystem clean.
trap_ctrl_c() {
    echo
    echo "Process interrupted by user. Removing generated design files..."

    # Collect directories to remove
    dirs_to_remove=()
    for design_file in "${generated_design_files[@]}"; do
        design_dir="$(dirname "$design_file")"
        if [ -d "$design_dir" ]; then
            dirs_to_remove+=("$design_dir")
        fi
    done

    # Remove them all
    for d in "${dirs_to_remove[@]}"; do
        rm -r "$d"
    done

    # Print a single grouped list
    if [ ${#dirs_to_remove[@]} -gt 0 ]; then
        echo
        echo "Removed the following temporary design directories:"
        for d in "${dirs_to_remove[@]}"; do
            echo "- ${d#$BASE_PATH/}"
        done
    fi

    exit 1
}
trap 'trap_ctrl_c' SIGINT

read -r
trap - SIGINT

###############################################################################
#                        RUN FEAT ON THE DESIGN FILES
###############################################################################
echo
echo "=== Running Fixed Effects ==="

# Loop through each generated design file and run FEAT, then clean up the design directory.
for design_file in "${generated_design_files[@]}"; do
    echo
    echo "--- Processing Design File ---"
    echo
    echo "File Path:"
    echo "- ${design_file#$BASE_PATH/}"

    feat "$design_file"
    echo
    echo "Finished running fixed effects with:"
    echo "- ${design_file#$BASE_PATH/}"

    # Remove the temporary design directory after FEAT completes.
    design_dir="$(dirname "$design_file")"
    rm -r "$design_dir"
    echo
    echo "Removed temporary design directory:"
    echo "- ${design_dir#$BASE_PATH/}"
done

echo
echo "=== All processing is complete. Please check the output directories for results. ==="
echo
