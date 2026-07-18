FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .
COPY rbac.py .
COPY jwt_middleware.py .

RUN useradd -m appuser
USER appuser

# Utilise la variable d'environnement SERVICE_PORT
CMD ["sh", "-c", "uvicorn main:app --host 0.0.0.0 --port $SERVICE_PORT"]