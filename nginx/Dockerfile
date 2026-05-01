FROM nginx:alpine

RUN rm /etc/nginx/conf.d/default.conf

COPY nginx.conf /etc/nginx/nginx.conf

# Убираем COPY sites — конфиги будут монтироваться через volume

EXPOSE 80 443

CMD ["nginx", "-g", "daemon off;"]