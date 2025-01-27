#!/bin/bash

# Purpose:
#   This script automates the setup of a BIDS-compliant directory structure for fMRI or other neuroimaging projects.
#   It creates DICOM directories to store DICOM .zip folders for subjects, sessions, and an optional custom events
#   (e.g., raw txt files) directory, and moves itself to a code/scripts directory.

# Usage:
#   1. Place this script inside a directory named "BIDS-master".
#   2. Run the script from the terminal:
#         ./setup_bids.sh
#   3. Follow the prompts to specify the project name, number of subjects, folder prefix, number of sessions,
#      and whether to include a custom events directory.

# Notes:
#   Author:  Raphael Gabiazon
#   School:  Western University
#   Program: PhD Neuroscience
#   - Automatically prefixes the project name with 'BIDS-' if not already present.
#   - Validates project and events directory names to prevent spaces and ensure BIDS compliance.
#   - Creates a "sourcedata" directory with "Dicom" and optional custom events subdirectories.
#   - Organizes subject folders (e.g., "sub-01", "sub-02") with specified prefixes and session folders within each subject.
#   - Moves itself to a "code/scripts" directory within the project.
#   - Updates the terminal prompt to reflect the project directory.

# Function to print directory structure recursively
print_structure() {
    local DIR=$1
    local PREFIX=$2
    for ENTRY in "$DIR"/*; do
        if [ -d "$ENTRY" ]; then
            echo "${PREFIX}|-- $(basename "$ENTRY")"
            print_structure "$ENTRY" "$PREFIX|   "
        fi
    done
}

echo -e "\n==== BIDS Setup ===="

# Get the script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"
CURRENT_DIR_NAME="$(basename "$SCRIPT_DIR")"

# Ensure the script is in "BIDS-master"
if [ "$CURRENT_DIR_NAME" != "BIDS-master" ]; then
    echo -e "The script must be located in a 'BIDS-master' directory.\n"
    exit 1
fi

# Function to validate project and directory names
validate_name() {
    local NAME=$1
    if [[ "$NAME" =~ [[:space:]] ]]; then
        echo "Name must not contain spaces."
        return 1
    fi
    if [[ ! "$NAME" =~ ^[A-Za-z0-9_-]+$ ]]; then
        echo "Name must contain only letters, numbers, underscores, or hyphens."
        return 1
    fi
    return 0
}

# Prompt for Project Name
while true; do
    read -p "Enter project name: " INPUT_PROJECT_NAME
    # Remove leading/trailing whitespace
    INPUT_PROJECT_NAME="$(echo -e "${INPUT_PROJECT_NAME}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    
    # Validate name
    if ! validate_name "$INPUT_PROJECT_NAME"; then
        echo "Please enter a valid project name without spaces or special characters."
        continue
    fi
    
    # Add 'BIDS-' prefix if not present
    if [[ "$INPUT_PROJECT_NAME" =~ ^BIDS- ]]; then
        PROJECT_NAME="$INPUT_PROJECT_NAME"
    else
        PROJECT_NAME="BIDS-$INPUT_PROJECT_NAME"
    fi
    
    # Check if project directory already exists
    if [ -d "$PARENT_DIR/$PROJECT_NAME" ]; then
        echo "A directory named '$PROJECT_NAME' already exists. Please choose a different project name."
    else
        break
    fi
done

echo "Renaming 'BIDS-master' to '$PROJECT_NAME'..."
mv "$SCRIPT_DIR" "$PARENT_DIR/$PROJECT_NAME"
PROJECT_DIR="$PARENT_DIR/$PROJECT_NAME"

# Number of Subjects
while true; do
    echo ""
    read -p "Enter number of subjects: " NUM_SUBJECTS
    if [[ "$NUM_SUBJECTS" =~ ^[0-9]+$ ]] && [ "$NUM_SUBJECTS" -gt 0 ]; then
        break
    else
        echo "Please enter a valid positive number."
    fi
done

# Subject Prefix
ACCEPTABLE_PREFIXES=("sub" "subj" "participant" "P" "pilot" "pilsub")
while true; do
    read -p "Enter subject folder prefix (e.g., 'sub', 'subj'): " SUBJECT_PREFIX
    if [[ " ${ACCEPTABLE_PREFIXES[@]} " =~ " ${SUBJECT_PREFIX} " ]]; then
        break
    else
        echo "Please enter a valid subject prefix (${ACCEPTABLE_PREFIXES[*]})."
    fi
done

# Create Sourcedata/Dicom Directory
mkdir -p "$PROJECT_DIR/sourcedata/Dicom"

# Create Subject Folders
for (( i=1; i<=NUM_SUBJECTS; i++ )); do
    SUBJECT_DIR=$(printf "$PROJECT_DIR/sourcedata/Dicom/${SUBJECT_PREFIX}-%02d" $i)
    mkdir -p "$SUBJECT_DIR"
done

# Number of Sessions
while true; do
    echo ""
    read -p "Enter number of sessions: " NUM_SESSIONS
    if [[ "$NUM_SESSIONS" =~ ^[0-9]+$ ]] && [ "$NUM_SESSIONS" -gt 0 ]; then
        break
    else
        echo "Please enter a valid positive number."
    fi
done

# Baseline/Endpoint Option
BASELINE_ENDPOINT="no"
if [ "$NUM_SESSIONS" -eq 2 ]; then
    while true; do
        read -p "Baseline/Endpoint (y/n): " BASELINE_ENDPOINT_INPUT
        case "$BASELINE_ENDPOINT_INPUT" in
            [Yy]* )
                BASELINE_ENDPOINT="yes"
                break
                ;;
            [Nn]* )
                BASELINE_ENDPOINT="no"
                break
                ;;
            * )
                echo "Please answer yes (y) or no (n)."
                ;;
        esac
    done
fi

# Create Session Folders
for (( i=1; i<=NUM_SUBJECTS; i++ )); do
    SUBJECT_DIR=$(printf "$PROJECT_DIR/sourcedata/Dicom/${SUBJECT_PREFIX}-%02d" $i)
    if [ "$NUM_SESSIONS" -eq 2 ] && [ "$BASELINE_ENDPOINT" == "yes" ]; then
        mkdir -p "$SUBJECT_DIR/ses-baseline" "$SUBJECT_DIR/ses-endpoint"
    else
        for (( j=1; j<=NUM_SESSIONS; j++ )); do
            SESSION_DIR=$(printf "$SUBJECT_DIR/ses-%02d" $j)
            mkdir -p "$SESSION_DIR"
        done
    fi
done

# Custom Events Directory
echo ""
while true; do
    read -p "Do you want to create a custom events directory? (y/n): " CREATE_EVENTS
    case "$CREATE_EVENTS" in
        [Yy]* )
            while true; do
                read -p "Enter custom events directory name: " EVENTS_DIR
                # Remove leading/trailing whitespace
                EVENTS_DIR="$(echo -e "${EVENTS_DIR}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
                # Validate name
                if validate_name "$EVENTS_DIR"; then
                    break
                else
                    echo "Please enter a valid directory name without spaces or special characters."
                fi
            done
            echo "Creating custom events directory '$EVENTS_DIR'..."
            mkdir -p "$PROJECT_DIR/sourcedata/$EVENTS_DIR"
            
            # Mirror Subject/Session Structure
            for (( i=1; i<=NUM_SUBJECTS; i++ )); do
                SUBJECT_DIR=$(printf "$PROJECT_DIR/sourcedata/$EVENTS_DIR/${SUBJECT_PREFIX}-%02d" $i)
                mkdir -p "$SUBJECT_DIR"
                if [ "$NUM_SESSIONS" -eq 2 ] && [ "$BASELINE_ENDPOINT" == "yes" ]; then
                    mkdir -p "$SUBJECT_DIR/ses-baseline" "$SUBJECT_DIR/ses-endpoint"
                else
                    for (( j=1; j<=NUM_SESSIONS; j++ )); do
                        SESSION_DIR=$(printf "$SUBJECT_DIR/ses-%02d" $j)
                        mkdir -p "$SESSION_DIR"
                    done
                fi
            done
            break
            ;;
        [Nn]* )
            CREATE_EVENTS="no"
            break
            ;;
        * )
            echo "Please answer yes (y) or no (n)."
            ;;
    esac
done

# Display Directory Structure
echo -e "\nSourcedata directory structure:"
echo -e "\n$PROJECT_DIR/sourcedata/"
print_structure "$PROJECT_DIR/sourcedata" "    "

# Move Script to Code/Scripts Directory
echo ""
echo "Moving setup script to /code/scripts/..."
mkdir -p "$PROJECT_DIR/code/scripts"
SCRIPT_NAME="$(basename "$0")"
mv "$PROJECT_DIR/$SCRIPT_NAME" "$PROJECT_DIR/code/scripts/$SCRIPT_NAME"

# Output Summary
echo -e "\n==== Summary ===="
echo "Project Name:          $PROJECT_NAME"
echo "Number of Subjects:    $NUM_SUBJECTS"
echo "Sessions per Subject:  $NUM_SESSIONS"
if [[ "$CREATE_EVENTS" =~ ^[Yy]$ ]]; then
    echo -e "Custom Events Dir:     $EVENTS_DIR\n"
fi

# Notify user about script location
echo "The setup script has been moved to '$PROJECT_DIR/code/scripts/'."
echo -e "You can run additional scripts from $PROJECT_DIR/code/scripts/ as needed.\n"

# Change to Project Directory
cd "$PROJECT_DIR" || exit

# Update shell prompt to show current directory
PS1="(base) $(whoami)@$(hostname) $(basename "$PWD") % "

# Export the new prompt
export PS1

# Keep the shell session active with the updated prompt
exec $SHELL
