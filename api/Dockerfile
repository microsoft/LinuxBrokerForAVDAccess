FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV WEBSITES_PORT=8000

WORKDIR /app

# openssh-client provides the ssh binary the API uses to provision users and push host settings.
RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential curl freetds-dev gcc openssh-client \
    && rm -rf /var/lib/apt/lists/*

COPY api/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY api/ ./

EXPOSE 8000

# One sync worker with a 30 s timeout let a single slow checkout stall every other caller.
# gthread workers handle concurrent requests; SQL concurrency is capped separately by
# DB_MAX_CONCURRENCY. Override with a GUNICORN_CMD_ARGS app setting.
ENV GUNICORN_CMD_ARGS="--workers 2 --threads 8 --timeout 120 --graceful-timeout 30 --keep-alive 5"

CMD ["gunicorn", "--bind", "0.0.0.0:8000", "app:app"]
