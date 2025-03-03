# DICOMATIC: A DICOM Query & Download Tool

**DICOMATIC** is a lightweight Python-based command-line utility designed to query a DICOM server (e.g., CFMM at Western) and download DICOM studies inside a BIDS directory structure in /sourcecode. It uses the [**cfmm2tar**](https://github.com/khanlab/cfmm2tar) Docker image to do the actual downloading.

---

## Table of Contents

1. [Project Structure](#project-structure)  
2. [Prerequisites](#prerequisites)  
3. [Installing & Building `cfmm2tar`](#installing--building-cfmm2tar)  
4. [Installation of Python Dependencies](#installation-of-python-dependencies)  
5. [Configuration](#configuration)  
   - [Session Maps](#session-maps)
6. [Usage](#usage)  
7. [Example Session](#example-session)  
8. [Troubleshooting](#troubleshooting)

---

## Project Structure

A typical folder layout for this project:

<pre lang="markdown">
BIDS-YourProject/
├── code/
│   ├── design_files/
│   └── dicomatic/                     <-- Main code folder
│       ├── config.yaml               <-- Main configuration
│       ├── dicom_query.py
│       ├── download_dicom.py
│       ├── query_and_download.py     <-- Entry point script
│       ├── requirements.txt
│       └── README.md                 <-- Documentation for this folder
└── sourcedata/
    ├── Dicom/                       
    └── Tar/                          
</pre>

- **query_and_download.py** is the primary script to run.
- **config.yaml** holds your DICOM server parameters and user settings.
- **requirements.txt** lists Python dependencies (e.g., `ruamel.yaml`).

---

## Prerequisites

1. **Python 3.7+** (preferably 3.9+).  
2. **Docker** installed and running.  
3. Network access (e.g., to CFMM’s DICOM server) and valid credentials.

---

## Installing & Building `cfmm2tar`

1. **Install Docker** if you haven’t already.  
2. **Clone** the [**cfmm2tar** repository](https://github.com/khanlab/cfmm2tar):
   ```bash
   git clone https://github.com/khanlab/cfmm2tar
   cd cfmm2tar
   ```
3.	Build the image:
   ```bash
  docker build -t cfmm2tar .
   ```
4.	Test by running:
   ```bash
  docker run --rm -i -t cfmm2tar
   ```
You should see help text for cfmm2tar.

---

## Installation of Python Dependencies

From your dicomatic folder:
   ```bash
   python3 -m venv .venv
   source .venv/bin/activate
   pip install -r requirements.txt 
   ```
---
## Configuration

Open config.yaml and adjust fields under dicom: for your server details and credentials. For example:
   ```yaml
  dicom:
    container: "cfmm2tar"
    bind: "DEFAULT"
    server: "CFMM@dicom.cfmm.uwo.ca"
    port: "11112"
    tls: "aes"
    username: "YOUR_USERNAME"
    password: "YOUR_PASSWORD"  # If left as "YOUR_PASSWORD", the script will prompt at runtime
  ```
If you do not want to store credentials in config.yaml, you can create a .secrets/uwo_credentials file in the project root (two lines: username + password). The script automatically detects and uses it if valid.

### Session Maps

If you want to automatically map trailing substrings in a DICOM Patient Name to session labels, add or modify the session_map section in config.yaml. For example:
   ```yaml
   session_map:
    baseline: "01"
    endpoint: "02"
  ```
Then, if your DICOM Patient Name ends in _baseline, DICOMATIC will label the session as ses-01. If it ends in _endpoint, it becomes ses-02. Adjust these mappings as needed.

---
## Usage
   ```bash
   python3 query_and_download.py
   ```

A menu will appear prompting you to choose one of three modes:
1. **By Study Description**  
     Prompts for a `StudyDescription` (e.g. “fMRI_Study1”) and queries the DICOM server.
2. **By Patient Name**  
   Prompts for a single `PatientName` (e.g. “2025_01_01_001_baseline”).
3. **By Local BIDS Folder**  
   Scans `sourcedata/Dicom/sub-*/ses-*` and checks the server for matches to download.

After DICOMATIC retrieves a list of studies, it offers to download them. The actual download uses cfmm2tar behind the scenes and creates .tar archives in either sourcedata/Tar/ (modes 1 & 2) or directly in each session folder (mode 3).

---
## Example Session
   ```bash
   cd /path/to/BIDS-YourProject/code/dicomatic
  python3 query_and_download.py

  [==== DICOMATIC - DICOM Query & Download ====]
          A DICOM Query & Download Tool

  Enter DICOM username: myusername
  Enter DICOM password: ******

  Which query+download mode do you want?
  1) By StudyDescription
  2) By PatientName
  3) By local BIDS subjects in /sourcedata/Dicom
  > 3

  [INFO] Searching for sub-* folders in: /path/to/BIDS-YourProject/sourcedata/Dicom
  Found X studies matching local BIDS subjects/sessions.
  ...
   ```
You can then filter the studies to download by typing session labels, subject labels, or pressing Enter to download all.

---
## Troubleshooting
- **Docker Errors**  
     Occasionally, you might see a non-zero exit status because of leftover intermediate files. If the .tar was created successfully, you can generally ignore the warning.

- **Credential Prompts**  
     If you’re repeatedly prompted for credentials, ensure that either:
    - 	You’ve updated config.yaml with your correct username / password, or
    - You’ve placed a .secrets/uwo_credentials file in the project root with valid credentials.

- **No Studies Found**  
     Verify your search parameters (StudyDescription, PatientName) or confirm you’re pointing to the correct DICOM server and have permission.
- **Metadata JSON**  
    If create_dicom_metadata is set to true in config.yaml, a minimal dicom_metadata.json is generated under sourcedata/dicom. You can disable this by setting it to false.
---
For more details on cfmm2tar, visit the [**GitHub repo.**](https://github.com/khanlab/cfmm2tar)