variable "bucket_name" {
  description = "Globally unique name for the contracts bucket"
  type        = string
  default     = "ct-tf-contracts-eyoel-1234"
}

variable "stack_up" {
  description = "Turn on the parts that cost money per hour (NAT, Load Balancer, servers, database)"
  type        = bool
  default     = false
}
