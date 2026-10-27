# Valores de las variables declaradas en config.hcl
# (equivale al terraform.tfvars de Terraform).
# Se carga con:  packer build -var-file=variables.hcl config.pkr.hcl
#
# OJO: las llaves de AWS NUNCA van aquí; Packer las toma de `aws configure`
# o de las variables de entorno AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY.

ssh_username = "packer"
ssh_password = "packer"

vm_name    = "packer"
aws_region = "us-east-1"
s3_bucket  = "packer-vbox-import-isaac-2710"
