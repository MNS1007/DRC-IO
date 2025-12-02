FROM python:3.11-slim

# Install system dependencies
RUN apt-get update && apt-get install -y \
    procps \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy requirements and install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY *.py ./

# Make main.py executable
RUN chmod +x main.py

# Run as non-root user (but container will need privileged access)
USER 1000

# Expose metrics port
EXPOSE 8080

# Run the controller
CMD ["python", "main.py"]

