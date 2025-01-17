data "aws_region" "current" {}

data "aws_subnet" "first" {
  id = "${element(var.subnet_ids, 0)}"
}

data "aws_ami" "eks_node" {
  filter {
    name   = "name"
    values = ["${var.ami_lookup}"]
  }

  most_recent = true
  owners      = ["969262732424"]
}