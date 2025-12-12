import os
import time
import signal
import logging
import sys
from datetime import datetime

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Configuration
DATA_DIR = os.getenv('DATA_DIR', '/data')
IO_INTENSITY = int(os.getenv('IO_INTENSITY', '8'))  # 1-10 scale
FILE_SIZE_MB = 100  # Size of each file operation

# Global flag for graceful shutdown
running = True


def signal_handler(signum, frame):
    """Handle shutdown signals gracefully"""
    global running
    logger.info(f"Received signal {signum}, shutting down gracefully...")
    running = False


# Register signal handlers
signal.signal(signal.SIGTERM, signal_handler)
signal.signal(signal.SIGINT, signal_handler)


class IOStressGenerator:
    """
    Generates heavy disk I/O load to simulate batch feature engineering.
    This creates contention with the HP GNN service.
    """

    def __init__(self, data_dir, intensity):
        self.data_dir = data_dir
        self.intensity = intensity
        self.iteration = 0
        self.total_bytes_written = 0
        self.total_bytes_read = 0
        self.start_time = time.time()

        # Create data directory
        os.makedirs(data_dir, exist_ok=True)

        logger.info("Initialized I/O Stress Generator")
        logger.info(f"Data Directory: {data_dir}")
        logger.info(f"Intensity: {intensity}/10")
        logger.info(f"File Size: {FILE_SIZE_MB} MB per operation")

    def write_file(self, filename, size_mb):
        """Write a file with random data"""
        filepath = os.path.join(self.data_dir, filename)
        bytes_written = 0

        chunk_size = 1024 * 1024  # 1 MB chunks

        with open(filepath, 'wb') as f:
            for _ in range(size_mb):
                # Generate random data (simulates feature computation)
                data = os.urandom(chunk_size)
                f.write(data)
                bytes_written += chunk_size

                # Flush to disk to ensure actual I/O
                if bytes_written % (10 * chunk_size) == 0:
                    f.flush()
                    os.fsync(f.fileno())

        # Final sync
        with open(filepath, 'rb') as f:
            os.fsync(f.fileno())

        self.total_bytes_written += bytes_written
        return bytes_written

    def read_file(self, filename):
        """Read a file completely"""
        filepath = os.path.join(self.data_dir, filename)
        bytes_read = 0

        if not os.path.exists(filepath):
            return 0

        chunk_size = 1024 * 1024  # 1 MB chunks

        with open(filepath, 'rb') as f:
            while True:
                chunk = f.read(chunk_size)
                if not chunk:
                    break
                bytes_read += len(chunk)

        self.total_bytes_read += bytes_read
        return bytes_read

    def process_batch(self):
        """
        Simulate one batch processing iteration.
        Represents feature engineering: read raw data, compute, write features.
        """
        self.iteration += 1
        iteration_start = time.time()

        logger.info(f"═══ Iteration {self.iteration} starting ═══")

        # Step 1: Write "raw transaction data" (simulates data ingestion)
        raw_file = f"raw_transactions_{self.iteration}.dat"
        logger.info(f"Writing {FILE_SIZE_MB}MB raw data...")
        write_start = time.time()
        bytes_written = self.write_file(raw_file, FILE_SIZE_MB)
        write_time = time.time() - write_start
        write_throughput = (bytes_written / (1024 * 1024)) / write_time if write_time > 0 else 0
        logger.info(f"  Written: {bytes_written / (1024 * 1024):.1f} MB in {write_time:.2f}s ({write_throughput:.1f} MB/s)")

        # Step 2: Read back for processing (simulates feature computation)
        logger.info(f"Reading {FILE_SIZE_MB}MB for processing...")
        read_start = time.time()
        bytes_read = self.read_file(raw_file)
        read_time = time.time() - read_start
        read_throughput = (bytes_read / (1024 * 1024)) / read_time if read_time > 0 else 0
        logger.info(f"  Read: {bytes_read / (1024 * 1024):.1f} MB in {read_time:.2f}s ({read_throughput:.1f} MB/s)")

        # Step 3: Simulate computation (in real world, this would be feature engineering)
        compute_time = 0.5  # Small compute between I/O operations
        time.sleep(compute_time)

        # Step 4: Write "computed features" (simulates feature output)
        feature_file = f"features_{self.iteration}.dat"
        logger.info(f"Writing {FILE_SIZE_MB}MB computed features...")
        write_start = time.time()
        bytes_written = self.write_file(feature_file, FILE_SIZE_MB)
        write_time = time.time() - write_start
        write_throughput = (bytes_written / (1024 * 1024)) / write_time if write_time > 0 else 0
        logger.info(f"  Written: {bytes_written / (1024 * 1024):.1f} MB in {write_time:.2f}s ({write_throughput:.1f} MB/s)")

        # Cleanup old files to prevent disk fill
        if self.iteration > 5:
            old_iteration = self.iteration - 5
            for f in [f"raw_transactions_{old_iteration}.dat", f"features_{old_iteration}.dat"]:
                filepath = os.path.join(self.data_dir, f)
                if os.path.exists(filepath):
                    os.remove(filepath)

        iteration_time = time.time() - iteration_start

        # Log iteration summary
        logger.info(f"═══ Iteration {self.iteration} complete ═══")
        logger.info(f"  Total time: {iteration_time:.2f}s")
        logger.info(f"  I/O time: {write_time + read_time:.2f}s")
        logger.info(f"  Compute time: {compute_time:.2f}s")
        logger.info("")

        return iteration_time

    def print_statistics(self):
        """Print cumulative statistics"""
        elapsed = time.time() - self.start_time
        elapsed_min = elapsed / 60

        total_written_gb = self.total_bytes_written / (1024 ** 3)
        total_read_gb = self.total_bytes_read / (1024 ** 3)
        total_io_gb = total_written_gb + total_read_gb

        avg_write_throughput = (self.total_bytes_written / (1024 ** 2)) / elapsed if elapsed > 0 else 0
        avg_read_throughput = (self.total_bytes_read / (1024 ** 2)) / elapsed if elapsed > 0 else 0

        logger.info("╔════════════════════════════════════════════════════════╗")
        logger.info("║              BATCH JOB STATISTICS                      ║")
        logger.info("╠════════════════════════════════════════════════════════╣")
        logger.info(f"║  Iterations:        {self.iteration:>6}                           ║")
        logger.info(f"║  Elapsed time:      {elapsed_min:>6.1f} minutes                   ║")
        logger.info(f"║  Data written:      {total_written_gb:>6.2f} GB                      ║")
        logger.info(f"║  Data read:         {total_read_gb:>6.2f} GB                      ║")
        logger.info(f"║  Total I/O:         {total_io_gb:>6.2f} GB                      ║")
        logger.info(f"║  Avg write speed:   {avg_write_throughput:>6.1f} MB/s                   ║")
        logger.info(f"║  Avg read speed:    {avg_read_throughput:>6.1f} MB/s                   ║")
        logger.info("╚════════════════════════════════════════════════════════╝")
        logger.info("")

    def run(self):
        """Main execution loop"""
        logger.info("Starting batch processing loop...")
        logger.info("This simulates feature engineering with heavy I/O")
        logger.info("")

        last_stats_time = time.time()

        while running:
            try:
                # Process one batch iteration
                iteration_time = self.process_batch()

                # Print statistics every 10 iterations or 5 minutes
                if self.iteration % 10 == 0 or (time.time() - last_stats_time) > 300:
                    self.print_statistics()
                    last_stats_time = time.time()

                # Sleep between iterations based on intensity
                # Lower intensity = longer sleep
                sleep_time = max(0.1, (11 - self.intensity) * 0.5)
                logger.info(f"Sleeping {sleep_time:.1f}s before next iteration...")
                time.sleep(sleep_time)

            except Exception as e:
                logger.error(f"Error in iteration {self.iteration}: {str(e)}", exc_info=True)
                time.sleep(5)

        # Final statistics
        logger.info("")
        logger.info("Batch job shutting down...")
        self.print_statistics()
        logger.info("Batch job terminated.")


def main():
    """Main entry point"""
    logger.info("╔════════════════════════════════════════════════════════╗")
    logger.info("║     LOW-PRIORITY BATCH JOB (I/O STRESS GENERATOR)     ║")
    logger.info("╚════════════════════════════════════════════════════════╝")
    logger.info("")
    logger.info("This job simulates feature engineering batch processing")
    logger.info("that creates I/O contention with real-time services.")
    logger.info("")

    # Create stress generator
    stress_gen = IOStressGenerator(DATA_DIR, IO_INTENSITY)

    # Run the batch job
    stress_gen.run()


if __name__ == '__main__':
    main()
