packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "~> 1"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "us-east-2"
}

variable "eks_version" {
  type    = string
  default = "1.36"
}

variable "source_ami_id" {
  type        = string
  description = "Pinned EKS 1.36 AL2023 x86_64 standard AMI."
}

variable "subnet_id" {
  type        = string
  description = "Public subnet used only by the temporary Packer builder."
}

variable "nvidia_driver_version" {
  type    = string
  default = "615.71.10"
}

variable "ami_name" {
  type    = string
  default = "amazon-eks-1.36-al2023-nvidia-r615-{{timestamp}}"
}

source "amazon-ebs" "eks_al2023_r615" {
  ami_description             = "EKS ${var.eks_version} AL2023 with NVIDIA open driver (R615 branch, requested ${var.nvidia_driver_version}) for GPU fractioning"
  ami_name                    = var.ami_name
  associate_public_ip_address = true
  encrypt_boot                = true
  instance_type               = "m5.xlarge"
  region                      = var.aws_region
  source_ami                  = var.source_ami_id
  ssh_username                = "ec2-user"
  subnet_id                   = var.subnet_id

  temporary_security_group_source_public_ip = true

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  launch_block_device_mappings {
    delete_on_termination = true
    device_name           = "/dev/xvda"
    volume_size           = 50
    volume_type           = "gp3"
  }

  run_tags = {
    Name        = "eks-runai-gpu-fractioning-ami-builder"
    auto-delete = "yes"
    purpose     = "runai-gpu-fractioning-ami-build"
  }

  # nvidia-driver-version here is only the configured R615 branch selector,
  # known before the build runs. install-r615.sh's dnf module install can
  # resolve to a later point release on that branch (the repo moves
  # forward independent of this config). 02-build-ami.sh overwrites this
  # tag with the version actually discovered on the built image once the
  # build completes, so the published AMI tag never understates the real
  # driver version.
  tags = {
    Name                  = var.ami_name
    auto-delete           = "no"
    eks-version           = var.eks_version
    nvidia-driver-version = var.nvidia_driver_version
    purpose               = "runai-gpu-fractioning-sample"
    source-ami-id         = var.source_ami_id
  }
}

build {
  sources = ["source.amazon-ebs.eks_al2023_r615"]

  provisioner "shell" {
    environment_vars = [
      "NVIDIA_DRIVER_VERSION=${var.nvidia_driver_version}",
    ]
    script = "${path.root}/install-r615.sh"
  }

  # install-r615.sh only pins the requested value as a branch selector and
  # records the driver version actually installed from the CUDA repo (which
  # can be a later point release) to /etc/eks-runai-nvidia-driver-version.
  # Download that file so 02-build-ami.sh can tag the resulting AMI, and
  # downstream node-group rendering, with the version that is really on the
  # image -- never the configured branch selector. One packer build runs
  # one source block, producing one file; 02-build-ami.sh reads and
  # relocates it (keyed to the resulting AMI ID) immediately after this
  # build completes, so a fixed name does not race a concurrent build.
  provisioner "file" {
    direction   = "download"
    source      = "/etc/eks-runai-nvidia-driver-version"
    destination = "${path.root}/installed-driver-version.txt"
  }

  post-processor "manifest" {
    output     = "${path.root}/manifest.json"
    strip_path = true
  }
}
