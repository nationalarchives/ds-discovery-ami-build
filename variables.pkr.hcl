locals {
  amiName        = "${var.application}-ami-${var.tier}-{{timestamp}}"
  amiDescription = "Windows Core 2019 - ${var.application} - ${var.tier}"

  vpc_id               = "${var.vpcId}"
  subnet_id            = "${var.subnetId}"
  security_group_id    = "${var.securityGroupId}"
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
