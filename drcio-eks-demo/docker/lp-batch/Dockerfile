# DRC-IO Low-Priority Batch I/O Stress Dockerfile

FROM python:3.11-slim

# Metadata
LABEL maintainer="DRC-IO Team"
LABEL description="Low-Priority Batch I/O Stress Generator"
LABEL version="1.0.0"

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    procps \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN useradd -m -u 1000 -s /bin/bash batchuser

# Set working directory
WORKDIR /app

# Copy requirements
COPY requirements.txt .

# Install Python dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY stress.py .

# Make script executable
RUN chmod +x stress.py

# Create work directory with proper permissions
RUN mkdir -p /data && chown -R batchuser:batchuser /data

# Change ownership
RUN chown -R batchuser:batchuser /app

# Switch to non-root user
USER batchuser

# Environment variables
ENV PYTHONUNBUFFERED=1
ENV WORK_DIR=/data

# Expose metrics port
EXPOSE 8000

# Default command
ENTRYPOINT ["python", "stress.py"]
CMD ["--work-dir", "/data", "--num-operations", "1000", "--io-pattern", "sequential"]
