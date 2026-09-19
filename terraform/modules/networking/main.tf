
// DATA SOURCES

data "aws_availability_zones" "available" {
  state = "available"
}


// VPC

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}


// PUBLIC SUBNETS (for ALB)

resource "aws_subnet" "public_1" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 1)
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-public-1"
  }
}

resource "aws_subnet" "public_2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 2)
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-public-2"
  }
}


// PRIVATE SUBNETS (for ECS tasks)

resource "aws_subnet" "private_1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 10)
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = {
    Name = "${var.project_name}-private-1"
  }
}

resource "aws_subnet" "private_2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 20)
  availability_zone = data.aws_availability_zones.available.names[1]

  tags = {
    Name = "${var.project_name}-private-2"
  }
}


// INTERNET GATEWAY + PUBLIC ROUTE TABLE

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.project_name}-public-rt"
  }
}

resource "aws_route_table_association" "public_1" {
  subnet_id      = aws_subnet.public_1.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_2" {
  subnet_id      = aws_subnet.public_2.id
  route_table_id = aws_route_table.public.id
}


// NAT GATEWAYS (one per AZ — egress for private subnets)
// High-availability: each private subnet egresses via the NAT in its own AZ, so
// an AZ failure can't take out the other AZ's outbound path, and egress never
// crosses an AZ boundary (avoids cross-AZ data-transfer charges).

resource "aws_eip" "nat_1" {
  domain = "vpc"

  tags = {
    Name = "${var.project_name}-nat-eip-1"
  }
}

resource "aws_eip" "nat_2" {
  domain = "vpc"

  tags = {
    Name = "${var.project_name}-nat-eip-2"
  }
}

resource "aws_nat_gateway" "nat_1" {
  allocation_id = aws_eip.nat_1.id
  subnet_id     = aws_subnet.public_1.id

  tags = {
    Name = "${var.project_name}-nat-1"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "nat_2" {
  allocation_id = aws_eip.nat_2.id
  subnet_id     = aws_subnet.public_2.id

  tags = {
    Name = "${var.project_name}-nat-2"
  }

  depends_on = [aws_internet_gateway.main]
}


// PRIVATE ROUTE TABLES (one per AZ — egress via the same-AZ NAT Gateway)

resource "aws_route_table" "private_1" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_1.id
  }

  tags = {
    Name = "${var.project_name}-private-rt-1"
  }
}

resource "aws_route_table" "private_2" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_2.id
  }

  tags = {
    Name = "${var.project_name}-private-rt-2"
  }
}

resource "aws_route_table_association" "private_1" {
  subnet_id      = aws_subnet.private_1.id
  route_table_id = aws_route_table.private_1.id
}

resource "aws_route_table_association" "private_2" {
  subnet_id      = aws_subnet.private_2.id
  route_table_id = aws_route_table.private_2.id
}


// SECURITY GROUPS


// CloudFront's origin-facing address ranges, maintained by AWS.
data "aws_ec2_managed_prefix_list" "cloudfront_origin" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

// ALB Security Group — reachable only from CloudFront
//
// This was 0.0.0.0/0 on 80 and 443, and that is not a theoretical exposure: four
// minutes after the load balancer went live, an unauthenticated GET / from an
// external scanner reached it, was answered 503 because the service was scaled to
// zero, and tripped the wake alarm. A stranger launched GPU instances in the
// account. Scale-to-zero turns an open origin into a remotely triggerable way to
// spend money, so the origin is no longer open.
//
// A managed prefix list consumes its MaxEntries against the 60-rules-per-group
// quota, which is why only port 80 is listed: the load balancer has an HTTP
// listener and nothing else, so the old 443 rule admitted traffic that had
// nowhere to go. Two prefix-list rules would exceed the quota.
//
// This stops anything that is not CloudFront. It does not distinguish THIS
// distribution from someone else's — that needs a secret header injected by
// CloudFront and verified by the WAF, which is recorded as future work.
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "Allow HTTP from CloudFront origin-facing ranges only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "HTTP from CloudFront only"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront_origin.id]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-alb-sg"
  }
}

// ECS Security Group — only accepts traffic from ALB
resource "aws_security_group" "ecs" {
  name        = "${var.project_name}-ecs-sg"
  description = "Allow traffic from ALB only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "HTTP from ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "All outbound (via NAT for AWS APIs; S3 endpoint for ECR layers)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-ecs-sg"
  }
}


// VPC ENDPOINTS — S3 gateway only (free; keeps ECR layer pulls off the NAT)

resource "aws_vpc_endpoint" "s3" {
  vpc_id       = aws_vpc.main.id
  service_name = "com.amazonaws.${var.aws_region}.s3"

  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private_1.id, aws_route_table.private_2.id]

  tags = {
    Name = "${var.project_name}-s3-endpoint"
  }
}
