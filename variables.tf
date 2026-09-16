variable "compartment_id" {
  description = "OCID of the compartment in which to create the server."
  type        = string
}

variable "tenancy_ocid" {
  description = "OCID of the tenancy, used to look up availability domains, the home region, and available images."
  type        = string
}

variable "region" {
  description = "Region the provider is configured for; the server must be placed in the tenancy's home region to remain Always Free eligible."
  type        = string
}

variable "subnet_id" {
  description = "OCID of the subnet the server's VNIC attaches to."
  type        = string
}
