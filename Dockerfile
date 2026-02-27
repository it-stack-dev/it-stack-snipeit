# Dockerfile — IT-Stack SNIPEIT wrapper
# Module 16 | Category: it-management | Phase: 4
# Base image: snipe/snipe-it:latest

FROM snipe/snipe-it:latest

# Labels
LABEL org.opencontainers.image.title="it-stack-snipeit" \
      org.opencontainers.image.description="Snipe-IT IT asset management" \
      org.opencontainers.image.vendor="it-stack-dev" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.source="https://github.com/it-stack-dev/it-stack-snipeit"

# Copy custom configuration and scripts
COPY src/ /opt/it-stack/snipeit/
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost/health || exit 1

ENTRYPOINT ["/entrypoint.sh"]
