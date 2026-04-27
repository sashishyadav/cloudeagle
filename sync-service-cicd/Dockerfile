# =========================================================
# sync-service Dockerfile — multi-stage build
# =========================================================

# ── Build stage ──────────────────────────────────────────
FROM eclipse-temurin:17-jdk-alpine AS build

WORKDIR /app

# Cache dependencies first
COPY .mvn/ .mvn/
COPY mvnw pom.xml ./
RUN ./mvnw dependency:go-offline -q

# Build the app
COPY src ./src
RUN ./mvnw package -DskipTests -q

# ── Runtime stage ────────────────────────────────────────
FROM eclipse-temurin:17-jre-alpine

WORKDIR /app

# Non-root user
RUN addgroup -S syncapp && adduser -S syncapp -G syncapp

ARG JAR_FILE=target/sync-service-*.jar
ARG PROFILE=qa

ENV SPRING_PROFILES_ACTIVE=${PROFILE}
ENV JAVA_TOOL_OPTIONS="-XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0"

COPY --from=build --chown=syncapp:syncapp /app/${JAR_FILE} sync-service.jar

USER syncapp
EXPOSE 8080

# Graceful shutdown support: SIGTERM → Spring handles it
STOPSIGNAL SIGTERM

HEALTHCHECK --interval=15s --timeout=5s --start-period=60s --retries=3 \
  CMD wget -qO- http://localhost:8080/actuator/health | grep -q '"status":"UP"' || exit 1

ENTRYPOINT ["java", \
  "-Djava.security.egd=file:/dev/./urandom", \
  "-jar", "sync-service.jar"]
