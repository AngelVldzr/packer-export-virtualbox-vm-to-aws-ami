# ---------------------------------------------------------------------------
# Packer HCL2: VM existente de VirtualBox  ->  NGINX  ->  AMI en AWS
#
# Las credenciales SSH NO están aquí: se declaran como variables y sus
# valores vienen de variables.hcl (se pasa con -var-file).
#
# Packer solo reconoce plantillas que terminan en .pkr.hcl, por eso antes de
# correrlo se hace una copia: config.hcl -> config.pkr.hcl (ver README).
# ---------------------------------------------------------------------------

packer {
  required_version = ">= 1.10.0"
  required_plugins {
    virtualbox = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/virtualbox"
    }
    amazon = {
      version = ">= 1.3.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

# ----------------------------- Variables ----------------------------------
# Solo se DECLARAN aquí (tipo, descripción). Los VALORES están en variables.hcl

variable "ssh_username" {
  type        = string
  description = "Usuario SSH de la VM de VirtualBox"
}

variable "ssh_password" {
  type        = string
  description = "Contraseña SSH (y de sudo) de la VM"
  sensitive   = true # Packer la oculta en la salida de la consola
}

variable "vm_name" {
  type        = string
  description = "Nombre exacto de la VM tal como aparece en VirtualBox"
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "s3_bucket" {
  type        = string
  description = "Bucket S3 (ya creado) donde se sube el .ova para importarlo"
}

locals {
  ts = formatdate("YYYYMMDDhhmmss", timestamp())
}

# ----------------------------- Builder ------------------------------------

source "virtualbox-vm" "ubuntu" {
  vm_name = var.vm_name

  attach_snapshot       = "base-limpia"
  target_snapshot       = "nginx-packer-hcl"
  force_delete_snapshot = true
  keep_registered       = false
  skip_export           = false

  format           = "ova"
  output_directory = "output-hcl"
  export_opts = [
    "--manifest",
    "--vsys", "0",
    "--description", "VM VirtualBox + NGINX (Packer HCL)"
  ]

  headless             = true
  guest_additions_mode = "disable"

  communicator = "ssh"
  ssh_username = var.ssh_username
  ssh_password = var.ssh_password
  ssh_timeout  = "20m"

  shutdown_command = "echo '${var.ssh_password}' | sudo -S shutdown -P now"
  shutdown_timeout = "10m"
}

# ----------------------------- Build --------------------------------------

build {
  name    = "vbox-nginx-ami"
  sources = ["source.virtualbox-vm.ubuntu"]

  provisioner "shell" {
    execute_command = "echo '${var.ssh_password}' | sudo -S -E bash '{{ .Path }}'"
    script          = "${path.root}/../scripts/install-nginx.sh"
  }

  post-processor "amazon-import" {
    region          = var.aws_region
    s3_bucket_name  = var.s3_bucket
    s3_key_name     = "packer/hcl/vbox-nginx-${local.ts}.ova"
    format          = "ova"
    role_name       = "vmimport"
    boot_mode       = "uefi"
    platform        = "linux"
    ami_name        = "vbox-nginx-hcl-${local.ts}"
    ami_description = "VM de VirtualBox con NGINX importada con Packer (HCL)"

    keep_input_artifact = true

    tags = {
      Name      = "vbox-nginx-hcl"
      Proyecto  = "packer-export-virtualbox-vm-to-aws-ami"
      CreadoCon = "packer-hcl"
    }
  }
}
