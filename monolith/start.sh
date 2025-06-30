#!/bin/bash
set -e

service postgresql start
service rabbitmq-server start
service redis-server start
# start solr if installed
if command -v solr >/dev/null; then
    service solr start
fi

# run musicbrainz entrypoint
exec /usr/local/bin/docker-entrypoint.sh start.sh
