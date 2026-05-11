import os
import secrets
from flask import Flask, request
import subprocess

app = Flask(__name__)

def get_or_create_api_key():
    # 1. Allow power users to override via Env Var in docker-compose
    env_key = os.environ.get("API_KEY")
    if env_key:
        return env_key

    # 2. Check if a key was already generated and saved in the persistent config volume
    key_file_path = "/config/api_key.txt"
    if os.path.exists(key_file_path):
        with open(key_file_path, "r") as f:
            return f.read().strip()

    # 3. First time run! Generate a robust key and save it
    new_key = secrets.token_urlsafe(32)
    try:
        with open(key_file_path, "w") as f:
            f.write(new_key)
        print("\n" + "="*65, flush=True)
        print(f" NEW API KEY GENERATED: {new_key} ", flush=True)
        print(" Please add this to the Authorization header in qBittorrent.", flush=True)
        print("="*65 + "\n", flush=True)
    except Exception as e:
        print(f"[ERROR] Failed to write API key to {key_file_path}: {e}", flush=True)
        
    return new_key

API_KEY = get_or_create_api_key()

@app.route('/process', methods=['POST'])
def process_torrent():
    # Check Authorization header
    auth_header = request.headers.get('Authorization')

    # Use a constant-time comparison to mitigate timing attacks.
    # This is best practice, even if the risk is low with a high-entropy key.
    is_authorized = False
    if auth_header and auth_header.startswith("Bearer "):
        submitted_key = auth_header.removeprefix("Bearer ")
        is_authorized = secrets.compare_digest(submitted_key, API_KEY)

    if not is_authorized:
        print("API Received -> Unauthorized request attempt.", flush=True)
        return "Unauthorized", 401

    # Grab both variables sent by qBittorrent
    category = request.form.get('category', '')
    torrent_path = request.form.get('path')

    if not torrent_path:
        return "Error: No path provided", 400

    print(f"API Received -> Category: '{category}' | Path: '{torrent_path}'")

    # Pass Category as $1 and Path as $2
    subprocess.Popen(['/app/musicLinkarr.sh', torrent_path, category])

    return f"Processing started for {torrent_path}", 200

if __name__ == '__main__':
    # Listen on all network interfaces inside the container on port 5000
    app.run(host='0.0.0.0', port=8585)
