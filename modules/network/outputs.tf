output "vpc_id" {
  description = "VPC id."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "VPC CIDR."
  value       = aws_vpc.this.cidr_block
}

output "azs" {
  description = "AZs in use."
  value       = local.azs
}

output "public_subnet_ids" {
  description = "Public subnet ids (ALB; lean-profile app; NAT)."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet ids (data; ha-profile app)."
  value       = aws_subnet.private[*].id
}

output "nat_enabled" {
  description = "Whether private subnets have NAT egress."
  value       = var.enable_nat
}

output "alb_sg_id" {
  description = "ALB security group id."
  value       = aws_security_group.alb.id
}

output "app_sg_id" {
  description = "App (Fargate) security group id."
  value       = aws_security_group.app.id
}

output "data_sg_id" {
  description = "Data (RDS/Valkey) security group id."
  value       = aws_security_group.data.id
}
