# Runtime image for the Arrowhead 5.2.2 EventHandler (ah5-support-java-spring/EventHandler).
# The jar is built beforehand by scripts/build-java-jars.sh; "ehsrc" is a Compose additional context.
FROM maven:3.9.9-eclipse-temurin-21@sha256:3a4ab3276a087bf276f79cae96b1af04f53731bec53fb2e651aca79e4b10211e

WORKDIR /app
COPY --from=ehsrc target/arrowhead-eventhandler-5.2.2.jar arrowhead-eventhandler.jar
COPY --from=ehsrc src/main/resources/log4j2.xml log4j2.xml
# Read-only container (J3): log files go to /app/logs (a tmpfs), in smaller files; the full log stream is on stdout.
RUN mkdir -p /app/logs && sed -i -E 's#(<Property name="LOG_DIR">)[^<]*#\1/app/logs#; s#size="100MB"#size="10MB"#; s#max="10"#max="2"#' /app/log4j2.xml

EXPOSE 8455
ENTRYPOINT ["java", "-Xms64m", "-Xmx256m", "-Dlog4j.configurationFile=/app/log4j2.xml", "-jar", "/app/arrowhead-eventhandler.jar"]
