"""
Kubernetes API utilities for the DRC I/O controller.
Handles pod listing, node detection, and container information extraction.
"""

import os
import logging
from typing import List, Dict, Optional
from kubernetes import client, config
from kubernetes.client.rest import ApiException

logger = logging.getLogger(__name__)


def load_k8s_config():
    """Load Kubernetes configuration (in-cluster or from kubeconfig)."""
    try:
        config.load_incluster_config()
        logger.info("Loaded in-cluster Kubernetes configuration")
    except config.ConfigException:
        try:
            config.load_kube_config()
            logger.info("Loaded Kubernetes configuration from kubeconfig")
        except config.ConfigException as e:
            logger.error(f"Failed to load Kubernetes configuration: {e}")
            raise


def get_node_name() -> str:
    """
    Determine the current node name.
    Checks environment variable MY_NODE_NAME first, then falls back to
    Kubernetes downward API field reference or hostname.
    """
    # Try environment variable first (set by DaemonSet)
    node_name = os.environ.get("MY_NODE_NAME")
    if node_name:
        logger.info(f"Node name from MY_NODE_NAME: {node_name}")
        return node_name
    
    # Fallback to hostname
    node_name = os.environ.get("HOSTNAME") or os.uname().nodename
    logger.info(f"Node name from hostname: {node_name}")
    return node_name


def list_pods_on_node(node_name: str) -> List[Dict]:
    """
    List all pods running on the specified node.
    
    Args:
        node_name: The name of the Kubernetes node
        
    Returns:
        List of pod dictionaries with metadata and container information
    """
    try:
        v1 = client.CoreV1Api()
        pods = v1.list_pod_for_all_namespaces(
            field_selector=f"spec.nodeName={node_name}",
            watch=False
        )
        
        pod_list = []
        for pod in pods.items:
            if pod.status.phase not in ["Running", "Pending"]:
                continue
                
            pod_info = {
                "name": pod.metadata.name,
                "namespace": pod.metadata.namespace,
                "uid": pod.metadata.uid,
                "labels": pod.metadata.labels or {},
                "containers": []
            }
            
            # Extract container information
            for container_status in pod.status.container_statuses or []:
                if container_status.container_id:
                    # Extract container ID (format: docker://<id> or containerd://<id>)
                    container_id = container_status.container_id.split("://")[-1]
                    pod_info["containers"].append({
                        "name": container_status.name,
                        "id": container_id,
                        "ready": container_status.ready
                    })
            
            pod_list.append(pod_info)
        
        logger.debug(f"Found {len(pod_list)} pods on node {node_name}")
        return pod_list
        
    except ApiException as e:
        logger.error(f"Failed to list pods: {e}")
        raise


def group_pods_by_priority(pods: List[Dict]) -> tuple[List[Dict], List[Dict]]:
    """
    Group pods into high priority and low priority based on group-id label.
    
    Args:
        pods: List of pod dictionaries
        
    Returns:
        Tuple of (high_priority_pods, low_priority_pods)
    """
    high_priority = []
    low_priority = []
    
    for pod in pods:
        group_id = pod.get("labels", {}).get("group-id", "")
        if group_id == "hp":
            high_priority.append(pod)
        elif group_id == "lp":
            low_priority.append(pod)
    
    logger.info(f"Detected {len(high_priority)} high priority pods and {len(low_priority)} low priority pods")
    return high_priority, low_priority

