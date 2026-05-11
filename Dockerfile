FROM alpine:3.19

# Added imagemagick-jpeg and imagemagick-png for image format support
RUN apk add --no-cache \
    bash \
    flac \
    imagemagick \
    imagemagick-jpeg \
    jq \
    curl \
    file \
    python3 \
    py3-flask \
    py3-gunicorn \
    findutils \
    su-exec

WORKDIR /app
RUN mkdir -p /config

COPY musicLinkarr.sh .
COPY server.py .
COPY entrypoint.sh .

RUN chmod +x musicLinkarr.sh entrypoint.sh

EXPOSE 8585

# Use the entrypoint script instead of starting python directly
CMD ["./entrypoint.sh"]
