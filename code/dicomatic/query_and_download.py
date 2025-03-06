#!/usr/bin/env python3
"""
query_and_download.py

Provides a command-line interface for querying a DICOM server
and downloading the queried DICOM studies into a BIDS-like directory structure.

Supports three modes:
  1) Search by Study Description
  2) Search by Patient Name
  3) Match local BIDS subjects/sessions in sourcedata/dicom
"""

import os
import re
import subprocess
import tempfile
import atexit
from getpass import getpass

# External libraries
from ruamel.yaml import YAML

# Local modules
from dicom_query import (
    build_findscu_for_description,
    build_findscu_for_patient_name,
    build_findscu_for_all_studies,
    run_findscu,
    parse_studies_with_demographics
)
from download_dicom import download_dicom

# Global list to track temporary files for cleanup
_temp_files = []


@atexit.register
def cleanup_temp_files():
    """Removes any created temporary credential files on exit.

    Returns:
        None
    """
    for tfile in _temp_files:
        if os.path.exists(tfile):
            try:
                os.remove(tfile)
            except OSError:
                pass


def create_temp_credentials_file(username, password):
    """Creates a temporary file containing username/password for secure Docker binding.

    Args:
        username (str): The DICOM username.
        password (str): The DICOM password.

    Returns:
        str: The path to the temporary credentials file.
    """
    fd, path = tempfile.mkstemp(prefix="dicom_creds_", text=True)
    with os.fdopen(fd, 'w') as f:
        f.write(username + "\n" + password + "\n")
    _temp_files.append(path)
    return path


def get_credentials(script_dir, config, debug=False):
    """Retrieves credentials from a .secrets file if present/valid,
    otherwise falls back to values from `config.yaml` or prompts for
    credentials.

    Args:
        script_dir (str): The directory of the current script.
        config (dict): The loaded configuration dictionary.
        debug (bool, optional): If True, prints debug information. Defaults to False.

    Returns:
        tuple:
            - bool: Indicates whether the secrets file was used.
            - str: The username.
            - str: The password.
            - str or None: The path to the secrets file if used, otherwise None.
    """
    project_root = os.path.abspath(os.path.join(script_dir, "..", ".."))
    secrets_file = os.path.join(project_root, ".secrets", "uwo_credentials")

    username = config["dicom"]["username"]
    password = config["dicom"]["password"]
    use_secrets_file = False

    if os.path.isfile(secrets_file):
        if os.path.getsize(secrets_file) > 0:
            with open(secrets_file, "r") as f:
                lines = [l.strip() for l in f.readlines()]
            if len(lines) >= 2 and lines[0] and lines[1]:
                username = lines[0]
                password = lines[1]
                use_secrets_file = True
                if debug:
                    print(f"[DEBUG] Using credentials from {secrets_file}")
                    print(f"[DEBUG] username={username}, password=******")
            else:
                if debug:
                    print("[DEBUG] .secrets/uwo_credentials is invalid or incomplete.")
        else:
            if debug:
                print("[DEBUG] .secrets/uwo_credentials is empty.")
    else:
        if debug:
            print("[DEBUG] .secrets/uwo_credentials not found.")

    if not use_secrets_file:
        if username == "YOUR_USERNAME":
            username = input("\nEnter DICOM username: ")
        if password == "YOUR_PASSWORD":
            password = getpass("Enter DICOM password: ")
        if debug:
            print("[DEBUG] Using credentials from config.yaml or prompted input.")
            print(f"[DEBUG] username={username}, password=******")

    if use_secrets_file:
        return True, username, password, secrets_file
    return False, username, password, None


def prompt_for_server_info(dicom_config, debug=False):
    """Prompts the for server/port/tls if not set in dicom_config.

    Args:
        dicom_config (dict): Dictionary containing keys 'server', 'port', 'tls'.
        debug (bool, optional): If True, prints debug information. Defaults to False.

    Returns:
        bool: True if any server settings were updated, False otherwise.
    """
    changed = False

    if not dicom_config.get("server"):
        dicom_config["server"] = input("Enter DICOM server (host or AET@host): ").strip()
        changed = True

    if not dicom_config.get("port"):
        dicom_config["port"] = input("Enter DICOM port: ").strip()
        changed = True

    if not dicom_config.get("tls"):
        dicom_config["tls"] = input("Enter DICOM TLS method (e.g. aes, ssl, or none): ").strip()
        changed = True

    if debug and changed:
        print(f"[DEBUG] Updated server settings -> server={dicom_config['server']}, "
              f"port={dicom_config['port']}, tls={dicom_config['tls']}")

    return changed


def maybe_save_new_server_settings(config, config_path, changed_server_settings, query_was_successful):
    """Optionally persists new server settings to config.yaml if selected,
    given that a query was successful.

    Args:
        config (dict): Configuration dictionary (modified in-memory).
        config_path (str): Path to the `config.yaml` file.
        changed_server_settings (bool): Whether any server settings were updated this run.
        query_was_successful (bool): Whether the query was successful.

    Returns:
        None
    """
    if not changed_server_settings:
        return
    if not query_was_successful:
        print("Query was not successful; server settings will not be saved.")
        return
    if not config.get("persist_server_settings", False):
        return

    while True:
        choice = input("Save new server/port/tls to config.yaml? (y/n): ").strip().lower()
        if choice in ("y", "n"):
            break
        print("Please enter 'y' or 'n'.")

    if choice == "y":
        ruamel_yaml = YAML()
        ruamel_yaml.preserve_quotes = True

        with open(config_path, "r") as f:
            original_data = ruamel_yaml.load(f)

        original_data["dicom"]["server"] = config["dicom"]["server"]
        original_data["dicom"]["port"] = config["dicom"]["port"]
        original_data["dicom"]["tls"] = config["dicom"]["tls"]

        with open(config_path, "w") as f:
            ruamel_yaml.dump(original_data, f)

        print("[INFO] New server settings have been saved to config.yaml.")
    else:
        print("[INFO] Server settings changes were not saved.")


def parse_subject_digits(dicom_patient_name):
    """Parses the subject digits from a DICOM patient name.

    For example, '2023_08_22_001_baseline' -> 'sub-001'.

    Args:
        dicom_patient_name (str): The patient name from the DICOM record.

    Returns:
        str or None: A string with the format 'sub-XXX' if found, otherwise None.
    """
    pattern = r'^(?:\d{4}_\d{2}_\d{2}_)?(?:[A-Za-z]*-?)?(\d+)(?:_.*)?$'
    match = re.match(pattern, dicom_patient_name)
    if not match:
        return None
    digits = match.group(1)
    if not digits:
        return None
    return f"sub-{digits}"


def parse_trailing_substring(dicom_patient_name):
    """Extracts the trailing substring of a DICOM patient name.

    For example, '2023_08_22_001_baseline' -> 'baseline'.

    Args:
        dicom_patient_name (str): The patient name from the DICOM record.

    Returns:
        str or None: The trailing substring if available, otherwise None.
    """
    pattern = r'^(?:\d{4}_\d{2}_\d{2}_)?(?:[A-Za-z]*-?)?\d+(?:_(.*))?$'
    match = re.match(pattern, dicom_patient_name)
    if not match:
        return None
    return match.group(1)


def find_session_label(sub_label, trailing, session_map=None):
    """Determines session label (e.g. 'ses-01') given a subject label and trailing substring.

    Checks an optional session_map first (e.g., 'baseline': '01').

    Args:
        sub_label (str): The subject label (e.g. 'sub-001').
        trailing (str): The trailing substring parsed from the patient name.
        session_map (dict, optional): A map of known trailing strings to session numbers.

    Returns:
        str or None: The session label (e.g. 'ses-01'), or None if not found.
    """
    if not sub_label or not trailing:
        return None

    if session_map:
        key = trailing.lower().strip()
        mapped_val = session_map.get(key)
        if mapped_val:
            if not mapped_val.startswith("ses-"):
                return f"ses-{mapped_val}"
            return mapped_val
    return None


def prompt_yes_no(question):
    """Prompts for a yes/no response.

    Args:
        question (str): The question to display (e.g., "Do you want to continue? (y/n): ").

    Returns:
        str: 'y' or 'n' based on input.
    """
    while True:
        ans = input(question).strip().lower()
        if ans in ['y', 'n']:
            return ans
        print("Please enter 'y' or 'n'.")


def list_subject_folders(bids_root):
    """Searches for sub-* folders in a BIDS root directory and records associated ses-* folders.

    Args:
        bids_root (str): Path to the BIDS root directory.

    Returns:
        dict: A dictionary where keys are subject folder names (e.g. 'sub-001')
              and values are lists of session folder names (e.g. ['ses-01', 'ses-02']).
    """
    subjects_dict = {}
    if not os.path.isdir(bids_root):
        return subjects_dict

    for sub_name in os.listdir(bids_root):
        if not sub_name.startswith("sub-"):
            continue
        sub_path = os.path.join(bids_root, sub_name)
        if not os.path.isdir(sub_path):
            continue

        sessions = []
        for ses_name in os.listdir(sub_path):
            if ses_name.startswith("ses-"):
                ses_path = os.path.join(sub_path, ses_name)
                if os.path.isdir(ses_path):
                    sessions.append(ses_name)

        subjects_dict[sub_name] = sessions

    return subjects_dict


def print_studies_info(studies, show_mapping=False):
    """Prints a list of DICOM studies with optional subject/session mapping.

    Args:
        studies (list of dict): A list of study dictionaries to display.
        show_mapping (bool, optional): If True, prints mapping info like sub-label, ses-label.
    """
    for i, st in enumerate(studies, start=1):
        print(f"--- Study #{i} ---")
        print(f"  Study Date:        {st['study_date']}")
        print(f"  Patient Name:      {st['patient_name']}")
        print(f"  Patient ID:        {st['patient_id']}")
        print(f"  Study Description: {st['study_description']}")
        print(f"  Patient Sex:       {st['patient_sex']}")
        print(f"  Patient Age:       {st['patient_age']}")
        print(f"  StudyInstanceUID:  {st['study_uid']}")
        print("")


def run_dicom_download_command(study,
                               credentials_file,
                               do_cleanup=False,
                               check_existing_archives=False,
                               create_dicom_metadata=False):
    """Runs the Docker-based download command for a single DICOM study.

    Args:
        study (dict): A dictionary containing study information (including 'sub_label',
                      'ses_label', 'out_dir', etc.).
        credentials_file (str): The path to the credentials file.
        do_cleanup (bool, optional): If True, leftover files (e.g. .attached.tar) are removed.
        check_existing_archives (bool, optional): If True, checks for existing archives
            in out_dir before downloading.
        create_dicom_metadata (bool, optional): If True, writes basic metadata (age/sex)
            into dicom_metadata.json.

    Returns:
        None
    """
    sub_label = study["sub_label"]
    ses_label = study["ses_label"]
    out_dir = study["out_dir"]

    print(f"Subject:    {sub_label}   | Session: {ses_label}")
    print("--------------------------------------------------")

    # Check for existing archives
    if check_existing_archives and os.path.isdir(out_dir):
        archives = [f for f in os.listdir(out_dir)
                    if f.lower().endswith((".zip", ".tar", ".tar.gz", ".tgz"))]
        if archives:
            cap_sub_str = f"Sub-{sub_label[4:]}" if sub_label.startswith("sub-") else sub_label
            skip_combo_str = f"{cap_sub_str}_{ses_label}"
            print(f"WARNING: {skip_combo_str} has existing archives in {out_dir}")
            print(f"Skipping {skip_combo_str}.\n")
            return

    # Actually run the Docker download (subprocess) via download_dicom(...)
    download_dicom(
        study,
        credentials_file,
        do_cleanup=do_cleanup,
        create_dicom_metadata=create_dicom_metadata
    )


def main():
    """Main entry point for the DICOM Query & Download tool.

    Provides a menu-driven interface for various query modes:
      1) By StudyDescription
      2) By PatientName
      3) By local BIDS subjects in /sourcedata/dicom

    Returns:
        None
    """
    script_dir = os.path.dirname(__file__)
    config_path = os.path.join(script_dir, "config.yaml")

    print("\n[==== DICOMATIC - DICOM Query & Download ====]")
    print("        A DICOM Query & Download Tool")

    ruamel_yaml = YAML()
    ruamel_yaml.preserve_quotes = True

    with open(config_path, "r") as f:
        config = ruamel_yaml.load(f)

    debug = False  # Set to True for verbose logs

    # 1) Credentials
    use_secrets_file, username, password, secrets_file_path = get_credentials(script_dir, config, debug=debug)
    config["dicom"]["username"] = username
    config["dicom"]["password"] = password

    # 2) Server info
    dicom_config = config["dicom"]
    changed_server_settings = prompt_for_server_info(dicom_config, debug=debug)

    # 3) Create temp credentials file if needed
    if use_secrets_file:
        credentials_file = secrets_file_path
    else:
        credentials_file = create_temp_credentials_file(username, password)
        if debug:
            print(f"[DEBUG] Created temporary credentials file: {credentials_file}")

    session_map = config.get("session_map", {})
    query_tags = config["dicom_query_tags"]
    tag_map = config["dicom_tag_map"]
    create_dicom_metadata = config.get("create_dicom_metadata", False)

    # Menu selection
    while True:
        print("\nWhich query+download mode do you want?")
        print(" 1) By StudyDescription (list multiple studies)")
        print(" 2) By PatientName (search for a specific participant)")
        print(" 3) By local BIDS subjects in /sourcedata/dicom\n")
        choice = input("Enter 1, 2, or 3.\n> ").strip()
        if choice in ("1", "2", "3"):
            break
        print("Invalid choice. Please enter '1', '2', or '3'.")

    query_was_successful = False

    # ============================
    # MODE 1: By StudyDescription
    # ============================
    if choice == "1":
        study_desc = config.get("study_params", {}).get("study_description", "").strip()
        if not study_desc:
            study_desc = input("Enter StudyDescription to search for: ").strip()
            if not study_desc:
                print("No StudyDescription provided. Exiting.")
                maybe_save_new_server_settings(config, config_path, changed_server_settings, False)
                return

        cmd = build_findscu_for_description(
            container=dicom_config["container"],
            bind=dicom_config["bind"],
            server=dicom_config["server"],
            port=dicom_config["port"],
            tls=dicom_config["tls"],
            username=dicom_config["username"],
            password=dicom_config["password"],
            study_description=study_desc,
            query_tags=query_tags
        )
        output = run_findscu(cmd, debug=False)
        if not output:
            print("No output from findscu. Exiting.")
            maybe_save_new_server_settings(config, config_path, changed_server_settings, False)
            return

        studies = parse_studies_with_demographics(output, tag_map)
        if not studies:
            print(f"No studies found with StudyDescription='{study_desc}'.")
            maybe_save_new_server_settings(config, config_path, changed_server_settings, False)
            return

        query_was_successful = True
        print(f"\nFound {len(studies)} studies with description '{study_desc}':")

        def date_to_int(d):
            return int(d) if (d and d.isdigit()) else 0

        studies.sort(key=lambda st: date_to_int(st["study_date"]))
        print_studies_info(studies, show_mapping=False)

        download_prompt = prompt_yes_no("Would you like to download these studies now? (y/n): ")
        if download_prompt == "n":
            print("No downloads selected. Exiting.\n")
            maybe_save_new_server_settings(config, config_path, changed_server_settings, True)
            return

        print("Select studies by number, exact patient name, or StudyInstanceUID (space separated).")
        user_line = input("> ").strip()
        if not user_line:
            print("No studies selected. Exiting.")
            maybe_save_new_server_settings(config, config_path, changed_server_settings, True)
            return

        index_map = {}
        name_map = {}
        uid_map = {}
        for idx, st in enumerate(studies, start=1):
            index_map[idx] = st
            pname = st["patient_name"]
            uid = st["study_uid"]
            name_map.setdefault(pname, []).append(idx)
            uid_map[uid] = idx

        matched_indices = set()
        tokens = user_line.split()
        for token in tokens:
            # Try integer index
            try:
                num = int(token)
                if 1 <= num <= len(studies):
                    matched_indices.add(num)
                else:
                    print(f"  [WARNING] No study with index {num}. Skipping.")
                continue
            except ValueError:
                pass

            # Check name
            if token in name_map:
                for iidx in name_map[token]:
                    matched_indices.add(iidx)
                continue

            # Check UID
            if token in uid_map:
                matched_indices.add(uid_map[token])
                continue

            print(f"  [WARNING] No match for '{token}'. Skipping.")

        if not matched_indices:
            print("No valid matches found. Exiting.")
            maybe_save_new_server_settings(config, config_path, changed_server_settings, True)
            return

        selected_studies = [index_map[i] for i in sorted(matched_indices)]

        # Group by subject to assign sessions
        def group_studies_by_subject(studies_list):
            grouped = {}
            for s in studies_list:
                sname = s["patient_name"]
                sub_label = parse_subject_digits(sname) or "sub-unknown"
                s.setdefault("sub_label", sub_label)
                grouped.setdefault(sub_label, []).append(s)
            return grouped

        grouped = group_studies_by_subject(selected_studies)
        for sub, stlist in grouped.items():
            stlist.sort(key=lambda x: date_to_int(x["study_date"]))
            ses_counter = 1
            for s in stlist:
                trailing = parse_trailing_substring(s["patient_name"])
                maybe_ses = find_session_label(sub, trailing, session_map=session_map)
                if maybe_ses is None:
                    maybe_ses = f"ses-{ses_counter:02d}"
                    ses_counter += 1
                s["ses_label"] = maybe_ses

        # Setup output directory
        project_root = os.path.abspath(os.path.join(script_dir, "..", ".."))
        tar_dir = os.path.join(project_root, "sourcedata", "tar")
        os.makedirs(tar_dir, exist_ok=True)

        print("\n============== RUNNING DICOMATIC DOCKER COMMANDS  ==============\n")

        for s in selected_studies:
            s["out_dir"] = tar_dir
            run_dicom_download_command(
                s,
                credentials_file,
                do_cleanup=False,
                check_existing_archives=False,
                create_dicom_metadata=create_dicom_metadata
            )

        print("All docker operations have been completed.\n")
        maybe_save_new_server_settings(config, config_path, changed_server_settings, True)

    # ========================
    # MODE 2: By PatientName
    # ========================
    elif choice == "2":
        patient_name = config.get("study_params", {}).get("patient_name", "").strip()
        if not patient_name:
            patient_name = input("Enter PatientName to search for: ").strip()
            if not patient_name:
                print("No PatientName provided. Exiting.")
                maybe_save_new_server_settings(config, config_path, changed_server_settings, False)
                return

        cmd = build_findscu_for_patient_name(
            container=dicom_config["container"],
            bind=dicom_config["bind"],
            server=dicom_config["server"],
            port=dicom_config["port"],
            tls=dicom_config["tls"],
            username=dicom_config["username"],
            password=dicom_config["password"],
            patient_name=patient_name,
            query_tags=query_tags
        )
        output = run_findscu(cmd, debug=False)
        if not output:
            print("No output from findscu. Exiting.")
            maybe_save_new_server_settings(config, config_path, changed_server_settings, False)
            return

        studies = parse_studies_with_demographics(output, tag_map)
        if not studies:
            print(f"No studies found for PatientName='{patient_name}'.")
            maybe_save_new_server_settings(config, config_path, changed_server_settings, False)
            return

        query_was_successful = True
        print(f"\nFound {len(studies)} studies for PatientName '{patient_name}':")

        def date_to_int(d):
            return int(d) if (d and d.isdigit()) else 0

        studies.sort(key=lambda st: date_to_int(st["study_date"]))
        print_studies_info(studies, show_mapping=False)

        download_prompt = prompt_yes_no("Download ALL these studies now? (y/n): ")
        if download_prompt == "n":
            print("No downloads selected. Exiting.\n")
            maybe_save_new_server_settings(config, config_path, changed_server_settings, True)
            return

        # Group by subject
        def group_studies_by_subject(studies_list):
            grouped = {}
            for s in studies_list:
                sname = s["patient_name"]
                sub_label = parse_subject_digits(sname) or "sub-unknown"
                s.setdefault("sub_label", sub_label)
                grouped.setdefault(sub_label, []).append(s)
            return grouped

        grouped = group_studies_by_subject(studies)
        for sub, stlist in grouped.items():
            stlist.sort(key=lambda x: date_to_int(x["study_date"]))
            ses_counter = 1
            for s in stlist:
                trailing = parse_trailing_substring(s["patient_name"])
                maybe_ses = find_session_label(sub, trailing, session_map=session_map)
                if maybe_ses is None:
                    maybe_ses = f"ses-{ses_counter:02d}"
                    ses_counter += 1
                s["ses_label"] = maybe_ses

        project_root = os.path.abspath(os.path.join(script_dir, "..", ".."))
        tar_dir = os.path.join(project_root, "sourcedata", "tar")
        os.makedirs(tar_dir, exist_ok=True)

        print("\n============== RUNNING DICOMATIC DOCKER COMMANDS  ==============\n")
        for s in studies:
            s["out_dir"] = tar_dir
            run_dicom_download_command(
                s,
                credentials_file,
                do_cleanup=False,
                check_existing_archives=False,
                create_dicom_metadata=create_dicom_metadata
            )

        print("All docker operations have been completed.\n")
        maybe_save_new_server_settings(config, config_path, changed_server_settings, True)

    # ==========================================
    # MODE 3: By local BIDS subjects in Dicom/
    # ==========================================
    elif choice == "3":
        project_root = os.path.abspath(os.path.join(script_dir, "..", ".."))
        bids_root = os.path.join(project_root, "sourcedata", "dicom")
        print(f"[INFO] Searching for sub-* folders in: {bids_root}")

        subjects_dict = list_subject_folders(bids_root)
        if not subjects_dict:
            print(f"No sub-* folders found in {bids_root}. Exiting.")
            maybe_save_new_server_settings(config, config_path, changed_server_settings, False)
            return

        cmd = build_findscu_for_all_studies(
            container=dicom_config["container"],
            bind=dicom_config["bind"],
            server=dicom_config["server"],
            port=dicom_config["port"],
            tls=dicom_config["tls"],
            username=dicom_config["username"],
            password=dicom_config["password"],
            query_tags=query_tags
        )
        output = run_findscu(cmd, debug=False)
        if not output:
            maybe_save_new_server_settings(config, config_path, changed_server_settings, False)
            return

        all_studies = parse_studies_with_demographics(output, tag_map)
        if not all_studies:
            print("No studies found in DICOM query.")
            maybe_save_new_server_settings(config, config_path, changed_server_settings, False)
            return

        query_was_successful = True
        matched_studies = []
        for st in all_studies:
            dicom_name = st["patient_name"]
            sub_label = parse_subject_digits(dicom_name)
            if not sub_label:
                continue
            if sub_label not in subjects_dict:
                continue

            trailing = parse_trailing_substring(dicom_name)
            session_label = find_session_label(sub_label, trailing, session_map=session_map)
            if session_label is None:
                # Fallback: if trailing is exactly 'ses-XXX'
                possible_ses_list = subjects_dict[sub_label]
                trailing_lower = trailing.lower().strip() if trailing else ""
                if trailing_lower in possible_ses_list:
                    session_label = trailing_lower
                else:
                    continue

            if session_label not in subjects_dict[sub_label]:
                continue

            st["sub_label"] = sub_label
            st["ses_label"] = session_label
            out_dir = os.path.join(bids_root, sub_label, session_label)
            st["out_dir"] = out_dir
            matched_studies.append(st)

        studies = matched_studies
        print(f"\nFound {len(studies)} studies matching local BIDS subjects/sessions.")

        def date_to_int(d):
            return int(d) if (d and d.isdigit()) else 0
        studies.sort(key=lambda st: date_to_int(st["study_date"]))

        print_studies_info(studies, show_mapping=True)

        if not studies:
            maybe_save_new_server_settings(config, config_path, changed_server_settings, False)
            return

        query_was_successful = True
        subject_dict = {}
        for st in studies:
            subj = st["sub_label"]
            sess = st["ses_label"]
            subject_dict.setdefault(subj, {})[sess] = st

        print("\nThe following subjects and sessions are available:\n")

        def sub_numeric_key(s):
            try:
                return int(s.replace("sub-", ""))
            except ValueError:
                return 999999

        def ses_numeric_key(s):
            try:
                return int(s.replace("ses-", ""))
            except ValueError:
                return 999999

        for subj in sorted(subject_dict.keys(), key=sub_numeric_key):
            print(f"--- Subject: {subj} ---")
            print("Sessions:")
            sorted_ses = sorted(subject_dict[subj].keys(), key=ses_numeric_key)
            for ses in sorted_ses:
                print(f"  • {subject_dict[subj][ses]['out_dir']}")
            print("")

        print("Please specify how to filter studies to download:")
        print(" • If only session labels are entered (e.g., 'ses-01 ses-02'),")
        print("   those sessions will be downloaded for every subject.")
        print(" • If only subject labels are entered (e.g., 'sub-001 sub-002'),")
        print("   a follow-up prompt for session selection will appear.")
        print(" • If both subjects and sessions are entered (e.g. 'sub-001 ses-01'),")
        print("   only those exact subject-session matches will be included.")
        print(" • Or press Enter to download all available subjects and sessions.\n")
        user_line = input("> ").strip()

        do_cleanup = bool(config.get("cfmm2tar_attached_tar", False))

        # (A) Pressed Enter => all subjects, all sessions
        if user_line == "":
            print("\n============== RUNNING DICOMATIC DOCKER COMMANDS  ==============\n")
            for subj in sorted(subject_dict.keys(), key=sub_numeric_key):
                ses_keys = sorted(subject_dict[subj].keys(), key=ses_numeric_key)
                for ses in ses_keys:
                    st = subject_dict[subj][ses]
                    run_dicom_download_command(
                        st,
                        credentials_file,
                        do_cleanup=do_cleanup,
                        check_existing_archives=True,
                        create_dicom_metadata=create_dicom_metadata
                    )
            print("\nAll docker operations have been completed.\n")
            maybe_save_new_server_settings(config, config_path, changed_server_settings, True)
            return

        tokens = user_line.split()
        recognized_subs = [t for t in tokens if t in subject_dict]

        all_ses_keys = set()
        for sbj in subject_dict:
            all_ses_keys.update(subject_dict[sbj].keys())
        recognized_ses = [t for t in tokens if t in all_ses_keys]

        # (B) Only sessions => apply to all subjects
        if not recognized_subs and recognized_ses:
            print("\n============== RUNNING DICOMATIC DOCKER COMMANDS  ==============\n")
            for subj in sorted(subject_dict.keys(), key=sub_numeric_key):
                ses_keys = sorted(subject_dict[subj].keys(), key=ses_numeric_key)
                for ses in ses_keys:
                    if ses in recognized_ses:
                        st = subject_dict[subj][ses]
                        run_dicom_download_command(
                            st,
                            credentials_file,
                            do_cleanup=do_cleanup,
                            check_existing_archives=True,
                            create_dicom_metadata=create_dicom_metadata
                        )
            print("\nAll docker operations have been completed.\n")
            maybe_save_new_server_settings(config, config_path, changed_server_settings, True)
            return

        # (C) Only subjects => prompt for each subject's sessions
        if recognized_subs and not recognized_ses:
            # Collect session inputs for each recognized subject
            session_map_input = {}
            for subj in recognized_subs:
                if subj not in subject_dict:
                    print(f"{subj} not found in matched studies. Skipping.\n")
                    continue
                ses_keys = sorted(subject_dict[subj].keys(), key=ses_numeric_key)

                print(f"Enter sessions to download for {subj} (space-separated), or press Enter for all:")
                user_sessions_line = input("> ").strip()
                session_map_input[subj] = user_sessions_line

            print("\n============== RUNNING DICOMATIC DOCKER COMMANDS  ==============\n")
            for subj in recognized_subs:
                if subj not in subject_dict:
                    continue
                user_sessions_line = session_map_input[subj]
                ses_keys = sorted(subject_dict[subj].keys(), key=ses_numeric_key)
                if user_sessions_line == "":
                    for ses in ses_keys:
                        st = subject_dict[subj][ses]
                        run_dicom_download_command(
                            st,
                            credentials_file,
                            do_cleanup=do_cleanup,
                            check_existing_archives=True,
                            create_dicom_metadata=create_dicom_metadata
                        )
                else:
                    chosen_ses = user_sessions_line.split()
                    for ses in chosen_ses:
                        if ses not in subject_dict[subj]:
                            print(f"  Session {ses} not found for {subj}. Skipping.\n")
                            continue
                        st = subject_dict[subj][ses]
                        run_dicom_download_command(
                            st,
                            credentials_file,
                            do_cleanup=do_cleanup,
                            check_existing_archives=True,
                            create_dicom_metadata=create_dicom_metadata
                        )
            print("\nAll docker operations have been completed.\n")
            maybe_save_new_server_settings(config, config_path, changed_server_settings, True)
            return

        # (D) Both subjects and sessions
        if recognized_subs and recognized_ses:
            print("\n============== RUNNING DICOMATIC DOCKER COMMANDS  ==============\n")
            for subj in recognized_subs:
                if subj not in subject_dict:
                    print(f"{subj} not found in matched studies. Skipping.\n")
                    continue
                for ses in recognized_ses:
                    if ses not in subject_dict[subj]:
                        print(f"  Session {ses} not found for {subj}. Skipping.\n")
                        continue
                    st = subject_dict[subj][ses]
                    run_dicom_download_command(
                        st,
                        credentials_file,
                        do_cleanup=do_cleanup,
                        check_existing_archives=True,
                        create_dicom_metadata=create_dicom_metadata
                    )
            print("\nAll docker operations have been completed.\n")
            maybe_save_new_server_settings(config, config_path, changed_server_settings, True)
            return

        print("No recognized subjects or sessions found. Exiting.")
        maybe_save_new_server_settings(config, config_path, changed_server_settings, True)


if __name__ == "__main__":
    main()
