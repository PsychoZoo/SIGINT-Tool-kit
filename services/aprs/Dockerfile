# Build context: repository root
FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
RUN apt-get update \
 && apt-get install -y --no-install-recommends rtl-sdr multimon-ng \
 && rm -rf /var/lib/apt/lists/*
COPY lib /opt/sigint-lib
RUN pip install /opt/sigint-lib
WORKDIR /app
COPY services/aprs/aprs.py .
CMD ["python", "aprs.py"]
