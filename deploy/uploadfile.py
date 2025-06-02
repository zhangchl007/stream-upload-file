import requests
import time
import argparse
import os
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor, as_completed

def upload_once(url, file_path, base_filename, file_size, show_progress=True):
    try:
        if show_progress:
            print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] Upload {base_filename} - Sending file...")
        with open(file_path, 'rb') as f:
            files = {'file': (base_filename, f, 'application/octet-stream')}
            start_time = time.time()
            response = requests.post(url, files=files, timeout=30)
            elapsed = time.time() - start_time
            upload_speed = file_size / elapsed / 1024 / 1024  # MB/s
        if response.status_code == 200:
            if show_progress:
                print(f"Success {base_filename} (HTTP {response.status_code}) - {upload_speed:.2f} MB/s ({elapsed:.2f}s)")
                print(f"Response: {response.json()}")
            return True
        else:
            print(f"Error {base_filename}: HTTP {response.status_code} - {response.text}")
            return False
    except requests.RequestException as e:
        print(f"Error {base_filename}: {str(e)}")
        return False

def upload_files_threadpool(url, file_paths, delay=1, show_progress=True, num_workers=4):
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

    try:
        with ThreadPoolExecutor(max_workers=num_workers) as executor:
            while True:
                # Submit one upload per file, up to num_workers at a time
                futures = [
                    executor.submit(upload_once, url, file_path, base_filename, file_size, show_progress)
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

                if upload_count % 10 == 0:
                    print(f"\nUpload statistics:")
                    print(f"  Total uploads: {upload_count}")
                    print(f"  Successful: {success_count} ({success_count/upload_count*100:.1f}%)")
                    print(f"  Failed: {error_count} ({error_count/upload_count*100:.1f}%)")

                if delay > 0:
                    time.sleep(delay)
    except KeyboardInterrupt:
        print("\nUpload process stopped by user.")
        print(f"\nFinal statistics:")
        print(f"  Total uploads: {upload_count}")
        print(f"  Successful: {success_count} ({success_count/upload_count*100:.1f}% success rate)")
        print(f"  Failed: {error_count} ({error_count/upload_count*100:.1f}% failure rate)")
        return True

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='Continuously upload multiple files to a server using a thread pool')
    parser.add_argument('--url', default='http://localhost:8080/upload', help='Upload URL')
    parser.add_argument('--files', nargs='+', required=True, help='Paths to the files to upload (space separated)')
    parser.add_argument('--delay', type=float, default=1.0, help='Delay between upload rounds in seconds')
    parser.add_argument('--quiet', action='store_true', help='Minimize output')
    parser.add_argument('--threads', type=int, default=4, help='Number of parallel upload threads')
    args = parser.parse_args()

    upload_files_threadpool(args.url, args.files, delay=args.delay, show_progress=not args.quiet, num_workers=args.threads)