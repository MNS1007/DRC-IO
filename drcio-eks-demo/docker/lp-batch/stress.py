#!/usr/bin/env python3
"""
DRC-IO Low-Priority Batch I/O Stress Generator

This script generates intensive I/O workload to simulate batch processing jobs
such as data analytics, ETL pipelines, or log processing. It's designed to
test DRC-IO's ability to deprioritize batch workloads in favor of real-time
services.

Features:
- Configurable I/O patterns (sequential, random)
- Read/write mix control
- File size and operation count tuning
- Prometheus metrics export
- Graceful shutdown handling
"""

import os
import sys
import time
import random
import logging
import signal
import argparse
from datetime import datetime
from pathlib import Path
from prometheus_client import Counter, Histogram, Gauge, start_http_server
import threading

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Prometheus metrics
IO_OPERATIONS = Counter(
    'batch_io_operations_total',
    'Total number of I/O operations',
    ['operation_type', 'status']
)

IO_BYTES = Counter(
    'batch_io_bytes_total',
    'Total bytes read/written',
    ['operation_type']
)

IO_LATENCY = Histogram(
    'batch_io_latency_seconds',
    'I/O operation latency',
    ['operation_type'],
    buckets=(0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0)
)

ACTIVE_OPERATIONS = Gauge(
    'batch_active_operations',
    'Number of active I/O operations'
)

TOTAL_RUNTIME = Gauge(
    'batch_runtime_seconds',
    'Total runtime of the batch job'
)

# Global state
shutdown_requested = False
start_time = None


##############################################################################
# I/O Workload Generator
##############################################################################

class IOStressGenerator:
    """
    Generates I/O stress workload with configurable patterns.
    """

    def __init__(self, config):
        self.config = config
        self.work_dir = Path(config['work_dir'])
        self.work_dir.mkdir(parents=True, exist_ok=True)

        self.total_operations = 0
        self.total_bytes_read = 0
        self.total_bytes_written = 0

        logger.info("=" * 60)
        logger.info("I/O Stress Generator Configuration")
        logger.info("=" * 60)
        logger.info(f"Work Directory: {self.work_dir}")
        logger.info(f"File Size: {self._format_bytes(config['file_size'])}")
        logger.info(f"Block Size: {self._format_bytes(config['block_size'])}")
        logger.info(f"Operation Count: {config['num_operations']}")
        logger.info(f"I/O Pattern: {config['io_pattern']}")
        logger.info(f"Read/Write Mix: {config['read_ratio']*100:.0f}% reads")
        logger.info(f"Concurrency: {config['num_workers']} workers")
        logger.info("=" * 60)

    def run(self):
        """Execute the I/O stress workload."""
        global start_time
        start_time = time.time()

        logger.info("Starting I/O stress workload...")

        # Create initial test files
        self._create_test_files()

        # Run workload
        if self.config['num_workers'] > 1:
            self._run_concurrent()
        else:
            self._run_sequential()

        # Cleanup
        self._cleanup()

        runtime = time.time() - start_time
        TOTAL_RUNTIME.set(runtime)

        logger.info("=" * 60)
        logger.info("Workload Complete")
        logger.info("=" * 60)
        logger.info(f"Total Operations: {self.total_operations}")
        logger.info(f"Total Bytes Read: {self._format_bytes(self.total_bytes_read)}")
        logger.info(f"Total Bytes Written: {self._format_bytes(self.total_bytes_written)}")
        logger.info(f"Runtime: {runtime:.2f}s")
        logger.info(f"Throughput: {self._format_bytes((self.total_bytes_read + self.total_bytes_written) / runtime)}/s")
        logger.info("=" * 60)

    def _create_test_files(self):
        """Create initial test files."""
        logger.info("Creating test files...")

        num_files = min(10, self.config['num_operations'])
        file_size = self.config['file_size']

        for i in range(num_files):
            if shutdown_requested:
                break

            file_path = self.work_dir / f"testfile_{i}.dat"
            self._write_file(file_path, file_size)

        logger.info(f"Created {num_files} test files")

    def _run_sequential(self):
        """Run I/O operations sequentially."""
        logger.info("Running sequential workload...")

        for i in range(self.config['num_operations']):
            if shutdown_requested:
                logger.info("Shutdown requested, stopping workload...")
                break

            # Choose operation type based on read ratio
            if random.random() < self.config['read_ratio']:
                self._perform_read_operation(i)
            else:
                self._perform_write_operation(i)

            # Progress logging
            if (i + 1) % 100 == 0:
                progress = (i + 1) / self.config['num_operations'] * 100
                logger.info(f"Progress: {progress:.1f}% ({i + 1}/{self.config['num_operations']})")

    def _run_concurrent(self):
        """Run I/O operations with multiple workers."""
        logger.info(f"Running concurrent workload with {self.config['num_workers']} workers...")

        threads = []
        ops_per_worker = self.config['num_operations'] // self.config['num_workers']

        for worker_id in range(self.config['num_workers']):
            thread = threading.Thread(
                target=self._worker_thread,
                args=(worker_id, ops_per_worker)
            )
            threads.append(thread)
            thread.start()

        # Wait for all workers to complete
        for thread in threads:
            thread.join()

    def _worker_thread(self, worker_id, num_operations):
        """Worker thread for concurrent operations."""
        logger.info(f"Worker {worker_id} started")

        for i in range(num_operations):
            if shutdown_requested:
                break

            if random.random() < self.config['read_ratio']:
                self._perform_read_operation(i, worker_id)
            else:
                self._perform_write_operation(i, worker_id)

        logger.info(f"Worker {worker_id} completed")

    def _perform_read_operation(self, op_id, worker_id=0):
        """Perform a read operation."""
        ACTIVE_OPERATIONS.inc()
        start = time.time()

        try:
            # Select random file to read
            files = list(self.work_dir.glob("testfile_*.dat"))
            if not files:
                logger.warning("No files available for reading")
                return

            file_path = random.choice(files)

            # Perform read based on pattern
            if self.config['io_pattern'] == 'sequential':
                bytes_read = self._sequential_read(file_path)
            else:  # random
                bytes_read = self._random_read(file_path)

            # Record metrics
            self.total_operations += 1
            self.total_bytes_read += bytes_read

            IO_OPERATIONS.labels(operation_type='read', status='success').inc()
            IO_BYTES.labels(operation_type='read').inc(bytes_read)

        except Exception as e:
            logger.error(f"Read operation failed: {str(e)}")
            IO_OPERATIONS.labels(operation_type='read', status='error').inc()

        finally:
            ACTIVE_OPERATIONS.dec()
            latency = time.time() - start
            IO_LATENCY.labels(operation_type='read').observe(latency)

    def _perform_write_operation(self, op_id, worker_id=0):
        """Perform a write operation."""
        ACTIVE_OPERATIONS.inc()
        start = time.time()

        try:
            file_path = self.work_dir / f"output_{worker_id}_{op_id}.dat"

            # Perform write based on pattern
            if self.config['io_pattern'] == 'sequential':
                bytes_written = self._sequential_write(file_path)
            else:  # random
                bytes_written = self._random_write(file_path)

            # Record metrics
            self.total_operations += 1
            self.total_bytes_written += bytes_written

            IO_OPERATIONS.labels(operation_type='write', status='success').inc()
            IO_BYTES.labels(operation_type='write').inc(bytes_written)

        except Exception as e:
            logger.error(f"Write operation failed: {str(e)}")
            IO_OPERATIONS.labels(operation_type='write', status='error').inc()

        finally:
            ACTIVE_OPERATIONS.dec()
            latency = time.time() - start
            IO_LATENCY.labels(operation_type='write').observe(latency)

    def _sequential_read(self, file_path):
        """Read file sequentially."""
        bytes_read = 0
        block_size = self.config['block_size']

        with open(file_path, 'rb') as f:
            while True:
                chunk = f.read(block_size)
                if not chunk:
                    break
                bytes_read += len(chunk)

        return bytes_read

    def _random_read(self, file_path):
        """Read file randomly."""
        bytes_read = 0
        block_size = self.config['block_size']
        file_size = file_path.stat().st_size

        with open(file_path, 'rb') as f:
            # Perform random reads
            num_reads = min(10, file_size // block_size)
            for _ in range(num_reads):
                offset = random.randint(0, max(0, file_size - block_size))
                f.seek(offset)
                chunk = f.read(block_size)
                bytes_read += len(chunk)

        return bytes_read

    def _sequential_write(self, file_path):
        """Write file sequentially."""
        bytes_written = 0
        block_size = self.config['block_size']
        file_size = self.config['file_size']

        with open(file_path, 'wb') as f:
            remaining = file_size
            while remaining > 0:
                write_size = min(block_size, remaining)
                data = os.urandom(write_size)
                f.write(data)
                bytes_written += write_size
                remaining -= write_size

            f.flush()
            os.fsync(f.fileno())  # Force write to disk

        return bytes_written

    def _random_write(self, file_path):
        """Write file randomly."""
        bytes_written = 0
        block_size = self.config['block_size']
        file_size = self.config['file_size']

        # Create file with random data
        with open(file_path, 'wb') as f:
            # Pre-allocate file
            f.seek(file_size - 1)
            f.write(b'\0')

        # Perform random writes
        with open(file_path, 'r+b') as f:
            num_writes = min(10, file_size // block_size)
            for _ in range(num_writes):
                offset = random.randint(0, max(0, file_size - block_size))
                f.seek(offset)
                data = os.urandom(block_size)
                f.write(data)
                bytes_written += block_size

            f.flush()
            os.fsync(f.fileno())

        return bytes_written

    def _write_file(self, file_path, size):
        """Write a file with random data."""
        block_size = self.config['block_size']

        with open(file_path, 'wb') as f:
            remaining = size
            while remaining > 0:
                write_size = min(block_size, remaining)
                f.write(os.urandom(write_size))
                remaining -= write_size

    def _cleanup(self):
        """Clean up test files."""
        if self.config.get('cleanup', True):
            logger.info("Cleaning up test files...")
            for file_path in self.work_dir.glob("*"):
                try:
                    file_path.unlink()
                except Exception as e:
                    logger.warning(f"Failed to delete {file_path}: {str(e)}")

    @staticmethod
    def _format_bytes(bytes_value):
        """Format bytes in human-readable format."""
        for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
            if bytes_value < 1024.0:
                return f"{bytes_value:.2f} {unit}"
            bytes_value /= 1024.0
        return f"{bytes_value:.2f} PB"


##############################################################################
# Signal Handling
##############################################################################

def signal_handler(signum, frame):
    """Handle shutdown signals."""
    global shutdown_requested

    logger.info(f"Received signal {signum}, initiating graceful shutdown...")
    shutdown_requested = True


##############################################################################
# Main Entry Point
##############################################################################

def parse_args():
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(
        description='DRC-IO Low-Priority Batch I/O Stress Generator'
    )

    parser.add_argument(
        '--work-dir',
        default='/tmp/io-stress',
        help='Working directory for I/O operations (default: /tmp/io-stress)'
    )

    parser.add_argument(
        '--file-size',
        type=int,
        default=100 * 1024 * 1024,  # 100 MB
        help='Size of files to create in bytes (default: 100MB)'
    )

    parser.add_argument(
        '--block-size',
        type=int,
        default=4096,  # 4 KB
        help='Block size for I/O operations in bytes (default: 4KB)'
    )

    parser.add_argument(
        '--num-operations',
        type=int,
        default=1000,
        help='Number of I/O operations to perform (default: 1000)'
    )

    parser.add_argument(
        '--io-pattern',
        choices=['sequential', 'random'],
        default='sequential',
        help='I/O access pattern (default: sequential)'
    )

    parser.add_argument(
        '--read-ratio',
        type=float,
        default=0.5,
        help='Ratio of read operations (0.0-1.0, default: 0.5)'
    )

    parser.add_argument(
        '--num-workers',
        type=int,
        default=1,
        help='Number of concurrent workers (default: 1)'
    )

    parser.add_argument(
        '--metrics-port',
        type=int,
        default=8000,
        help='Port for Prometheus metrics (default: 8000)'
    )

    parser.add_argument(
        '--no-cleanup',
        action='store_true',
        help='Do not clean up files after completion'
    )

    return parser.parse_args()


def main():
    """Main entry point."""
    args = parse_args()

    # Register signal handlers
    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)

    # Start Prometheus metrics server
    logger.info(f"Starting Prometheus metrics server on port {args.metrics_port}...")
    start_http_server(args.metrics_port)

    # Build configuration
    config = {
        'work_dir': args.work_dir,
        'file_size': args.file_size,
        'block_size': args.block_size,
        'num_operations': args.num_operations,
        'io_pattern': args.io_pattern,
        'read_ratio': args.read_ratio,
        'num_workers': args.num_workers,
        'cleanup': not args.no_cleanup
    }

    # Run workload
    try:
        generator = IOStressGenerator(config)
        generator.run()

        logger.info("✓ Batch job completed successfully")
        sys.exit(0)

    except Exception as e:
        logger.error(f"Batch job failed: {str(e)}", exc_info=True)
        sys.exit(1)


if __name__ == '__main__':
    main()
