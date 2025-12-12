FROM python:3.11-slim

# Create app directory
WORKDIR /app

# Copy requirements and install
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application
COPY controller.py .

# Make executable
RUN chmod +x controller.py

# Run as root (needed for cgroup access)
USER root

# Expose metrics port
EXPOSE 8080

# Run controller
CMD ["python", "-u", "controller.py"]
