FROM ruby:4.0.6-slim AS provider-assets
ARG PAYGEN_SOURCE_SHA
ENV PAYGEN_SOURCE_SHA=$PAYGEN_SOURCE_SHA
ENV BUNDLE_FROZEN=true BUNDLE_WITHOUT=development:test
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends build-essential libyaml-dev \
    && rm -rf /var/lib/apt/lists/*
COPY src ./src
COPY fixtures/novapay ./fixtures/novapay
COPY docs/scripts/docs_provider_assets.rb ./docs/scripts/docs_provider_assets.rb
RUN gem install bundler -v 4.0.20 --no-document && src/run setup --jobs 4 --retry 3
RUN mkdir -p /assets && src/run exec ruby docs/scripts/docs_provider_assets.rb /assets

FROM node:22.22.0-slim AS build
WORKDIR /app/docs
RUN corepack enable && corepack prepare pnpm@10.32.1 --activate
COPY docs/package.json docs/pnpm-lock.yaml docs/.npmrc ./
RUN pnpm install --frozen-lockfile --ignore-scripts
COPY docs/content ./content
COPY docs/scripts ./scripts
RUN pnpm run docs:render
COPY --from=provider-assets /assets/downloads ./_build/downloads
COPY --from=provider-assets /assets/version.json ./_build/version.json
RUN pnpm run docs:seal && pnpm run docs:check
FROM nginx:stable-alpine
COPY docs/scripts/docs-nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/docs/_build /usr/share/nginx/html/paygen
EXPOSE 80
