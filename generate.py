#!/usr/bin/env python3
"""Torture test generator for h2c.

Generates n releases, each with n Deployments, n ConfigMaps, n Secrets,
n Services, and 1 Ingress. Two axes of pain:

  1. Cross-release configmap mounts: each deployment mounts ALL n² configmaps
     (from every release, not just its own) → n² deployments × n² mounts = n⁴

  2. Env vars with K8s FQDNs: each deployment has env vars referencing all n²
     services as FQDNs → h2c hostname rewriting scans n² envs × n² services = n⁴

Usage:
    python3 generate.py 15                    # n=15, output in /tmp/h2c-torture-15/manifests/
    python3 generate.py 15 --output /tmp/foo  # custom output dir
"""

import argparse
import os
import sys


def all_configmap_names(n):
    """Return all n² configmap names across all releases."""
    return [f"r{r:03d}-config-{i:03d}" for r in range(n) for i in range(n)]


def all_service_fqdns(n):
    """Return all n² service FQDNs across all releases."""
    return [f"r{r:03d}-app-{i:03d}.default.svc.cluster.local"
            for r in range(n) for i in range(n)]


def generate_release(release_idx, n, cm_names, fqdns):
    """Generate all manifests for a single release."""
    prefix = f"r{release_idx:03d}"
    docs = []

    # ConfigMaps
    for i in range(n):
        docs.append(
            f"apiVersion: v1\n"
            f"kind: ConfigMap\n"
            f"metadata:\n"
            f"  name: {prefix}-config-{i:03d}\n"
            f"  namespace: default\n"
            f"data:\n"
            f"  SETTING_A: \"value-a-{release_idx}-{i}\"\n"
            f"  SETTING_B: \"value-b-{release_idx}-{i}\"\n"
            f"  config.yaml: |\n"
            f"    key: release-{release_idx}-cm-{i}\n"
        )

    # Secrets
    for i in range(n):
        docs.append(
            f"apiVersion: v1\n"
            f"kind: Secret\n"
            f"metadata:\n"
            f"  name: {prefix}-secret-{i:03d}\n"
            f"  namespace: default\n"
            f"type: Opaque\n"
            f"data:\n"
            f"  password: cGFzc3dvcmQ=\n"
            f"  token: dG9rZW4xMjM=\n"
        )

    # Deployments — mounts ALL configmaps, env vars reference ALL service FQDNs
    for i in range(n):
        # Volume mounts: all n² configmaps
        volume_mounts = "\n".join(
            f"            - name: cm-{idx:04d}\n"
            f"              mountPath: /etc/config/{idx:04d}\n"
            f"              readOnly: true"
            for idx in range(len(cm_names))
        )
        volumes = "\n".join(
            f"        - name: cm-{idx:04d}\n"
            f"          configMap:\n"
            f"            name: {name}"
            for idx, name in enumerate(cm_names)
        )

        # Env vars: every service FQDN as a value (triggers hostname rewriting)
        env_vars = "\n".join(
            f"            - name: SVC_{idx:04d}\n"
            f"              value: \"http://{fqdn}:8080/api\""
            for idx, fqdn in enumerate(fqdns)
        )

        # envFrom: secrets from own release only (to keep it sane)
        env_from = "\n".join(
            f"            - secretRef:\n"
            f"                name: {prefix}-secret-{j:03d}"
            for j in range(n)
        )

        docs.append(
            f"apiVersion: apps/v1\n"
            f"kind: Deployment\n"
            f"metadata:\n"
            f"  name: {prefix}-app-{i:03d}\n"
            f"  namespace: default\n"
            f"  labels:\n"
            f"    app: {prefix}-app-{i:03d}\n"
            f"spec:\n"
            f"  replicas: 1\n"
            f"  selector:\n"
            f"    matchLabels:\n"
            f"      app: {prefix}-app-{i:03d}\n"
            f"  template:\n"
            f"    metadata:\n"
            f"      labels:\n"
            f"        app: {prefix}-app-{i:03d}\n"
            f"    spec:\n"
            f"      initContainers:\n"
            f"        - name: init\n"
            f"          image: busybox:1.36\n"
            f"          command: ['sh', '-c', 'echo init-{prefix}-{i}']\n"
            f"      containers:\n"
            f"        - name: main\n"
            f"          image: nginx:1.27-alpine\n"
            f"          ports:\n"
            f"            - containerPort: 8080\n"
            f"          env:\n"
            f"{env_vars}\n"
            f"          envFrom:\n"
            f"{env_from}\n"
            f"          volumeMounts:\n"
            f"{volume_mounts}\n"
            f"        - name: sidecar\n"
            f"          image: busybox:1.36\n"
            f"          command: ['sh', '-c', 'sleep infinity']\n"
            f"      volumes:\n"
            f"{volumes}\n"
        )

    # Services
    for i in range(n):
        docs.append(
            f"apiVersion: v1\n"
            f"kind: Service\n"
            f"metadata:\n"
            f"  name: {prefix}-app-{i:03d}\n"
            f"  namespace: default\n"
            f"spec:\n"
            f"  type: ClusterIP\n"
            f"  ports:\n"
            f"    - port: 8080\n"
            f"      targetPort: 8080\n"
            f"  selector:\n"
            f"    app: {prefix}-app-{i:03d}\n"
        )

    # Ingress (n paths)
    paths = "\n".join(
        f"          - path: /svc-{i:03d}\n"
        f"            pathType: Prefix\n"
        f"            backend:\n"
        f"              service:\n"
        f"                name: {prefix}-app-{i:03d}\n"
        f"                port:\n"
        f"                  number: 8080"
        for i in range(n)
    )
    docs.append(
        f"apiVersion: networking.k8s.io/v1\n"
        f"kind: Ingress\n"
        f"metadata:\n"
        f"  name: {prefix}-ingress\n"
        f"  namespace: default\n"
        f"  annotations:\n"
        f"    kubernetes.io/ingress.class: haproxy\n"
        f"spec:\n"
        f"  rules:\n"
        f"    - host: {prefix}.example.com\n"
        f"      http:\n"
        f"        paths:\n"
        f"{paths}\n"
    )

    return "---\n".join(docs)


def main():
    parser = argparse.ArgumentParser(description="Generate h2c torture test manifests")
    parser.add_argument("n", type=int, help="Scale factor")
    parser.add_argument("--output", default=None,
                        help="Output directory (default: /tmp/h2c-torture-N/manifests)")
    args = parser.parse_args()

    n = args.n
    if n < 1:
        print("Error: n must be >= 1", file=sys.stderr)
        sys.exit(1)

    output = args.output or f"/tmp/h2c-torture-{n}/manifests"
    os.makedirs(output, exist_ok=True)

    total_deploy = n * n
    total_cm = n * n
    total_mounts = total_deploy * total_cm
    total_env_rewrites = total_deploy * total_deploy
    print(f"Generating torture test: n={n}")
    print(f"  {total_deploy} deployments, {total_cm} configmaps, {total_deploy} services")
    print(f"  {total_mounts} configmap mount resolutions (n⁴)")
    print(f"  {total_env_rewrites} env FQDN rewrites (n⁴)")
    print(f"  Output: {output}")

    cm_names = all_configmap_names(n)
    fqdns = all_service_fqdns(n)

    for release_idx in range(n):
        release_dir = os.path.join(output, f"release-{release_idx:03d}")
        os.makedirs(release_dir, exist_ok=True)
        content = generate_release(release_idx, n, cm_names, fqdns)
        manifest_path = os.path.join(release_dir, "manifests.yaml")
        with open(manifest_path, "w") as f:
            f.write(content)

    print(f"Done. {n} release directories written to {output}")


if __name__ == "__main__":
    main()
