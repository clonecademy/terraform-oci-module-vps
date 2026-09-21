# Always Free allows 5 volume backups in total, boot and block volumes combined, in the home region, and a scheduled backup
# cannot be created once that limit is reached. The defaults spend all 5 on this volume: one weekly full baseline and four
# daily incrementals. Lower them to leave room for block volumes attached later.
variable "boot_volume_weekly_backups_to_keep" {
  description = "Number of weekly full boot volume backups to keep; older ones expire."
  type        = number
  default     = 1

  validation {
    condition     = var.boot_volume_weekly_backups_to_keep >= 1 && var.boot_volume_weekly_backups_to_keep == floor(var.boot_volume_weekly_backups_to_keep)
    error_message = "Weekly boot volume backups to keep must be a whole number of 1 or greater."
  }
}

variable "boot_volume_daily_backups_to_keep" {
  description = "Number of daily incremental boot volume backups to keep; older ones expire. Zero takes weekly backups only."
  type        = number
  default     = 4

  validation {
    condition     = var.boot_volume_daily_backups_to_keep >= 0 && var.boot_volume_daily_backups_to_keep == floor(var.boot_volume_daily_backups_to_keep)
    error_message = "Daily boot volume backups to keep must be a whole number of 0 or greater."
  }
}

# UTC does not follow daylight saving, so the default of 9 is 2 AM in California from March to November and 1 AM the rest
# of the year. Backups can start several hours after the scheduled time.
variable "boot_volume_backup_hour_utc" {
  description = "Hour of the day, 0 to 23 in UTC, at which boot volume backups are scheduled."
  type        = number
  default     = 9

  validation {
    condition     = var.boot_volume_backup_hour_utc >= 0 && var.boot_volume_backup_hour_utc <= 23 && var.boot_volume_backup_hour_utc == floor(var.boot_volume_backup_hour_utc)
    error_message = "Boot volume backup hour must be a whole number from 0 to 23."
  }
}

variable "boot_volume_backup_weekday" {
  description = "Day of the week, in UTC, on which the weekly full boot volume backup is scheduled."
  type        = string
  default     = "SUNDAY"

  validation {
    condition     = contains(["MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY", "SUNDAY"], var.boot_volume_backup_weekday)
    error_message = "Boot volume backup weekday must be an uppercase day name, e.g. SUNDAY."
  }
}

locals {
  seconds_per_day  = 24 * 60 * 60
  seconds_per_week = 7 * local.seconds_per_day

  # OCI retention is time-based; there is no way to keep only the newest N backups. Retention is set half a day short of N
  # periods so that the oldest backup expires before its replacement is due. A full N periods would leave both alive at
  # the boundary, and the replacement would fail at the 5-backup limit. The margin is generous because backups can start
  # hours late.
  backup_expiry_margin_seconds = 12 * 60 * 60
}

# A custom policy is needed because Oracle's predefined ones (bronze, silver, gold) all keep more backups than the free
# allowance holds.
resource "oci_core_volume_backup_policy" "boot_volume" {
  compartment_id = var.compartment_id
  display_name   = "main-instance-boot-volume"

  schedules {
    backup_type       = "FULL"
    period            = "ONE_WEEK"
    offset_type       = "STRUCTURED"
    day_of_week       = var.boot_volume_backup_weekday
    hour_of_day       = var.boot_volume_backup_hour_utc
    time_zone         = "UTC"
    retention_seconds = var.boot_volume_weekly_backups_to_keep * local.seconds_per_week - local.backup_expiry_margin_seconds
  }

  # Oracle documents incremental backups as equivalent to full ones for recovery, so they stay usable after the weekly
  # baseline they followed has expired.
  dynamic "schedules" {
    for_each = var.boot_volume_daily_backups_to_keep > 0 ? [1] : []

    content {
      backup_type       = "INCREMENTAL"
      period            = "ONE_DAY"
      offset_type       = "STRUCTURED"
      hour_of_day       = var.boot_volume_backup_hour_utc
      time_zone         = "UTC"
      retention_seconds = var.boot_volume_daily_backups_to_keep * local.seconds_per_day - local.backup_expiry_margin_seconds
    }
  }

  lifecycle {
    # Throw an error if the retained backups would not fit in the Always Free allowance.
    precondition {
      condition     = var.boot_volume_weekly_backups_to_keep + var.boot_volume_daily_backups_to_keep <= 5
      error_message = "Always Free allows 5 volume backups in total, but ${var.boot_volume_weekly_backups_to_keep} weekly and ${var.boot_volume_daily_backups_to_keep} daily backups would be kept."
    }
  }
}

# The assignment is on the boot volume, which is replaced along with the instance, so it is recreated with it.
resource "oci_core_volume_backup_policy_assignment" "boot_volume" {
  asset_id  = oci_core_instance.main.boot_volume_id
  policy_id = oci_core_volume_backup_policy.boot_volume.id
}
