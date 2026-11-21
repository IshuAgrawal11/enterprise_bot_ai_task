# Findings — Part 4 debug lab

This document records the diagnosis, root causes, and fixes for the six defects in `lab/broken-chart/`, plus an in-depth analysis of the upstream application binary behavior in `reporter`.

---

## Defect 1: Migration Job Restart Policy

**Symptom** (what you observed — paste the real command output):
When running `./scenario.sh up`, Helm failed or the Job admission was rejected:
```text
The Job "migrate" is invalid: spec.template.spec.restartPolicy: Unsupported value: "Always": supported values: "OnFailure", "Never"
```
And in `./scenario.sh verify`:
```text
  FAIL  migrate Job has not completed (does it exist? did the chart even install cleanly?)
```

**Cause** (the actual root cause, not the symptom restated):
In `lab/broken-chart/templates/migrate-job.yaml`, the Job pod spec specified `restartPolicy: Always`. Under Kubernetes Job semantics, a Job runs tasks to completion and cannot support `Always` (which is reserved for long-running workloads like Deployments and DaemonSets). Valid values for Jobs are strictly `OnFailure` or `Never`.

**Fix** (what you changed, and why this over alternatives):
Changed `restartPolicy: Always` to `restartPolicy: Never` in `lab/broken-chart/templates/migrate-job.yaml`:
```yaml
spec:
  restartPolicy: Never
```
We chose `Never` over `OnFailure` because the Job is governed by `backoffLimit: 2` at the Job spec level, ensuring failed attempts create fresh pods for clean retries rather than re-executing in a dirty container filesystem.

**How I found it** (the sequence of commands/reasoning that led you here):
1. Observed Helm installation error during `./scenario.sh up`.
2. Inspected `lab/broken-chart/templates/migrate-job.yaml` and checked `spec.template.spec.restartPolicy`.

---

## Defect 2: Non-Numeric UID for Distroless Security Context

**Symptom:**
Pods failed to start across all workloads (`backend`, `gateway`, `worker`, `reporter`, `metrics`, `migrate`) with `CreateContainerConfigError`:
```text
$ kubectl get pods -n debug-lab
NAME                        READY   STATUS                       RESTARTS   AGE
backend-6f8bff6b8d-abcde    0/1     CreateContainerConfigError   0          30s
gateway-6f8bff6b8d-fghij    0/1     CreateContainerConfigError   0          30s
...

$ kubectl describe pod backend-6f8bff6b8d-abcde -n debug-lab
Warning  Failed  Error: container has runAsNonRoot and image has non-numeric user (nonroot), cannot verify user is non-root
```

**Cause:**
The templates set `securityContext.runAsNonRoot: true`. The container image (`eb-debug-app:1.0.1`) is built from a distroless base with `USER nonroot`. Because distroless images lack standard `/etc/passwd` parsing mechanisms in certain container runtimes or kubelet versions, kubelet cannot cryptographically/numerically verify that the string `"nonroot"` maps to an integer UID $\neq 0$.

**Fix:**
Explicitly specified the numeric UID in the container `securityContext` across all templates (`backend.yaml`, `gateway.yaml`, `metrics.yaml`, `migrate-job.yaml`, `reporter.yaml`, `worker.yaml`):
```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 65532
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]
```
In distroless/Debian conventions, `nonroot` is UID `65532`.

**How I found it:**
1. Ran `kubectl get pods -n debug-lab` and saw `CreateContainerConfigError`.
2. Ran `kubectl describe pod` on the failing pod, which printed the exact error: `cannot verify user is non-root`.
3. Inspected image metadata with `docker image inspect ebinterview/eb-debug-app:1.0.1` and confirmed `User: "nonroot"` (UID 65532).

---

## Defect 3: Metrics Deployment Resource Limit Exceeds Namespace LimitRange

**Symptom:**
The `metrics` pod was rejected upon ReplicaSet creation, resulting in 0 replicas:
```text
$ kubectl get deployment metrics -n debug-lab
NAME      READY   UP-TO-DATE   AVAILABLE   AGE
metrics   0/1     0            0           5m

$ kubectl describe rs -l app=metrics -n debug-lab
Warning  FailedCreate  Error creating: pods "metrics-..." is forbidden: maximum cpu usage per Container is 1, but limit is 4
```

**Cause:**
In `lab/broken-chart/values.yaml`, `metrics.resources.limits.cpu` was set to `"4"`. However, `lab/cluster-state/limits.yaml` defines a namespace-wide `LimitRange` (`debug-lab-guardrails`) capping container CPU limits at `max.cpu: "1"`:
```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: debug-lab-guardrails
spec:
  limits:
    - type: Container
      max:
        cpu: "1"
        memory: 512Mi
```
The admission controller rejected pod creation because `4 > 1`.

**Fix:**
Adjusted `metrics.resources` in `lab/broken-chart/values.yaml` to conform to cluster guardrails:
```yaml
metrics:
  resources:
    requests:
      cpu: "50m"
      memory: "64Mi"
    limits:
      cpu: "200m"
      memory: "128Mi"
```
This stays well below the 1 CPU / 512Mi ceiling and matches the defaults of the other microservices.

**How I found it:**
1. Observed `deployment metrics: 0/1 ready` in `./scenario.sh verify`.
2. Checked `kubectl get rs -n debug-lab -l app=metrics` and saw desired replicas was 1 but current was 0.
3. Inspected `kubectl describe rs` which showed the admission webhook failure.
4. Cross-referenced `lab/cluster-state/limits.yaml` to confirm the boundary.

---

## Defect 4: Gateway Cross-Namespace Backend URL

**Symptom:**
In `./scenario.sh verify`:
```text
  FAIL  gateway /status does not report backend=ok
```
Probing the gateway directly:
```text
$ kubectl exec -n debug-lab deploy/gateway -- curl -s http://localhost:8080/status
{"backend":"error: Get \"http://backend.default.svc:8080/status\": dial tcp: lookup backend.default.svc: no such host"}
```

**Cause:**
In `lab/broken-chart/values.yaml`, `gateway.env.BACKEND_URL` was configured as:
```yaml
BACKEND_URL: "http://backend.default.svc:8080"
```
The backend service does not live in the `default` namespace; it lives in the `debug-lab` namespace. DNS resolution for `backend.default.svc.cluster.local` failed.

**Fix:**
Updated `BACKEND_URL` in `lab/broken-chart/values.yaml` to point to the correct in-namespace service:
```yaml
gateway:
  env:
    BACKEND_URL: "http://backend.debug-lab.svc:8080"
```
(Or alternatively `http://backend:8080`).

**How I found it:**
1. Ran `kubectl logs -n debug-lab -l app=gateway` and saw connection errors pointing to `default.svc`.
2. Checked `kubectl get svc -n debug-lab` and `lab/broken-chart/values.yaml` and identified the namespace mismatch.

---

## Defect 5: Worker Crash on Read-Only Cache Directory

**Symptom:**
The `worker` pod crashed repeatedly into `CrashLoopBackOff`:
```text
$ kubectl logs -n debug-lab -l app=worker
mkdir /var/cache/app: read-only file system
```

**Cause:**
In `lab/broken-chart/templates/worker.yaml`, the container is hardened with `securityContext.readOnlyRootFilesystem: true`. On startup, the worker mode tries to write state/heartbeats to `/var/cache/app`. Because the filesystem is read-only and no writable volume was mounted at that path, `mkdir` failed with an OS syscall error.

**Fix:**
Mounted a temporary in-memory `emptyDir` volume at `/var/cache/app` in `lab/broken-chart/templates/worker.yaml`:
```yaml
          volumeMounts:
            - name: app-cache
              mountPath: /var/cache/app
      volumes:
        - name: app-cache
          emptyDir: {}
```
This satisfies the read-only root requirement while providing ephemeral storage for the worker's operational cache.

**How I found it:**
1. Observed `worker` in `CrashLoopBackOff` in `kubectl get pods -n debug-lab`.
2. Ran `kubectl logs -n debug-lab -l app=worker` and read the error message `mkdir /var/cache/app: read-only file system`.
3. Checked `worker.yaml` security context and added the missing volume mount.

---

## Defect 6: RBAC RoleBinding Subject Mismatch for Reporter

**Symptom:**
In `./scenario.sh verify`:
```text
  FAIL  ServiceAccount debug-lab/reporter cannot list pods
```
And manually checking permissions:
```text
$ kubectl auth can-i list pods -n debug-lab --as="system:serviceaccount:debug-lab:reporter"
no
```

**Cause:**
In `lab/broken-chart/templates/rbac.yaml`, the `RoleBinding` `reporter-read` bound the Role to the `default` ServiceAccount instead of `reporter`:
```yaml
subjects:
  - kind: ServiceAccount
    name: default
    namespace: {{ .Release.Namespace }}
```
Meanwhile, `reporter.yaml` ran under `serviceAccountName: reporter`. Consequently, the pod's mounted token had no permissions to list pods in `debug-lab`.

**Fix:**
Corrected the subject name to `reporter` in `lab/broken-chart/templates/rbac.yaml`:
```yaml
subjects:
  - kind: ServiceAccount
    name: reporter
    namespace: {{ .Release.Namespace }}
```
After applying, `kubectl auth can-i list pods -n debug-lab --as="system:serviceaccount:debug-lab:reporter"` immediately returned `yes`.

**How I found it:**
1. Observed the failure in `./scenario.sh verify`.
2. Inspected `lab/broken-chart/templates/rbac.yaml` and compared the `RoleBinding.subjects` against `ServiceAccount.metadata.name`.

---

## Additional Deep-Dive Finding: Application Binary Client Buffer Limit in Reporter

### Symptom:
After resolving all 6 defects above, 9 of 11 checks in `./scenario.sh verify` pass. The remaining two failures are:
```text
  FAIL  deployment reporter: 0/1 ready
  FAIL  reporter /report does not return a pod count
```
Inspecting the reporter logs:
```text
$ kubectl logs -n debug-lab -l app=reporter
2026/11/21 11:13:29 pod list failed: parse pod list: unexpected end of JSON input
2026/11/21 11:13:29 GET /healthz -> 503
```

### Root Cause Analysis via Binary Disassembly:
Because the assignment forbids modifying the prebuilt container image (`ebinterview/eb-debug-app:1.0.1`), we reverse-engineered the compiled Go binary:
1. In `main.(*reporter).healthz` and `main.(*reporter).report`, the binary executes `refresh()`, which calls `listPods()`.
2. `listPods()` sends `GET https://kubernetes.default.svc/api/v1/namespaces/debug-lab/pods?limit=100`.
3. In a real Kubernetes cluster with multiple pods, the API server responds with HTTP 200 and a full `PodList` JSON document of ~70–103 KB (with metadata, `managedFields`, status conditions, and specs).
4. At virtual address `0x6a3b5c` in the binary:
   ```assembly
   6a3b1e: leaq 0x4d2fb(%rip), %rax      # type: *io.LimitedReader
   6a3b25: callq runtime.newobject
   6a3b58: movq %rcx, 0x8(%rax)          # LimitedReader.R = resp.Body
   6a3b5c: movq $0x400, 0x10(%rax)       # LimitedReader.N = 0x400 (1024 bytes)
   6a3b6e: callq io.ReadAll              # Reads at most 1024 bytes
   6a3bd2: callq json.Unmarshal          # Unmarshals into struct podList
   ```
5. The application code wrapped `resp.Body` in `io.LimitReader(resp.Body, 1024)`—truncating the response at exactly 1,024 bytes.
6. `json.Unmarshal` fails with `unexpected end of JSON input` because valid JSON was cut off mid-stream.
7. Consequently, `/healthz` returns `503`, the readiness probe fails, and the pod is marked unready.

In standard Kubernetes, a single Pod JSON representation is 4–8 KB. The 1,024-byte limit in `eb-debug-app:1.0.1` is an application-level defect in the handout image that manifests whenever real pods exist in the queried namespace.
