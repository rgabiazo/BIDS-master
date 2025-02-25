#!/bin/bash
#
###############################################################################
# generate_fixed_effects_design_fsf.sh
#
# Purpose:
#   This script automatically generates a modified_fixed-effects_design.fsf file for
#   second-level fixed effects analysis in FSL. It programmatically inserts the
#   first-level .feat directories, sets up the appropriate EV and group membership
#   parameters, and defines thresholding values (Z and Cluster P).
#
# Usage:
#   generate_fixed_effects_design_fsf.sh output_path cope_count z_threshold cluster_p_threshold feat_dirs...
#
# Usage Examples:
#   1) ./generate_fixed_effects_design_fsf.sh \
#        /path/to/second_level_output/sub-01_ses-01_fixed_effects \
#        4 2.3 0.05 \
#        /path/to/sub-01_ses-01_run-01.feat \
#        /path/to/sub-01_ses-01_run-02.feat \
#        /path/to/sub-01_ses-01_run-03.feat \
#        /path/to/sub-01_ses-01_run-04.feat
#
# Options:
#   (No additional command-line flags; positional arguments only.)
#
# Requirements:
#   - FSL installed and accessible in your PATH (for final FEAT usage).
#   - A base fixed-effects design file (e.g., fixed-effects_design.fsf) located
#     at $BASE_DIR/code/design_files/fixed-effects_design.fsf
#   - A standard brain template (e.g., MNI152_T1_2mm_brain.nii.gz) at
#     $BASE_DIR/derivatives/templates
#   - Bash 3.2+ recommended.
#
# Notes:
#   - The script writes out a modified_fixed-effects_design.fsf to the specified
#     'output_path' directory. Ensure you have permissions to create files there.
#   - 'cope_count' is the number of contrasts (copes) in each first-level analysis
#     being combined.
#   - The final design.fsf references each first-level .feat directory and sets up
#     group membership and EVs for a standard fixed-effects model.
#   - This script does not itself run 'feat'; it only generates the design file.
#     You can call 'feat' on the generated .fsf afterwards, or it can be run
#     automatically as part of a higher-level script.
#
###############################################################################

usage() {
  cat <<EOF
Usage:
  $(basename "$0") output_path cope_count z_threshold cluster_p_threshold feat_dirs...

Example:
  $(basename "$0") /path/to/second_level_output/sub-01_ses-01_fixed_effects \\
                   4 2.3 0.05 \\
                   /path/to/sub-01_ses-01_run-01.feat \\
                   /path/to/sub-01_ses-01_run-02.feat \\
                   /path/to/sub-01_ses-01_run-03.feat \\
                   /path/to/sub-01_ses-01_run-04.feat

Description:
  Generates a second-level fixed-effects FSF file by inserting each first-level .feat
  directory into the model. The outputs are directed to 'output_path', and the
  number of contrasts (COPES) is specified by 'cope_count'. Z and Cluster-P thresholds
  are also configurable.

EOF
}

# Check if at least 5 arguments are provided
if [ "$#" -lt 5 ]; then
    usage
    exit 1
fi

# Parse inputs
output_path="$1"
COPE_COUNT="$2"
z_threshold="$3"
cluster_p_threshold="$4"
shift 4
feat_dirs=("$@")

N=${#feat_dirs[@]}  # Number of first-level analyses

# Define paths (modify BASE_DIR if needed)
script_dir="$(dirname "$(realpath "$0")")"
BASE_DIR="$(dirname "$(dirname "$script_dir")")"
BASE_DESIGN_FSF="$BASE_DIR/code/design_files/fixed-effects_design.fsf"
TEMPLATE="$BASE_DIR/derivatives/templates/MNI152_T1_2mm_brain.nii.gz"

# Generate feat_files content
FEAT_FILES_CONTENT=""
i=1
while [ $i -le $N ]; do
    FEAT_FILES_CONTENT="${FEAT_FILES_CONTENT}# 4D AVW data or FEAT directory ($i)\n"
    FEAT_FILES_CONTENT="${FEAT_FILES_CONTENT}set feat_files($i) \"${feat_dirs[$i-1]}\"\n\n"
    i=$((i + 1))
done

# Generate copeinput content for each cope
COPEINPUT_CONTENT=""
j=1
while [ $j -le $COPE_COUNT ]; do
    COPEINPUT_CONTENT="${COPEINPUT_CONTENT}# Use lower-level cope $j for higher-level analysis\n"
    COPEINPUT_CONTENT="${COPEINPUT_CONTENT}set fmri(copeinput.$j) 1\n\n"
    j=$((j + 1))
done

# Generate EVG values content
EVG_VALUES_CONTENT=""
i=1
while [ $i -le $N ]; do
    EVG_VALUES_CONTENT="${EVG_VALUES_CONTENT}# Higher-level EV value for EV 1 and input $i\n"
    EVG_VALUES_CONTENT="${EVG_VALUES_CONTENT}set fmri(evg${i}.1) 1\n\n"
    i=$((i + 1))
done

# Generate group membership content
GROUP_MEMBERSHIP_CONTENT=""
i=1
while [ $i -le $N ]; do
    GROUP_MEMBERSHIP_CONTENT="${GROUP_MEMBERSHIP_CONTENT}# Group membership for input $i\n"
    GROUP_MEMBERSHIP_CONTENT="${GROUP_MEMBERSHIP_CONTENT}set fmri(groupmem.$i) 1\n\n"
    i=$((i + 1))
done

# Read the base design.fsf and generate the new design.fsf
OUTPUT_DESIGN_FSF="${output_path}/modified_fixed-effects_design.fsf"
mkdir -p "$(dirname "$OUTPUT_DESIGN_FSF")"

{
  while IFS= read -r line || [ -n "$line" ]; do
      # Replace placeholders
      line="${line//@OUTPUT_DIR@/$output_path}"
      line="${line//@TEMPLATE@/$TEMPLATE}"
      line="${line//@NPTS@/$N}"
      line="${line//@COPE_COUNT@/$COPE_COUNT}"
      line="${line//@Z_THRESHOLD@/$z_threshold}"
      line="${line//@CLUSTER_P_THRESHOLD@/$cluster_p_threshold}"
      if echo "$line" | grep -q '^set fmri(multiple) '; then
          echo "set fmri(multiple) $N"
      elif echo "$line" | grep -q '^set fmri(ncopeinputs) '; then
          echo "set fmri(ncopeinputs) $COPE_COUNT"
      elif [ "$line" = "@FEAT_FILES@" ]; then
          printf "$FEAT_FILES_CONTENT"
      elif [ "$line" = "@EVG_VALUES@" ]; then
          printf "$EVG_VALUES_CONTENT"
      elif [ "$line" = "@GROUP_MEMBERSHIP@" ]; then
          printf "$GROUP_MEMBERSHIP_CONTENT"
      elif [ "$line" = "@COPEINPUTS@" ]; then
          printf "$COPEINPUT_CONTENT"
      else
          echo "$line"
      fi
  done < "$BASE_DESIGN_FSF"
} > "$OUTPUT_DESIGN_FSF"
