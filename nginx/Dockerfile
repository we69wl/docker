FROM nginx:alpine

RUN rm /etc/nginx/conf.d/default.conf

# Создаём папку для Certbot с правильными правами
RUN mkdir -p /var/www/certbot && \
    chown -R nginx:nginx /var/www/certbot && \
    chmod -R 755 /var/www/certbot

COPY nginx.conf /etc/nginx/nginx.conf

# Убираем COPY sites — конфиги будут монтироваться через volume

EXPOSE 80 443

CMD ["nginx", "-g", "daemon off;"]