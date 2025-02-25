#!/bin/bash
#
###############################################################################
# create_dataset_description.sh
#
# Purpose:
#   Create or update a BIDS-compatible dataset_description.json in an analysis
#   directory. If dataset_description.json already exists, this script skips it
#   (i.e. does not overwrite).
#
# Usage:
#   create_dataset_description.sh --analysis-dir <dir> \
#       --ds-name "Your_Derivative_Name" \
#       --dataset-type "derivative" \
#       --description "Some description" \
#       --bids-version "1.10.0" \
#       --generatedby "Name=FSL,Version=6.0.7,Description=Used for motion correction" \
#       [--generatedby "Name=SomeOther,Version=...,Description=..."] \
#       ...
#
# Options:
#   --analysis-dir <dir>      : Directory where dataset_description.json is placed
#   --ds-name <str>           : The "Name" field (default "Unnamed_Derivative")
#   --dataset-type <str>      : The "DatasetType" field (default "derivative")
#   --description <str>       : The "Description" field (default "No description provided.")
#   --bids-version <str>      : The BIDSVersion (default "1.10.0")
#   --generatedby <keypairs>  : Comma-separated key-value pairs for each "GeneratedBy" entry
#                                e.g. "Name=FSL,Version=6.0.7,Description=Used for ..."
#                                Can supply multiple --generatedby flags.
#   --help, -h                : Show this help message
#
# Usage Examples:
#   create_dataset_description.sh \
#       --analysis-dir "/my/BIDS/derivatives/fsl/level-2/analysis_postICA" \
#       --ds-name "FSL_FEAT_with_Fixed_Effects" \
#       --dataset-type "derivative" \
#       --description "FSL second-level fixed-effects pipeline" \
#       --bids-version "1.10.0" \
#       --generatedby "Name=FSL,Version=6.0.7,Description=Used for second-level FEAT"
#
# Notes:
#   - If a dataset_description.json already exists in the --analysis-dir,
#     print a message and skip creation (exit 0).
#   - Otherwise, write a new JSON with the specified fields.
###############################################################################

usage() {
  cat <<EOM
Usage: $(basename "$0") --analysis-dir <dir> [--ds-name <str>] [--dataset-type <str>]
                        [--description <str>] [--bids-version <str>]
                        [--generatedby <key=val,key=val,...>] [...]
                        [--help]

Creates or updates a BIDS dataset_description.json in the specified directory,
skipping if a dataset_description.json is already present.

Required arguments:
  --analysis-dir <dir>        : Directory for dataset_description.json

Optional arguments:
  --ds-name <str>             : The "Name" field (default "Unnamed_Derivative")
  --dataset-type <str>        : The "DatasetType" (default "derivative")
  --description <str>         : The "Description" field (default "No description provided.")
  --bids-version <str>        : The BIDSVersion (default "1.10.0")
  --generatedby <k=v,k=v,...> : Zero or more times; each describes a "GeneratedBy" entry
  --help, -h                  : Show this help and exit

EOM
  exit 1
}

###############################################################################
# Default values
###############################################################################
ANALYSIS_DIR=""
DS_NAME="Unnamed_Derivative"
DATASET_TYPE="derivative"
DESCRIPTION="No description provided."
BIDS_VERSION="1.10.0"
declare -a GENERATED_BY_ITEMS=()

###############################################################################
# Parse command-line arguments
###############################################################################
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    --help|-h)
      usage
      ;;
    --analysis-dir)
      ANALYSIS_DIR="$2"
      shift; shift
      ;;
    --ds-name)
      DS_NAME="$2"
      shift; shift
      ;;
    --dataset-type)
      DATASET_TYPE="$2"
      shift; shift
      ;;
    --description)
      DESCRIPTION="$2"
      shift; shift
      ;;
    --bids-version)
      BIDS_VERSION="$2"
      shift; shift
      ;;
    --generatedby)
      GENERATED_BY_ITEMS+=("$2")
      shift; shift
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      ;;
  esac
done

###############################################################################
# Validate that --analysis-dir was provided
###############################################################################
if [ -z "$ANALYSIS_DIR" ]; then
  echo "Error: --analysis-dir <dir> is required."
  usage
fi

###############################################################################
# Create the target directory if needed
###############################################################################
mkdir -p "$ANALYSIS_DIR"
JSON_FILE="${ANALYSIS_DIR}/dataset_description.json"

###############################################################################
# If dataset_description.json already exists, skip
###############################################################################
if [ -f "$JSON_FILE" ]; then
  exit 0
fi

###############################################################################
# Build the JSON in a temp file, then move it
###############################################################################
TMPFILE=$(mktemp)

# Start the JSON
cat <<EOF > "$TMPFILE"
{
  "Name": "${DS_NAME}",
  "DatasetType": "${DATASET_TYPE}",
  "BIDSVersion": "${BIDS_VERSION}",
  "Description": "${DESCRIPTION}",
  "GeneratedBy": [
EOF

# If no --generatedby args, the "GeneratedBy" will remain an empty array
COUNT=${#GENERATED_BY_ITEMS[@]}
if [ "$COUNT" -gt 0 ]; then
  # For each --generatedby "Name=...,Version=...,Description=..."
  for ((i=0; i<COUNT; i++)); do
    entry="${GENERATED_BY_ITEMS[$i]}"
    IFS=',' read -ra KV_PAIRS <<< "$entry"

    printf '    {\n' >> "$TMPFILE"

    LEN=${#KV_PAIRS[@]}
    for ((j=0; j<LEN; j++)); do
      kv="${KV_PAIRS[$j]}"
      keyPart="$(echo "$kv" | cut -d'=' -f1)"
      valPart="$(echo "$kv" | cut -d'=' -f2- | sed 's/"/\\"/g')" # Escape any quotes

      if [ $((j+1)) -lt $LEN ]; then
        printf '      "%s": "%s",\n' "$keyPart" "$valPart" >> "$TMPFILE"
      else
        printf '      "%s": "%s"\n' "$keyPart" "$valPart" >> "$TMPFILE"
      fi
    done

    if [ $((i+1)) -lt $COUNT ]; then
      printf '    },\n' >> "$TMPFILE"
    else
      printf '    }\n' >> "$TMPFILE"
    fi
  done
fi

# Finish the JSON
cat <<EOF >> "$TMPFILE"
  ]
}
EOF

mv "$TMPFILE" "$JSON_FILE"
exit 0
