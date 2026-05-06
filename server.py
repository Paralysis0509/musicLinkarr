from flask import Flask, request
import subprocess

app = Flask(__name__)

@app.route('/process', methods=['POST'])
def process_torrent():
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
