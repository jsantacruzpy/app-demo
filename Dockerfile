# Dockerfile
FROM nginx:alpine

# Copiar script de inicio que inyecta el hostname
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

COPY index.html /usr/share/nginx/html/index.html

EXPOSE 80

# El script inyecta el hostname y luego arranca nginx
CMD ["/docker-entrypoint.sh"]
