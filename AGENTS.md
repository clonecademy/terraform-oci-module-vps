# AGENTS.md

This file provides guidance to agents when working with code in this repository.

## What this is

A reusable Terraform child module that provisions one Oracle Cloud (OCI) **Always Free** VPS: a `VM.Standard.A1.Flex` Ubuntu 26.04 Minimal (aarch64) instance with a reserved public IP, its own NSG, a boot volume backup policy, and optional monitoring alarms. It was extracted from `clonecademy/terraform-oci-tenancy`, which consumes it. The module declares no `provider` block or backend; the caller configures the `oci` provider and passes `region`, `tenancy_ocid`, `compartment_id`, and `subnet_id`.

Pinned versions (`versions.tf`): Terraform `~> 1.16.0`, `oracle/oci` `~> 9.1.0`.

## Commands

There are no tests or CI. Validate changes locally:

```sh
terraform init -backend=false   # once, or after changing versions.tf
terraform fmt -check            # or `terraform fmt` to rewrite
terraform validate
```

`terraform plan`/`apply` only make sense from a root module that calls this one (with OCI credentials).

## Layout

Files are split by concern, and **each file owns its own variables, locals, resources, and outputs** (there is no `outputs.tf`/`locals.tf`). `variables.tf` holds only the shared, required inputs used across files.

- `server.tf` — instance, image lookup, AD selection, reserved public IP, instance outputs
- `security.tf` — NSG and its ingress rules (SSH, Tailscale UDP 41641, HTTP/HTTPS)
- `backups.tf` — custom boot volume backup policy and assignment
- `monitoring.tf` — `oci_monitoring_alarm` set driven by a `local.alarms` map

Resources are named `main` (or `this` for data sources); OCI display names use the `main-instance-*` prefix.

## Design constraints to preserve

The overriding requirement is staying inside Always Free limits. Many choices that look odd exist because of that, and the comments explain why; keep them accurate when changing code.

- **Home region only**: a precondition on the instance fails the plan if `var.region` isn't the tenancy's home region.
- **200 GB block allowance**: the boot volume consumes all of it, which is why `preserve_boot_volume` defaults to `false`.
- **5 volume backups total**: weekly + daily retention counts must sum to ≤ 5 (enforced by a precondition). Retention is set half a day short of N periods so the oldest backup expires before its replacement runs.
- **Monitoring/Notifications quotas**: alarms reuse metrics the platform already emits and notify only on state change.
- The image data source is sorted by `DISPLAYNAME` (not creation time), and `source_details[0].source_id` is in `ignore_changes` so new vendor images don't rebuild the server.
- The public IP is `RESERVED` with `prevent_destroy`, and the instance gets no ephemeral IP, so the address survives instance replacement.
- Ingress lives on an instance NSG (derived from the subnet's VCN), never the subnet security list.

## Conventions

- Exposure is opt-in: new ingress or features default to off/empty and are toggled with `count`/`for_each` on a bool or list. `ssh_ingress_cidrs` intentionally has **no default** so exposing port 22 is always explicit; an empty list means VPN-only (e.g. Tailscale).
- Validate inputs with `validation` blocks (whole-number checks use `x == floor(x)`), and guard free-tier invariants with `lifecycle` `precondition`s whose error messages state the limit and the offending values.
- Name magic numbers in `locals` (protocol numbers, ports, durations).
- Comments explain *why* (limits, OCI behavior, trade-offs), not what.
- `README.md` documents every input and output for consumers; update its tables and notes when adding, renaming, or changing the default of a variable or output.
- Commits are Conventional Commits in lowercase (`feat: ...`), one feature per PR, squash-merged.
