FROM node:18-bullseye

WORKDIR /app

# Install dependencies including Chromium
RUN apt-get update && apt-get install -y \
    chromium-browser \
    chromium \
    ca-certificates \
    fonts-liberation \
    libappindicator3-1 \
    libasound2 \
    libatk-bridge2.0-0 \
    libatk1.0-0 \
    libc6 \
    libcairo2 \
    libcups2 \
    libdbus-1-3 \
    libexpat1 \
    libfontconfig1 \
    libgbm1 \
    libgcc1 \
    libglib2.0-0 \
    libgtk-3-0 \
    libharfbuzz0b \
    libhtml5-gperf \
    libjpeg-turbo-progs \
    libpango-1.0-0 \
    libpangocairo-1.0-0 \
    libpango1.0-0 \
    libpci3 \
    libpixman-1-0 \
    libpthread-stubs0-dev \
    libssl1.1 \
    libstdc++6 \
    libx11-6 \
    libx11-xcb1 \
    libxcb1 \
    libxcomposite1 \
    libxcursor1 \
    libxdamage1 \
    libxext6 \
    libxfixes3 \
    libxft2 \
    libxi6 \
    libxinerama1 \
    libxkbcommon0 \
    libxrandr2 \
    libxrender1 \
    libxss1 \
    libxtst6 \
    xdg-utils \
    && rm -rf /var/lib/apt/lists/*

# Copy package files
COPY package*.json ./

# Install npm dependencies
RUN npm install --only=production

# Copy application
COPY . .

# Create output directory
RUN mkdir -p ./output

# Set environment variable for Puppeteer
ENV PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true
ENV PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium

# Run the watcher
CMD ["node", "watch-actual.js"]
