#!/usr/bin/env python3
"""
download_dicom.py

Defines the function that runs a Docker command to download
a DICOM study from a remote server into a local directory, with optional
cleanup and basic metadata storage.
"""

import os
import re
import json
import subprocess

# Directory of JSON file containing metadata of subjects
METADATA_FILE = os.path.join(
    os.path.dirname(__file__),  # current file directory
    "..",                       # go up one
    "..",                       # go up another (project root)
    "sourcedata",               # into sourcedata/
    "dicom",                    # into sourcedata/dicom
    "dicom_metadata.json"       # metadata filename
)

# In-memory store for subject metadata
_collected_metadata = {}

def download_dicom(study, credentials_file, do_cleanup=False, create_dicom_metadata=False):
    """Executes the Docker command to download the specified study into its output directory.

    Optionally removes leftover *.attached.tar or *.uid files if `do_cleanup=True`.
    If `create_dicom_metadata=True`, collects demographic data (age/sex) and writes
    it to sourcedata/dicom/dicom_metadata.json.

    Args:
        study (dict): A dictionary containing study metadata, such as 'study_uid' and 'out_dir'.
            Also may include 'sub_label', 'patient_sex', etc.
        credentials_file (str): The path to the credentials file to mount into Docker.
        do_cleanup (bool, optional): Whether to remove leftover temporary files after download.
        create_dicom_metadata (bool, optional): If True, store demographic info in JSON logs.

    Returns:
        None
    """
    study_uid = study["study_uid"]
    out_dir = study["out_dir"]
    sub_label = study.get("sub_label", "sub-unknown")

    # Build the Docker command as a list for subprocess
    docker_cmd = [
        "docker", "run",
        "--rm",
        "-v", f"{credentials_file}:/mysecrets/uwo_credentials:ro",
        "-v", f"{out_dir}:/data",
        "cfmm2tar",
        "-c", "/mysecrets/uwo_credentials",
        "-u", study_uid,
        "/data"
    ]

    print(f"Running Docker command for {sub_label} (Study UID: {study_uid}):")
    print(" ".join(docker_cmd))

    # Execute the command
    try:
        subprocess.run(docker_cmd, check=True)
    except subprocess.CalledProcessError as e:
        print(f"[ERROR] Docker command failed for {sub_label} (UID={study_uid}): {e}")
        return

    # Optional local cleanup: remove leftover *.attached.tar or *.uid in out_dir
    if do_cleanup:
        leftover_files = [
            f for f in os.listdir(out_dir)
            if f.endswith(".attached.tar") or f.endswith(".uid")
        ]
        for lf in leftover_files:
            full_path = os.path.join(out_dir, lf)
            try:
                os.remove(full_path)
                print(f"Removed leftover file: {full_path}")
            except OSError as e:
                print(f"[WARNING] Could not remove {full_path}: {e}")

    # Optionally collect metadata (e.g., age, sex) into a central JSON file
    if create_dicom_metadata:
        patient_sex = study.get("patient_sex", "")
        patient_age = study.get("patient_age", "")  # e.g. "065Y"
        numeric_age = None
        match = re.search(r"(\d+)", patient_age)
        if match:
            numeric_age = int(match.group(1))

        # Merge any existing metadata file into in-memory store
        if os.path.isfile(METADATA_FILE):
            try:
                with open(METADATA_FILE, "r") as f:
                    existing_data = json.load(f)
                    for k, v in existing_data.items():
                        _collected_metadata[k] = v
            except (json.JSONDecodeError, OSError) as e:
                print(f"[WARNING] Could not read/parse {METADATA_FILE}: {e}")

        # Update memory store with current subject's data
        _collected_metadata[sub_label] = {
            "age": numeric_age,
            "sex": patient_sex
        }

        # Ensure directory is created before writing
        metadata_dir = os.path.dirname(METADATA_FILE)
        os.makedirs(metadata_dir, exist_ok=True)

        def subject_number(label):
            """Extracts the integer portion from a subject label for sorting purposes.

            For example, "sub-010" becomes 10, "sub-2" becomes 2, and if no digits are found,
            a fallback value of 999999999 is returned to ensure such labels sort last.

            Args:
                label (str): The subject label, e.g. "sub-010" or "sub-002_baseline".

            Returns:
                int: The numeric portion of the subject label if digits are found, otherwise 999999999.
            """
            m = re.search(r"\d+", label)
            return int(m.group()) if m else 999999999

        # Gather subjects in ascending numeric order
        sorted_keys = sorted(_collected_metadata.keys(), key=subject_number)

        # Rebuild a sorted dictionary
        ordered_data = {k: _collected_metadata[k] for k in sorted_keys}

        # Write updated metadata in sorted order
        try:
            with open(METADATA_FILE, "w") as f:
                json.dump(ordered_data, f, indent=2)
        except OSError as e:
            print(f"[WARNING] Could not write to {METADATA_FILE}: {e}")

    print(f"Docker command completed for {sub_label}.\n")
