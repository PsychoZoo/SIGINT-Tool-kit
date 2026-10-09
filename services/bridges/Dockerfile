# Build context: repository root. One image for all bridges; the compose
# service picks which script runs.
FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
COPY lib /opt/sigint-lib
RUN pip install /opt/sigint-lib
WORKDIR /app
COPY services/bridges/*.py .
