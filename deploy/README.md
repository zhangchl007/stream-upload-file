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

### `uploadfile.py`

- **Purpose:** Continuously uploads multiple files in parallel using a thread pool.
- **Usage Example:**
  ```sh
  python uploadfile.py --url http://localhost:8080/upload --files ./test1.zip ./test2.zip ./test3.zip --threads 4 --delay 1
  ```
- **Arguments:**
  - `--url`: The upload endpoint (default:http://localhost:8080/upload`)
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