# Alarms need somewhere to deliver, and the destination (usually a Notifications topic with an email subscription) is shared
# with the rest of the tenancy, so it is taken as a variable rather than created here. An empty list creates no alarms.
variable "alarm_destinations" {
  description = "OCIDs of Notifications topics that instance alarms deliver to. Pass an empty list to create no alarms."
  type        = list(string)
  default     = []
}

variable "alarm_cpu_utilization_percent" {
  description = "Mean CPU utilization, in percent, above which the high CPU alarm fires."
  type        = number
  default     = 90

  validation {
    condition     = var.alarm_cpu_utilization_percent > 0 && var.alarm_cpu_utilization_percent <= 100
    error_message = "CPU utilization alarm threshold must be greater than 0 and at most 100."
  }
}

variable "alarm_memory_utilization_percent" {
  description = "Mean memory utilization, in percent, above which the high memory alarm fires."
  type        = number
  default     = 90

  validation {
    condition     = var.alarm_memory_utilization_percent > 0 && var.alarm_memory_utilization_percent <= 100
    error_message = "Memory utilization alarm threshold must be greater than 0 and at most 100."
  }
}

locals {
  instance_filter = "{resourceId = \"${oci_core_instance.main.id}\"}"

  # Monitoring bills by data points, and Always Free covers 500 million ingested and 1 billion retrieved a month. The metrics
  # below are already emitted by the platform and Oracle Cloud Agent, so the alarms ingest nothing new, and evaluating five of
  # them every minute retrieves a few million data points a month. Notifications allows 1,000 emails a month for free, so
  # alarms notify on state changes only and never repeat while firing.
  alarms = {
    # The platform reports 1 when the instance is down because of an infrastructure problem, not when it is stopped.
    down = {
      display_name     = "main-instance-down"
      namespace        = "oci_compute_infrastructure_health"
      query            = "instance_status[1m]${local.instance_filter}.max() > 0"
      severity         = "CRITICAL"
      pending_duration = "PT1M"
      body             = "The instance is down because of an infrastructure problem. Oracle usually recovers it automatically; check the instance in the console."
    }

    # Catches what instance_status cannot: a hung kernel, a crashed agent, or the instance being stopped. The absence
    # detection period is the maximum, so a long outage keeps the alarm firing rather than aging out of evaluation.
    unresponsive = {
      display_name     = "main-instance-unresponsive"
      namespace        = "oci_computeagent"
      query            = "CpuUtilization[1m]${local.instance_filter}.groupBy(resourceId).absent(3d)"
      severity         = "CRITICAL"
      pending_duration = "PT5M"
      body             = "The instance has stopped reporting metrics. It may be stopped, hung, or out of memory, or Oracle Cloud Agent may have stopped running."
    }

    maintenance = {
      display_name     = "main-instance-maintenance-scheduled"
      namespace        = "oci_compute_infrastructure_health"
      query            = "maintenance_status[1m]${local.instance_filter}.max() > 0"
      severity         = "WARNING"
      pending_duration = "PT1M"
      body             = "Oracle has scheduled infrastructure maintenance for the instance, which reboots it. Check the console for the due time; rebooting before then applies the maintenance at a time of your choosing."
    }

    cpu = {
      display_name     = "main-instance-cpu-high"
      namespace        = "oci_computeagent"
      query            = "CpuUtilization[5m]${local.instance_filter}.mean() > ${var.alarm_cpu_utilization_percent}"
      severity         = "WARNING"
      pending_duration = "PT15M"
      body             = "Mean CPU utilization has been above ${var.alarm_cpu_utilization_percent}% for 15 minutes."
    }

    memory = {
      display_name     = "main-instance-memory-high"
      namespace        = "oci_computeagent"
      query            = "MemoryUtilization[5m]${local.instance_filter}.mean() > ${var.alarm_memory_utilization_percent}"
      severity         = "WARNING"
      pending_duration = "PT15M"
      body             = "Mean memory utilization has been above ${var.alarm_memory_utilization_percent}% for 15 minutes."
    }
  }
}

resource "oci_monitoring_alarm" "instance" {
  for_each = length(var.alarm_destinations) > 0 ? local.alarms : {}

  compartment_id        = var.compartment_id
  metric_compartment_id = var.compartment_id
  display_name          = each.value.display_name
  namespace             = each.value.namespace
  query                 = each.value.query
  severity              = each.value.severity
  pending_duration      = each.value.pending_duration
  body                  = each.value.body
  destinations          = var.alarm_destinations
  message_format        = "ONS_OPTIMIZED"
  is_enabled            = true
}

output "instance_alarm_ids" {
  description = "OCIDs of the instance alarms, keyed by alarm"
  value       = { for key, alarm in oci_monitoring_alarm.instance : key => alarm.id }
}
