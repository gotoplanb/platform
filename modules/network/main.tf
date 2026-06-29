# Network stack (platform#3). One VPC with a public tier and a private tier across
# `az_count` AZs. The structure is the SAME for both cost profiles (ADR-015) — only
# egress differs:
#   - lean (enable_nat=false): app runs in PUBLIC subnets (auto public IP, reaches ECR
#     directly); private subnets hold RDS/Valkey, which need no internet egress.
#   - ha   (enable_nat=true):  app runs in PRIVATE subnets; egress via NAT in the public
#     tier. Data stays private.
# The app/data STACKS (#4/#6) choose subnet placement from the outputs + the env toggle;
# this module is placement-agnostic and always exposes both tiers.

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # /16 split into /20s: public = first block per AZ, private = offset by 8.
  public_cidrs  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i)]
  private_cidrs = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i + 8)]

  nat_count = var.enable_nat ? (var.single_nat_gateway ? 1 : var.az_count) : 0
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(var.tags, { Name = var.name })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = var.name })
}

# ---- Subnets ----------------------------------------------------------------

resource "aws_subnet" "public" {
  count                   = var.az_count
  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.public_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true
  tags = merge(var.tags, {
    Name = "${var.name}-public-${local.azs[count.index]}"
    tier = "public"
  })
}

resource "aws_subnet" "private" {
  count             = var.az_count
  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_cidrs[count.index]
  availability_zone = local.azs[count.index]
  tags = merge(var.tags, {
    Name = "${var.name}-private-${local.azs[count.index]}"
    tier = "private"
  })
}

# ---- Public routing (-> IGW) ------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-public" })
}

resource "aws_route" "public_igw" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count          = var.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ---- NAT (optional, ha profile) ---------------------------------------------

resource "aws_eip" "nat" {
  count  = local.nat_count
  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.name}-nat-${count.index}" })
}

resource "aws_nat_gateway" "this" {
  count         = local.nat_count
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = merge(var.tags, { Name = "${var.name}-nat-${count.index}" })
  depends_on    = [aws_internet_gateway.this]
}

# ---- Private routing (-> NAT when enabled) ----------------------------------
# One route table per AZ so a per-AZ NAT (single_nat_gateway=false) keeps traffic
# in-AZ. With a single NAT, all private RTs point at the one gateway.

resource "aws_route_table" "private" {
  count  = var.az_count
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-private-${local.azs[count.index]}" })
}

resource "aws_route" "private_nat" {
  count                  = var.enable_nat ? var.az_count : 0
  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[var.single_nat_gateway ? 0 : count.index].id
}

resource "aws_route_table_association" "private" {
  count          = var.az_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ---- S3 gateway endpoint (free) ---------------------------------------------
# Lets both tiers reach S3 without traversing NAT (image layers, state, artifacts).

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat(aws_route_table.private[*].id, [aws_route_table.public.id])
  tags              = merge(var.tags, { Name = "${var.name}-s3" })
}

# ---- Security groups (tiered, least privilege) ------------------------------
# ALB <- internet ; app <- ALB only ; data <- app only.

resource "aws_security_group" "alb" {
  name_prefix = "${var.name}-alb-"
  description = "ALB: public HTTP/HTTPS ingress."
  vpc_id      = aws_vpc.this.id
  tags        = merge(var.tags, { Name = "${var.name}-alb" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "app" {
  name_prefix = "${var.name}-app-"
  description = "App (Fargate): ingress from the ALB only."
  vpc_id      = aws_vpc.this.id
  tags        = merge(var.tags, { Name = "${var.name}-app" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "data" {
  name_prefix = "${var.name}-data-"
  description = "Data (RDS/Valkey): ingress from the app only."
  vpc_id      = aws_vpc.this.id
  tags        = merge(var.tags, { Name = "${var.name}-data" })

  lifecycle {
    create_before_destroy = true
  }
}

# ALB ingress: 443 + 80 (80 redirects to 443 at the listener).
resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
  description       = "HTTPS from internet"
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
  description       = "HTTP from internet (redirected to HTTPS)"
}

resource "aws_vpc_security_group_egress_rule" "alb_all" {
  security_group_id = aws_security_group.alb.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "All egress"
}

# App ingress: app_port from the ALB SG only.
resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = var.app_port
  to_port                      = var.app_port
  referenced_security_group_id = aws_security_group.alb.id
  description                  = "App port from ALB"
}

resource "aws_vpc_security_group_egress_rule" "app_all" {
  security_group_id = aws_security_group.app.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "All egress (DB, AWS APIs, image pulls)"
}

# Data ingress: Postgres + Valkey from the app SG only.
resource "aws_vpc_security_group_ingress_rule" "data_postgres" {
  security_group_id            = aws_security_group.data.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.app.id
  description                  = "Postgres from app"
}

resource "aws_vpc_security_group_ingress_rule" "data_valkey" {
  security_group_id            = aws_security_group.data.id
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
  referenced_security_group_id = aws_security_group.app.id
  description                  = "Valkey/Redis from app"
}
