# Place your server in another availability domain if out of capacity.
variable "availability_domain_number" {
  description = "The availability domain that your server will be placed in."
  type        = number
  default     = 1

  # Prevent index out of bounds errors.
  validation {
    condition     = var.availability_domain_number >= 1 && var.availability_domain_number == floor(var.availability_domain_number)
    error_message = "Availability domain number must be a whole number of 1 or greater."
  }
}

variable "free_instance_shape" {
  description = "The compute shape for the server."
  type        = string
  default     = "VM.Standard.A1.Flex"
}

variable "free_instance_ocpus" {
  description = "Number of OCPUs allocated to the server."
  type        = number
  default     = 4
}

variable "free_instance_memory_gbs" {
  description = "Amount of memory, in GB, allocated to the server."
  type        = number
  default     = 24
}

variable "free_boot_volume_gbs" {
  description = "Boot volume size, in GB, for the server."
  type        = string
  default     = "200"
}

variable "free_boot_volume_vpus_per_gb" {
  description = "Boot volume performance level (VPUs per GB) for the server."
  type        = string
  default     = "10"
}

# A preserved boot volume still counts against the 200 GB Always Free allowance, and the server's boot volume is that whole
# allowance, so on the free tier a replacement instance could not get its own. Opt in only with headroom to spare.
variable "preserve_boot_volume" {
  description = "Whether to keep the boot volume when the instance is destroyed. Kept volumes are orphaned and must be deleted by hand."
  type        = bool
  default     = false
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key installed on the server via authorized_keys."
  type        = string
}

data "oci_identity_availability_domains" "this" {
  compartment_id = var.tenancy_ocid
}

# Compute instances and block volumes are always free only in the home region.
data "oci_identity_region_subscriptions" "this" {
  tenancy_id = var.tenancy_ocid
}

data "oci_core_images" "ubuntu_minimal" {
  compartment_id           = var.tenancy_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "26.04 Minimal aarch64"
  shape                    = var.free_instance_shape
  state                    = "AVAILABLE"
  # Sorted by DISPLAYNAME, not TIMECREATED because
  # Oracle doesn't publish vendors' builds in build order.
  sort_by    = "DISPLAYNAME"
  sort_order = "DESC"
}

locals {
  availability_domain = data.oci_identity_availability_domains.this.availability_domains[var.availability_domain_number - 1].name

  home_region = one([
    for subscription in data.oci_identity_region_subscriptions.this.region_subscriptions :
    subscription.region_name if subscription.is_home_region
  ])

  ubuntu_minimal_image_id = data.oci_core_images.ubuntu_minimal.images[0].id
}

resource "oci_core_instance" "main" {
  compartment_id      = var.compartment_id
  availability_domain = local.availability_domain
  display_name        = "main-instance"
  shape               = var.free_instance_shape

  shape_config {
    ocpus         = var.free_instance_ocpus
    memory_in_gbs = var.free_instance_memory_gbs
  }

  source_details {
    source_type = "image"
    source_id   = local.ubuntu_minimal_image_id

    boot_volume_size_in_gbs = var.free_boot_volume_gbs
    boot_volume_vpus_per_gb = var.free_boot_volume_vpus_per_gb
  }

  # The reserved public IP below is attached instead; an ephemeral one would be lost whenever the instance is replaced.
  create_vnic_details {
    subnet_id                 = var.subnet_id
    display_name              = "main-instance-vnic"
    hostname_label            = "main"
    assign_public_ip          = false
    assign_private_dns_record = true
    nsg_ids                   = [oci_core_network_security_group.main.id]
  }

  # An admin must initially upload their SSH key before managing SSH using authorized_keys.
  metadata = {
    ssh_authorized_keys = file(pathexpand(var.ssh_public_key_path))
  }

  preserve_boot_volume = var.preserve_boot_volume

  lifecycle {
    # Because vendors publish new images regularly, the newest image would become the desired source_id and a routine apply would
    # destroy and rebuild the server. Change the image deliberately instead.
    ignore_changes = [source_details[0].source_id]

    # Throw an error if the server is provisioned in a region other than the home region.
    precondition {
      condition     = var.region == local.home_region
      error_message = "Always Free compute and block volume storage exist only in the tenancy's home region (${local.home_region}); region is set to ${var.region}, where this instance would be billed."
    }

    # Throw an error if there were no images found.
    precondition {
      condition     = length(data.oci_core_images.ubuntu_minimal.images) > 0
      error_message = "No AVAILABLE Canonical Ubuntu 26.04 Minimal image was found for ${var.free_instance_shape} in ${var.region}."
    }
  }
}

data "oci_core_vnic_attachments" "main" {
  compartment_id = var.compartment_id
  instance_id    = oci_core_instance.main.id
}

data "oci_core_private_ips" "main" {
  vnic_id = data.oci_core_vnic_attachments.main.vnic_attachments[0].vnic_id
}

locals {
  primary_private_ip_id = one([
    for private_ip in data.oci_core_private_ips.main.private_ips :
    private_ip.id if private_ip.is_primary
  ])
}

# A reserved public IP outlives the instance: if the server is replaced, it moves to the new instance's private IP.
resource "oci_core_public_ip" "main" {
  compartment_id = var.compartment_id
  display_name   = "main-instance-public-ip"
  lifetime       = "RESERVED"
  private_ip_id  = local.primary_private_ip_id

  lifecycle {
    prevent_destroy = true
  }
}

output "instance_availability_domain" {
  description = "Availability domain the instance was placed in"
  value       = oci_core_instance.main.availability_domain
}

output "instance_boot_volume_size_in_gbs" {
  description = "Boot volume size, which consumes the entire 200 GB Always Free block volume allowance"
  value       = oci_core_instance.main.source_details[0].boot_volume_size_in_gbs
}

output "instance_id" {
  description = "OCID of the always-free compute instance"
  value       = oci_core_instance.main.id
}

output "instance_image_name" {
  description = "Display name of the Ubuntu image the instance was launched from"
  value       = data.oci_core_images.ubuntu_minimal.images[0].display_name
}

output "instance_private_ip" {
  description = "Private IP address of the instance in the public subnet"
  value       = oci_core_instance.main.private_ip
}

output "instance_public_ip" {
  description = "Reserved public IP address of the instance"
  value       = oci_core_public_ip.main.ip_address
}

output "instance_ssh_command" {
  description = "Command to connect to the instance as the default ubuntu user"
  value       = "ssh ubuntu@${oci_core_public_ip.main.ip_address}"
}
