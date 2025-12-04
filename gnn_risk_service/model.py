import torch
import torch.nn as nn


class SimpleGCN(nn.Module):
    """
    Minimal GCN-like model:
    h = ReLU(Â X W1)
    out = Â h W2
    """
    def __init__(self, in_dim: int, hidden_dim: int = 32, out_dim: int = 1):
        super().__init__()
        self.fc1 = nn.Linear(in_dim, hidden_dim)
        self.fc2 = nn.Linear(hidden_dim, out_dim)

    def forward(self, x, norm_adj):
        h = norm_adj @ x
        h = torch.relu(self.fc1(h))
        out = norm_adj @ h
        out = self.fc2(out)
        return out.squeeze(-1)


def build_norm_adjacency(num_nodes, edges):
    device = edges.device
    adj = torch.zeros((num_nodes, num_nodes), device=device)

    src = edges[:, 0]
    dst = edges[:, 1]

    adj[src, dst] = 1.0
    adj[dst, src] = 1.0  # undirected

    # self-loops
    idx = torch.arange(num_nodes, device=device)
    adj[idx, idx] = 1.0

    deg = adj.sum(dim=1)
    deg_inv_sqrt = torch.pow(deg, -0.5)
    deg_inv_sqrt[torch.isinf(deg_inv_sqrt)] = 0.0

    D_inv_sqrt = torch.diag(deg_inv_sqrt)
    norm_adj = D_inv_sqrt @ adj @ D_inv_sqrt
    return norm_adj


def load_model_or_init(in_dim, model_path, device):
    model = SimpleGCN(in_dim=in_dim).to(device)
    try:
        state = torch.load(model_path, map_location=device)
        model.load_state_dict(state)
        print(f"[GNN] Loaded model from {model_path}")
    except FileNotFoundError:
        print(f"[GNN] No model at {model_path}, using random init.")
    model.eval()
    return model
