# Exposing SSH to the internet is a deliberate choice, so there is no default: a consumer who never thinks about this
# variable gets a plan error rather than a server whose port 22 answers the whole internet.
variable "ssh_ingress_cidrs" {
  description = "CIDR blocks allowed to reach SSH on the server. Pass an empty list to expose no SSH at all, e.g. when the server is reached over a VPN such as Tailscale."
  type        = list(string)

  validation {
    condition     = alltrue([for cidr in var.ssh_ingress_cidrs : can(cidrhost(cidr, 0))])
    error_message = "SSH ingress CIDRs must be valid IPv4 CIDR notation, e.g. 203.0.113.4/32."
  }
}

# A Minecraft server is played by whoever the operator invites, from whatever address they happen to be on, so like
# web_ingress (and unlike SSH/Dokploy) there is nothing to narrow to a CIDR list — it is a plain on/off switch.
variable "minecraft_ingress" {
  description = "Whether to accept inbound Minecraft traffic (TCP 25565) from the internet."
  type        = bool
  default     = false
}

# Unlike SSH, this rule exposes nothing: tailscaled drops any packet that is not from an authenticated peer, so the
# default is the safe one either way and a consumer who does not run Tailscale should leave it alone.
variable "tailscale_direct_ingress" {
  description = "Whether to accept inbound Tailscale traffic so peers can connect directly instead of relaying through DERP. Tailscale works without this; it is a latency and throughput improvement."
  type        = bool
  default     = false
}

# Serving web apps means answering the whole internet, so unlike SSH there is nothing to narrow. It is still opt-in so that a
# consumer who is not hosting anything does not get ports opened they never asked for.
variable "web_ingress" {
  description = "Whether to accept inbound HTTP (TCP 80) and HTTPS (TCP 443) from the internet, for hosting web apps."
  type        = bool
  default     = false
}

# Unlike web_ingress, the Dokploy dashboard is an admin panel (and an unauthenticated setup screen on first boot), not a
# hosted app, so it defaults closed and is meant to be narrowed to known addresses, the same pattern as SSH, instead of
# opened to everyone.
variable "dokploy_ingress_cidrs" {
  description = "CIDR blocks allowed to reach the Dokploy dashboard on TCP 3000. Pass an empty list to expose no Dokploy port at all, e.g. when it's reached over a VPN such as Tailscale."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for cidr in var.dokploy_ingress_cidrs : can(cidrhost(cidr, 0))])
    error_message = "Dokploy ingress CIDRs must be valid IPv4 CIDR notation, e.g. 203.0.113.4/32."
  }
}

locals {
  protocol_tcp = "6"
  protocol_udp = "17"

  anywhere_cidr = "0.0.0.0/0"

  ssh_port = 22

  tailscale_port = 41641

  web_ports = {
    http  = 80
    https = 443
  }

  dokploy_port = 3000

  minecraft_port = 25565
}

# The NSG is looked up from the subnet rather than taken as a variable so that it cannot disagree with the subnet the
# VNIC actually attaches to.
data "oci_core_subnet" "this" {
  subnet_id = var.subnet_id
}

# Ingress belongs on an NSG rather than the subnet's security list: a security list applies to every VNIC in the subnet,
# so rules meant for this server would be inherited by anything else placed alongside it.
resource "oci_core_network_security_group" "main" {
  compartment_id = var.compartment_id
  vcn_id         = data.oci_core_subnet.this.vcn_id
  display_name   = "main-instance-nsg"
}

# An empty ssh_ingress_cidrs produces no rules at all, which is the VPN-only case.
resource "oci_core_network_security_group_security_rule" "ssh_ingress" {
  for_each = toset(var.ssh_ingress_cidrs)

  network_security_group_id = oci_core_network_security_group.main.id
  direction                 = "INGRESS"
  protocol                  = local.protocol_tcp
  source                    = each.value
  source_type               = "CIDR_BLOCK"
  stateless                 = false

  tcp_options {
    destination_port_range {
      min = local.ssh_port
      max = local.ssh_port
    }
  }
}

# Tailscale establishes its tunnel over egress alone and falls back to a DERP relay when it cannot reach a peer directly.
# Accepting the port tailscaled listens on lets peers skip the relay. The source has to be the whole internet because a
# peer can dial in from any address it happens to have.
resource "oci_core_network_security_group_security_rule" "tailscale_direct_ingress" {
  count = var.tailscale_direct_ingress ? 1 : 0

  network_security_group_id = oci_core_network_security_group.main.id
  direction                 = "INGRESS"
  protocol                  = local.protocol_udp
  source                    = local.anywhere_cidr
  source_type               = "CIDR_BLOCK"
  stateless                 = false

  udp_options {
    destination_port_range {
      min = local.tailscale_port
      max = local.tailscale_port
    }
  }
}

# An empty dokploy_ingress_cidrs produces no rules at all, the same VPN-only pattern as SSH.
resource "oci_core_network_security_group_security_rule" "dokploy_ingress" {
  for_each = toset(var.dokploy_ingress_cidrs)

  network_security_group_id = oci_core_network_security_group.main.id
  direction                 = "INGRESS"
  protocol                  = local.protocol_tcp
  source                    = each.value
  source_type               = "CIDR_BLOCK"
  stateless                 = false

  tcp_options {
    destination_port_range {
      min = local.dokploy_port
      max = local.dokploy_port
    }
  }
}

resource "oci_core_network_security_group_security_rule" "minecraft_ingress" {
  count = var.minecraft_ingress ? 1 : 0

  network_security_group_id = oci_core_network_security_group.main.id
  direction                 = "INGRESS"
  protocol                  = local.protocol_tcp
  source                    = local.anywhere_cidr
  source_type               = "CIDR_BLOCK"
  stateless                 = false

  tcp_options {
    destination_port_range {
      min = local.minecraft_port
      max = local.minecraft_port
    }
  }
}

resource "oci_core_network_security_group_security_rule" "web_ingress" {
  for_each = var.web_ingress ? local.web_ports : {}

  network_security_group_id = oci_core_network_security_group.main.id
  direction                 = "INGRESS"
  protocol                  = local.protocol_tcp
  source                    = local.anywhere_cidr
  source_type               = "CIDR_BLOCK"
  stateless                 = false

  tcp_options {
    destination_port_range {
      min = each.value
      max = each.value
    }
  }
}

output "instance_nsg_id" {
  description = "OCID of the network security group attached to the instance's VNIC"
  value       = oci_core_network_security_group.main.id
}
