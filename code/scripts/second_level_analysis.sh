#!/bin/bash
#
###############################################################################
# second_level_analysis.sh
#
# Purpose:
#   This script performs second-level fixed effects analysis using FSL's FEAT tool.
#   Allows for interactively selecting first-level analysis directories, subjects, sessions,
#   and runs, then generates and runs the required design files for fixed effects.
#
#   After running FEAT for all subject-sessions, it optionally creates a single
#   dataset_description.json at the top-level second-level directory using
#   create_dataset_description.sh, with the "Name" = "FSL_FEAT_with_Fixed_Effects".
#
# Usage:
#   1) Run this script (e.g., ./second_level_analysis.sh).
#   2) Select a first-level analysis directory from the presented options.
#   3) Review and optionally filter which subject/session/run combinations are included.
#   4) Optionally specify a custom task name for output directories.
#   5) Specify (or accept default) thresholding values (Z and Cluster P).
#   6) Confirm to begin running second-level FEAT analyses.
#
# Usage Examples:
#   Syntax:
#     subject[:session[:runs]]   (for INCLUSION)
#     -subject[:session[:runs]]  (for EXCLUSION)
#
#   Patterns (generic examples):
#     1) 'sub-XX'                  => Include subject sub-XX (all sessions, all runs)
#     2) '-sub-XX'                 => Exclude subject sub-XX (all sessions, all runs)
#     3) 'sub-XX:ses-YY'           => Include subject sub-XX, session ses-YY (all runs)
#     4) '-sub-XX:ses-YY'          => Exclude subject sub-XX in session ses-YY (all runs)
#     5) 'sub-XX:ses-YY:01,02'     => Include runs 01,02 for subject sub-XX, session ses-YY
#     6) '-sub-XX:ses-YY:01,02'    => Exclude runs 01,02 for subject sub-XX, session ses-YY
#     ... etc.
#
# Requirements:
#   - FSL (and FEAT) must be installed and available in your PATH.
#   - Bash (v3.2+).
#   - The generate_fixed_effects_design_fsf.sh script must be in the expected location.
#   - The base design file (fixed-effects_design.fsf) must exist.
#   - create_dataset_description.sh must be somewhere in $SCRIPT_DIR or called path.
#
# Notes:
#   - Creates second-level fixed effects .gfeat directories in derivatives/fsl/level-2.
#   - Interacts via prompts to include/exclude subjects, sessions, and runs.
#   - Generates a temporary design file (modified_fixed-effects_design.fsf) for each subject-session
#     and calls 'feat' to run the fixed-effects analysis.
#   - This script checks for presence of .feat directories and ensures consistent cope counts
#     across runs to avoid errors in fixed-effects analysis.
#   - Then, calls create_dataset_description.sh to create a top-level dataset_description.json
#     (Name="FSL_FEAT_with_Fixed_Effects") for your second-level results.
#
###############################################################################

###############################################################################
#                          INITIAL SETUP AND LOGGING
###############################################################################

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
# 1) PROMPT FOR FIRST-LEVEL ANALYSIS DIRECTORY
###############################################################################

ANALYSIS_DIRS=($(find "$ANALYSIS_BASE_DIR" -maxdepth 1 -type d -name "*analysis*"))
if [ ${#ANALYSIS_DIRS[@]} -eq 0 ]; then
    echo "No analysis directories found in $ANALYSIS_BASE_DIR."
    exit 1
fi

ANALYSIS_DIRS=($(printf "%s\n" "${ANALYSIS_DIRS[@]}" | sort))

echo -e "\n=== First-Level Analysis Directory Selection ==="
echo "Please select a first-level analysis directory for second-level fixed effects processing:"
echo
i=1
for dir in "${ANALYSIS_DIRS[@]}"; do
    echo "$i) $dir"
    ((i++))
done
echo

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

# This is where the second-level outputs will be stored (replicating structure).
LEVEL_2_ANALYSIS_DIR="${BASE_DIR}/derivatives/fsl/level-2/$(basename "$ANALYSIS_DIR")"
BASE_PATH="$ANALYSIS_DIR"

###############################################################################
#                      FIND SUBJECT & SESSION DIRECTORIES
###############################################################################
# Below to add "sub-*" explicitly to patterns for typical BIDS labels.

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
    echo "No subject directories found in $ANALYSIS_DIR."
    exit 1
fi

ALL_SUBJECTS=()
ALL_SESSIONS=()
SUBJECT_SESSION_LIST=()

subject_session_keys=()
subject_session_cope_counts=()
all_valid_feat_dirs=()
available_subject_sessions=()

###############################################################################
#       COUNT COPE FILES
###############################################################################
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
#       CHECK COMMON COPE COUNTS
###############################################################################
check_common_cope_count() {
    local feat_dirs=("$@")
    local cope_counts=()
    local valid_feat_dirs=()
    local warning_messages=""
    local total_runs=${#feat_dirs[@]}

    for feat_dir in "${feat_dirs[@]}"; do
        local c
        c=$(count_cope_files "$feat_dir")
        cope_counts+=("$c")
    done

    unique_cope_counts=()
    cope_counts_freq=()

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

    local max_freq=0
    local common_cope_counts=()
    for ((i=0; i<${#unique_cope_counts[@]}; i++)); do
        local freq=${cope_counts_freq[i]}
        if [ "$freq" -gt "$max_freq" ]; then
            max_freq=$freq
            common_cope_counts=("${unique_cope_counts[i]}")
        elif [ "$freq" -eq "$max_freq" ]; then
            common_cope_counts+=("${unique_cope_counts[i]}")
        fi
    done

    if [ ${#common_cope_counts[@]} -gt 1 ]; then
        echo "UNEQUAL_COPES_TIE"
        echo "  - Unequal cope counts found across runs: ${unique_cope_counts[*]}."
        return
    fi

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
        echo "UNEQUAL_COPES"
        echo "  - Unequal cope counts across runs: ${unique_cope_counts[*]}. Excluding subject-session."
    fi
}

###############################################################################
#       GATHER VALID FIRST-LEVEL FEAT DIRS
###############################################################################
LISTING_OUTPUT=""
LISTING_OUTPUT+="=== Listing First-Level Feat Directories ===\n\n"

SESSION_NAME_PATTERNS=("ses-*" "session-*" "ses_*" "session_*" "ses*" "session*" "baseline" "endpoint" "ses-001" "ses-002")

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
                trimmed="${feat_dir#$BASE_PATH/}"
                LISTING_OUTPUT+="  • $trimmed\n"
            done

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

all_valid_feat_dirs=($(printf "%s\n" "${all_valid_feat_dirs[@]}" | sort))

###############################################################################
# SIMPLE MEMBERSHIP CHECKS
###############################################################################

is_valid_subject() {
    local subj="$1"
    array_contains "$subj" "${ALL_SUBJECTS[@]}"
    return $?
}

is_valid_session() {
    local sess="$1"
    array_contains "$sess" "${ALL_SESSIONS[@]}"
    return $?
}

is_valid_subject_session() {
    local subj="$1"
    local sess="$2"
    local pair="${subj}|${sess}"
    array_contains "$pair" "${SUBJECT_SESSION_LIST[@]}"
    return $?
}

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

PROMPT_MODE="short"

show_selection_prompt() {
    if [ "$PROMPT_MODE" = "extended" ]; then
        clear
        echo -e "$LISTING_OUTPUT"
        echo "=== Subject, Session, and Run Selection ==="
        echo "Specify patterns like:"
        echo "  sub-01[:ses-02[:01,02]] for inclusion"
        echo "  -sub-01[:ses-02[:01,02]] for exclusion"
        echo "Multiple entries can be on one line. Press Enter for all."
    else
        echo "=== Subject, Session, and Run Selection ==="
        echo "Enter your selections to include or exclude subjects, sessions, or runs."
        echo "Use 'subject[:session[:runs]]' for inclusion, '-subject[:session[:runs]]' for exclusion."
        echo "Enter 'help' for more info, or press Enter/Return for all."
    fi
    echo -n "> "
}

show_selection_prompt

inclusion_map_keys=()
inclusion_map_values=()
exclusion_map_keys=()
exclusion_map_values=()

while true; do
    read selection_input

    if [ -z "$selection_input" ]; then
        break
    fi

    if [ "$selection_input" = "help" ]; then
        PROMPT_MODE="extended"
        show_selection_prompt
        continue
    fi

    IFS=' ' read -ra entries <<< "$selection_input"
    invalid_selections=()
    temp_incl_keys=()
    temp_incl_vals=()
    temp_excl_keys=()
    temp_excl_vals=()

    for selection in "${entries[@]}"; do
        exclude=false
        if [[ "$selection" == -* ]]; then
            exclude=true
            selection="${selection#-}"
        fi

        IFS=':' read -ra parts <<< "$selection"
        sel_subj=""
        sel_sess=""
        sel_runs=""

        case ${#parts[@]} in
            1)
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
                if is_valid_subject "${parts[0]}"; then
                    sel_subj="${parts[0]}"
                    sel_sess="${parts[1]}"
                    if ! is_valid_subject_session "$sel_subj" "$sel_sess"; then
                        invalid_selections+=("$selection")
                        continue
                    fi
                elif is_valid_session "${parts[0]}"; then
                    sel_sess="${parts[0]}"
                    sel_runs="${parts[1]}"
                else
                    invalid_selections+=("$selection")
                    continue
                fi
                ;;
            3)
                sel_subj="${parts[0]}"
                sel_sess="${parts[1]}"
                sel_runs="${parts[2]}"
                if ! is_valid_subject_session "$sel_subj" "$sel_sess"; then
                    invalid_selections+=("$selection")
                    continue
                fi
                ;;
            *)
                invalid_selections+=("$selection")
                continue
                ;;
        esac

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

        if $exclude; then
            temp_excl_keys+=("${sel_subj}:${sel_sess}")
            temp_excl_vals+=("$sel_runs")
        else
            temp_incl_keys+=("${sel_subj}:${sel_sess}")
            temp_incl_vals+=("$sel_runs")
        fi
    done

    if [ ${#invalid_selections[@]} -gt 0 ]; then
        joined_invalid=$(printf ", %s" "${invalid_selections[@]}")
        joined_invalid="${joined_invalid:2}"
        echo "Invalid selections: $joined_invalid. Try again."
        echo -n "> "
    else
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
echo "If left blank, output will use 'desc-fixed-effects.gfeat'."
echo

valid_task=false
task_name=""

echo "Enter task name (or press Enter for default):"
while [ "$valid_task" = false ]; do
    echo -n "> "
    read user_input

    if [ -z "$user_input" ]; then
        task_name=""
        valid_task=true
        break
    fi

    if [[ "$user_input" =~ ^[A-Za-z0-9_-]+$ ]]; then
        task_name="$user_input"
        valid_task=true
    else
        echo "Invalid name. Use letters, numbers, underscores, or dashes."
    fi
done

###############################################################################
# 4) PROMPT FOR Z THRESHOLD AND CLUSTER P THRESHOLD
###############################################################################
echo -e "\n=== FEAT Thresholding Options ==="
echo "Specify Z threshold and Cluster P threshold, or press Enter for defaults (2.3, 0.05)."

default_z=2.3
default_p=0.05

z_threshold=""
cluster_p_threshold=""

valid_z=false
while [ "$valid_z" = false ]; do
    echo -e "\nEnter Z threshold (default $default_z):"
    echo -n "> "
    read z_threshold_input

    while [ -n "$z_threshold_input" ] && ! [[ "$z_threshold_input" =~ ^[0-9]*\.?[0-9]+$ ]]; do
        echo "Invalid numeric value. Try again."
        echo -n "> "
        read z_threshold_input
    done

    if [ -z "$z_threshold_input" ]; then
        z_threshold=$default_z
    else
        z_threshold="$z_threshold_input"
    fi
    valid_z=true
    echo "Using Z threshold of $z_threshold"
done

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
    else
        cluster_p_threshold="$cluster_p_threshold_input"
    fi
    valid_p=true
    echo "Using Cluster P threshold of $cluster_p_threshold"
done

###############################################################################
#       CHECK INCLUSION/EXCLUSION
###############################################################################
should_include_subject_session() {
    local subject="$1"
    local session="$2"

    # Check exclusions
    for idx in "${!exclusion_map_keys[@]}"; do
        local excl_key="${exclusion_map_keys[$idx]}"
        local excl_runs="${exclusion_map_values[$idx]}"

        IFS=':' read -ra eparts <<< "$excl_key"
        local excl_subj="${eparts[0]}"
        local excl_sess="${eparts[1]}"

        # If matches subject or session with no runs => exclude entire session
        if [ -n "$excl_subj" ] && [ "$excl_subj" = "$subject" ]; then
            if [ -z "$excl_sess" ] || [ "$excl_sess" = "$session" ]; then
                if [ -z "$excl_runs" ]; then
                    return 1
                else
                    return 0
                fi
            fi
        fi

        if [ -z "$excl_subj" ] && [ -n "$excl_sess" ] && [ "$excl_sess" = "$session" ]; then
            if [ -z "$excl_runs" ]; then
                return 1
            else
                return 0
            fi
        fi
    done

    # If inclusion rules, then it must match at least one
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
#  DEFINE PATHS, SCRIPTS
###############################################################################
GENERATE_DESIGN_SCRIPT="$BASE_DIR/code/scripts/generate_fixed_effects_design_fsf.sh"
if [ ! -f "$GENERATE_DESIGN_SCRIPT" ]; then
    echo "Error: generate_fixed_effects_design_fsf.sh not found at $GENERATE_DESIGN_SCRIPT"
    exit 1
fi

# Optionally, the create_dataset_description.sh script must be present:
CREATE_DS_DESC_SCRIPT="$BASE_DIR/code/scripts/create_dataset_description.sh"

###############################################################################
# CONFIRM SELECTIONS, GENERATE DESIGN FILES, PREPARE FOR FIXED-EFFECTS
###############################################################################
echo
echo "=== Confirm Your Selections for Fixed Effects Analysis ==="

generated_design_files=()

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

        if ! should_include_subject_session "$subject" "$session"; then
            echo
            echo "Subject: $subject | Session: $session"
            echo "  - Excluded based on selections."
            continue
        fi

        sel_key="$subject:$session"
        specific_runs=""
        for idx in "${!inclusion_map_keys[@]}"; do
            if [ "${inclusion_map_keys[$idx]}" = "$sel_key" ]; then
                specific_runs="${inclusion_map_values[$idx]}"
                break
            fi
        done

        exclude_runs=""
        for idx in "${!exclusion_map_keys[@]}"; do
            if [ "${exclusion_map_keys[$idx]}" = "$sel_key" ]; then
                exclude_runs="${exclusion_map_values[$idx]}"
                break
            fi
        done

        echo
        echo "Subject: $subject | Session: $session"
        echo "----------------------------------------"

        feat_dirs=()
        for d in "${all_valid_feat_dirs[@]}"; do
            if [[ "$d" == *"/$subject/$session/"* ]]; then
                feat_dirs+=("$d")
            fi
        done

        if [ -n "$specific_runs" ]; then
            selected_feat_dirs=()
            IFS=',' read -ra sruns <<< "$specific_runs"
            for r in "${sruns[@]}"; do
                r_no0=$(echo "$r" | sed 's/^0*//')
                rgx=".*run-0*${r_no0}\.feat$"
                for fdir in "${feat_dirs[@]}"; do
                    [[ "$fdir" =~ $rgx ]] && selected_feat_dirs+=("$fdir")
                done
            done
            feat_dirs=("${selected_feat_dirs[@]}")
        fi

        if [ -n "$exclude_runs" ]; then
            IFS=',' read -ra eruns <<< "$exclude_runs"
            for r in "${eruns[@]}"; do
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
            echo "  - Not enough runs for fixed effects (need >= 2). Skipping."
            continue
        fi

        echo "Selected Feat Directories:"
        for f in "${feat_dirs[@]}"; do
            echo "  • ${f#$BASE_PATH/}"
        done

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
            echo "No common cope count found for $subject_session_key. Skipping."
            continue
        fi

        if [ -n "$task_name" ]; then
            output_filename="${subject}_${session}_task-${task_name}_desc-fixed-effects"
        else
            output_filename="${subject}_${session}_desc-fixed-effects"
        fi

        output_path="$LEVEL_2_ANALYSIS_DIR/$subject/$session/$output_filename"

        echo
        echo "Output Directory: ${output_path}.gfeat"

        if [ -d "${output_path}.gfeat" ]; then
            echo
            echo "[Notice] Output directory already exists. Skipping."
            continue
        fi

        "$GENERATE_DESIGN_SCRIPT" "$output_path" "$common_cope_count" "$z_threshold" "$cluster_p_threshold" "${feat_dirs[@]}"
        echo
        echo "Generated FEAT design file at:"
        echo "- ${output_path}/modified_fixed-effects_design.fsf"

        generated_design_files+=("$output_path/modified_fixed-effects_design.fsf")
    done
done

if [ ${#generated_design_files[@]} -eq 0 ]; then
    echo
    echo "=== No new analyses to run. All specified outputs already exist or were excluded. ==="
    echo
    exit 0
fi

echo
echo "Press Enter/Return to proceed with second-level FEAT, or Ctrl+C to cancel now."

trap_ctrl_c() {
    echo
    echo "Interrupted. Removing any partial design dirs..."
    dirs_to_remove=()
    for design_file in "${generated_design_files[@]}"; do
        design_dir="$(dirname "$design_file")"
        [ -d "$design_dir" ] && dirs_to_remove+=("$design_dir")
    done
    for d in "${dirs_to_remove[@]}"; do
        rm -rf "$d"
    done
    if [ ${#dirs_to_remove[@]} -gt 0 ]; then
        echo
        echo "Removed these design directories:"
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

for design_file in "${generated_design_files[@]}"; do
    echo
    echo "--- Processing Design File: ---"
    echo "  ${design_file#$BASE_PATH/}"

    feat "$design_file"
    echo
    echo "Finished running fixed effects:"
    echo "  ${design_file#$BASE_PATH/}"

    design_dir="$(dirname "$design_file")"
    rm -rf "$design_dir"
    echo "Removed temporary design directory: ${design_dir#$BASE_PATH/}"
done

echo "=== All processing complete. Please check $LEVEL_2_ANALYSIS_DIR for outputs. ==="
echo

###############################################################################
#  CREATE/UPDATE DATASET_DESCRIPTION.JSON AT TOP LEVEL
###############################################################################
# Place it in $LEVEL_2_ANALYSIS_DIR

# If create_dataset_description.sh is missing, skip:
if [ ! -f "$CREATE_DS_DESC_SCRIPT" ]; then
    echo "[Notice] create_dataset_description.sh not found at $CREATE_DS_DESC_SCRIPT." >> $LOGFILE
    echo "Skipping dataset_description.json creation." >> $LOGFILE
else
    # Acquire FSL version
    FSL_VERSION="Unknown"
    if [ -n "$FSLDIR" ] && [ -f "$FSLDIR/etc/fslversion" ]; then
        FSL_VERSION=$(cat "$FSLDIR/etc/fslversion" | cut -d'%' -f1)
    fi

    # Call create_dataset_description.sh
    "$CREATE_DS_DESC_SCRIPT" \
        --analysis-dir "$LEVEL_2_ANALYSIS_DIR" \
        --ds-name "FSL_FEAT_with_Fixed_Effects" \
        --dataset-type "derivative" \
        --description "A second-level FSL pipeline for fixed-effects analysis across multiple first-level runs." \
        --bids-version "1.10.0" \
        --generatedby "Name=FSL,Version=$FSL_VERSION,Description=Used for second-level fixed effects."
fi
