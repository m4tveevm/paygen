FROM ruby:4.0.6-slim
ARG PAYGEN_SOURCE_SHA=unknown
ARG PAYGEN_SOURCE_DIRTY=unknown
ENV PAYGEN_SOURCE_SHA=${PAYGEN_SOURCE_SHA} PAYGEN_SOURCE_DIRTY=${PAYGEN_SOURCE_DIRTY}
LABEL org.opencontainers.image.revision=${PAYGEN_SOURCE_SHA}
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends build-essential ca-certificates && rm -rf /var/lib/apt/lists/*
COPY . .
RUN gem install bundler -v 4.0.20 --no-document && bundle install && gem build paygen.gemspec
ENTRYPOINT ["bundle", "exec", "bin/paygen"]
CMD ["doctor"]
