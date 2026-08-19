FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV WEBSITES_PORT=8000

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential curl freetds-dev gcc \
    && rm -rf /var/lib/apt/lists/*

COPY api/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY api/ ./

EXPOSE 8000

CMD ["gunicorn", "--bind", "0.0.0.0:8000", "app:app"]
