# Python File Upload Test Scripts

This directory contains Python scripts for testing file uploads to your Go-based Azure Blob Storage upload server. You can use these scripts to simulate continuous or parallel uploads for load testing, performance benchmarking, or functional validation.

## Scripts

### `one-uploadfile.py`

- **Purpose:** Continuously uploads a single file to the server in a loop.
- **Usage Example:**
  ```sh
  python one-uploadfile.py --url http://localhost:8080/upload --file ./test1.zip --delay 1
  ```
- **Arguments:**
  - `--url`: The upload endpoint (default: `http://localhost:8080/upload`)
  - `--file`: Path to the file to upload (**required**)
  - `--delay`: Delay (in seconds) between uploads (default: `1.0`)
  - `--quiet`: Minimize output

### `uploadfile.py`

- **Purpose:** Continuously uploads multiple files in parallel using a thread pool.
- **Usage Example:**
  ```sh
  python uploadfile.py --url http://localhost:8080/upload --files ./test1.zip ./test2.zip ./test3.zip --threads 4 --delay 1
  ```
- **Arguments:**
  - `--url`: The upload endpoint (default: `http://localhost:8080/upload`)
  - `--files`: Space-separated list of file paths to upload (**required**)
  - `--threads`: Number of parallel upload threads (default: `4`)
  - `--delay`: Delay (in seconds) between upload rounds (default: `1.0`)
  - `--quiet`: Minimize output

## Features

- Shows upload speed and statistics.
- Retries failed uploads (for `one-uploadfile.py`).
- Graceful shutdown with Ctrl+C.
- Useful for stress-testing your upload server and Azure Blob integration.

## Requirements

- Python 3.6+
- `requests` library (`pip install requests`)

## Example: Upload All Test Files in Parallel

```sh
python uploadfile.py --url http://localhost:8080/upload --files ./test1.zip ./test2.zip ./test3.zip ./test4.zip --threads 4
```

## Example: Continuous Single File Upload

```sh
python one-uploadfile.py --url http://localhost:8080/upload --file ./test1.zip --delay 2
```

---

**Note:**  
- Adjust the `--url` parameter if your server is running on a different host or port.
- For Kubernetes/Ingress testing, use the external URL (e.g., `http://fileupload.127.0.0.1.nip.io/upload`).

---
```# Python File Upload Test Scripts

This directory contains Python scripts for testing file uploads to your Go-based Azure Blob Storage upload server. You can use these scripts to simulate continuous or parallel uploads for load testing, performance benchmarking, or functional validation.

## Scripts

### `one-uploadfile.py`

- **Purpose:** Continuously uploads a single file to the server in a loop.
- **Usage Example:**
  ```sh
  python one-uploadfile.py --url http://localhost:8080/upload --file ./test1.zip --delay 1
  ```
- **Arguments:**
  - `--url`: The upload endpoint (default: `http://localhost:8080/upload`)
  - `--file`: Path to the file to upload (**required**)
  - `--delay`: Delay (in seconds) between uploads (default: `1.0`)
  - `--quiet`: Minimize output

# Python File Upload Utility

This script allows you to upload multiple files to a server endpoint in parallel, supporting various ways to specify files and custom SSL certificates.

## Usage

```sh
python uploadfile.py [options]
```

### Options

- `-h, --help`           Show this help message and exit
- `--url URL`            **(Required)** Upload URL (e.g., http://localhost:8080/upload)
- `--files [FILES ...]`  Paths to the files to upload (space separated)
- `--dir DIR`            Directory to upload all files from
- `--filelist FILELIST`  Text file with one file path per line
- `--glob GLOB`          Glob pattern for files (e.g. "*.zip")
- `--delay DELAY`        Delay between upload rounds in seconds (default: 1.0)
- `--quiet`              Minimize output
- `--threads THREADS`    Number of parallel upload threads (default: 4)
- `--cert CERT`          Path to custom CA certificate file (PEM) for HTTPS

## Examples

**Upload all `.zip` files in a directory with 10 threads:**
```sh
python uploadfile.py --url http://localhost:8080/upload --dir ./myfiles --glob "*.zip" --threads 10
```

**Upload files listed in a text file:**
```sh
python uploadfile.py --url http://localhost:8080/upload --filelist files.txt --threads 20
```

**Upload with a custom CA certificate:**
```sh
python uploadfile.py --url https://yourhost/upload --files file1 file2 --cert /path/to/ca.pem
```

**Upload a specific set of files:**
```sh
python uploadfile.py --url http://localhost:8080/upload --files file1.txt file2.txt file3.txt --threads 3
```

## Features

- Uploads files in parallel using a thread pool.
- Supports specifying files via direct paths, directory, glob pattern, or file list.
- Custom CA certificate support for HTTPS endpoints.
- Graceful shutdown and upload statistics.
- Retries failed uploads with exponential backoff.

## Requirements

- Python 3.6+
- `requests` library (`pip install requests`)

---

**Tip:**  
You can combine `--files`, `--dir`, `--filelist`, and `--glob` to specify your upload set.

## Features

- Shows upload speed and statistics.
- Retries failed uploads (for `one-uploadfile.py`).
- Graceful shutdown with Ctrl+C.
- Useful for stress-testing your upload server and Azure Blob integration.

## Requirements

- Python 3.6+
- `requests` library (`pip install requests`)

## Example: Upload All Test Files in Parallel

```sh
python uploadfile.py --filelist files.txt --url https://upstreamfiles.cloudapp008.com/upload --threads 50 --cert ../../appgateway/myca.pem
```

## Example: Continuous Single File Upload

```sh
python one-uploadfile.py --url http://localhost:8080/upload --file ./test1.zip --delay 2
```

---

**Note:**  
- Adjust the `--url` parameter if your server is running on a different host or port.
- For Kubernetes/Ingress testing, use the external URL (e.g., `http://fileupload.127.0.0.1.nip.io/upload`).

---