data "aws_iam_policy_document" "assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "tic_game_cluster_role" {
  name               = "eks-cluster-cloud"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

resource "aws_iam_role_policy_attachment" "tic-AmazonEKSClusterPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.tic_game_cluster.name
}

#get vpc data
data "aws_vpc" "default" {
  default = true
}
#get public subnets for cluster
data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}
#cluster provision
resource "aws_eks_cluster" "tic_game_cluster" {
  name     = "EKS_CLOUD"
  role_arn = aws_iam_role.tic_game_cluster_role.arn

  vpc_config {
    subnet_ids = data.aws_subnets.public.ids
  }

  # Ensure that IAM Role permissions are created before and deleted after EKS Cluster handling.
  # Otherwise, EKS will not be able to properly delete EKS managed EC2 infrastructure such as Security Groups.
  depends_on = [
    aws_iam_role_policy_attachment.tic-AmazonEKSClusterPolicy,
  ]
}
resource "aws_iam_role" "tic_game_node_role" {
  name = "eks-node-group-cloud"

  assume_role_policy = jsonencode({
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
    Version = "2012-10-17"
  })
}

resource "aws_iam_role_policy_attachment" "node-AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.tic_game_node_role.name
}

resource "aws_iam_role_policy_attachment" "enode-AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.tic_game_node_role.name
}

resource "aws_iam_role_policy_attachment" "node-AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.tic_game_node_role.name
}

#create node group
resource "aws_eks_node_group" "example" {
  cluster_name    = aws_eks_cluster.tic_game_cluster.name
  node_group_name = "Node-cloud"
  node_role_arn   = aws_iam_role.tic_game_node_role.arn
  subnet_ids      = data.aws_subnets.public.ids

  scaling_config {
    desired_size = 1
    max_size     = 2
    min_size     = 1
  }
  instance_types = ["t2.small"]

  # Ensure that IAM Role permissions are created before and deleted after EKS Node Group handling.
  # Otherwise, EKS will not be able to properly delete EC2 Instances and Elastic Network Interfaces.
  depends_on = [
    aws_iam_role_policy_attachment.node-AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.node-AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.node-AmazonEC2ContainerRegistryReadOnly,
  ]
}

________________________________________________

# Create an OIDC identity provider for EKS
data "aws_eks_cluster" "cluster" {
  name = aws_eks_cluster.tic_game_cluster.name
}

data "aws_eks_cluster_auth" "cluster" {
  name = aws_eks_cluster.tic_game_cluster.name
}

resource "aws_iam_openid_connect_provider" "karpenter_oidc_provider" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.aws_eks_cluster.cluster.identity[0].oidc.issuer_thumbprint]
  url             = data.aws_eks_cluster.cluster.identity[0].oidc.issuer
}

# Create an IAM Role for Karpenter controller
data "aws_iam_policy_document" "karpenter_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.karpenter_oidc_provider.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_eks_cluster.cluster.identity[0].oidc.issuer, "https://", "")}:sub"
      values   = ["system:serviceaccount:karpenter:karpenter"]
    }
  }
}

resource "aws_iam_role" "karpenter_controller_role" {
  name               = "karpenter-controller-role"
  assume_role_policy = data.aws_iam_policy_document.karpenter_assume_role.json
}

resource "aws_iam_role_policy_attachment" "karpenter_controller_policy" {
  role       = aws_iam_role.karpenter_controller_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterAutoscalerPolicy"
}

# Install Karpenter Helm chart
resource "helm_release" "karpenter" {
  name       = "karpenter"
  namespace  = "karpenter"
  chart      = "karpenter"
  repository = "https://charts.karpenter.sh"
  version    = "v0.29.0" # Update to the latest stable version

  set {
    name  = "serviceAccount.create"
    value = "false"
  }

  set {
    name  = "serviceAccount.name"
    value = "karpenter"
  }

  set {
    name  = "controller.clusterName"
    value = aws_eks_cluster.tic_game_cluster.name
  }

  set {
    name  = "controller.clusterEndpoint"
    value = data.aws_eks_cluster.cluster.endpoint
  }

  set {
    name  = "controller.aws.defaultInstanceProfile"
    value = "karpenter-node-instance-profile" # Replace with your node instance profile
  }
}

# Create a Karpenter provisioner (YAML example)
resource "kubernetes_manifest" "karpenter_provisioner" {
  manifest = <<EOT
apiVersion: karpenter.sh/v1alpha5
kind: Provisioner
metadata:
  name: default
spec:
  requirements:
    - key: "karpenter.sh/capacity-type"
      operator: "In"
      values: ["on-demand", "spot"]
    - key: "node.kubernetes.io/instance-type"
      operator: "In"
      values: ["t3.medium", "t3.large"]
  limits:
    resources:
      cpu: 1000
      memory: 2000Gi
  provider:
    cluster:
      endpoint: "${data.aws_eks_cluster.cluster.endpoint}"
      name: "${aws_eks_cluster.tic_game_cluster.name}"
EOT
}

##############################################################








