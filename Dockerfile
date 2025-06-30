# Simple monolithic MusicBrainz container built from prebuilt server image
ARG MUSICBRAINZ_SERVER_VERSION=v-2025-06-23.0
ARG MUSICBRAINZ_BUILD_SEQUENCE=1
FROM metabrainz/musicbrainz-docker-musicbrainz:${MUSICBRAINZ_SERVER_VERSION}-build${MUSICBRAINZ_BUILD_SEQUENCE}

# Set local service hosts
ENV MUSICBRAINZ_POSTGRES_SERVER=localhost \
    MUSICBRAINZ_RABBITMQ_SERVER=localhost \
    MUSICBRAINZ_REDIS_SERVER=localhost \
    MUSICBRAINZ_SEARCH_SERVER=localhost:8983/solr

# Install additional services
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        postgresql-16 \
        rabbitmq-server \
        redis-server \
        openjdk-17-jre-headless \
        supervisor && \
    rm -rf /var/lib/apt/lists/*

# Copy start script to launch all services
COPY monolith/start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh

ENTRYPOINT ["/usr/local/bin/start.sh"]
