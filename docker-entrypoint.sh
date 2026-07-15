#!/bin/sh

# Reemplazar el placeholder HOSTNAME en el HTML
# con el hostname real del contenedor (nombre del pod en k8s)
sed -i "s|__HOSTNAME__|$(hostname)|g" /usr/share/nginx/html/index.html

# Arrancar nginx en foreground
nginx -g "daemon off;"
