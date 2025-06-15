#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import requests
import time
import argparse
import os
import glob
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import List

def expand_file_args(files: List[str], dir: str = None, filelist: str = None, glob_pattern: str = None) -> List[str]:
    result = set()
    if files:
        result.update(files)
    if dir:
        for entry in os.scandir(dir):
            if entry.is_file():
                result.add(entry.path)
    if filelist:
        with open(filelist, "r") as f:
            for line in f:
                path = line.strip()
                if path:
                    result.add(path)
    if glob_pattern:
        result.update(glob.glob(glob_pattern))
    # Filter to existing files and convert to absolute paths
    return [os.path.abspath(f) for f in result if os.path.isfile(f)]

def upload_once(session, url, file_path, base_filename, file_size, show_progress=True, verify=True, max_retries=3):
    attempt = 0
    backoff = 1
    while attempt < max_retries:
        try:
            if show_progress:
                print(f"[{datetime.now():%Y-%m-%d %H:%M:%S}] Upload {base_filename} - Sending file...")

            with open(file_path, 'rb') as f:
                files = {'file': (base_filename, f, 'application/octet-stream')}
                start_time = time.time()
                response = session.post(url, files=files, timeout=(30, 60), verify=verify)
                #response = session.post(url, files=files, timeout=60, verify=verify)
                elapsed = time.time() - start_time

            upload_speed = file_size / elapsed / 1024 / 1024  # MB/s

            if response.status_code == 200:
                if show_progress:
                    print(f"Success {base_filename} (HTTP {response.status_code}) - {upload_speed:.2f} MB/s ({elapsed:.2f}s)")
                    try:
                        print(f"Response: {response.json()}")
                    except Exception:
                        print("Response is not JSON.")
                return True
            else:
                if show_progress:
                    print(f"Error {base_filename}: HTTP {response.status_code} - {response.text}")
                return False

        except requests.RequestException as e:
            if show_progress:
                print(f"Error {base_filename} attempt {attempt+1}: {e}")
            attempt += 1
            time.sleep(backoff)
            backoff *= 2

    if show_progress:
        print(f"Failed {base_filename} after {max_retries} attempts.")
    return False

def upload_files_threadpool(url, file_paths, delay=1, show_progress=True, num_workers=4, verify=True):
    files_info = []
    for file_path in file_paths:
        if not os.path.exists(file_path):
            print(f"Error: File '{file_path}' not found.")
            continue
        file_size = os.path.getsize(file_path)
        base_filename = os.path.basename(file_path)
        files_info.append((file_path, base_filename, file_size))

    if not files_info:
        print("No valid files to upload.")
        return

    print(f"Starting parallel upload of {[f[1] for f in files_info]} to {url} with {num_workers} threads")
    print("Press Ctrl+C to stop uploading.")

    upload_count = 0
    success_count = 0
    error_count = 0
    session = requests.Session()

    try:
        with ThreadPoolExecutor(max_workers=num_workers) as executor:
            while True:
                futures = [
                    executor.submit(upload_once, session, url, file_path, base_filename, file_size, show_progress, verify)
                    for file_path, base_filename, file_size in files_info
                ]
                for future in as_completed(futures):
                    upload_count += 1
                    try:
                        result = future.result()
                        if result:
                            success_count += 1
                        else:
                            error_count += 1
                    except Exception as e:
                        print(f"Thread error: {e}")
                        error_count += 1

                if upload_count % 10 == 0 or upload_count == len(files_info):
                    print(f"\nUpload statistics:")
                    print(f"  Total uploads: {upload_count}")
                    print(f"  Successful: {success_count} ({(success_count/upload_count)*100:.1f}%)")
                    print(f"  Failed: {error_count} ({(error_count/upload_count)*100:.1f}%)")

                if delay > 0:
                    time.sleep(delay)
    except KeyboardInterrupt:
        print("\nUpload process stopped by user.")
        print(f"\nFinal statistics:")
        print(f"  Total uploads: {upload_count}")
        print(f"  Successful: {success_count} ({(success_count/upload_count)*100:.1f}% success rate)")
        print(f"  Failed: {error_count} ({(error_count/upload_count)*100:.1f}% failure rate)")
    finally:
        session.close()

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='Continuously upload multiple files to a server using a thread pool')
    parser.add_argument('--url', default='http://localhost:8080/upload', help='Upload URL')
    parser.add_argument('--files', nargs='*', help='Paths to the files to upload (space separated)')
    parser.add_argument('--dir', help='Directory to upload all files from')
    parser.add_argument('--filelist', help='Text file with one file path per line')
    parser.add_argument('--glob', help='Glob pattern for files (e.g. "*.zip")')
    parser.add_argument('--delay', type=float, default=1.0, help='Delay between upload rounds in seconds')
    parser.add_argument('--quiet', action='store_true', help='Minimize output')
    parser.add_argument('--threads', type=int, default=4, help='Number of parallel upload threads')
    parser.add_argument('--cert', default=None, help='Path to custom CA certificate file (PEM)')
    args = parser.parse_args()

    all_files = expand_file_args(args.files, args.dir, args.filelist, args.glob)
    verify = args.cert if args.cert else True

    upload_files_threadpool(args.url, all_files, delay=args.delay, show_progress=not args.quiet, num_workers=args.threads, verify=verify)