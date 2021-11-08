variable "environment" {
  type    = string
  default = null

  validation {
    condition     = var.environment == "dev" || var.environment == "test" || var.environment == "live"
    error_message = "Environment can only be dev, test or live."
  }
}
variable "tier" {
  type    = string
  default = null
}
variable "application" {
  type    = string
  default = null
}
variable "account" {
  type    = string
  default = null
}
variable "vpcId" {
  type    = string
  default = null
}
variable "subnetId" {
  type    = string
  default = null
}
variable "securityGroupId" {
  type    = string
  default = null
}

locals {
  amiName        = "${var.application}-ami-${var.tier}-{{timestamp}}"
  amiDescription = "Windows Core 2019 - ${var.application} - ${var.tier}"
  ami_users      = ""

  ssh_keypair_name     = "${var.application}-${var.tier}-${var.environment}"
  ssh_private_key_file = "c:\\ssh_keys\\${var.application}-${var.tier}-${var.environment}.pem"

  profile              = "${var.environment}dsadmin"
  iam_instance_profile = "discovery_instance_profile"

  files_source_path = "./files/"
  app_source_path   = "./apps/"
  application_path  = "${var.application}/"
  file_dest_path    = "C:\\temp\\"
  startup_path      = "C:\\tna-startup\\"
  ps_startup_script = "server-setup.ps1"
  ps_env_upd_script = "updEnv.ps1"
  file_downloader   = "file-downloader.ps1"
}

packer {
  required_version = ">= 1.7.0"

  required_plugins {
    amazon = {
      version = ">= 0.0.1"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

source "amazon-ebs" "ebs" {
  ami_description = local.amiDescription
  ami_name        = local.amiName

  ami_users = [
    local.ami_users]

  associate_public_ip_address = false
  communicator                = "winrm"
  iam_instance_profile        = local.iam_instance_profile
  instance_type               = "t3a.large"

  source_ami_filter {
    filters = {
      name                = "Windows_Server-2019-English-Core-Base*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }

    most_recent = true

    owners = [
      "801119661308"]
  }

  launch_block_device_mappings {
    delete_on_termination = true
    device_name           = "/dev/sda1"
    encrypted             = true
    volume_size           = 30
    volume_type           = "gp2"
  }

  profile = "${local.profile}"
  region  = "eu-west-2"

  run_tags = {
    Name = "discovery_ami_${var.tier}_${var.environment}"
  }

  security_group_id    = var.securityGroupId
  ssh_interface        = "private_ip"
  ssh_keypair_name     = local.ssh_keypair_name
  ssh_private_key_file = local.ssh_private_key_file
  subnet_id            = var.subnetId

  tags = {
    ApplicationType = ".NET"
    CostCentre      = "53"
    CreatedBy       = "GitHub Actions"
    Environment     = var.environment
    Name            = local.amiName
    Owner           = "Digital Services"
    Role            = var.tier
    Service         = var.application
    Terraform       = "false"
  }

  user_data_file = "./scripts/wincore-2019.ps1"
  vpc_id         = var.vpcId
  winrm_port     = 5985
  winrm_timeout  = "10m"
  winrm_username = "Administrator"
  #winrm_insecure = true
  #winrm_use_ssl  = true
}

build {
  description = "Build Windows Core Server 2019 Server for Discovery"

  sources = [
    "source.amazon-ebs.ebs"]

  provisioner "powershell" {
    inline = [
      "md ${local.file_dest_path}",
      "md c:\\tna-startup"]
  }

  provisioner "file" {
    destination = "${local.file_dest_path}${local.file_downloader}"
    source      = "${local.files_source_path}${local.file_downloader}"
  }

  provisioner "file" {
    destination = "${local.file_dest_path}${local.ps_startup_script}"
    source      = "${local.app_source_path}${local.application_path}${local.ps_startup_script}"
  }

  provisioner "file" {
    destination = "${local.startup_path}startup.ps1"
    source      = "${local.app_source_path}${var.application}/startup.ps1"
  }

  provisioner "file" {
    destination = "${local.startup_path}${local.ps_env_upd_script}"
    source      = "${local.app_source_path}${local.application_path}${local.ps_env_upd_script}"
  }

  provisioner "powershell" {
    #elevated_password = "${var.password}"
    #elevated_user     = "${var.user}"

    inline = [
      "cd ${local.file_dest_path}",
      "./${local.ps_startup_script} -environment ${var.environment} -tier ${var.tier} -application ${var.application}"]
  }
}
