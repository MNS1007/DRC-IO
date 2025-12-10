FROM python:3.11-slim

# Create app directory
WORKDIR /app

# Copy application
COPY stress.py .

# Create data directory
RUN mkdir -p /data

# Create non-root user
RUN useradd -m -u 1000 batchuser && \
    chown -R batchuser:batchuser /app /data
USER batchuser

# Run batch job
CMD ["python", "-u", "stress.py"]
