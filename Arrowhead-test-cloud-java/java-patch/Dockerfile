# Released Arrowhead 5.2.2 image with its jar replaced by the local build, which is linked against the
# local ah5-common-java-spring (native sysMonitor publisher). The jar bundles MariaDB Connector/J instead
# of MySQL Connector/J, so the default configuration copied to /app/config at start-up is switched to it.
# The key alias follows the local cloud name (ARROWHEAD_CLOUD_NAME, default TestCloud).
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
ARG JAR_NAME
COPY --from=jarsrc ${JAR_NAME} /app/${JAR_NAME}
RUN for f in /app/config_temp/application.properties /app/config/application.properties; do \
      [ -f "$f" ] || continue; \
      sed -i -E 's#jdbc:mysql://([^?[:space:]]+)\?serverTimezone=UTC#jdbc:mariadb://\1?sslMode=trust#; s#jdbc:mysql://#jdbc:mariadb://#; s#com\.mysql\.cj\.jdbc\.Driver#org.mariadb.jdbc.Driver#; s#^(server\.ssl\.key-alias=[A-Za-z]+)\.TestCloud\.#\1.${arrowhead.cloud.name:TestCloud}.#' "$f"; \
    done
# Read-only container (security finding J3): the default configuration is baked into /app/config at build time instead
# of being copied there by the upstream entrypoint at every start, so only the system's keystores are mounted (read-only,
# at /app/config/certificate). The upstream sample keystores (config_temp/certificte) are dropped. Log files go to
# /app/logs (a tmpfs), in smaller files; the full log stream is on stdout.
RUN set -e; \
    if [ -d /app/config_temp ]; then mkdir -p /app/config && cp -r /app/config_temp/. /app/config/ && rm -rf /app/config_temp; fi; \
    rm -rf /app/config/certificte /app/config/certificate; mkdir -p /app/config/certificate /app/logs; \
    sed -i -E 's#(<Property name="LOG_DIR">)[^<]*#\1/app/logs#; s#size="100MB"#size="10MB"#; s#max="10"#max="2"#' /app/config/log4j2.xml; \
    chmod -R a+rX /app
