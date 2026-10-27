# packer-export-virtualbox-vm-to-aws-ami

De una máquina virtual de **VirtualBox** a una **AMI de AWS**, de tres formas:

| Parte | Herramienta | Qué hace |
|---|---|---|
| 1 | `VBoxManage export` + `aws ec2 import-image` | A mano, con la CLI |
| 2 | Packer **JSON** (`json/config.json`) | VM → NGINX → AMI, credenciales SSH hardcodeadas |
| 3 | Packer **HCL** (`hcl/config.hcl` + `hcl/variables.hcl`) | Lo mismo, con credenciales como variables en otro archivo |

```
VM VirtualBox ──export──▶ .ova (OVF 2.0) ──S3──▶ VM Import ──▶ AMI ──▶ EC2 (NGINX en :80)
```

## Estructura

```
.
├── aws/
│   ├── trust-policy.json     # rol vmimport (quién puede asumirlo)
│   ├── role-policy.json      # rol vmimport (qué puede hacer)
│   └── containers.json       # disco a importar en la parte 1
├── scripts/install-nginx.sh  # provisioner compartido por JSON y HCL
├── json/config.json          # Parte 2
└── hcl/
    ├── config.hcl            # Parte 3: plantilla (declara variables)
    └── variables.hcl         # Parte 3: valores de las variables
```

> Antes de usarlo, cambia `packer-vbox-import-isaac-2710` (bucket) y `ubuntu-server` (nombre de la VM) en todos los archivos.

---

## 0. Preparación (una sola vez)

**Herramientas en tu PC:** VirtualBox 7, AWS CLI v2 (`aws configure` hecho), Packer ≥ 1.10, Git.

**Dentro de la VM (Ubuntu Server):**

1. Usuario `packer` / contraseña `packer` con sudo.
2. `sudo apt install -y openssh-server && sudo systemctl enable --now ssh`
3. Red por DHCP que funcione con cualquier nombre de tarjeta (en EC2 la NIC no se llama `enp0s3`). En `/etc/netplan/50-cloud-init.yaml`:
   ```yaml
   network:
     version: 2
     ethernets:
       todas:
         match: { name: "en*" }
         dhcp4: true
   ```
   y `sudo netplan apply`.
4. Un solo disco, sin ISO montada, adaptador 1 en **NAT**.
5. Revisa el firmware: VirtualBox → Configuración → Sistema → *Habilitar EFI*. Con EFI usa `uefi`; sin EFI cambia a `legacy-bios` en los comandos y plantillas.
6. Apaga la VM y toma un snapshot llamado **`base-limpia`** (lo usan las partes 2 y 3).

**En AWS (una sola vez):**

```bash
BUCKET=packer-vbox-import-isaac-2710
REGION=us-east-1

aws s3 mb s3://$BUCKET --region $REGION

aws iam create-role --role-name vmimport \
  --assume-role-policy-document file://aws/trust-policy.json

aws iam put-role-policy --role-name vmimport --policy-name vmimport \
  --policy-document file://aws/role-policy.json
```

---

## 1. Exportar con VBoxManage e importar con `aws ec2 import-image`

```bash
VBoxManage list vms
VBoxManage showvminfo "packer" --machinereadable | grep -i firmware   # Windows: findstr /i firmware

VBoxManage export "packer" \
  --output packer.ova \
  --ovf20 \
  --options manifest,nomacs \
  --vsys 0 --description "VM Ubuntu Server para importar a AWS"
```

| Flag | Para qué |
|---|---|
| `--output x.ova` | `.ova` = paquete OVF en un solo archivo (lo que AWS acepta directo) |
| `--ovf20` | Formato OVF 2.0 |
| `--options manifest` | Genera el `.mf` con checksums |
| `--options nomacs` | Quita las MAC de VirtualBox (en la nube no sirven) |
| `--vsys 0 --description` | Metadatos del sistema virtual 0 |

```bash
aws s3 cp packer.ova s3://$BUCKET/vm-import/packer.ova

aws ec2 import-image --region $REGION \
  --description "VirtualBox ubuntu-server" \
  --disk-containers file://aws/containers.json \
  --boot-mode uefi --platform Linux

# Repite hasta Status = completed (tarda 20-60 min)
aws ec2 describe-import-image-tasks --region $REGION \
  --import-task-ids import-ami-XXXXXXXX \
  --query "ImportImageTasks[0].[Status,Progress,StatusMessage,ImageId]"
```

### Lanzar la instancia

UEFI requiere un tipo de instancia Nitro (`t3.micro` sí, `t2.micro` no).

```bash
MI_IP=$(curl -s https://checkip.amazonaws.com)

SG=$(aws ec2 create-security-group --group-name vbox-nginx-sg \
  --description "SSH desde mi IP y HTTP" --query GroupId --output text)
aws ec2 authorize-security-group-ingress --group-id $SG --protocol tcp --port 22 --cidr $MI_IP/32
aws ec2 authorize-security-group-ingress --group-id $SG --protocol tcp --port 80 --cidr 0.0.0.0/0

aws ec2 run-instances --image-id ami-XXXXXXXX --instance-type t3.micro \
  --security-group-ids $SG \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=vbox-import-cli}]"

aws ec2 describe-instances --filters "Name=tag:Name,Values=vbox-import-cli" \
  --query "Reservations[].Instances[].[InstanceId,State.Name,PublicIpAddress]" --output table

aws ec2 get-console-output --instance-id i-XXXXXXXX --latest --output text
ssh packer@IP_PUBLICA
```

---

## 2. Packer JSON

```bash
packer plugins install github.com/hashicorp/virtualbox
packer plugins install github.com/hashicorp/amazon

cd json
packer validate config.json
packer build config.json
```

## 3. Packer HCL

Packer solo lee plantillas con extensión `.pkr.hcl`; el archivo de valores sí puede llamarse `variables.hcl`.

```bash
cd hcl
cp config.hcl config.pkr.hcl          # PowerShell: Copy-Item config.hcl config.pkr.hcl
packer init config.pkr.hcl
packer fmt -check config.pkr.hcl
packer validate -var-file=variables.hcl config.pkr.hcl
packer build    -var-file=variables.hcl config.pkr.hcl
```

Al terminar, la última línea muestra la AMI (`us-east-1: ami-...`). Lánzala igual que en la parte 1 y abre `http://IP_PUBLICA`: debe aparecer **"NGINX instalado con Packer"**.

---

## Limpieza (para no generar costos)

```bash
aws ec2 terminate-instances --instance-ids i-XXXXXXXX
aws ec2 deregister-image --image-id ami-XXXXXXXX
aws ec2 delete-snapshot --snapshot-id snap-XXXXXXXX
aws s3 rm s3://$BUCKET --recursive
```
