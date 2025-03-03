"""
dicom_query.py

Provides helper functions for constructing and running 'findscu'
commands in a Docker container and parsing the results.
"""

import subprocess
import re


def build_base_findscu_cmd(container, bind, server, port, tls, username, password, query_tags):
    """Constructs the base Docker command for dcm4che's findscu with specified query tags.

    Args:
        container (str): Name of the Docker container image (e.g. 'cfmm2tar').
        bind (str): Networking bind option for the container (e.g. 'DEFAULT').
        server (str): Server string, possibly "AET@hostname".
        port (str): DICOM server port.
        tls (str): TLS setting (e.g. 'aes', 'ssl', or 'none').
        username (str): Username for the DICOM server.
        password (str): Password for the DICOM server.
        query_tags (list): A list of DICOM attributes (e.g. ["PatientName"]).

    Returns:
        list: A list of command elements that can be passed to subprocess.
    """
    cmd = [
        "docker", "run",
        "--rm",
        "--entrypoint", "/opt/dcm4che/bin/findscu",
        container,
        "--bind", bind,
        "--connect", f"{server}:{port}",
        f"--tls-{tls}",
        "--user", username,
        "--user-pass", password,
        "-L", "STUDY"
    ]

    for tag_name in query_tags:
        cmd += ["-r", tag_name]
    return cmd


def build_findscu_for_description(container, bind, server, port, tls, username, password,
                                  study_description, query_tags):
    """Creates a command list to search for a study by StudyDescription.

    Args:
        container (str): Name of the Docker container image.
        bind (str): Networking bind option for the container.
        server (str): DICOM server string (e.g. 'CFMM@dicom.cfmm.uwo.ca').
        port (str): DICOM server port.
        tls (str): TLS setting for encryption.
        username (str): Username for the DICOM server.
        password (str): Password for the DICOM server.
        study_description (str): The StudyDescription to match.
        query_tags (list): A list of DICOM attributes to retrieve.

    Returns:
        list: Command list for subprocess to execute.
    """
    cmd = build_base_findscu_cmd(container, bind, server, port, tls, username, password, query_tags)
    if study_description:
        cmd += ["-m", f"StudyDescription={study_description}"]
    return cmd


def build_findscu_for_patient_name(container, bind, server, port, tls, username, password,
                                   patient_name, query_tags):
    """Creates a command list to search by a specific PatientName.

    Args:
        container (str): Name of the Docker container image.
        bind (str): Networking bind option for the container.
        server (str): DICOM server string.
        port (str): DICOM server port.
        tls (str): TLS setting for encryption.
        username (str): Username for the DICOM server.
        password (str): Password for the DICOM server.
        patient_name (str): The PatientName to match.
        query_tags (list): A list of DICOM attributes to retrieve.

    Returns:
        list: Command list for subprocess to execute.
    """
    cmd = build_base_findscu_cmd(container, bind, server, port, tls, username, password, query_tags)
    if patient_name:
        cmd += ["-m", f"PatientName={patient_name}"]
    return cmd


def build_findscu_for_all_studies(container, bind, server, port, tls, username, password,
                                  query_tags):
    """Creates a command list to search for all studies on the server.

    Args:
        container (str): Name of the Docker container image.
        bind (str): Networking bind option for the container.
        server (str): DICOM server string.
        port (str): DICOM server port.
        tls (str): TLS setting for encryption.
        username (str): Username for the DICOM server.
        password (str): Password for the DICOM server.
        query_tags (list): A list of DICOM attributes to retrieve.

    Returns:
        list: Command list for subprocess to execute.
    """
    cmd = build_base_findscu_cmd(container, bind, server, port, tls, username, password, query_tags)
    return cmd


def run_findscu(cmd, debug=False):
    """Runs the findscu command via subprocess and captures its output.

    Args:
        cmd (list): List of command elements for the findscu utility.
        debug (bool, optional): If True, prints debug statements.

    Returns:
        str or None: The standard output from the command, or None if an error occurred.
    """
    if debug:
        print("[DEBUG] Running command:", " ".join(cmd))

    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        if debug:
            print("[DEBUG] findscu encountered an error:\n", result.stderr)
        return None

    if debug:
        lines = result.stdout.splitlines()
        for i, line in enumerate(lines):
            print(f"[DEBUG] LINE {i}: {repr(line)}")
    return result.stdout


def parse_studies_with_demographics(output, tag_map):
    """Parses 'findscu' text output and maps recognized DICOM tags to a list of study dictionaries.

    This function looks for lines like:
        (0008,1030) LO [Study Description]
    and uses `tag_map` to know that (0008,1030), LO -> 'study_description'.

    Args:
        output (str): Text output from the findscu command.
        tag_map (dict): Maps attribute strings (e.g. 'PatientName') to a dict of:
            {
              "group_elem": "(0010,0010)",
              "vr": "PN",
              "field": "patient_name"
            }

    Returns:
        list of dict: Each dict contains keys such as 'patient_name', 'study_date', 'study_uid', etc.
    """
    reverse_map = {}
    for attr_name, info in tag_map.items():
        ge = info["group_elem"]
        vr = info["vr"]
        field_name = info["field"]
        reverse_map[(ge, vr)] = field_name

    # Initialize 'current' with None for each field
    current = {}
    for _, info in tag_map.items():
        current[info["field"]] = None

    studies = []
    lines = output.splitlines()

    for line in lines:
        match = re.search(r'^\(([\dA-Fa-f]{4},[\dA-Fa-f]{4})\)\s+(\S+)\s+\[(.*)\]', line)
        if match:
            group_elem_raw = match.group(1)
            vr = match.group(2)
            value = match.group(3)
            group_elem = f"({group_elem_raw})"

            if (group_elem, vr) in reverse_map:
                field_name = reverse_map[(group_elem, vr)]
                current[field_name] = value

        # status=ff00H or status=0H indicates end of a dataset item
        if "status=ff00H" in line or "status=0H" in line:
            if current.get("study_uid"):
                studies.append(dict(current))
            # Reset for the next dataset
            current = {}
            for _, info in tag_map.items():
                current[info["field"]] = None

    # If any leftover dictionary is populated
    if current.get("study_uid"):
        studies.append(dict(current))

    return studies