# Python File Upload Test Scripts

This directory contains Python scripts for testing file uploads to your Go-based Azure Blob Storage upload server. You can use these scripts to simulate continuous or parallel uploads for load testing, performance benchmarking, or functional validation.
---

## Scripts

### 1. `uploadfile.py`

A flexible, parallel file uploader for stress-testing and automation.

#### **Usage**

```sh
python uploadfile.py [options]
```

#### **Options**

- `-h, --help`           Show help message and exit  
- `--url URL`            **(Required)** Upload URL (e.g., http://localhost:8080/upload)  
- `--files [FILES ...]`  Paths to the files to upload (space separated)  
- `--dir DIR`            Directory to upload all files from  
- `--filelist FILELIST`  Text file with one file path per line  
- `--glob GLOB`          Glob pattern for files (e.g. "*.zip")  
- `--delay DELAY`        Delay between upload rounds in seconds (default: 1.0)  
- `--quiet`              Minimize output  
- `--threads THREADS`    Number of parallel upload threads (default: 4)  
- `--cert CERT`          Path to custom CA certificate file (PEM) for HTTPS  

#### **Examples**

- Upload all `.zip` files in a directory with 10 threads:
  ```sh
  python uploadfile.py --url http://localhost:8080/upload --dir ./myfiles --glob "*.zip" --threads 10
  ```
- Upload files listed in a text file:
  ```sh
  python uploadfile.py --url http://localhost:8080/upload --filelist files.txt --threads 20
  ```
- Upload with a custom CA certificate:
  ```sh
  python uploadfile.py --url https://yourhost/upload --files file1 file2 --cert /path/to/ca.pem
  ```
- Upload a specific set of files:
  ```sh
  python uploadfile.py --url http://localhost:8080/upload --files file1.txt file2.txt file3.txt --threads 3
  ```

#### **Features**

- Uploads files in parallel using a thread pool.
- Supports specifying files via direct paths, directory, glob pattern, or file list.
- Custom CA certificate support for HTTPS endpoints.
- Graceful shutdown and upload statistics.
- Retries failed uploads with exponential backoff.

---

### 2. `one-uploadfile.py`

A simple script for repeatedly uploading a single file, useful for continuous or soak testing.

#### **Usage**

```sh
python one-uploadfile.py --url URL --file FILE [--delay DELAY] [--quiet]
```

#### **Options**

- `-h, --help`        Show help message and exit  
- `--url URL`         **(Required)** Upload URL (e.g., http://localhost:8080/upload)  
- `--file FILE`       **(Required)** Path to the file to upload  
- `--delay DELAY`     Delay between uploads in seconds (default: 1.0)  
- `--quiet`           Minimize output  

#### **Example**

```sh
python one-uploadfile.py --url http://localhost:8080/upload --file ./test1.zip --delay 2
```

#### **Features**

- Continuously uploads a single file in a loop.
- Shows upload speed and statistics.
- Retries failed uploads.
- Graceful shutdown with Ctrl+C.

---

## Requirements

- Python 3.6+
- `requests` library (`pip install requests`)

---

**Note:**  
- Adjust the `--url` parameter if your server is running on a different host or port.
- For Kubernetes/Ingress testing, use the external URL (e.g., `http://fileupload.127.0.0.1.nip.io/upload`).

---