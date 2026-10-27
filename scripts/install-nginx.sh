#!/usr/bin/env bash
# Instala y habilita NGINX dentro de la VM durante el build de Packer.
# Lo usan las dos plantillas (json/config.json y hcl/config.hcl).
set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive

# Si al arrancar la VM ya hay un apt corriendo (actualizaciones automáticas),
# esperamos hasta 5 minutos por el candado en lugar de fallar.
APT="apt-get -y -o DPkg::Lock::Timeout=300"

$APT update
$APT install nginx

systemctl enable nginx
systemctl restart nginx

# Página de evidencia: cuando abras la IP pública de la instancia EC2
# en el navegador verás este mensaje y sabrás que la AMI salió de Packer.
cat > /var/www/html/index.html <<EOF
<!doctype html>
<html lang="es">
<head><meta charset="utf-8"><title>Packer + NGINX</title></head>
<body style="font-family:sans-serif;text-align:center;margin-top:10%">
  <h1>NGINX instalado con Packer</h1>
  <p>VM de VirtualBox convertida en AMI con el post-processor amazon-import.</p>
  <p>Build: $(date -u +"%Y-%m-%d %H:%M:%S UTC") &middot; Host: $(hostname)</p>
</body>
</html>
EOF

nginx -v
systemctl is-active nginx
curl -s -o /dev/null -w "HTTP local: %{http_code}\n" http://localhost || true
