# =============================================================================
# Security groups. Your EC2 security group is the real firewall; ufw on the host
# (installed by Ansible) is defence in depth.
# =============================================================================

resource "aws_security_group" "ec2" {
  name        = "${local.name}-ec2"
  description = "Solrise app host - SSH, HTTP (ACME) and HTTPS"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH (Ansible / operations)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_cidr_blocks
  }

  ingress {
    description = "HTTP - Let's Encrypt HTTP-01 challenge + https redirect"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All egress (package install, image build, RDS, S3, ACME)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-ec2-sg" }
}

resource "aws_security_group" "rds" {
  name        = "${local.name}-rds"
  description = "MariaDB reachable only from the app host security group"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "MariaDB from the app host"
    from_port       = var.db_port
    to_port         = var.db_port
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]
  }

  egress {
    description = "Allow all egress (RDS does not initiate connections)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-rds-sg" }
}
