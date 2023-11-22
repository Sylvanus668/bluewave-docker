

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  tags = {
    Name = "${var.product}-vpc-${var.environment}"
  }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id
}

resource "aws_subnet" "subnet" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "10.0.1.0/24"
  map_public_ip_on_launch = true
  tags = {
    Name = "${var.product}-subnet-${var.environment}"
  }
}

resource "aws_route_table" "main" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "${var.product}-rt-${var.environment}"
  }
}

resource "aws_route_table_association" "main" {
  subnet_id      = aws_subnet.subnet.id
  route_table_id = aws_route_table.main.id
}


data "http" "my_ip" {
  url = "http://ipv4.icanhazip.com"
}

resource "aws_security_group" "allow_ssh" {
  vpc_id = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 8081
    to_port     = 8081
    protocol    = "tcp"
    cidr_blocks = ["${trimspace(data.http.my_ip.body)}/32"]
  }

  tags = {
    Name = "${var.product}-sg-${var.environment}"
  }
}


data "aws_ami" "app_and_web_server" {
  most_recent = true

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["137112412989"]
}


resource "aws_key_pair" "deployer" {
  key_name   = "${var.product}-kp-${var.environment}"
  public_key = tls_private_key.key_pair.public_key_openssh
}

resource "tls_private_key" "key_pair" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_secretsmanager_secret" "private_key" {
  name = "${var.product}-private-key-${var.environment}"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "private_key" {
  secret_id     = aws_secretsmanager_secret.private_key.id
  secret_string = tls_private_key.key_pair.private_key_pem
}

resource "local_file" "private_key" {
  content  = tls_private_key.key_pair.private_key_pem
  filename = "${path.module}/../ssh_key.pem"

  file_permission = "0600"
}


resource "aws_instance" "app_and_web_server" {
  ami           = data.aws_ami.app_and_web_server.id
  instance_type = var.instance_type
  subnet_id     = aws_subnet.subnet.id
  key_name      = aws_key_pair.deployer.key_name

  iam_instance_profile = aws_iam_instance_profile.ec2_ecr_instance_profile.name

  root_block_device {
    volume_size = 30
  }

  vpc_security_group_ids = [aws_security_group.allow_ssh.id]

  user_data = local.user_data
  tags = {
    Name = "${var.product}-app-and-web-server-${var.environment}"
  }
}


resource "aws_ecr_repository" "bluewave_app" {
  name                 = "bluewave-app"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
  force_delete = true

  tags = {
    Name = "${var.product}-ecr-repo-${var.environment}"
  }
}

resource "aws_iam_role" "ec2_ecr_role" {
  name = "${var.product}-ec2-ecr-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })
}

resource "aws_iam_policy" "ecr_read_policy" {
  name        = "${var.product}-ecr-read-policy-${var.environment}"
  path        = "/"
  description = "A policy that allows pulling images from ECR."

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
            "Effect": "Allow",
            "Action": "ecr:GetAuthorizationToken",
            "Resource": "*"
        },
      {
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:GetRepositoryPolicy",
          "ecr:DescribeRepositories",
          "ecr:ListImages",
          "ecr:DescribeImages",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage"
        ],
        Effect   = "Allow",
        Resource = "${aws_ecr_repository.bluewave_app.arn}"
      },
    ]
  })
}




data "aws_iam_policy" "policy_ssm_managed_instance_core" {
  arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy" "policy_ssm_patch" {
  arn = "arn:aws:iam::aws:policy/AmazonSSMPatchAssociation"
}

resource "aws_iam_policy" "iam_policy_2" {
  name = "${var.product}-ec2-additional-policy-${var.environment}"

  policy = <<-EOF
  {
      "Version": "2012-10-17",
      "Statement": [
          {
              "Effect": "Allow",
              "Action": [
                  "ssmmessages:CreateControlChannel",
                  "ssmmessages:CreateDataChannel",
                  "ssmmessages:OpenControlChannel",
                  "ssmmessages:OpenDataChannel",
                  "ssm:UpdateInstanceInformation"
              ],
              "Resource": "*"
          },
          {
              "Effect": "Allow",
              "Action": [
                  "logs:CreateLogStream",
                  "logs:PutLogEvents",
                  "logs:DescribeLogGroups",
                  "logs:DescribeLogStreams"
              ],
              "Resource": "*"
          },
          {
              "Effect": "Allow",
              "Action": [
                  "s3:PutObject"
              ],
              "Resource": "*"
          },
          {
              "Effect": "Allow",
              "Action": [
                  "s3:GetEncryptionConfiguration"
              ],
              "Resource": "*"
          },
          {
              "Effect": "Allow",
              "Action": [
                  "kms:Decrypt"
              ],
              "Resource": "*"
          },
          {
              "Effect": "Allow",
              "Action": "kms:GenerateDataKey",
              "Resource": "*"
          }
      ]
  }
  EOF
}

resource "aws_iam_role_policy_attachment" "ssm_managed_instance_core_attachment" {
  role       = aws_iam_role.ec2_ecr_role.name
  policy_arn = data.aws_iam_policy.policy_ssm_managed_instance_core.arn
}

resource "aws_iam_role_policy_attachment" "ssm_patch_attachment" {
  role       = aws_iam_role.ec2_ecr_role.name
  policy_arn = data.aws_iam_policy.policy_ssm_patch.arn
  depends_on = [ aws_iam_role_policy_attachment.ssm_managed_instance_core_attachment ]
}

resource "aws_iam_role_policy_attachment" "iam_policy_2_attachment" {
  role       = aws_iam_role.ec2_ecr_role.name
  policy_arn = aws_iam_policy.iam_policy_2.arn
  depends_on = [ aws_iam_role_policy_attachment.ssm_patch_attachment ]
}

resource "aws_iam_role_policy_attachment" "ecr_read_policy_attachment" {
  role       = aws_iam_role.ec2_ecr_role.name
  policy_arn = aws_iam_policy.ecr_read_policy.arn
  depends_on = [ aws_iam_role_policy_attachment.iam_policy_2_attachment]
}

resource "aws_iam_instance_profile" "ec2_ecr_instance_profile" {
  name = "${var.product}-instance-profile-${var.environment}"
  role = aws_iam_role.ec2_ecr_role.name
}