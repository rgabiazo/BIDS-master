#!/bin/bash
#
###############################################################################
# setup_bids.sh
#
# Purpose:
#   1) Renames "BIDS-master" to "BIDS-<ProjectName>"
#   2) Creates a minimal "dataset_description.json"
#   3) Prompts for #subjects & #sessions, then calls "setup_dir.sh" to create:
#      - sourcedata/Dicom
#      - (optional) a custom events directory
#
# Usage:
#   1. Place this script in a directory named "BIDS-master".
#   2. Place "setup_dir.sh" in the same folder (so both are in BIDS-master).
#   3. Run:  ./setup_bids.sh
#
###############################################################################

# Helper function to print directory structure recursively
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

###########################################
# 1) Verify setup script is in "BIDS-master" directory
###########################################
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"
CURRENT_DIR_NAME="$(basename "$SCRIPT_DIR")"

if [ "$CURRENT_DIR_NAME" != "BIDS-master" ]; then
    echo -e "Error: This script must be located inside a directory named 'BIDS-master'.\n"
    exit 1
fi

###########################################
# 2) Prompt for Project Name
###########################################
validate_name() {
    local NAME=$1
    # No spaces allowed, only letters/numbers/underscore/hyphens
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

while true; do
    read -p "Enter project name: " INPUT_PROJECT_NAME
    # Trim whitespace
    INPUT_PROJECT_NAME="$(echo -e "${INPUT_PROJECT_NAME}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

    if ! validate_name "$INPUT_PROJECT_NAME"; then
        echo "Please enter a valid name without spaces or special characters."
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

# Rename "BIDS-master" → "BIDS-<ProjectName>"
echo "Renaming 'BIDS-master' to '$PROJECT_NAME'..."
mv "$SCRIPT_DIR" "$PARENT_DIR/$PROJECT_NAME"
PROJECT_DIR="$PARENT_DIR/$PROJECT_NAME"

###########################################
# 3) Create dataset_description.json
###########################################
cat <<EOF > "$PROJECT_DIR/dataset_description.json"
{
  "Name": "$PROJECT_NAME",
  "BIDSVersion": "1.10.0",
  "DatasetType": "raw"
}
EOF
echo "Created $PROJECT_DIR/dataset_description.json"

###########################################
# 4) Prompt for #subjects
###########################################
while true; do
    echo ""
    read -p "Enter number of subjects: " NUM_SUBJECTS
    if [[ "$NUM_SUBJECTS" =~ ^[0-9]+$ ]] && [ "$NUM_SUBJECTS" -gt 0 ]; then
        break
    else
        echo "Please enter a valid positive integer."
    fi
done

###########################################
# 5) Prompt for number of sessions
###########################################
while true; do
    echo ""
    read -p "Enter number of sessions: " NUM_SESSIONS
    if [[ "$NUM_SESSIONS" =~ ^[0-9]+$ ]] && [ "$NUM_SESSIONS" -gt 0 ]; then
        break
    else
        echo "Please enter a valid positive integer."
    fi
done

# Build a session label array (01, 02, 03, ... up to NUM_SESSIONS)
SESSION_LABELS=()
for (( i=1; i<=NUM_SESSIONS; i++ )); do
  if [ $i -lt 10 ]; then
    SESSION_LABELS+=("0$i")
  else
    SESSION_LABELS+=("$i")
  fi
done

###########################################
# 6) Prompt custom events directory
###########################################
CREATE_EVENTS="no"
EVENTS_DIR=""
while true; do
    echo ""
    read -p "Do you want to create a custom events directory? (y/n): " ANSWER
    case "$ANSWER" in
        [Yy]* )
            CREATE_EVENTS="yes"
            while true; do
                read -p "Enter custom events directory name: " EVENTS_DIR
                # Trim whitespace
                EVENTS_DIR="$(echo -e "${EVENTS_DIR}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
                if validate_name "$EVENTS_DIR"; then
                    break
                else
                    echo "Please enter a valid directory name without spaces or special characters."
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

###########################################
# 7) Move scripts into code/scripts
###########################################
mkdir -p "$PROJECT_DIR/code/scripts"
THIS_SCRIPT_NAME="$(basename "$0")"

# Move setup_dir.sh if present
if [ -f "$PROJECT_DIR/setup_dir.sh" ]; then
    mv "$PROJECT_DIR/setup_dir.sh" "$PROJECT_DIR/code/scripts/setup_dir.sh"
elif [ -f "$PARENT_DIR/BIDS-master/setup_dir.sh" ]; then
    mv "$PARENT_DIR/BIDS-master/setup_dir.sh" "$PROJECT_DIR/code/scripts/setup_dir.sh"
fi

# Move *this* script
mv "$PROJECT_DIR/$THIS_SCRIPT_NAME" "$PROJECT_DIR/code/scripts/$THIS_SCRIPT_NAME"

###########################################
# 8) Call setup_dir.sh (from the new folder)
###########################################
cd "$PROJECT_DIR" || exit

echo ""
echo "Creating subject/session folders with command:"
CMD="./code/scripts/setup_dir.sh -dcm"
if [ "$CREATE_EVENTS" = "yes" ]; then
  CMD+=" -events $EVENTS_DIR"
fi
CMD+=" -subject_prefix sub -subject_label 00 -num_sub $NUM_SUBJECTS -sessions"
for s in "${SESSION_LABELS[@]}"; do
  CMD+=" $s"
done

echo "  $CMD"
echo ""
eval "$CMD"

###########################################
# 9) Display final directory structure, summary, prompt
###########################################
echo -e "\nSourcedata directory structure:\n"
if [ -d "$PROJECT_DIR/sourcedata" ]; then
  print_structure "$PROJECT_DIR/sourcedata" "    "
else
  echo "No 'sourcedata' directory created."
fi

echo -e "\n==== Summary ===="
echo "Project Name:          $PROJECT_NAME"
echo "Number of Subjects:    $NUM_SUBJECTS"
echo "Sessions per Subject:  $NUM_SESSIONS"
if [ "$CREATE_EVENTS" = "yes" ]; then
  echo "Custom Events Dir:     $EVENTS_DIR"
fi
echo ""
echo -e "dataset_description.json created in: $PROJECT_DIR\n"
echo -e "You can run additional scripts from $PROJECT_DIR/code/scripts as needed.\n"

PS1="(base) $(whoami)@$(hostname) $(basename "$PROJECT_DIR") % "
export PS1

exec $SHELL
