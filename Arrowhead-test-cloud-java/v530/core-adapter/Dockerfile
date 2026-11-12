# Test-cloud adapter for the core images built from Eclipse-Arrowhead-java/ah5-core-java-spring/<module>/docker.
# Same read-only adjustments as ../../java-patch (security finding J3), but on top of the primary build, so jar and
# default configuration are both the primary source: the default configuration is copied into /app/config at build
# time (the entrypoint then finds no config_temp), MySQL URLs use the bundled MariaDB driver, the key alias follows
# the cloud name, logs go to /app/logs (tmpfs) and only the keystores are mounted at /app/config/certificate.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
USER root
RUN set -e; \
    if [ -d /app/config_temp ]; then mkdir -p /app/config && cp -r /app/config_temp/. /app/config/ && rm -rf /app/config_temp; fi; \
    for f in /app/config/application.properties; do \
      sed -i -E 's#jdbc:mysql://([^?[:space:]]+)\?serverTimezone=UTC#jdbc:mariadb://\1?sslMode=trust#; s#jdbc:mysql://#jdbc:mariadb://#; s#com\.mysql\.cj\.jdbc\.Driver#org.mariadb.jdbc.Driver#; s#^(server\.ssl\.key-alias=[A-Za-z]+)\.TestCloud\.#\1.${arrowhead.cloud.name:TestCloud}.#' "$f"; \
    done; \
    rm -rf /app/config/certificte /app/config/certificate; mkdir -p /app/config/certificate /app/logs; \
    sed -i -E 's#(<Property name="LOG_DIR">)[^<]*#\1/app/logs#; s#size="100MB"#size="10MB"#; s#max="10"#max="2"#' /app/config/log4j2.xml; \
    chmod -R a+rX /app
