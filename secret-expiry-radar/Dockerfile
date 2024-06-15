FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 RADAR_DB=/data/radar.db
WORKDIR /app
RUN groupadd --gid 10001 radar && useradd --uid 10001 --gid radar --no-create-home radar && mkdir /data && chown radar:radar /data
COPY --chown=radar:radar radar ./radar
USER 10001:10001
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/healthz',timeout=3)" || exit 1
CMD ["python", "-m", "radar", "serve", "--host", "0.0.0.0"]
