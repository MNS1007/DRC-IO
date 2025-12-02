"""
Cgroup utilities for finding cgroup paths and applying I/O bandwidth limits.
Works with cgroup v2 io.max interface.
"""

import os
import logging
import re
from typing import Optional, List, Dict
from pathlib import Path

logger = logging.getLogger(__name__)

# Cgroup v2 mount point
CGROUP_ROOT = "/sys/fs/cgroup"
IO_MAX_FILE = "io.max"


def find_container_cgroup_path(container_id: str) -> Optional[str]:
    """
    Find the cgroup path for a container by its ID.
    
    Uses multiple strategies:
    1. Search /proc for processes with cgroup paths containing the container ID
    2. Check common Kubernetes cgroup paths (kubepods, system.slice, etc.)
    
    For cgroup v2, the format is: 0::/path/to/cgroup
    
    Args:
        container_id: Container ID (short or full)
        
    Returns:
        Cgroup path relative to /sys/fs/cgroup, or None if not found
    """
    # Try to find the container's main process
    # Container IDs in /proc are often in the format: <short_id> or full hash
    container_id_short = container_id[:12] if len(container_id) > 12 else container_id
    
    # Strategy 1: Search through /proc to find processes with matching cgroup
    for proc_dir in Path("/proc").iterdir():
        if not proc_dir.name.isdigit():
            continue
        
        try:
            cgroup_file = proc_dir / "cgroup"
            if not cgroup_file.exists():
                continue
            
            with open(cgroup_file, "r") as f:
                cgroup_content = f.read()
            
            # For cgroup v2, look for format: 0::/path
            # Also check if container ID appears in the cgroup path
            for line in cgroup_content.strip().split("\n"):
                if line.startswith("0::"):
                    cgroup_path = line[3:]  # Remove "0::" prefix
                    
                    # Check if this cgroup path contains the container ID
                    if container_id_short in cgroup_path or container_id in cgroup_path:
                        logger.debug(f"Found cgroup path {cgroup_path} for container {container_id_short}")
                        return cgroup_path
                        
        except (PermissionError, IOError, ValueError):
            continue
    
    # Strategy 2: Check common Kubernetes cgroup paths
    # Typical paths: /kubepods.slice/kubepods-<qos>.slice/kubepods-<qos>-pod<pod_uid>.slice/<container_id>
    common_prefixes = [
        "/kubepods.slice",
        "/system.slice",
    ]
    
    for prefix in common_prefixes:
        prefix_path = Path(CGROUP_ROOT) / prefix.lstrip("/")
        if not prefix_path.exists():
            continue
        
        # Recursively search for directories containing the container ID
        try:
            for cgroup_dir in prefix_path.rglob("*"):
                if cgroup_dir.is_dir() and (container_id_short in cgroup_dir.name or container_id in cgroup_dir.name):
                    # Check if this directory has an io.max file (confirms it's a valid cgroup)
                    if (cgroup_dir / IO_MAX_FILE).exists():
                        # Get relative path from CGROUP_ROOT
                        rel_path = str(cgroup_dir.relative_to(Path(CGROUP_ROOT)))
                        logger.debug(f"Found cgroup path {rel_path} for container {container_id_short} via directory search")
                        return f"/{rel_path}"
        except (PermissionError, IOError):
            continue
    
    logger.warning(f"Could not find cgroup path for container {container_id_short}")
    return None


def find_pod_cgroup_paths(pod: Dict) -> List[str]:
    """
    Find cgroup paths for all containers in a pod.
    
    Args:
        pod: Pod dictionary with container information
        
    Returns:
        List of cgroup paths (relative to /sys/fs/cgroup)
    """
    cgroup_paths = []
    
    for container in pod.get("containers", []):
        container_id = container.get("id", "")
        if not container_id:
            continue
        
        cgroup_path = find_container_cgroup_path(container_id)
        if cgroup_path:
            cgroup_paths.append(cgroup_path)
    
    return cgroup_paths


def discover_block_device(mount_path: str) -> Optional[str]:
    """
    Discover the block device backing a mount path by parsing /proc/self/mountinfo.
    
    Handles various device formats including:
    - Direct major:minor format (e.g., "8:0")
    - Device paths (e.g., "/dev/nvme0n1", "/dev/sda1") - resolves to major:minor
    - AWS EBS volumes (typically NVMe devices)
    
    Args:
        mount_path: The mount path (e.g., /mnt/features)
        
    Returns:
        Block device name (e.g., "8:0" for major:minor) or None if not found
    """
    try:
        with open("/proc/self/mountinfo", "r") as f:
            for line in f:
                parts = line.split()
                if len(parts) < 10:
                    continue
                
                # Format: <id> <parent> <major:minor> <root> <mount_point> ...
                mount_point = parts[4]
                if mount_point == mount_path:
                    # The device is in the third field (index 2)
                    device = parts[2]
                    
                    # If already in major:minor format, return it
                    if ":" in device and device.replace(":", "").isdigit():
                        logger.info(f"Found block device {device} for mount {mount_path}")
                        return device
                    
                    # Otherwise, resolve device path to major:minor
                    # Handle both absolute paths and relative device names
                    device_paths = [device]
                    if not device.startswith("/"):
                        # Try common device paths
                        device_paths.extend([
                            f"/dev/{device}",
                            f"/dev/disk/by-id/{device}",
                        ])
                    
                    for dev_path in device_paths:
                        try:
                            # Try to stat the device
                            if os.path.exists(dev_path):
                                stat = os.stat(dev_path)
                                # Check if it's a block device
                                if os.path.S_ISBLK(stat.st_mode):
                                    major = os.major(stat.st_rdev)
                                    minor = os.minor(stat.st_rdev)
                                    device_id = f"{major}:{minor}"
                                    logger.info(f"Resolved block device {dev_path} to {device_id} for mount {mount_path}")
                                    return device_id
                        except (OSError, AttributeError, ValueError):
                            continue
                    
                    # If device path doesn't exist, try to resolve via /proc/partitions
                    # This handles cases where device might be a partition
                    try:
                        with open("/proc/partitions", "r") as pf:
                            for part_line in pf:
                                part_parts = part_line.strip().split()
                                if len(part_parts) >= 4 and part_parts[3] == os.path.basename(device):
                                    major = int(part_parts[0])
                                    minor = int(part_parts[1])
                                    device_id = f"{major}:{minor}"
                                    logger.info(f"Resolved block device {device} to {device_id} via /proc/partitions")
                                    return device_id
                    except (IOError, ValueError):
                        pass
        
        logger.warning(f"Could not find block device for mount path {mount_path}")
        return None
        
    except IOError as e:
        logger.error(f"Failed to read /proc/self/mountinfo: {e}")
        return None


def apply_io_limit(cgroup_path: str, device: str, rbps: str, wbps: str) -> bool:
    """
    Apply I/O bandwidth limits to a cgroup using io.max.
    
    Format for io.max: <device> rbps=<value> wbps=<value>
    Values can be "max" or a number with suffix (e.g., "200M", "50M")
    
    Args:
        cgroup_path: Cgroup path relative to /sys/fs/cgroup
        device: Block device identifier (major:minor format, e.g., "8:0")
        rbps: Read bandwidth limit (e.g., "200M" or "max")
        wbps: Write bandwidth limit (e.g., "50M" or "max")
        
    Returns:
        True if successful, False otherwise
    """
    full_cgroup_path = os.path.join(CGROUP_ROOT, cgroup_path.lstrip("/"))
    io_max_file = os.path.join(full_cgroup_path, IO_MAX_FILE)
    
    if not os.path.exists(full_cgroup_path):
        logger.warning(f"Cgroup path does not exist: {full_cgroup_path}")
        return False
    
    # Format: <device> rbps=<value> wbps=<value>
    io_limit_line = f"{device} rbps={rbps} wbps={wbps}\n"
    
    try:
        # Read existing limits to preserve other device limits
        existing_limits = []
        if os.path.exists(io_max_file):
            with open(io_max_file, "r") as f:
                existing_limits = [line.strip() for line in f if line.strip()]
        
        # Remove existing limit for this device if present
        existing_limits = [
            line for line in existing_limits
            if not line.startswith(f"{device} ")
        ]
        
        # Add new limit
        existing_limits.append(io_limit_line.strip())
        
        # Write all limits back
        with open(io_max_file, "w") as f:
            f.write("\n".join(existing_limits) + "\n")
        
        logger.info(f"Applied I/O limit rbps={rbps} wbps={wbps} to cgroup {cgroup_path} for device {device}")
        return True
        
    except (IOError, PermissionError) as e:
        logger.error(f"Failed to write to {io_max_file}: {e}")
        return False


def get_current_io_limits(cgroup_path: str) -> Dict[str, Dict[str, str]]:
    """
    Read current I/O limits from a cgroup's io.max file.
    
    Args:
        cgroup_path: Cgroup path relative to /sys/fs/cgroup
        
    Returns:
        Dictionary mapping device to limits: {device: {"rbps": "...", "wbps": "..."}}
    """
    full_cgroup_path = os.path.join(CGROUP_ROOT, cgroup_path.lstrip("/"))
    io_max_file = os.path.join(full_cgroup_path, IO_MAX_FILE)
    
    limits = {}
    
    if not os.path.exists(io_max_file):
        return limits
    
    try:
        with open(io_max_file, "r") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                
                # Parse format: <device> rbps=<value> wbps=<value>
                match = re.match(r"(\S+)\s+rbps=(\S+)\s+wbps=(\S+)", line)
                if match:
                    device, rbps, wbps = match.groups()
                    limits[device] = {"rbps": rbps, "wbps": wbps}
    except (IOError, PermissionError) as e:
        logger.error(f"Failed to read {io_max_file}: {e}")
    
    return limits

