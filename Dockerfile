FROM node:22-bookworm-slim AS deps
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends python3 make g++ ca-certificates && rm -rf /var/lib/apt/lists/*
COPY package.json ./
RUN npm install --omit=dev

FROM node:22-bookworm-slim
ENV NODE_ENV=production PORT=3000 CCNEXUS_DATA_DIR=/app/data
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg espeak-ng python3 python3-venv ca-certificates \
  && python3 -m venv /opt/yt-dlp \
  && /opt/yt-dlp/bin/pip install --no-cache-dir yt-dlp \
  && rm -rf /var/lib/apt/lists/*
ENV YTDLP_BIN=/opt/yt-dlp/bin/yt-dlp TTS_BIN=espeak-ng
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY src ./src
COPY public ./public
COPY lua ./lua
COPY docs ./docs
RUN mkdir -p /app/data && chown -R node:node /app
USER node
EXPOSE 3000
VOLUME ["/app/data"]
CMD ["node","src/server.js"]
