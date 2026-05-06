#!/bin/bash

# Default to true if the variable is entirely missing
API_STATUS="${ENABLE_API:-true}"

if [ "$API_STATUS" = "true" ]; then
    echo "[INFO] Starting MusicLinkarr API via Gunicorn..."
    # 'exec' hands over control to gunicorn so Docker can stop it gracefully later
    exec gunicorn --bind 0.0.0.0:8585 server:app
else
    echo "[INFO] API Disabled. Container is sleeping quietly for Cron execution..."
    # Keep the container alive with zero CPU usage so 'docker exec' works
    exec sleep infinity
fi
