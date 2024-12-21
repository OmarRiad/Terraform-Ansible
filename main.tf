resource "aws_vpc" "main" {
 cidr_block = "10.0.0.0/16"
 
 tags = {
   Name = "Primary-VPC"
 }
}
resource "aws_key_pair" "key" {
  key_name   = "id_rsa"
  public_key = file(var.ssh_pubkey_file)
}

resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  map_public_ip_on_launch = true
  availability_zone       = "eu-west-2a"
  tags = {
    Name = "Public-subnet"
  }
}
resource "aws_subnet" "public-subnet-2" { 
  tags = {
    Name = "public-subnet-2"
  }
  cidr_block        = var.public_subnet_2_cidr
  vpc_id            = aws_vpc.main.id
  availability_zone = "eu-west-2b"
}
resource "aws_subnet" "private1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet1_cidr
  availability_zone = "eu-west-2a"
  tags = {
    Name = "Private-Subnet-1"
  }
}
resource "aws_subnet" "private2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet2_cidr
  availability_zone = "eu-west-2b"
  tags = {
    Name = "Private-Subnet-2"
  }
}
resource "aws_internet_gateway" "gw" {
 vpc_id = aws_vpc.main.id
 
 tags = {
   Name = "Project VPC IG"
 }
}
resource "aws_route_table" "second_rt" {
 vpc_id = aws_vpc.main.id
 
 route {
   cidr_block = "0.0.0.0/0"
   gateway_id = aws_internet_gateway.gw.id
 }
 
 tags = {
   Name = "2nd Route Table"
 }
}

# NAT Gateway for the public subnet
resource "aws_eip" "nat_gateway" {
  vpc = true
  associate_with_private_ip = "10.0.0.5"
  depends_on = [aws_internet_gateway.gw]
}
resource "aws_nat_gateway" "nat_gateway" {
  allocation_id = aws_eip.nat_gateway.id
  subnet_id     = aws_subnet.public_subnet.id

  tags = {
    Name = "ngw"
  }
  depends_on = [aws_eip.nat_gateway]
}

resource "aws_route_table" "public-route-table" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "public-route-table"
  }
}
resource "aws_route_table" "private-route-table" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "private-route-table"
  }
}

resource "aws_route" "public-internet-igw-route" {
  route_table_id         = aws_route_table.public-route-table.id
  gateway_id             = aws_internet_gateway.gw.id
  destination_cidr_block = "0.0.0.0/0"
}
# Route NAT Gateway
resource "aws_route" "nat-ngw-route" {
  route_table_id         = aws_route_table.private-route-table.id
  nat_gateway_id         = aws_nat_gateway.nat_gateway.id
  destination_cidr_block = "0.0.0.0/0"
}

resource "aws_route_table_association" "public_subnet_association" {
 subnet_id      = aws_subnet.public_subnet.id
 route_table_id = aws_route_table.second_rt.id
}

resource "aws_route_table_association" "private-route-1-association" {
  route_table_id = aws_route_table.private-route-table.id
  subnet_id      = aws_subnet.private1.id
}
resource "aws_route_table_association" "private-route-2-association" {
  route_table_id = aws_route_table.private-route-table.id
  subnet_id      = aws_subnet.private2.id
}

resource "aws_security_group" "load-balancer" {
  name        = "load_balancer_security_group"
  description = "Controls access to the ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Instance Security group (traffic ALB -> EC2, ssh -> EC2)
resource "aws_security_group" "ec2" {
  name        = "ec2_security_group"
  description = "Allows inbound access from the ALB only"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    security_groups = [aws_security_group.load-balancer.id]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}


# Load Balancer
resource "aws_lb" "app-lb" {
  name               = "app-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.load-balancer.id]
  subnets            = [aws_subnet.public_subnet.id, aws_subnet.public-subnet-2.id]
}

# Target group
resource "aws_alb_target_group" "default-target-group" {
  name     = "app-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = var.health_check_path
    port                = "traffic-port"
    healthy_threshold   = 5
    unhealthy_threshold = 2
    timeout             = 2
    interval            = 60
    matcher             = "200"
  }
}

resource "aws_autoscaling_attachment" "asg_attachment_bar" {
  autoscaling_group_name = aws_autoscaling_group.ec2-cluster.id
  lb_target_group_arn    = aws_alb_target_group.default-target-group.arn
}

resource "aws_alb_listener" "ec2-alb-http-listener" {
  load_balancer_arn = aws_lb.app-lb.id
  port              = "80"
  protocol          = "HTTP"
  depends_on        = [aws_alb_target_group.default-target-group]

  default_action {
    type             = "forward"
    target_group_arn = aws_alb_target_group.default-target-group.arn
  }
}
# Launch Template for EC2 instances
resource "aws_launch_template" "ec2" {
  name_prefix   = "my-app-launch-template-"
  image_id      = var.ami_id
  instance_type = "t2.micro"
  key_name = aws_key_pair.key.key_name


  # Network interface configuration
  network_interfaces {
    security_groups          = [aws_security_group.ec2.id]
    associate_public_ip_address = false
  }

  user_data = base64encode(<<-EOL
    #!/bin/bash -xe
    sudo yum update -y
    sudo yum -y install docker
    sudo service docker start
    sudo usermod -a -G docker ec2-user
    sudo chmod 666 /var/run/docker.sock
    docker pull nginx
    docker tag nginx my-nginx
    docker run --rm --name nginx-server -d -p 80:80 -t my-nginx
  EOL
  )
  depends_on = [aws_nat_gateway.nat_gateway]

  tags = {
    Name = "EC2 Instance"
  }

  lifecycle {
    create_before_destroy = true
  }
}


# Auto Scaling Group using Launch Template
resource "aws_autoscaling_group" "ec2-cluster" {
  name              = "myapp_auto_scaling_group"
  min_size          = var.autoscale_min
  max_size          = var.autoscale_max
  desired_capacity  = var.autoscale_desired
  health_check_type = "EC2"
  
  vpc_zone_identifier = [aws_subnet.private1.id, aws_subnet.private2.id]
  target_group_arns   = [aws_alb_target_group.default-target-group.arn]

  launch_template {
    id      = aws_launch_template.ec2.id
    version = "$Latest"
  }

}

resource "aws_instance" "bastion" {
  ami                         = var.ami_id
  instance_type               = "${var.instance_type}"
  key_name                    = aws_key_pair.key.key_name
  
  associate_public_ip_address = true
  security_groups            = [aws_security_group.ec2.id]
  subnet_id                   = aws_subnet.public_subnet.id
  tags = {
    Name = "Bastion"
  }
}

resource "aws_instance" "db_instance" {
  ami                         = var.ami_id
  instance_type               = "t2.micro"
  key_name                    = aws_key_pair.key.key_name
  associate_public_ip_address = false
  subnet_id                   = aws_subnet.private1.id
  security_groups             = [aws_security_group.db-instance.id]
  
  tags = {
    Name = "DB Instance"
  }
}
resource "aws_security_group" "db-instance" {
  name        = "private_instance_security_group"
  description = "Allows SSH access from the Bastion host only"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    cidr_blocks = ["0.0.0.0/0"] 
  }
  ingress {
    from_port       = 27017
    to_port         = 27017
    protocol        = "tcp"
    cidr_blocks = ["0.0.0.0/0"] 
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
