import requests
import time
import argparse
import os
from datetime import datetime

def upload_file(url, file_path, delay=1, max_retries=3, show_progress=True):
    """
    Upload a file to the specified URL repeatedly.
    
    Args:
        url (str): The upload endpoint.
        file_path (str): Path to the file to upload.
        delay (float): Seconds to wait between uploads.
        max_retries (int): Maximum number of retries on failure.
        show_progress (bool): Whether to show upload progress.
    """
    # Check if file exists
    if not os.path.exists(file_path):
        print(f"Error: File '{file_path}' not found.")
        return False
    
    file_size = os.path.getsize(file_path)
    file_size_mb = file_size / (1024 * 1024)
    
    # Get the base filename for display
    base_filename = os.path.basename(file_path)
    
    print(f"Starting continuous upload of '{base_filename}' ({file_size_mb:.2f} MB) to {url}")
    print("Press Ctrl+C to stop uploading.")
    
    upload_count = 0
    success_count = 0
    error_count = 0
    
    try:
        while True:
            upload_count += 1
            start_time = time.time()
            
            retry_count = 0
            success = False
            
            while retry_count < max_retries and not success:
                try:
                    if show_progress:
                        print(f"\n[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] Upload #{upload_count} - Sending file...")
                    
                    with open(file_path, 'rb') as f:
                        files = {'file': (base_filename, f, 'application/octet-stream')}
                        response = requests.post(url, files=files, timeout=30)
                    
                    elapsed = time.time() - start_time
                    upload_speed = file_size / elapsed / 1024 / 1024  # MB/s
                    
                    if response.status_code == 200:
                        success_count += 1
                        success = True
                        if show_progress:
                            print(f"Success (HTTP {response.status_code}) - {upload_speed:.2f} MB/s ({elapsed:.2f}s)")
                            print(f"Response: {response.json()}")
                    else:
                        error_count += 1
                        print(f"Error: HTTP {response.status_code} - {response.text}")
                        retry_count += 1
                        if retry_count < max_retries:
                            print(f"Retrying ({retry_count}/{max_retries})...")
                            time.sleep(1)  # Short delay before retry
                
                except requests.RequestException as e:
                    error_count += 1
                    print(f"Error: {str(e)}")
                    retry_count += 1
                    if retry_count < max_retries:
                        print(f"Retrying ({retry_count}/{max_retries})...")
                        time.sleep(1)  # Short delay before retry
                    else:
                        break
            
            # Show statistics periodically
            if upload_count % 10 == 0:
                print(f"\nUpload statistics:")
                print(f"  Total uploads: {upload_count}")
                print(f"  Successful: {success_count} ({success_count/upload_count*100:.1f}%)")
                print(f"  Failed: {error_count} ({error_count/upload_count*100:.1f}%)")
            
            # Delay before next upload
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
    parser = argparse.ArgumentParser(description='Continuously upload a file to a server')
    parser.add_argument('--url', default='http://localhost:8080/upload', help='Upload URL')
    parser.add_argument('--file', required=True, help='Path to the file to upload')
    parser.add_argument('--delay', type=float, default=1.0, help='Delay between uploads in seconds')
    parser.add_argument('--quiet', action='store_true', help='Minimize output')
    args = parser.parse_args()

    upload_file(args.url, args.file, delay=args.delay, show_progress=not args.quiet)