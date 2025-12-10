# DRC-IO Controller Dockerfile

FROM python:3.11-slim

# Metadata
LABEL maintainer="DRC-IO Team"
LABEL description="DRC-IO Dynamic Resource Controller"
LABEL version="1.0.0"

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    procps \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user (but needs host cgroup access)
RUN useradd -m -u 1000 -s /bin/bash drcio

# Set working directory
WORKDIR /app

# Copy requirements
COPY requirements.txt .

# Install Python dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY controller.py .

# Make script executable
RUN chmod +x controller.py

# Change ownership
RUN chown -R drcio:drcio /app

# Switch to non-root user
# Note: In production, run as root or with appropriate capabilities
# to access host cgroups
USER root

# Environment variables
ENV PYTHONUNBUFFERED=1
ENV METRICS_PORT=9100

# Expose metrics port
EXPOSE 9100

# Run controller
CMD ["python", "controller.py"]
