FROM alpine:3.19

# Added 'py3-gunicorn' and 'findutils' (from our previous fix)
RUN apk add --no-cache \
    bash \
    flac \
    imagemagick \
    jq \
    curl \
    file \
    python3 \
    py3-flask \
    py3-gunicorn \
    findutils

WORKDIR /app
RUN mkdir -p /log

COPY musicLinkarr.sh .
COPY server.py .
COPY entrypoint.sh .

RUN chmod +x musicLinkarr.sh entrypoint.sh

EXPOSE 8585

# Use the entrypoint script instead of starting python directly
CMD ["./entrypoint.sh"]
