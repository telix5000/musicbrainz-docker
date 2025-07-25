# MusicBrainz mirror server with search and replication

This repo contains everything needed to run a musicbrainz mirror server with
search and replication in docker.

## Table of contents

<!-- toc -->

* [Prerequisites](#prerequisites)
  - [Recommended hardware/VM](#recommended-hardwarevm)
  - [Required software](#required-software)
  - [External documentation](#external-documentation)
* [Components version](#components-version)
* [Installation](#installation)
  - [Build Docker images](#build-docker-images)
  - [Create database](#create-database)
  - [Build materialized tables](#build-materialized-tables)
  - [Start website](#start-website)
  - [Set up search indexes](#set-up-search-indexes)
  - [Enable replication](#enable-replication)
  - [Enable live indexing](#enable-live-indexing)
* [Advanced configuration](#advanced-configuration)
  - [Local changes](#local-changes)
  - [Docker environment variables](#docker-environment-variables)
  - [Docker Compose overrides](#docker-compose-overrides)
* [Test setup](#test-setup)
* [Development setup](#development-setup)
  - [Local development of MusicBrainz Server](#local-development-of-musicbrainz-server)
  - [Local development of Search Index Rebuilder](#local-development-of-search-index-rebuilder)
  - [Local development of MusicBrainz Solr](#local-development-of-musicbrainz-solr)
* [Helper scripts](#helper-scripts)
  - [Recreate database](#recreate-database)
  - [Recreate database with indexed search](#recreate-database-with-indexed-search)
* [Update](#update)
* [Cleanup](#cleanup)
* [Removal](#removal)
* [Issues](#issues)

<!-- tocstop -->

## Prerequisites

### Recommended hardware/VM

* CPU: 16 threads (or 2 without indexed search), x86-64 architecture
* RAM: 16 GB (or 4 without indexed search)
* Disk Space: 350 GB (or 100 without indexed search)

### Required software

* Docker Compose 2 (or higher), see [how to install Docker Compose](https://docs.docker.com/compose/install/)
* Git
* GNU Bash 4 (or higher) utilities, for [admin helper scripts](admin/) only
  (On macOS, use [Homebrew](https://brew.sh/).)
* Linux or macOS
  (Windows is not documented yet, it is recommended to use Ubuntu via VirtualBox
  instead.)

If you use Docker Desktop on macOS you may need to increase the amount of memory
available to containers from the default of 2GB:

* Preferences > Resources > Memory

If you use Ubuntu 24.04 or later, the above requirements can be set up by running:

```bash
sudo apt-get update && \
sudo apt-get install docker.io docker-compose-v2 git && \
sudo systemctl enable --now docker.service
```

If you use [UFW](https://help.ubuntu.com/community/UFW) to manage your firewall:

* [ufw-docker](https://github.com/chaifeng/ufw-docker) or any other way to fix
  the Docker and UFW security flaw.

### External documentation

* Introduction: [Getting started with Docker](https://docs.docker.com/get-started/)
  and [Overview of Docker Compose](https://docs.docker.com/compose/)
* Command-line: [`docker` CLI reference](https://docs.docker.com/engine/reference/commandline/docker/)
  and [`docker compose` CLI reference](https://docs.docker.com/compose/reference/overview/)
* Configuration: [Compose file version 3 reference](https://docs.docker.com/compose/compose-file/)

## Components version

* Current MB Branch: [v-2025-06-23.0](build/musicbrainz/Dockerfile#L98)
* Current DB_SCHEMA_SEQUENCE: [30](build/musicbrainz/Dockerfile#L134)
* Postgres Version: [16](docker-compose.yml)
  (can be changed by setting the environment variable `POSTGRES_VERSION`)
* MB Solr search server: [4.1.0](docker-compose.yml#L84)
  (can be changed by setting the environment variable `MB_SOLR_VERSION`)
* Search Index Rebuilder: [4.0.1](build/sir/Dockerfile#L38)

## Installation

This section is about installing MusicBrainz mirror server
with locally indexed search and automatically replicated data.

Download this repository and change current working directory with:

```bash
git clone https://github.com/metabrainz/musicbrainz-docker.git
cd musicbrainz-docker
```

If you want to mirror the Postgres database only (neither the website
nor the web API), change the base configuration with the following
command (as a first step, otherwise it will blank it out):

```bash
admin/configure with alt-db-only-mirror
```

### Build Docker images

Docker images for composed services should be built once using:

```bash
docker compose build
```

### Build monolithic image

A simplified Dockerfile is provided at the repository root to build a single
container bundling all services (database, message queue, search, cache and
web server). Build it with:

```bash
docker build -t musicbrainz-all-in-one .
```

### Create database

:gear: Postgres shared buffers are set to 2GB by default.
Before running this step, you should consider [modifying your memory
settings](#modify-memory-settings) in order to give your database a
sufficient amount of ram, otherwise your database could run very slowly.

Download latest full data dumps and create the database with:

```bash
docker compose run --rm musicbrainz createdb.sh -fetch
```

<!-- TODO: document available FTP servers -->
<!-- TODO: document how to load local dumps -->

### Build materialized tables

This is an optional step.

MusicBrainz Server makes use of materialized (or denormalized) tables in
production to improve the performance of certain pages and features. These
tables duplicate primary table data and can take up several additional gigabytes
of space, so they're optional but recommended. If you don't populate these
tables, the server will generally fall back to slower queries in their place.

If you wish to configure the materialized tables, you can run:

```bash
docker compose run --rm musicbrainz bash -c 'carton exec -- ./admin/BuildMaterializedTables --database=MAINTENANCE all'
```

### Start website

Make the local website available at <http://localhost:5000> with:

```bash
docker compose up -d
```

At this point the local website will show data loaded from the dumps
only. For indexed search and replication, keep going!

### Set up search indexes

:information_source: Search indexes are updated asynchronously,
some delay can be experienced before getting updated results.

Depending on your available ressources in CPU/RAM vs. bandwidth:

* Either build search indexes manually from the installed database:

  ```bash
  docker compose exec indexer python -m sir reindex
  ```

  :gear: Java heap for Solr is set to 2GB by default.
  Before running this step, you should consider [modifying your memory
  settings](#modify-memory-settings) in order to give your search server a
  sufficient amount of ram, otherwise your search server could run very slowly.

  (This option is known to take 4½ hours with 16 CPU threads and 16 GB RAM.)

  To index cores individually, rather than all at once, add `--entity-type CORE`
  (any number of times) to the command above. For example `docker compose
  exec indexer python -m sir reindex --entity-type artist --entity-type release`

* Or download pre-built search indexes based on the latest data dump:

  ```bash
  docker compose up -d musicbrainz search
  docker compose exec search fetch-backup-archives
  docker compose exec search load-backup-archives
  ```

  (This option downloads 60 GB of Zstandard-compressed MB Solr backup archives.)

  Once you are satisfied with the search results, you can drop the fetched archive files:

  ```bash
  sudo docker-compose exec search remove-backup-archives
  ```

:warning: Search indexes are not included in replication. You will have to
rebuild search indexes regularly to keep it up-to-date. This can be done
manually with the commands above, with Live Indexing (see below), or with a
scheduled cron job. Here's an example cron job that can be added to your
`etc/crontab` file from your server's root:

```crontab
0 1 * * 7 YOUR_USER_NAME cd ~/musicbrainz-docker && /usr/bin/docker compose exec -T indexer python -m sir reindex
```

At this point indexed search works on the local website/webservice.
For replication, keep going!

### Enable replication

#### Set replication token

First, copy your MetaBrainz access token
(see [instructions for generating a token](http://blog.metabrainz.org/2015/05/19/schema-change-release-2015-05-18-including-upgrade-instructions/))
and paste when prompted to by the following command:

```bash
admin/set-replication-token
```

The token will be written to the file
[`local`](local/)`/secrets/metabrainz_access_token`.

Then, grant access to the token for replication with:

```bash
admin/configure add replication-token
docker compose up -d
```

#### Run replication once

Run replication script once to catch up with latest database updates:

```bash
bash -c 'docker compose exec musicbrainz replication.sh &' && \
docker compose exec musicbrainz /usr/bin/tail -f mirror.log
```

<!-- TODO: estimate replication time per missing day -->

#### Schedule replication

Enable replication as a cron job of `root` user in `musicbrainz`
service container with:

```bash
admin/configure add replication-cron
docker compose up -d
```

By default, it replicates data every day at 3 am UTC.
To change that, see [advanced configuration](#advanced-configuration).

You can view the replication log file while it is running with:

```bash
docker compose exec musicbrainz tail --follow mirror.log
```

The replication log file is sometimes renamed `mirror.log.1` after it is done.

### Enable live indexing

:warning: Search indexes’ live update for mirror server is **not stable** yet.
Until then, it should be considered as an experimental feature.
Do not use it if you don't want to get your hands dirty.

1. Disable [replication cron job](#schedule-replication) if you enabled it:

   ```bash
   admin/configure rm replication-cron
   docker compose up -d
   ```

2. Make indexer goes through [AMQP
   Setup](https://sir.readthedocs.io/en/latest/setup/index.html#amqp-setup)
   with:

   ```bash
   docker compose exec indexer python -m sir amqp_setup
   admin/create-amqp-extension
   admin/setup-amqp-triggers install
   ```

3. [Build search indexes](#set-up-search-indexes) if they either have not been
   built or are outdated.

4. Make indexer watch reindex messages with:

   ```bash
   admin/configure add live-indexing-search
   docker compose up -d
   ```

5. Reenable [replication cron job](#schedule-replication) if you disabled it at 1.

   ```bash
   admin/configure add replication-cron
   docker compose up -d
   ```

## Advanced configuration

### Local changes

You should **preferably not** locally change any file being tracked by git.
Check your working tree is clean with:

```bash
git status
```

Git is set to ignore the followings you are encouraged to write to:

* `.env` file,
* any new file under [`local`](local/) directory.

### Docker environment variables

There are many ways to set [environment variables in Docker
Compose](https://docs.docker.com/compose/environment-variables/), the most
convenient here is probably to edit the hidden file `.env`.

You can then check values to be passed to containers using:

```bash
docker compose config
```

Finally, make Compose picks up configuration changes with:

```bash
docker compose up -d
```

#### Customize web server host:port

By default, the web server listens at <http://localhost:5000>

This can be changed using the two Docker environment variables
`MUSICBRAINZ_WEB_SERVER_HOST` and `MUSICBRAINZ_WEB_SERVER_PORT`.

If `MUSICBRAINZ_WEB_SERVER_PORT` set to `80` (http), then the
port number will not appear in the base URL of the web server.

If set to `443` (https), then the port number will not appear either,
but the a separate reverse proxy is required to handle https correctly.

#### Customize the number of processes for MusicBrainz Server

By default, MusicBrainz Server uses 10 `plackup` processes at once.

This number can be changed using the Docker environment variable
`MUSICBRAINZ_SERVER_PROCESSES`.

#### Customize download server

By default, data dumps and pre-built search indexes are downloaded from
the main download server. There is only one server currently available.

For development purposes, the download server can be changed using the
Docker environment variable `MUSICBRAINZ_BASE_DOWNLOAD_URL`.

For backwards compatibility reasons an FTP server can be specified using the
`MUSICBRAINZ_BASE_FTP_URL` Docker environment variable. Note that support for
this variable is deprecated and will be removed in a future release.

#### Customize replication schedule

By default, there is no crontab file in `musicbrainz` service container.

If you followed the steps to [schedule replication](#schedule-replication),
then the crontab file used by `musicbrainz` service is bound to
[`default/replication.cron`](default/replication.cron).

This can be changed by creating a custom crontab file under
[`local/`](local/) directory,
[and finally](https://docs.docker.com/storage/bind-mounts/#choose-the--v-or---mount-flag)
setting the Docker environment variable `MUSICBRAINZ_CRONTAB_PATH` to
its path.

#### Customize search indexer configuration

By default, the configuration file used by `indexer` service is bound
to [`default/indexer.ini`](default/indexer.ini).

This can be changed by creating a custom configuration file under
[`local/`](local/) directory,
[and finally](https://docs.docker.com/storage/bind-mounts/#choose-the--v-or---mount-flag)
setting the Docker environment variable `SIR_CONFIG_PATH` to its path.

#### Customize backend Postgres server

By default, the services `indexer` and `musicbrainz` are trying to connect to the host `db` (for both read-only and write host) but the hosts can
be customized using the `MUSICBRAINZ_POSTGRES_SERVER` and `MUSICBRAINZ_POSTGRES_READONLY_SERVER` environment variables.

Notes:
* After switching to another Postgres server:
  * If not transferring data, it is needed to create the database again.
  * For live indexing, the RabbitMQ server has to still be reachable from the Postgres server.
* The helper script `create-amqp-extension` won’t work anymore.
* The service `db` will still be up even if unused.

#### Customize backend RabbitMQ server

By default, the services `db`, `indexer` and `musicbrainz` are trying to connect to the host `mq`
but the host can be customized using the `MUSICBRAINZ_RABBITMQ_SERVER` environment variable.

Notes:
* After switching to another RabbitMQ server:
  - Live indexing requires to go through AMQP Setup again.
  - If not transferring data, it might be needed to build search indexes again.
* The helper script `purge-message-queues` won’t work anymore.
* The service `mq` will still be up even if unused.

#### Customize backend Redis server

By default, the service `musicbrainz` is trying to connect to the host `redis`
but the host can be customized using the `MUSICBRAINZ_REDIS_SERVER` environment variable.

Notes:
* After switching to another Redis server:
  - If not transferring data, MusicBrainz user sessions will be reset.
* The service `redis` will still be running even if unused.

### Docker Compose overrides

In Docker Compose, it is possible to override the base configuration using
[multiple Compose files](https://docs.docker.com/compose/extends/#multiple-compose-files).

Some overrides are available under [`compose`](compose/) directory.
Feel free to write your own overrides under [`local`](local/) directory.

The helper script [`admin/configure`](admin/configure) is able to:

* **list** available compose files, with a descriptive summary
* **show** the value of `COMPOSE_FILE` variable in Docker environment
* set/update `COMPOSE_FILE` in `.env` file **with** a list of compose files
* set/update `COMPOSE_FILE` in `.env` file with **add**ed or
  **r**e**m**oved compose files

Try `admin/configure help` for more information.

#### Publish ports of all services

:warning: The service `search` is currently running Solr 7 in
standalone mode which is vulnerable to privilege escalation.
See [CVE-2025-24814](https://lists.apache.org/thread/gl291pn8x9f9n52ys5l0pc0b6qtf0qw1) for details.
We are working on upgrading to Solr 9 in SolrCloud mode.
See [SEARCH-685](https://tickets.metabrainz.org/browse/SEARCH-685) for follow-up.
In general, Solr is strongly recommended to be accessible to your own clients only.
See [Solr Security](https://cwiki.apache.org/confluence/display/SOLR/SolrSecurity) for details.
Similarly, other services have not been configured to be safely publicly accessible either.
Take this warning in consideration when publishing their ports.

To publish ports of services `db`, `mq`, `redis` and `search`
(additionally to `musicbrainz`) on the host, simply run:

```bash
admin/configure add publishing-all-ports
docker compose up -d
```

If you are running a database only mirror, run this instead:

```bash
admin/configure add publishing-db-port
docker compose up -d
```

#### Modify memory settings

By default, each of `db` and `search` services have about 2GB of RAM.
You may want to set more or less memory for any of these services,
depending on your available resources or on your priorities.

For example, to set 4GB to each of `db` and `search` services,
create a file `local/compose/memory-settings.yml` as follows:

```yaml
# Description: Customize memory settings

services:
  db:
    command: postgres -c "shared_buffers=4GB" -c "shared_preload_libraries=pg_amqp.so"
  search:
    environment:
      - SOLR_HEAP=4g
```

See [`postgres`](https://www.postgresql.org/docs/current/app-postgres.html)
for more configuration parameters and options to pass to `db` service,
and [`solr.in.sh`](https://github.com/apache/lucene-solr/blob/releases/lucene-solr/7.7.2/solr/bin/solr.in.sh)
for more environment variables to pass to `search` service,

Then enable it by running:

```bash
admin/configure add local/compose/memory-settings.yml
docker compose up -d
```

## Test setup

If you just need a small server with sample data to test your own SQL
queries and/or MusicBrainz Web Service calls, you can run the below
commands instead of following the above [installation](#installation):

```bash
git clone https://github.com/metabrainz/musicbrainz-docker.git
cd musicbrainz-docker
admin/configure add musicbrainz-standalone
docker compose build
docker compose run --rm musicbrainz createdb.sh -sample -fetch
docker compose up -d
```

The two differences are:

1. Sample data dump is downloaded instead of full data dumps,
2. MusicBrainz Server runs in standalone mode instead of mirror mode.

[Build search indexes](#set-up-search-indexes) and
[Enable live indexing](#enable-live-indexing) are the same.

Replication is not applicable to test setup.

## Development setup

Required disk space is much lesser than normal setup: 15GB to be safe.

The below sections are optional depending on which service(s) you are coding.

### Local development of MusicBrainz Server

For local development of MusicBrainz Server, you can run the below
commands instead of following the above [installation](#installation):

```bash
git clone https://github.com/metabrainz/musicbrainz-server.git
MUSICBRAINZ_SERVER_LOCAL_ROOT=$PWD/musicbrainz-server
git clone https://github.com/metabrainz/musicbrainz-docker.git
cd musicbrainz-docker
echo MUSICBRAINZ_DOCKER_HOST_IPADDRCOL=127.0.0.1: >> .env
echo MUSICBRAINZ_SERVER_LOCAL_ROOT="$MUSICBRAINZ_SERVER_LOCAL_ROOT" >> .env
admin/configure add musicbrainz-dev
docker compose build
docker compose run --rm musicbrainz createdb.sh -sample -fetch
docker compose up -d
```

The main differences are:

1. Sample data dump is downloaded instead of full data dumps,
2. MusicBrainz Server runs in standalone mode instead of mirror mode,
3. Development mode is enabled (but Catalyst debug),
4. JavaScript and resources are automaticaly recompiled on file changes,
5. MusicBrainz Server is automatically restarted on Perl file changes,
6. MusicBrainz Server code is in `musicbrainz-server/` directory.
7. Ports are published to the host only (through `MUSICBRAINZ_DOCKER_HOST_IPADDRCOL`)

After changing code in `musicbrainz-server/`, it can be run as follows:

```bash
docker compose restart musicbrainz
```

[Build search indexes](#set-up-search-indexes) and
[Enable live indexing](#enable-live-indexing) are the same.

Replication is not applicable to development setup.

Simply restart the container when checking out a new branch.

### Local development of Search Index Rebuilder

This is very similar to the above but for Search Index Rebuilder (SIR):

1. Optionally set the following variables in the `.env` file:
   - `SIR_DEV_CONFIG_PATH`
     (Default: `./default/config.ini` replacing `SIR_CONFIG_PATH`)
   - `SIR_DEV_LOCAL_ROOT`
     (Default: `../sir` assuming that `musicbrainz-docker` and `sir`
     have been cloned under the same parent directory)
   - `SIR_DEV_PYTHON_VERSION`
     (Default: `3.13` matching `metabrainz/python` image tag)
   - `SIR_DEV_BASE_IMAGE_DATE`
     (Default: `20250313` matching `metabrainz/python` image tag)
   - `SIR_DEV_VERSION`
     (Default: `py313-stage1` which is informative only)
2. Run `admin/configure add sir-dev`
3. Run `docker compose build indexer`
4. Run `docker compose up -d`

Notes:

* It will override any `config.ini` file in your local working copy of SIR.
* Requirements are being cached and will be updated on container’s startup.
* See [how to configure SIR in `musicbrainz-docker`](#customize-search-indexer-configuration).

### Local development of MusicBrainz Solr

The situation is quite different for this service as it doesn’t
depends on any other. Its development rather rely on schema. See
[mb-solr](https://github.com/metabrainz/mb-solr) and
[mmd-schema](https://github.com/metabrainz/mmd-schema).

However, other services depend on it, so it is useful to run a local
version of `mb-solr` in `search` service for integration tests:

1. Run `build.sh` from your `mb-solr` local working copy, which will
   build an image of `metabrainz/mb-solr` with a local tag reflecting
   the working tree status of your local clone of `mb-solr`.
2. Set `MB_SOLR_VERSION` in `.env` to this local tag.
3. Run `docker compose up -d`

## Helper scripts

There are two directories with helper scripts:

* [`admin/`](admin/) contains helper scripts to be run from the host.
  For more information, use the `--help` option:

  ```bash
  admin/configure --help
  admin/create-amqp-extension --help
  admin/purge-message-queues --help
  admin/set-replication-token --help
  admin/setup-amqp-triggers --help
  ```

  See also:
  - [Docker Compose overrides](#docker-compose-overrides) for more
    information about `admin/configure`.
  - [Enable live indexing](#enable-live-indexing) for more information
    about `admin/create-amqp-extension`
    and `admin/setup-amqp-triggers`.
  - [Enable replication](#enable-replication) for more information
    about `admin/set-replication-token`.

* [`build/musicbrainz/scripts/`](build/musicbrainz/scripts/) contains
  helper scripts to be run from the container attached to the service
  `musicbrainz`. Most of these scripts are not for direct use, but
  [createdb.sh](#create-database) and below-documented
  [recreatedb.sh](#recreate-database).

<!-- TODO: add help option to build/*/scripts/* -->

### Recreate database

If you need to recreate the database, you will need to enter the
postgres password set in [postgres.env](default/postgres.env):

* `docker compose run --rm musicbrainz recreatedb.sh`

or to fetch new data dumps before recreating the database:

* `docker compose run --rm musicbrainz recreatedb.sh -fetch`

### Recreate database with indexed search

If you need to recreate the database with indexed search:

```bash
admin/configure rm replication-cron # if replication is enabled
docker compose stop
docker compose run --rm musicbrainz fetch-dump.sh indexed
admin/purge-message-queues
docker compose up -d search
docker compose exec search fetch-backup-archives
docker compose exec search load-backup-archives
# See the note no. 1 below
docker compose run --rm musicbrainz recreatedb.sh
docker compose up -d
admin/setup-amqp-triggers install
admin/configure add replication-cron
docker compose up -d
# See the note no. 2 below
```

Notes:
1. You will need to enter the postgres password set in
   [postgres.env](default/postgres.env) when running the command
   `recreatedb.sh`
2. Once you are satisfied with the search results, you can drop the fetched archive files:

   ```bash
   sudo docker-compose exec search remove-backup-archives
   ```

## Update

Check your working tree is clean with:

```bash
git status
```

Check your currently checked out version:

```bash
git describe --dirty
```

Check [releases](https://github.com/metabrainz/musicbrainz-docker/releases) for
update instructions.

## Cleanup

Each time you are rebuilding a new image, for either updating to a new
release or applying some changes in configuration, the previous image
is not removed.
On the one hand, it is convenient as it allows you to quickly restore
it in case the new image has critical issues.
On the other hand, it is filling your disk with some GBs over time.
Thus it is recommended to do a regular cleanup as follows.

:warning: If you are using Docker for anything else than this Compose project,
the below command will also remove all unused images.

```bash
docker system prune --all
```

## Removal

Removing the directory isn’t enough, the Docker objects (images,
containers, volumes) have to be removed too for a complete removal.

Before removing the directory where you cloned this repository,
run the following command **from that directory**.

```bash
docker compose down --remove-orphans --rmi all --volumes
```

It will output what has been removed so that you can check it.
Only after it is over, you can remove the directory.

## Issues

If anything doesn't work, check the [troubleshooting](TROUBLESHOOTING.md) page.

If you still don’t have a solution, please create an issue with versions info:

```bash
echo MusicBrainz Docker: `git describe --always --broken --dirty --tags` && \
echo Docker Compose: `docker compose version --short` && \
docker version -f 'Docker Client/Server: {{.Client.Version}}/{{.Server.Version}}'
```
