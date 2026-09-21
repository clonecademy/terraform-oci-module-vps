# Always Free allows 5 volume backups in total, boot and block volumes combined, in the home region. The default keeps just
# one so the rest stay available for any block volumes attached later.
variable "boot_volume_backups_to_keep" {
  description = "Number of weekly boot volume backups to keep; older ones expire. Always Free allows 5 volume backups in total across all volumes."
  type        = number
  default     = 1

  validation {
    condition     = var.boot_volume_backups_to_keep >= 1 && var.boot_volume_backups_to_keep <= 5 && var.boot_volume_backups_to_keep == floor(var.boot_volume_backups_to_keep)
    error_message = "Boot volume backups to keep must be a whole number from 1 to 5, the Always Free volume backup limit."
  }
}

locals {
  seconds_per_week = 7 * 24 * 60 * 60
}

# A custom policy is needed because Oracle's predefined ones (bronze, silver, gold) all keep more backups than the free
# allowance holds.
resource "oci_core_volume_backup_policy" "boot_volume" {
  compartment_id = var.compartment_id
  display_name   = "main-instance-boot-volume-weekly"

  # A full backup is self-contained, so the single backup kept by default restores on its own.
  schedules {
    backup_type       = "FULL"
    period            = "ONE_WEEK"
    offset_type       = "STRUCTURED"
    day_of_week       = "SUNDAY"
    hour_of_day       = 3
    time_zone         = "UTC"
    retention_seconds = var.boot_volume_backups_to_keep * local.seconds_per_week
  }
}

# Backups outlive the boot volume they were taken from, so they remain a way back if the instance is replaced.
resource "oci_core_volume_backup_policy_assignment" "boot_volume" {
  asset_id  = oci_core_instance.main.boot_volume_id
  policy_id = oci_core_volume_backup_policy.boot_volume.id
}
