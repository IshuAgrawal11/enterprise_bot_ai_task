FROM python:3.12.7-slim AS builder

WORKDIR /build

COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.12.7-slim

WORKDIR /app

RUN useradd -r -u 1001 appuser

COPY --from=builder /install /usr/local
COPY app.py .

USER 1001
EXPOSE 8080

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]
