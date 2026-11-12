# SOS-16 (2026-11-10): current Python 3.13 base; pip is removed after the install (the running producer does not need it,
# and it vendors certifi and urllib3, which had known vulnerabilities).
FROM python:3.13.18-alpine3.24@sha256:1e1f6334529d1fb26a2ef619d7cffb30a7c7d7cc1cc7338ebee283a58d1aeaca

WORKDIR /app
COPY requirements.txt .
RUN apk upgrade --no-cache && pip install --no-cache-dir -r requirements.txt && python -m pip uninstall -y pip \
 && rm -rf /usr/local/lib/python3.13/ensurepip
COPY src ./src

ENV PYTHONUNBUFFERED=1
EXPOSE 8500

CMD ["python", "src/producer.py"]
