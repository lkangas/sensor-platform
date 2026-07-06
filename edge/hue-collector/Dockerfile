FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY hue_collector.py .
CMD ["python", "-u", "hue_collector.py"]
