# Build context: repository root (see modules/compose.yml)
FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
COPY lib /opt/sigint-lib
RUN pip install /opt/sigint-lib
WORKDIR /app
# Add any extra Python packages your program needs to requirements.txt
COPY modules/__NAME__/requirements.txt .
RUN pip install -r requirements.txt
COPY modules/__NAME__/ .
CMD ["python", "main.py"]
