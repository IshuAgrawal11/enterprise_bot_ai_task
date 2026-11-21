# Part 5 — Written Answers

### Q1. Migrating ~40 Ingress Objects from `ingress-nginx` to Gateway API with Zero Downtime

#### High-Level Approach
Migrating live traffic requires running both ingress controllers in parallel, verifying routing parity via canary testing, and performing a gradual, weighted DNS cutover.

#### Phased Execution Order

1. **Prerequisites & Infrastructure Deployment**:
   - Install the official Gateway API CRDs (`GatewayClass`, `Gateway`, `HTTPRoute`).
   - Deploy the new Gateway controller (e.g., Envoy Gateway, Cilium, or Cloud Load Balancer) alongside `ingress-nginx`.
   - Provision a shared `Gateway` resource with an independent external IP/LoadBalancer and wildcard/SAN TLS certificates via `cert-manager`.

2. **Automated Manifest Translation**:
   - Translate all 40 `Ingress` objects into `HTTPRoute` resources (using tools like `ingress2gateway` followed by manual review).
   - Ensure routes bind correctly to the new Gateway via `parentRefs` while existing Ingress objects remain active.

3. **Validation & Shadow Testing**:
   - Verify health and behavior of all 40 routes by curling the new Gateway IP directly using `Host` headers and local `/etc/hosts` overrides before pointing production DNS.
   - Run synthetic end-to-end regression suites against the Gateway endpoint.

4. **Zero-Downtime Traffic Shift (Weighted Cutover)**:
   - For low-risk services: Cut over CNAME records to the Gateway.
   - For mission-critical endpoints: Use weighted Route53/Cloudflare DNS records (e.g., 5% $\rightarrow$ 25% $\rightarrow$ 50% $\rightarrow$ 100%) to monitor error rates, latency (p95/p99), and proxy logs.

5. **Bake Period & Decommissioning**:
   - Leave `ingress-nginx` running for a 48–72 hour soak period to capture lingering DNS caches or hardcoded clients.
   - Delete legacy `Ingress` objects and uninstall `ingress-nginx`.

---

#### What to Expect to Break Along the Way

- **Nginx Ingress Annotations**: Custom nginx annotations (`configuration-snippet`, `server-snippet`, regex rewrites, `proxy-body-size`) do not map 1:1 to core Gateway API. They must be re-implemented using vendor-specific filters (e.g., Envoy `ExtensionRef` or URL rewrite filters).
- **Client IP & Header Preservation**: Differences in `X-Forwarded-For`, `X-Real-IP`, and PROXY protocol handling can break upstream geo-blocking, audit logging, and rate-limiting.
- **WebSocket & gRPC Streaming**: Protocols requiring explicit connection upgrades or long timeouts may drop connections if timeout policies are not tuned in `HTTPRoute`.
- **CORS & Authentication Hooks**: External authentication (`nginx.ingress.kubernetes.io/auth-url`) and CORS policies must be converted to native Gateway API or Envoy authentication filters.
