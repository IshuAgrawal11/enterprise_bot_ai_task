#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

CLUSTER_NAME="demo"

# 1. Create or reuse kind cluster named demo
if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  echo "==> Creating kind cluster '${CLUSTER_NAME}' with ingress-ready node and port mappings..."
  cat <<EOF | kind create cluster --name "$CLUSTER_NAME" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
EOF
else
  echo "==> Kind cluster '${CLUSTER_NAME}' already exists; reusing."
fi

# Ensure kubectl context is set
echo "==> Verifying cluster context kind-${CLUSTER_NAME}..."
kubectl cluster-info --context "kind-${CLUSTER_NAME}" >/dev/null

# 2. Install ingress-nginx controller (kind-specific manifest)
echo "==> Applying ingress-nginx manifest..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

echo "==> Waiting for ingress-nginx controller pod to exist..."
until kubectl get pod -n ingress-nginx -l app.kubernetes.io/component=controller --no-headers 2>/dev/null | grep -q .; do
  sleep 1
done

echo "==> Waiting for ingress-nginx controller to be ready..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s

# 3. Build Docker image and load into kind
echo "==> Building Docker image demo-service:1.0.0..."
docker build -t demo-service:1.0.0 ./service

echo "==> Loading Docker image into kind cluster '${CLUSTER_NAME}'..."
kind load docker-image demo-service:1.0.0 --name "$CLUSTER_NAME"

# 4. Deploy Helm chart idempotently
echo "==> Installing/upgrading Helm chart 'demo' in namespace 'demo'..."
helm upgrade --install demo ./chart --namespace demo --create-namespace --wait

echo "==> Setup completed successfully."
