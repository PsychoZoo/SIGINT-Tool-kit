# Build context: repository root (see docker-compose.yml)
FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
COPY lib /opt/sigint-lib
COPY services/api/requirements.txt /tmp/requirements.txt
RUN pip install /opt/sigint-lib -r /tmp/requirements.txt
WORKDIR /app
COPY services/api/ .
# The guide, shown at /guide (works with no internet).
COPY docs/GUIDE.md docs/GUIDE.md
EXPOSE 8080
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
