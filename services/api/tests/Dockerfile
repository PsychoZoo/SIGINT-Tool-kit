# Test runner for the API (./toolkit.sh test). Build context: repository root.
FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1 PYTHONDONTWRITEBYTECODE=1
COPY lib /opt/sigint-lib
COPY services/api/requirements.txt /tmp/requirements.txt
RUN pip install --root-user-action=ignore /opt/sigint-lib -r /tmp/requirements.txt "pytest>=8,<10" httpx2
WORKDIR /code/services/api
CMD ["python", "-m", "pytest", "-q", "-p", "no:cacheprovider", "tests"]
