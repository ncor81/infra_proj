FROM python:3.12-slim AS builder
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

FROM python:3.12-slim
WORKDIR /app
RUN useradd -m appuser
COPY --from=builder /usr/local/lib/python3.12 \
    /usr/local/lib/python3.12
COPY --from=builder /usr/local/bin/uvicorn \
    /usr/local/bin/uvicorn
COPY main.py .
USER appuser
EXPOSE 8000
CMD ["uvicorn","main:app", "--host", "0.0.0.0", "--port", "8000"]
