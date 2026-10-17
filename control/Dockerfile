# Control page image. Built on the node host by ./control/install.sh.
# Base pinned by digest; Python packages installed only if their hashes match
# requirements.txt (generated from requirements.in with pip-compile).
FROM python:3.13-slim@sha256:70729b46c69b4f1e97c4822c1af3df53a1476cf5ddc6c087c0c10bc3a5678c2f

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_DISABLE_PIP_VERSION_CHECK=1
RUN groupadd --system --gid 10001 control \
 && useradd --system --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin control
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --require-hashes --no-deps -r requirements.txt
COPY app/ /app/
USER 10001:10001
EXPOSE 8090
# One worker so the login rate limit is shared; threads for concurrency.
CMD ["gunicorn", "--bind", "127.0.0.1:8090", "--workers", "1", "--threads", "8", \
     "--forwarded-allow-ips", "127.0.0.1", "--access-logfile", "-", "control:app"]
