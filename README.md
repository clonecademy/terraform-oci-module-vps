# Virtual Private Server (VPS) — Terraform OCI Module

Provisions a single Oracle Cloud Infrastructure (OCI) server that stays within the [Always Free](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm) limits:

- An Ampere `VM.Standard.A1.Flex` instance running the newest Canonical Ubuntu 26.04 Minimal (aarch64) image. By default it gets 4 OCPUs, 24 GB of memory, and a 200 GB boot volume, which is the whole free allowance.
- A reserved public IP that is kept if the instance is replaced.
- A network security group (NSG) on the instance. SSH, Tailscale, and web traffic can each be allowed separately.
- A boot volume backup policy: one weekly full backup and four daily incremental backups.
- Optional alarms for outages, missed metrics, scheduled maintenance, and high CPU or memory use.

## Requirements

| Name | Version |
| --- | --- |
| Terraform | `~> 1.16.0` |
| [`oracle/oci`](https://registry.terraform.io/providers/oracle/oci/latest) | `~> 9.1.0` |

The module does not configure the `oci` provider. You configure it in your root module.

You also need to supply:

- **A subnet with a route to the internet.** The instance's network card is attached to it, and the reserved public IP is assigned to the instance's primary private IP. The module does not create a VCN or subnet.
- **The tenancy's home region.** Always Free compute and block storage are only free there. If `region` is any other region, the plan fails.
- **An SSH public key file.** It is installed for the default `ubuntu` user.

## Usage

```hcl
module "vps" {
  source = "git::https://github.com/clonecademy/terraform-oci-module-vps.git?ref=v0.4.0"

  tenancy_ocid   = var.tenancy_ocid
  region         = var.region
  compartment_id = var.compartment_id
  subnet_id      = oci_core_subnet.public.id

  ssh_public_key_path = "~/.ssh/id_ed25519.pub"
  ssh_ingress_cidrs   = ["203.0.113.4/32"]

  # Optional
  web_ingress        = true
  alarm_destinations = [oci_ons_notification_topic.alerts.id]
}
```

To reach the server only over a VPN such as Tailscale, pass `ssh_ingress_cidrs = []`. This opens no SSH port to the internet. You can also set `tailscale_direct_ingress = true` so peers connect directly instead of going through a relay.

## Inputs

### Required

| Name | Type | Description |
| --- | --- | --- |
| `compartment_id` | `string` | OCID of the compartment to create resources in. |
| `tenancy_ocid` | `string` | OCID of the tenancy. Used to look up availability domains, the home region, and images. |
| `region` | `string` | Region the provider is configured for. It must be the tenancy's home region. |
| `subnet_id` | `string` | OCID of the subnet the instance attaches to. The NSG is created in this subnet's VCN. |
| `ssh_public_key_path` | `string` | Path to the SSH public key to install. `~` is expanded. |
| `ssh_ingress_cidrs` | `list(string)` | IPv4 CIDR blocks allowed to reach TCP 22. There is no default, so opening SSH is always a deliberate choice. `[]` opens nothing. |

### Instance

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `availability_domain_number` | `number` | `1` | Availability domain to place the instance in, counting from 1. Try another one if OCI reports "Out of host capacity". |
| `free_instance_shape` | `string` | `"VM.Standard.A1.Flex"` | Compute shape. |
| `free_instance_ocpus` | `number` | `4` | OCPUs to allocate. |
| `free_instance_memory_gbs` | `number` | `24` | Memory to allocate, in GB. |
| `free_boot_volume_gbs` | `string` | `"200"` | Boot volume size in GB. |
| `free_boot_volume_vpus_per_gb` | `string` | `"10"` | Boot volume performance, in VPUs per GB. |
| `preserve_boot_volume` | `bool` | `false` | Keep the boot volume when the instance is destroyed. See [Boot volume](#boot-volume). |

### Network

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `tailscale_direct_ingress` | `bool` | `false` | Accept UDP 41641 from anywhere so Tailscale peers can connect directly instead of through a DERP relay. Tailscale works without it. |
| `web_ingress` | `bool` | `false` | Accept HTTP (TCP 80) and HTTPS (TCP 443) from anywhere. |

### Backups

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `boot_volume_weekly_backups_to_keep` | `number` | `1` | Weekly full backups to keep. Must be at least 1. |
| `boot_volume_daily_backups_to_keep` | `number` | `4` | Daily incremental backups to keep. `0` takes weekly backups only. |
| `boot_volume_backup_hour_utc` | `number` | `9` | Hour of the day (0–23, UTC) when backups are scheduled. |
| `boot_volume_backup_weekday` | `string` | `"SUNDAY"` | Day of the week (in UTC, uppercase) for the weekly full backup. |

### Monitoring

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `alarm_destinations` | `list(string)` | `[]` | OCIDs of Notifications topics to send alarms to. `[]` creates no alarms. |
| `alarm_cpu_utilization_percent` | `number` | `90` | Mean CPU use, in percent, above which the high CPU alarm fires. |
| `alarm_memory_utilization_percent` | `number` | `90` | Mean memory use, in percent, above which the high memory alarm fires. |

## Outputs

| Name | Description |
| --- | --- |
| `instance_id` | OCID of the instance. |
| `instance_public_ip` | Reserved public IP address. |
| `instance_private_ip` | Private IP address in the subnet. |
| `instance_ssh_command` | Command to connect, e.g. `ssh ubuntu@203.0.113.10`. |
| `instance_availability_domain` | Availability domain the instance was placed in. |
| `instance_image_name` | Display name of the image the instance was launched from. |
| `instance_boot_volume_size_in_gbs` | Boot volume size in GB. |
| `instance_nsg_id` | OCID of the instance's NSG. Attach extra rules to it for other ports. |
| `instance_alarm_ids` | OCIDs of the alarms, keyed by `down`, `unresponsive`, `maintenance`, `cpu`, and `memory`. |

## Things to know

### Staying free

The defaults use the entire Always Free allowance for A1 compute (4 OCPUs, 24 GB), block storage (200 GB), and volume backups (5). If you want other free resources in the same tenancy, such as another A1 instance, block volumes, or backups, lower these values to make room. The module checks that the weekly and daily backup counts add up to 5 or fewer.

### Image updates

The instance is created from the newest available Ubuntu 26.04 Minimal image. Later image releases are ignored, so a routine `apply` never rebuilds the server. To move to a newer image, replace the instance deliberately:

```sh
terraform apply -replace='module.vps.oci_core_instance.main'
```

### Reserved public IP

The public IP has `prevent_destroy` set, so it keeps its address when the instance is replaced. As a result, `terraform destroy`, or any plan that would delete the IP, fails. To really delete it, first remove it from state with `terraform state rm 'module.vps.oci_core_public_ip.main'`, then delete it in the OCI console.

### Boot volume

By default the boot volume is deleted with the instance. If you set `preserve_boot_volume = true`, the old volume is left behind with no owner, still counts toward the 200 GB free allowance, and has to be deleted by hand. On the free tier, a leftover 200 GB volume leaves no room for a replacement instance's boot volume.

### Backups

OCI keeps backups for a set length of time; it cannot keep "the newest N". Each backup is kept for half a day less than N periods, so the oldest one expires before its replacement is due. That keeps the total at or below 5. Scheduled backups can start several hours after the configured hour.

### Alarms

Alarms fire and send a notification when their state changes. They do not repeat while an alarm is still firing. The CPU, memory, and unresponsive alarms use metrics from Oracle Cloud Agent, which Ubuntu platform images run by default. If the agent stops, the `unresponsive` alarm fires.
