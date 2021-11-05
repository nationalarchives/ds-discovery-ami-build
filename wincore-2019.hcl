packer {
  required_version = ">= 1.7.0"
}

data "amazon-ami" "ami" {
  filters     = {
    name                = "Windows_Server-2019-English-Core-Base*"
    root-device-type    = "ebs"
    virtualization-type = "hvm"
  }
  most_recent = true
  owners      = [
    "801119661308"]
  profile     = "${var.profile}"
  region      = "eu-west-2"
}


source "amazon-ebs" "ebs" {
  ami_description             = "${var.amiDescription}"
  ami_name                    = "${var.amiName}"
  ami_users                   = "${var.ami_users}"
  associate_public_ip_address = false
  communicator                = "winrm"
  iam_instance_profile        = "${var.iam_instance_profile}"
  instance_type               = "t3a.large"
  launch_block_device_mappings {
    delete_on_termination = true
    device_name           = "/dev/sda1"
    encrypted             = true
    volume_size           = 30
    volume_type           = "gp2"
  }
  profile                     = "${var.profile}"
  region                      = "eu-west-2"
  run_tags                    = {
    Name = "discovery_ami_${var.tier}_${var.environment}"
  }
  security_group_id           = "${var.security_group_id}"
  source_ami                  = "${data.amazon-ami.ami.id}"
  ssh_interface               = "private_ip"
  ssh_keypair_name            = "${var.ssh_keypair_name}"
  ssh_private_key_file        = "${var.ssh_private_key_file}"
  subnet_id                   = "${var.subnet_id}"
  tags                        = {
    ApplicationType = ".NET"
    CostCentre      = "53"
    CreatedBy       = "GitHub Actions"
    Environment     = "${var.environment}"
    Name            = "${var.amiName}"
    Owner           = "Digital Services"
    Role            = "${var.tier}"
    Service         = "${var.application}"
    Terraform       = "false"
  }
  user_data_file              = "./scripts/wincore-2019.ps1"
  vpc_id                      = "${var.vpc_id}"
  winrm_port                  = 5985
  winrm_timeout               = "10m"
  winrm_username              = "Administrator"
}

build {
  description = "Build Windows Core Server 2019 Server for Discovery"

  sources = [
    "source.amazon-ebs.ebs"]

  provisioner "powershell" {
    inline = [
      "md ${var.file_dest_path}",
      "md c:\\tna-startup"]
  }

  provisioner "file" {
    destination = "${var.file_dest_path}${var.file_downloader}"
    source      = "${var.files_source_path}${var.file_downloader}"
  }

  provisioner "file" {
    destination = "${var.file_dest_path}${var.ps_startup_script}"
    source      = "${var.app_source_path}${var.application_path}${var.ps_startup_script}"
  }

  provisioner "file" {
    destination = "${var.startup_path}startup.ps1"
    source      = "${var.app_source_path}${var.application}/startup.ps1"
  }

  provisioner "file" {
    destination = "${var.startup_path}${var.ps_env_upd_script}"
    source      = "${var.app_source_path}${var.application_path}${var.ps_env_upd_script}"
  }

  provisioner "powershell" {
    elevated_password = "${var.password}"
    elevated_user     = "${var.user}"
    inline            = [
      "cd ${var.file_dest_path}",
      "./${var.ps_startup_script} -environment ${var.environment} -tier ${var.tier} -application ${var.application}"]
  }
}
