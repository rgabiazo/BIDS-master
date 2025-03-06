#!/bin/bash
#
###############################################################################
# setup_dir.sh
#
# Purpose: Creates subject/session directories in `sourcedata/dicom` and/or a custom events directory,
#          with optional zero-padding for subject IDs via -subject_label.
#
# Usage examples:
#   setup_dir.sh -dcm -num_sub 3 -sessions 01 02
#   setup_dir.sh -events custom_txt -num_sub 3 -sessions 01 02
#   setup_dir.sh -dcm -events custom_txt -num_sub 3 -sessions 01 02
#   setup_dir.sh -dcm -events custom_txt -num_sub 3 -sessions baseline endpoint
#   setup_dir.sh -subject_prefix subj -subject_label 00 -dcm -events custom_txt -num_sub 3 -sessions 01 02
#
# Options:
#   -dcm                Create subject/session folders in sourcedata/dicom
#   -events NAME        Create subject/session folders in sourcedata/NAME
#   -subject_prefix STR Subject prefix (default: 'sub'), e.g. 'subj' => subj-01
#   -subject_label 0    Zero-padding control: '0' => sub-01, '00' => sub-001, etc.
#   -num_sub N          Number of subjects to create
#   -sessions S1 S2..   One or more session labels (e.g., 01 02 or baseline endpoint)
#   -h, --help          Show this help message
#
# Notes:
#   - If a directory already exists, the script skips it (without listing each).
#   - By default, subject_prefix is 'sub' and subject_label is '0' (2-digit: sub-01).
#   - Always creates folders in the parent project root, two levels above this script.
################################################################################

DICOM=false
EVENTS=""
SUBJECT_PREFIX="sub"
SUBJECT_LABEL="0"  # default = 2-digit sub-01, sub-02, ...
NUM_SUBJECTS=0
SESSION_NAMES=()

usage() {
  echo "Usage: $0 [options]"
  echo "  -dcm                  Create subject/session folders in 'sourcedata/dicom'"
  echo "  -events NAME          Create subject/session folders in 'sourcedata/NAME'"
  echo "  -subject_prefix STR   Subject folder prefix (default: 'sub')"
  echo "  -subject_label 0      Zero-padding control: '0' => 2-digit, '00' => 3-digit, etc."
  echo "  -num_sub N            Number of subjects to create"
  echo "  -sessions S1 S2..     One or more session labels"
  echo "  -h, --help            Show this help message"
  echo
  echo "Examples:"
  echo "  $0 -dcm -num_sub 3 -sessions 01 02"
  echo "  $0 -events custom_txt -num_sub 3 -sessions baseline endpoint"
  echo "  $0 -dcm -events custom_txt -subject_prefix sub -subject_label 00 -num_sub 3 -sessions 01 02"
}

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -dcm)
      DICOM=true
      shift
      ;;
    -events)
      EVENTS="$2"
      shift 2
      ;;
    -subject_prefix)
      SUBJECT_PREFIX="$2"
      shift 2
      ;;
    -subject_label)
      SUBJECT_LABEL="$2"
      shift 2
      ;;
    -num_sub)
      NUM_SUBJECTS="$2"
      shift 2
      ;;
    -sessions)
      shift
      while [[ $# -gt 0 && ! "$1" =~ ^- ]]; do
        SESSION_NAMES+=("$1")
        shift
      done
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

# Basic validations
if [[ $NUM_SUBJECTS -le 0 ]]; then
  echo "Error: number of subjects (-num_sub) must be a positive integer."
  usage
  exit 1
fi
if [[ ${#SESSION_NAMES[@]} -eq 0 ]]; then
  echo "Error: at least one session name must be provided with -sessions."
  usage
  exit 1
fi

# Reference BIDS project root i.e., two levels above /code/scripts
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

[ ! -d "$PROJECT_DIR/sourcedata" ] && mkdir -p "$PROJECT_DIR/sourcedata"

#####################################
# Determine zero-padding
#####################################
# e.g. SUBJECT_LABEL="0" => sub-01
#      SUBJECT_LABEL="00" => sub-001, etc.
zero_padding=$((1 + ${#SUBJECT_LABEL}))

CREATED_DICOM_SUBJECTS=0
CREATED_EVENTS_SUBJECTS=0

#####################################
# If -dcm was requested
#####################################
if [ "$DICOM" = true ]; then
  DICOM_DIR="$PROJECT_DIR/sourcedata/dicom"
  [ ! -d "$DICOM_DIR" ] && mkdir -p "$DICOM_DIR"

  for (( i=1; i<=NUM_SUBJECTS; i++ )); do
    SUBJECT_NAME=$(printf "%s-%0${zero_padding}d" "$SUBJECT_PREFIX" "$i")
    SUBJECT_DIR="$DICOM_DIR/$SUBJECT_NAME"
    if [ ! -d "$SUBJECT_DIR" ]; then
      mkdir -p "$SUBJECT_DIR"
      ((CREATED_DICOM_SUBJECTS++))
    fi
    for SESSION in "${SESSION_NAMES[@]}"; do
      SESSION_DIR="$SUBJECT_DIR/ses-$SESSION"
      [ ! -d "$SESSION_DIR" ] && mkdir -p "$SESSION_DIR"
    done
  done
fi

#####################################
# If -events was specified
#####################################
if [ -n "$EVENTS" ]; then
  EVENTS_DIR="$PROJECT_DIR/sourcedata/$EVENTS"
  [ ! -d "$EVENTS_DIR" ] && mkdir -p "$EVENTS_DIR"

  for (( i=1; i<=NUM_SUBJECTS; i++ )); do
    SUBJECT_NAME=$(printf "%s-%0${zero_padding}d" "$SUBJECT_PREFIX" "$i")
    SUBJECT_DIR="$EVENTS_DIR/$SUBJECT_NAME"
    if [ ! -d "$SUBJECT_DIR" ]; then
      mkdir -p "$SUBJECT_DIR"
      ((CREATED_EVENTS_SUBJECTS++))
    fi
    for SESSION in "${SESSION_NAMES[@]}"; do
      SESSION_DIR="$SUBJECT_DIR/ses-$SESSION"
      [ ! -d "$SESSION_DIR" ] && mkdir -p "$SESSION_DIR"
    done
  done
fi

#####################################
# Print summary
#####################################
if [ "$DICOM" = true ]; then
  echo -e "\nCreated $CREATED_DICOM_SUBJECTS subject directories in:"
  echo "  $DICOM_DIR"
fi

if [ -n "$EVENTS" ]; then
  echo -e "\nCreated $CREATED_EVENTS_SUBJECTS subject directories in:"
  echo "  $EVENTS_DIR"
fi

echo ""
