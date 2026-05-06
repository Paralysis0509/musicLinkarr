# MusicLinkarr

A lightweight, Dockerized microservice that automatically organizes your manually downloaded FLAC music torrents for media servers (like Navidrome, Plex, or Jellyfin) using **zero extra disk space**.

## Why build this instead of using Lidarr?
Lidarr is an amazing tool for fully automated music fetching. However, I prefer to browse my trackers manually. 

MusicLinkarr is designed to be a simpler, strictly post-processing alternative. You download whatever you want, however you want. When the torrent finishes, qbittorrent wakes up musicLinkarr, reads the embedded FLAC metadata, and instantly creates a perfectly clean `Artist/Album/Track - Title.flac` structure in your media folder. 

### Features
* **Hardlinks:** Your files seed in your torrent folder and play in your media server simultaneously without duplicating data.
* **Smart Cover Art:** Automatically fetches the best cover art by checking:
  1. Local folder images (`cover.jpg`, `folder.png`, etc.)
  2. Embedded FLAC metadata art
  3. Online fallbacks via MusicBrainz & CoverArtArchive
  *(All images are automatically normalized/resized to a max 1000x1000 JPG).*
* **Built-in API:** Instantly triggered by qBittorrent the second a download finishes.
* **Bulk Scanning:** Can be run on a daily cron schedule to catch up on folders modified today.
* **Bulletproof Filenames:** Aggressively sanitizes weird characters to prevent OS pathing errors.

---

## Hardlinks & Folder Structure
For MusicLinkarr to work its magic without duplicating data, **Hardlinks must be possible.** 

Hardlinks cannot cross different hard drives, and in Docker, they cannot cross different volume mounts. You **must** mount a single, common parent directory to both your torrent client and MusicLinkarr. 

*If you are unfamiliar with this concept, it is highly recommended to read the [TRASH Guides on Hardlinks and Instant Moves](https://trash-guides.info/File-and-Folder-Structure/Hardlinks-and-Instant-Moves/).*

**Bad Docker Volume Setup (Hardlinks will fail):**
```yaml
volumes:
  - /data/torrents:/torrents
  - /data/media:/media
```

**Good Docker Volume Setup (Hardlinks will work):**
```yaml
volumes:
  - /data:/data
```

---

## Installation

### 1. Docker Compose
Add the following to your `docker-compose.yml`. Make sure your volume paths exactly match the paths used by your qBittorrent container so both containers see the exact same file structure!

```yaml
services:
  musiclinkarr:
    build: . # Or the path to the MusicLinkarr folder
    container_name: musiclinkarr
    restart: unless-stopped
    ports:
      - "8585:8585"
    volumes:
      # Mount the common parent directory
      - /path/to/your/local/data:/data
      # (Optional) Map the internal /log folder to your host to keep persistent logs
      - /path/to/your/local/logs:/log
    environment:
      - PUID=1000                       # Replace with your host user ID
      - PGID=1000                       # Replace with your host group ID
      - SRC_BASE=/data/torrents/music   # Where your downloads land
      - DEST_BASE=/data/media/music     # Where your organized music goes
      - WATCHED_CATEGORY=music          # The qBittorrent category to listen for
      - ENABLE_API=true                 # Keep true to allow qBittorrent to trigger it, false for daily bulk scan only
```

### 2. Environment Variables Explained

| Variable | Required | Default | Description |
| :--- | :---: | :--- | :--- |
| `SRC_BASE` | Yes | *None* | The root folder where your torrents are downloaded. |
| `DEST_BASE` | Yes | *None* | The root folder where your organized Artists/Albums will be linked. |
| `WATCHED_CATEGORY` | No | `music` | The API will ignore any triggers that menttion a different category. |
| `ENABLE_API` | No | `true` | Set to `false` to disable the web server (container will sleep for cron jobs). |

---

## Usage & Triggers

MusicLinkarr can be triggered in three different ways depending on your needs.

### Method 1: Instant Trigger via qBittorrent (Recommended)
You can tell qBittorrent to ping MusicLinkarr's API the exact second a download finishes.

1. Open your qBittorrent Web UI.
2. Go to **Settings -> Downloads**.
3. Scroll down to **Run external program on torrent completion**.
4. Check the box and paste the following command:

```bash
curl -X POST --data-urlencode "path=%F" --data-urlencode "category=%L" http://musiclinkarr:8585/process
```

* **Note on VPNs/Gluetun:** If your qBittorrent is routed through a VPN container like Gluetun, it might not be able to resolve `http://musiclinkarr`. Replace `musiclinkarr` with your host machine's local IP (e.g., `192.168.1.50`), and ensure you have added your local subnet to Gluetun's `FIREWALL_OUTBOUND_SUBNETS` variable (e.g., `192.168.1.0/24`, or even `192.168.1.50/32` if you're extra cautious).

### Method 2: Daily Cron Job (Bulk Scan)
If you prefer not to use the API, or want to catch folders you moved manually, you can run a bulk scan. When triggered without arguments, MusicLinkarr automatically scans `SRC_BASE` for any folders that were modified **in the last 48 hours** to ensure no files are missed.

Add this to your host machine's crontab (`crontab -e`) to run it every night at 3:00 AM (user musicapp to take UPUID and PGID into account):
```bash
0 3 * * * docker exec -u musicapp musiclinkarr /app/musicLinkarr.sh
```
(user musicapp to take UPUID and PGID into account)

### Method 3: Manual Execution
Need to process a specific folder manually? You can execute the script directly inside the container and pass the exact path you want to process:
```bash
docker exec musiclinkarr /app/musicLinkarr.sh "/data/torrents/music/My Awesome Album"
```

---

## Troubleshooting & Logs

**To view the API Web Server logs (to see if qBittorrent is talking to it):**
```bash
docker logs -f musiclinkarr
```

**To view the actual processing logs (Folder creation, metadata reading, hardlink successes):**
Check the `/log` directory inside the container (or the folder you mapped it to on your host machine in your `docker-compose.yml`). A new log file is generated daily: `musicLinkarr_YYYYMMDD.log`.
