FROM python:3.13-alpine@sha256:2d9aefe2fef018a7eb2c13064c89c71929800fd2e5dccdbf52ea5da5bb8d929a

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY src ./src
RUN addgroup -S arrowhead && adduser -S -G arrowhead arrowhead \
    && mkdir -p /data && chown -R arrowhead:arrowhead /app /data
USER arrowhead
CMD ["python", "src/server.py"]
