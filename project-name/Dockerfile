FROM node:24-alpine AS base

WORKDIR /app

FROM base AS dependencies
COPY package*.json ./
RUN npm install

FROM dependencies AS development
COPY . .
EXPOSE 3000
CMD ["npm", "run", "start:dev"]

FROM dependencies AS build
COPY . .
RUN npm run build
RUN npm prune --omit=dev

FROM base AS production
ENV NODE_ENV=production
COPY --from=build /app/package.json ./package.json
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
EXPOSE 3000
CMD ["npm", "run", "start:prod"]
