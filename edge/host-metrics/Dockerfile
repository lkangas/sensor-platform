FROM debian:stable-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      mosquitto-clients ca-certificates gawk coreutils procps && \
    rm -rf /var/lib/apt/lists/*
COPY publish-host-metrics.sh /usr/local/bin/publish-host-metrics.sh
RUN chmod +x /usr/local/bin/publish-host-metrics.sh
ENTRYPOINT ["/usr/local/bin/publish-host-metrics.sh"]
