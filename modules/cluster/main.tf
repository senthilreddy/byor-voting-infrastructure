terraform {
  required_version = ">= 0.10.3"
}

# Cluster Security Group
resource "aws_security_group" "cluster" {
  name        = "${var.name}-cluster"
  description = "Cluster communication with worker nodes"
  vpc_id      = "${var.vpc_id}"

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags {
    Name = "${var.name}-cluster"
  }
}

resource "aws_security_group_rule" "cluster-ingress-workstation-https" {
  count = "${length(var.cidr_block) != 0 ? 1 : 0}"

  description       = "Allow workstation to communicate with the cluster API Server"
  type              = "ingress"
  from_port         = 0
  to_port           = 65535
  protocol          = "-1"
  security_group_id = "${aws_security_group.cluster.id}"
  cidr_blocks       = ["${var.cidr_block}"]
}

# Node Security Group
resource "aws_security_group" "node" {
  name        = "${var.name}-node"
  description = "Security group for all nodes in the cluster"
  vpc_id      = "${var.vpc_id}"

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = "${
    map(
     "Name", "${var.name}-node",
     "kubernetes.io/cluster/${var.name}", "owned",
    )
  }"
}

resource "aws_security_group_rule" "node_ingress_self" {
  description              = "Allow node to communicate with each other"
  from_port                = 0
  protocol                 = "-1"
  security_group_id        = "${aws_security_group.node.id}"
  source_security_group_id = "${aws_security_group.node.id}"
  to_port                  = 65535
  type                     = "ingress"
}

resource "aws_security_group_rule" "node_allow_ssh" {
  count = "${length(var.ssh_cidr) != 0 ? 1 : 0}"

  description              = "Allow incoming ssh connections to the EKS nodes"
  from_port                = 22
  protocol                 = "tcp"
  security_group_id        = "${aws_security_group.node.id}"
  cidr_blocks              = ["${var.ssh_cidr}"]
  to_port                  = 22
  type                     = "ingress"
}

resource "aws_security_group_rule" "node_ingress_cluster" {
  description              = "Allow worker Kubelets and pods to receive communication from the cluster control plane"
  from_port                = 1025
  protocol                 = "tcp"
  security_group_id        = "${aws_security_group.node.id}"
  source_security_group_id = "${aws_security_group.cluster.id}"
  to_port                  = 65535
  type                     = "ingress"
}

resource "aws_security_group_rule" "node_ingress_cluster_https" {
  description              = "Allow incoming https connections from the EKS masters security group"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = "${aws_security_group.node.id}"
  source_security_group_id = "${aws_security_group.cluster.id}"
  type                     = "ingress"
}

resource "aws_security_group_rule" "cluster-ingress-node-https" {
  description              = "Allow pods to communicate with the cluster API Server"
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = "${aws_security_group.cluster.id}"
  source_security_group_id = "${aws_security_group.node.id}"
}

resource "aws_eks_cluster" "cluster" {
  name     = "${var.name}"
  version  = "${var.eks_version}"
  role_arn = "${aws_iam_role.cluster.arn}"

  vpc_config {
    subnet_ids               = ["${var.subnet_ids}"]
    security_group_ids       = ["${aws_security_group.cluster.id}"]
    endpoint_private_access  = "${var.cluster_private_access}"
    endpoint_public_access   = "${var.cluster_public_access}"
  }

  depends_on = [
    "aws_iam_role_policy_attachment.cluster_AmazonEKSClusterPolicy",
    "aws_iam_role_policy_attachment.cluster_AmazonEKSServicePolicy",
  ]
}


# Deploying Dashboard 

resource "local_file" "eks_admin" {
  count = "${var.enable_dashboard ? 1 : 0}"

  content  = "${local.eks_admin}"
  filename = "${path.root}/output/${var.name}/k8s-admin.yaml"

  depends_on = [
    "null_resource.output",
  ]
}

resource "null_resource" "dashboard" {
  count = "${var.enable_dashboard ? 1 : 0}"

  provisioner "local-exec" {
    command = <<COMMAND
      export KUBECONFIG=${path.root}/output/${var.name}/kubeconfig-${var.name} \
      && kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/master/aio/deploy/recommended/kubernetes-dashboard.yaml \
      && kubectl apply -f https://raw.githubusercontent.com/kubernetes/heapster/master/deploy/kube-config/influxdb/heapster.yaml \
      && kubectl apply -f https://raw.githubusercontent.com/kubernetes/heapster/master/deploy/kube-config/influxdb/influxdb.yaml \
      && kubectl apply -f https://raw.githubusercontent.com/kubernetes/heapster/master/deploy/kube-config/rbac/heapster-rbac.yaml \
      && kubectl apply -f ${path.root}/output/${var.name}/k8s-admin.yaml \
      && kubectl -n kube-system describe secret $(kubectl -n kube-system get secret | grep k8s-admin | awk '{print $1}') \
      && kubectl apply -f ${path.root}/output/${var.name}/tiller-svc.yaml 
    COMMAND
  }

  triggers {
    kubeconfig_rendered = "${local.kubeconfig}"
  }

  depends_on = [
    "local_file.eks_admin",
  ]
}
