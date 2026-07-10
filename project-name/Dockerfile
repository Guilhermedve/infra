FROM node:24-alpine AS build

WORKDIR /app

COPY project-name/package*.json ./

RUN npm install

COPY project-name/ .

RUN npm run build
RUN npm prune --omit=dev 

FROM node:24-alpine AS production

WORKDIR /app

ENV NODE_ENV=production

COPY --from=build /app/dist ./dist
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/package.json ./package.json

EXPOSE 3000

CMD ["npm", "run", "start:prod"]
