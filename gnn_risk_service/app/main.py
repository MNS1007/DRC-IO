import os
import time
import pandas as pd
import torch
from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import PlainTextResponse, JSONResponse
from prometheus_client import Counter, Histogram, generate_latest, CollectorRegistry, CONTENT_TYPE_LATEST

from model import SimpleGCN, build_norm_adjacency, load_model_or_init

# Config defaults
FEATURES_PATH = os.getenv("FEATURES_PATH", "data/features.csv")
EDGES_PATH = os.getenv("EDGES_PATH", "data/edges.csv")
MODEL_PATH = os.getenv("MODEL_PATH", "data/model.pt")
SLA_MS = float(os.getenv("SLA_MS", "500"))

device = torch.device("cuda" if torch.cuda.is_available() else "cpu")

app = FastAPI(title="GNN Risk Modeling Service")

registry = CollectorRegistry()
REQUEST_LATENCY = Histogram(
    "gnn_request_latency_seconds",
    "Latency of GNN scoring",
    ["endpoint"],
    registry=registry,
)
SLA_VIOLATIONS = Counter(
    "gnn_sla_violations_total",
    "Number of SLA violations",
    ["endpoint"],
    registry=registry,
)
TOTAL_REQUESTS = Counter(
    "gnn_requests_total",
    "Total requests",
    ["endpoint"],
    registry=registry,
)

features_df = None
node_index_map = None
norm_adj = None
gnn_model = None

@app.on_event("startup")
def load_artifacts():
    global features_df, node_index_map, norm_adj, gnn_model

    features_df = pd.read_csv(FEATURES_PATH)
    node_ids = features_df["node_id"].astype(int).tolist()
    node_index_map = {nid: i for i, nid in enumerate(node_ids)}

    feature_cols = [c for c in features_df.columns if c != "node_id"]
    x = torch.tensor(features_df[feature_cols].values, dtype=torch.float32, device=device)

    edges_df = pd.read_csv(EDGES_PATH)
    edges = torch.tensor(edges_df[["src", "dst"]].values, dtype=torch.long, device=device)

    norm_adj_local = build_norm_adjacency(len(features_df), edges)

    model = load_model_or_init(
        in_dim=len(feature_cols),
        model_path=MODEL_PATH,
        device=device
    )

    gnn_model = model
    norm_adj = norm_adj_local


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/metrics")
def metrics():
    data = generate_latest(registry)
    return PlainTextResponse(data.decode("utf-8"), media_type=CONTENT_TYPE_LATEST)


@app.get("/score")
def score(node_id: int):
    endpoint = "/score"
    TOTAL_REQUESTS.labels(endpoint=endpoint).inc()
    start = time.perf_counter()

    if node_id not in node_index_map:
        raise HTTPException(status_code=404, detail="Invalid node_id")

    idx = node_index_map[node_id]

    feature_cols = [c for c in features_df.columns if c != "node_id"]
    x = torch.tensor(features_df[feature_cols].values, dtype=torch.float32, device=device)

    with torch.no_grad():
        scores = gnn_model(x, norm_adj)
        score_value = float(scores[idx].item())

    latency = time.perf_counter() - start
    REQUEST_LATENCY.labels(endpoint=endpoint).observe(latency)

    sla_exceeded = latency * 1000 > SLA_MS
    if sla_exceeded:
        SLA_VIOLATIONS.labels(endpoint=endpoint).inc()

    return {
        "node_id": node_id,
        "risk_score": score_value,
        "latency_ms": latency * 1000,
        "sla_ms": SLA_MS,
        "sla_exceeded": sla_exceeded
    }
