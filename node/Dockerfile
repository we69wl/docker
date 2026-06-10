FROM node:lts-alpine
WORKDIR /app
COPY nginx/www/qzzdeals/backend/package*.json ./
RUN npm install --omit=dev
COPY nginx/www/qzzdeals/backend/ .
EXPOSE 3000
CMD ["node", "server.js"]
