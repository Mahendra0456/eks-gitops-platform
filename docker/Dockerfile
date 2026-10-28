# Build context is the repository root:  docker build -f docker/Dockerfile .
FROM node:22-alpine AS deps
WORKDIR /app
COPY application/package.json application/package-lock.json ./
RUN npm ci --omit=dev

FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production
RUN addgroup -S app && adduser -S app -G app
COPY --from=deps /app/node_modules ./node_modules
COPY application/ .
USER app
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=3s --start-period=20s \
  CMD wget -qO- http://localhost:3000/health || exit 1
CMD ["node", "server.js"]
