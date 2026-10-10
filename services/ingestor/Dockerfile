# Build context: repository root (see docker-compose.yml)
FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
COPY lib /opt/sigint-lib
RUN pip install /opt/sigint-lib
WORKDIR /app
COPY services/ingestor/ingestor.py .
CMD ["python", "ingestor.py"]
