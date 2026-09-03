# ---------------------------------------------------------------- web build
# The React portal is compiled here so the runtime image needs no Node toolchain
# and no network access. Everything it serves is bundled locally, which is what
# keeps the portal working in Azure Government, sovereign and air-gapped clouds.
FROM node:22-alpine AS web

WORKDIR /web

# Copied first so the dependency layer is only rebuilt when the manifests change.
COPY front_end/web/package.json front_end/web/package-lock.json ./
RUN npm ci

COPY front_end/web/ ./
# Vite writes to ../static/dist, which resolves to /static/dist from /web.
RUN npm run build

# -------------------------------------------------------------------- runtime
FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV WEBSITES_PORT=8000

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential gcc \
    && rm -rf /var/lib/apt/lists/*

COPY front_end/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY front_end/ ./

# The sources are not needed at runtime; only the compiled bundle is.
RUN rm -rf ./web

COPY --from=web /static/dist ./static/dist

EXPOSE 8000

CMD ["gunicorn", "--bind", "0.0.0.0:8000", "app:app"]
