variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "allowed_cidrs" {
  type = list(string)
}

variable "target_instance_id" {
  type = string
}

variable "target_port" {
  type = number
}

variable "certificate_arn" {
  type    = string
  default = null
}
