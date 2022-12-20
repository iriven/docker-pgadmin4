#syntax=docker/dockerfile:1.4
#########################################################################
# Create a Node container which will be used to build the JS components
# and clean up the web/ source code
#########################################################################
FROM	atchondjo/alpine AS app-builder
LABEL	maintainer="Alfred TCHONDJO <tchondjo.ext@gmail.com>"

ENV LANG=en_US.utf8 \
# make the "en_US.UTF-8" locale so postgres will be utf-8 enabled by default
# alpine doesn't require explicit locale-file generation
    PGADMIN4_VERSION=6.17 \
    PGADMIN4_BASE_URL=https://ftp.postgresql.org/pub/pgadmin/pgadmin4
ENV GPG_KEYS E8697E2EEF76C02D3A6332778881B2A8210976F2

RUN set -eux; \
    apk add --no-cache \
    autoconf \
    automake \
    gzip \
    curl \
    bash \
    g++ \
    git \
    libc6-compat \
    libjpeg-turbo-dev \
    libpng-dev \
    libtool \
    make \
    tar \
    nasm \
    nodejs \
    xz \
    yarn \
    zlib-dev

COPY docker/bin/docker-* /usr/local/bin/
#--------------------------------------------------------------------------------------------------
#   PHP PACKAGE DOWNLOADS
#--------------------------------------------------------------------------------------------------
RUN set -eux; \
    \
    # chmod +x /usr/local/bin/docker-pgadmin4-source; \
    apk add --no-cache --virtual .fetch-deps gnupg; \
    \
    mkdir -p /usr/src /pgadmin4; \
    cd /usr/src; \
    \
    PKG_URL="${PGADMIN4_BASE_URL}/v${PGADMIN4_VERSION}/source/pgadmin4-${PGADMIN4_VERSION}.tar.gz"; \
    PKG_ASC_URL="${PKG_URL}.asc"; \
    curl -fsSL -o pgadmin4.tar.gz "$PKG_URL"; \
    if [ -n "$PKG_ASC_URL" ]; then \
        curl -fsSL -o pgadmin4.tar.gz.asc "$PKG_ASC_URL"; \
        export GNUPGHOME="$(mktemp -d)"; \
        for key in $GPG_KEYS; do \
        gpg --batch --keyserver keyserver.ubuntu.com --recv-keys "$key"; \
        done; \
        gpg --batch --verify pgadmin4.tar.gz.asc pgadmin4.tar.gz; \
        gpgconf --kill all; \
        rm -rf "$GNUPGHOME"; \
    fi; \
    \
    apk del --no-network .fetch-deps \
    && docker-pgadmin4-source extract; \
    mv /usr/src/pgadmin4/web /pgadmin4/web; \
    mv /usr/src/pgadmin4/docs /pgadmin4/docs; \
    mv /usr/src/pgadmin4/pkg /pgadmin4/pkg; \
    rm -rf /pgadmin4/web/*.log \
    /pgadmin4/web/config_*.py \
    /pgadmin4/web/node_modules \
    /pgadmin4/web/regression \
    `find /pgadmin4/web -type d -name tests` \
    `find /pgadmin4/web -type f -name .DS_Store` ; \
    mv /usr/src/pgadmin4/LICENSE /pgadmin4/LICENSE; \
    mv /usr/src/pgadmin4/DEPENDENCIES /pgadmin4/DEPENDENCIES; \
    mv /usr/src/pgadmin4/requirements.txt /pgadmin4/requirements.txt; \
    cd /; \
    docker-pgadmin4-source delete;

WORKDIR /pgadmin4/web

# Build the JS vendor code in the app-builder, and then remove the vendor source.
RUN set -eux; \
    export CPPFLAGS="-DPNG_ARM_NEON_OPT=0" && \
    yarn install && \
    yarn run bundle && \
    rm -rf node_modules \
        yarn.lock \
        package.json \
        .[^.]* \
        babel.cfg \
        webpack.* \
        karma.conf.js \
        ./pgadmin/static/js/generated/.cache

#########################################################################
# Next, create the base environment for Python
#########################################################################

FROM atchondjo/alpine as env-builder

# Install dependencies
COPY --from=app-builder /pgadmin4/requirements.txt /
# COPY requirements.txt /
RUN  set -eux; \
    apk add --no-cache \
        make \
        python3 \
        py3-pip && \
    apk add --no-cache --virtual build-deps \
        build-base \
        openssl-dev \
        libffi-dev \
        postgresql-dev \
        krb5-dev \
        rust \
        cargo \
        zlib-dev \
        libjpeg-turbo-dev \
        libpng-dev \
        python3-dev && \
    python3 -m venv --system-site-packages --without-pip /venv && \
    /venv/bin/python3 -m pip install --no-cache-dir -r requirements.txt && \
    apk del --no-cache build-deps

#########################################################################
# Now, create a documentation build container for the Sphinx docs
#########################################################################

FROM env-builder as docs-builder

# Install Sphinx
RUN set -eux; \
    /venv/bin/python3 -m pip install --no-cache-dir sphinx

# Copy the docs from the local tree. Explicitly remove any existing builds that
# may be present
COPY --from=app-builder /pgadmin4/docs /pgadmin4/docs
COPY --from=app-builder /pgadmin4/web /pgadmin4/web

RUN set -eux; \
    rm -rf /pgadmin4/docs/en_US/_build

# Build the docs
RUN set -eux; \
    LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 /venv/bin/sphinx-build /pgadmin4/docs/en_US /pgadmin4/docs/en_US/_build/html

# Cleanup unwanted files
RUN set -eux; \
    rm -rf /pgadmin4/docs/en_US/_build/html/.doctrees \
    rm -rf /pgadmin4/docs/en_US/_build/html/_sources \
    rm -rf /pgadmin4/docs/en_US/_build/html/_static/*.png

#########################################################################
# Create additional builders to get all of the PostgreSQL utilities
#########################################################################

FROM postgres:10-alpine as pg10-builder
FROM postgres:11-alpine as pg11-builder
FROM postgres:12-alpine as pg12-builder
FROM postgres:13-alpine as pg13-builder
FROM postgres:14-alpine as pg14-builder
FROM postgres:15-alpine as pg15-builder

FROM atchondjo/alpine as tool-builder

# Copy the PG binaries
COPY --from=pg10-builder /usr/local/bin/pg_dump /usr/local/pgsql/pgsql-10/
COPY --from=pg10-builder /usr/local/bin/pg_dumpall /usr/local/pgsql/pgsql-10/
COPY --from=pg10-builder /usr/local/bin/pg_restore /usr/local/pgsql/pgsql-10/
COPY --from=pg10-builder /usr/local/bin/psql /usr/local/pgsql/pgsql-10/

COPY --from=pg11-builder /usr/local/bin/pg_dump /usr/local/pgsql/pgsql-11/
COPY --from=pg11-builder /usr/local/bin/pg_dumpall /usr/local/pgsql/pgsql-11/
COPY --from=pg11-builder /usr/local/bin/pg_restore /usr/local/pgsql/pgsql-11/
COPY --from=pg11-builder /usr/local/bin/psql /usr/local/pgsql/pgsql-11/

COPY --from=pg12-builder /usr/local/bin/pg_dump /usr/local/pgsql/pgsql-12/
COPY --from=pg12-builder /usr/local/bin/pg_dumpall /usr/local/pgsql/pgsql-12/
COPY --from=pg12-builder /usr/local/bin/pg_restore /usr/local/pgsql/pgsql-12/
COPY --from=pg12-builder /usr/local/bin/psql /usr/local/pgsql/pgsql-12/

COPY --from=pg13-builder /usr/local/bin/pg_dump /usr/local/pgsql/pgsql-13/
COPY --from=pg13-builder /usr/local/bin/pg_dumpall /usr/local/pgsql/pgsql-13/
COPY --from=pg13-builder /usr/local/bin/pg_restore /usr/local/pgsql/pgsql-13/
COPY --from=pg13-builder /usr/local/bin/psql /usr/local/pgsql/pgsql-13/

COPY --from=pg14-builder /usr/local/bin/pg_dump /usr/local/pgsql/pgsql-14/
COPY --from=pg14-builder /usr/local/bin/pg_dumpall /usr/local/pgsql/pgsql-14/
COPY --from=pg14-builder /usr/local/bin/pg_restore /usr/local/pgsql/pgsql-14/
COPY --from=pg14-builder /usr/local/bin/psql /usr/local/pgsql/pgsql-14/

COPY --from=pg15-builder /usr/local/bin/pg_dump /usr/local/pgsql/pgsql-15/
COPY --from=pg15-builder /usr/local/bin/pg_dumpall /usr/local/pgsql/pgsql-15/
COPY --from=pg15-builder /usr/local/bin/pg_restore /usr/local/pgsql/pgsql-15/
COPY --from=pg15-builder /usr/local/bin/psql /usr/local/pgsql/pgsql-15/

#########################################################################
# Assemble everything into the final container.
#########################################################################

FROM atchondjo/alpine:latest

ENV  GUNICORN_ACCESS_LOGFILE=/var/log/pgadmin/pgadmin-access.log
# Copy in the Python packages
COPY --from=env-builder /venv /venv

# Copy in the tools
COPY --from=tool-builder /usr/local/pgsql /usr/local/
COPY --from=pg15-builder /usr/local/lib/libpq.so.5.15 /usr/lib/
RUN set -eux; \
    ln -s libpq.so.5.15 /usr/lib/libpq.so.5 && \
    ln -s libpq.so.5.15 /usr/lib/libpq.so

WORKDIR /pgadmin4
ENV PYTHONPATH=/pgadmin4

# Copy in the code and docs
COPY --from=app-builder /pgadmin4/web /pgadmin4
COPY --from=docs-builder /pgadmin4/docs/en_US/_build/html/ /pgadmin4/docs

COPY --from=app-builder /pgadmin4/pkg/docker/run_pgadmin.py /pgadmin4
COPY --from=app-builder /pgadmin4/pkg/docker/gunicorn_config.py /pgadmin4
COPY --from=app-builder /pgadmin4/pkg/docker/entrypoint.sh /usr/local/bin/docker-pgadmin4-entrypoint


# License files
COPY --from=app-builder /pgadmin4/DEPENDENCIES /pgadmin4/DEPENDENCIES
COPY --from=app-builder /pgadmin4/LICENSE /pgadmin4/LICENSE

# Install runtime dependencies and configure everything in one RUN step
RUN set -eux; \
    apk add \
        python3 \
        py3-pip \
        postfix \
        krb5-libs \
        libjpeg-turbo \
        shadow \
        sudo \
        libedit \
        libldap \
        libcap && \
    /venv/bin/python3 -m pip install --no-cache-dir gunicorn && \
    find / -type d -name '__pycache__' -exec rm -rf {} + && \
    useradd -r -u 5050 -g root -s /sbin/nologin pgadmin && \
    GUNICORN_ACCESS_LOGDIR=$(dirname ${GUNICORN_ACCESS_LOGFILE}) &&\
    mkdir -p ${GUNICORN_ACCESS_LOGDIR} && \
    touch ${GUNICORN_ACCESS_LOGFILE} && \
    chown --recursive pgadmin:root ${GUNICORN_ACCESS_LOGDIR} && \
    chmod g=u ${GUNICORN_ACCESS_LOGDIR} && \
    mkdir -p /var/lib/pgadmin && \
    chown pgadmin:root /var/lib/pgadmin && \
    chmod g=u /var/lib/pgadmin && \
    touch /pgadmin4/config_distro.py && \
    chown pgadmin:root /pgadmin4/config_distro.py && \
    chmod g=u /pgadmin4/config_distro.py && \
    chmod g=u /etc/passwd && \
    setcap CAP_NET_BIND_SERVICE=+eip /usr/bin/python3.10 && \
    echo "pgadmin ALL = NOPASSWD: /usr/sbin/postfix start" > /etc/sudoers.d/postfix && \
    echo "pgadminr ALL = NOPASSWD: /usr/sbin/postfix start" >> /etc/sudoers.d/postfix

USER pgadmin

# Finish up
VOLUME /var/lib/pgadmin

EXPOSE 80 443

ENTRYPOINT ["docker-pgadmin4-entrypoint"]
