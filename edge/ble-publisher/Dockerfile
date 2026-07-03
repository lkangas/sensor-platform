# Profile C edge runtime: the repo's bleak-based Ruuvi publisher in a container.
# Build context is the REPO ROOT (see docker-compose.yml) so the single source of
# truth for the script stays scripts/test-publisher/ruuvi_test_publisher.py.
FROM python:3.12-slim

COPY scripts/test-publisher/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY scripts/test-publisher/ruuvi_test_publisher.py /app/ruuvi_test_publisher.py
WORKDIR /app

# -u: unbuffered so `docker logs` shows readings/heartbeats live
ENTRYPOINT ["python", "-u", "ruuvi_test_publisher.py"]
