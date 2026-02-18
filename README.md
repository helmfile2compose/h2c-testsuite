# h2c-testsuite

Regression and performance test suite for [helmfile2compose](https://github.com/helmfile2compose).

Compares h2c output between a **pinned reference version** and the **latest release** across a set of static edge-case manifests. The test harness uses h2c-manager (rolling from main) as the runner — it's the tool, not the subject. What's compared is core + extensions output between versions.

## Quick start

```bash
# Full regression: reference vs latest
./run-tests.sh

# Override reference core version
./run-tests.sh --core v2.0.0

# Override reference extension version
./run-tests.sh --ext keycloak==v0.1.0

# Performance test (run locally, not in CI)
./run-tests.sh --perf 5         # fast
./run-tests.sh --perf 15        # notable
./run-tests.sh --perf 30        # pain
./run-tests.sh --perf 15 --keep # keep /tmp output for inspection
```

## What it does

### Regression

1. Downloads h2c-manager from `main`
2. Creates two workdirs in `/tmp` — one for the reference version, one for latest
3. Runs h2c multiple times per version:
   - **Core only** (no extensions) — baseline
   - **Each extension individually** — isolation testing
   - **All extensions together** — interaction testing
4. Diffs the output directories
5. Cleans up `/tmp` on exit
6. Exit 0 = identical, exit 1 = differences (informational)

### Performance (`--perf N`)

Run locally (not in CI — runners aren't meant for this). Generates O(n³) manifests:

| n  | Deployments | ConfigMap mounts | Approx. time |
|----|-------------|------------------|--------------|
| 5  | 25          | 125              | < 1s         |
| 15 | 225         | 3,375            | seconds      |
| 30 | 900         | 27,000           | notable      |
| 50 | 2,500       | 125,000          | pain         |

## Reading diffs

A diff **is expected** when things change intentionally between versions. The output is meant for human review — there are no assertions.

- `core-only` diff = pure h2c-core behavioral change
- `ext-<name>` diff = change in that extension or its interaction with core
- `ext-all` diff = interaction between all extensions

## Reference versions

Edit `h2c-known-versions.yaml` to bump the pinned reference:

```yaml
reference:
  core: v2.2.0
  extensions:
    cert-manager: v0.1.0
    keycloak: v0.2.0
    servicemonitor: v0.1.0
    trust-manager: v0.1.1
    nginx: v0.1.0
    traefik: v0.1.0
    flatten-internal-urls: v0.1.1
  exclude-ext-all:
    - flatten-internal-urls
```

Extensions listed here are tested individually; unlisted are skipped. Extensions in `exclude-ext-all` are excluded from the combined `ext-all` combo (e.g. due to incompatibilities declared in the registry).

**Future**: `exclude-ext-all` is a stopgap. The plan is to replace it with explicit `ext-sets` — named combos of extensions to test together — and switch the YAML parser from the hand-rolled state machine to `yq`.

## CI

The GitHub Actions workflow runs regression only (weekly + on push to test files). Performance tests are manual — run them on your own machine.

## Structure

```
h2c-testsuite/
├── manifests/                    # static edge-case manifests
│   ├── deployments.yaml          # basic, multi-container, resource limits
│   ├── statefulsets.yaml         # volumeClaimTemplates, headless services
│   ├── jobs.yaml                 # Jobs, init containers, sidecars
│   ├── services.yaml             # ClusterIP, ExternalName, multi-port
│   ├── ingress.yaml              # paths, TLS, annotations
│   ├── configmaps-secrets.yaml   # volume mounts, envFrom, shared refs
│   ├── crds.yaml                 # KeycloakRealmImport, Certificate, ServiceMonitor
│   └── edge-cases.yaml           # empty docs, 64-char names, missing ns
├── generate.py                   # torture test generator (writes to /tmp)
├── h2c-known-versions.yaml       # reference versions for comparison
├── run-tests.sh                  # main test runner
├── .github/workflows/
│   └── regression.yml            # CI (regression only)
└── README.md
```
