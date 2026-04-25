FROM nginx:alpine

# Удаляем стандартный дефолтный конфиг
RUN rm /etc/nginx/conf.d/default.conf

# Копируем основной конфиг и конфиги сайтов
COPY nginx.conf /etc/nginx/nginx.conf
COPY sites /etc/nginx/conf.d

# Создаём папку для логов (опционально, для монтирования)
RUN mkdir -p /var/log/nginx

EXPOSE 80 443

CMD ["nginx", "-g", "daemon off;"]