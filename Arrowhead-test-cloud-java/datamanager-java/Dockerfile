# Runtime image for the Arrowhead 5.2.2 Java DataManager (ah5-support-java-spring/DataManager).
# The jar is built beforehand by scripts/build-datamanager-jar.sh; "dmsrc" is a Compose additional context.
FROM maven:3.9.9-eclipse-temurin-21@sha256:3a4ab3276a087bf276f79cae96b1af04f53731bec53fb2e651aca79e4b10211e

WORKDIR /app
COPY --from=dmsrc target/arrowhead-datamanager-5.2.2.jar arrowhead-datamanager.jar
COPY --from=dmsrc src/main/resources/log4j2.xml log4j2.xml
# Read-only container (J3): log files go to /app/logs (a tmpfs), in smaller files; the full log stream is on stdout.
RUN mkdir -p /app/logs && sed -i -E 's#(<Property name="LOG_DIR">)[^<]*#\1/app/logs#; s#size="100MB"#size="10MB"#; s#max="10"#max="2"#' /app/log4j2.xml

EXPOSE 8461
ENTRYPOINT ["java", "-Xms64m", "-Xmx384m", "-Dlog4j.configurationFile=/app/log4j2.xml", "-jar", "/app/arrowhead-datamanager.jar"]
