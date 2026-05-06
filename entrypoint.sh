#!/bin/bash

# 1. Grab PUID/PGID (Default to 1000 if not provided)
PUID=${PUID:-1000}
PGID=${PGID:-1000}

echo "[INFO] Configuring user context (PUID: $PUID, PGID: $PGID)..."

# 2. Create the group and user dynamically inside the container
addgroup -g "$PGID" musicapp 2>/dev/null || true
adduser -u "$PUID" -G musicapp -s /bin/sh -D musicapp 2>/dev/null || true

# 3. Fix permissions so our new user can write logs and access the app
chown -R musicapp:musicapp /log
chown -R musicapp:musicapp /app

# 4. Start the requested process, using su-exec to drop root privileges
API_STATUS="${ENABLE_API:-true}"

if [ "$API_STATUS" = "true" ]; then
    echo "[INFO] Starting MusicLinkarr API via Gunicorn..."
    # 'su-exec musicapp' forces Gunicorn to run as your host user
    exec su-exec musicapp gunicorn --bind 0.0.0.0:8585 server:app
else
    echo "[INFO] API Disabled. Container is sleeping quietly for Cron execution..."
    exec su-exec musicapp sleep infinity
fi
