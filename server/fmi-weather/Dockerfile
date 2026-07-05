FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY fmi_weather.py backfill.py ./
CMD ["python", "-u", "fmi_weather.py"]
