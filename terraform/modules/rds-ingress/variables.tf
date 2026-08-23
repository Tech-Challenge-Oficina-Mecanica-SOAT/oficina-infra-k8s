variable "environment" {
  description = "Ambiente (homolog ou prod)"
  type        = string
  validation {
    condition     = contains(["homolog", "prod"], var.environment)
    error_message = "environment deve ser homolog ou prod."
  }
}
