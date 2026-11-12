SHELL := /bin/sh
COMPOSE := docker compose
DATAMANAGER_SRC := ../ah5-support-java-spring/DataManager
DATAMANAGER_JAR := $(DATAMANAGER_SRC)/target/arrowhead-datamanager-5.2.2.jar

.PHONY: swap-java-blacklist restore-go-blacklist swap-rust-timemanager restore-go-timemanager swap-rust-sysmonitor restore-go-sysmonitor swap-rust-datamanager restore-go-datamanager smoke-mqtt smoke-translation-mqtt smoke-translation configure-translation-policy jars init validate pull up up-go up-java-legacy up-simple up-auth up-monitor up-orchestration-manager up-onboarding up-datamanager up-random-producer up-sysmonitor up-timemanager up-eventhandler up-plantdescriptionengine up-configuration up-choreographer up-aigym up-all status smoke smoke-aigym smoke-onboarding smoke-all configure-orchestration-security-policies configure-blacklist-policy configure-gatekeeper-policy configure-gatetunnel-policy configure-sysmonitor-policy configure-all-sysmonitor-policies configure-aigym-policy configure-timemanager-policy configure-eventhandler-policy configure-plantdescriptionengine-policy configure-configuration-policy configure-choreographer-policy configure-datamanager-monitoring-policy intercloud logs down clean amqp-acl smoke-onboarding-procedure secrets rotate-secrets console-password smoke-security

init:
	@./scripts/init.sh

validate:
	@./scripts/preflight.sh
	@$(COMPOSE) config --quiet

pull: validate
	@$(COMPOSE) --profile all pull

# The Java DataManager image packages a jar built from ah5-support-java-spring/DataManager; rebuild it when sources change.
$(DATAMANAGER_JAR): $(DATAMANAGER_SRC)/pom.xml $(shell find $(DATAMANAGER_SRC)/src/main -type f 2>/dev/null)
	@./scripts/build-datamanager-jar.sh

# Released Java images are patched with jars built against the local common library (native sysMonitor).
JAVA_JARS := ../ah5-core-java-spring/serviceregistry/target/arrowhead-serviceregistry-5.2.2.jar \
	../ah5-core-java-spring/authentication/target/arrowhead-authentication-5.2.2.jar \
	../ah5-core-java-spring/consumer-authorization/target/arrowhead-consumer-authorization-5.2.2.jar \
	../ah5-core-java-spring/serviceorchestration-dynamic/target/arrowhead-serviceorchestration-dynamic-5.2.2.jar \
	../ah5-core-java-spring/serviceorchestration-simple/target/arrowhead-serviceorchestration-simple-5.2.2.jar \
	../ah5-support-java-spring/Blacklist/target/arrowhead-blacklist-5.2.2.jar \
	../ah5-support-java-spring/TranslationManager/target/arrowhead-translation-manager-5.2.2.jar \
	../ah5-support-java-spring/DeviceQoSEvaluator/target/arrowhead-device-qos-evaluator-5.2.2.jar \
	../ah5-support-java-spring/TimeManager/target/arrowhead-timemanager-5.2.2.jar \
	../ah5-support-java-spring/EventHandler/target/arrowhead-eventhandler-5.2.2.jar \
	../ah5-support-java-spring/PlantDescriptionEngine/target/arrowhead-plantdescriptionengine-5.2.2.jar \
	../ah5-support-java-spring/Configuration/target/arrowhead-configuration-5.2.2.jar \
	../ah5-support-java-spring/Choreography/target/arrowhead-choreographer-5.2.2.jar \
	onboarding/app.jar

jars:
	@./scripts/build-java-jars.sh

$(JAVA_JARS):
	@./scripts/build-java-jars.sh

# Native Go core and support systems (../ah5-core-go, ../ah5-support-go), since 2026-10-17; see GO-NATIVE-FULL-2026-10-17.md
up: up-go

up-go:
	@./scripts/rotate-secrets.sh generate
	@./scripts/generate-x509.sh
	@./scripts/build-go-native.sh
	@./scripts/make-go-runtime.sh
	@$(MAKE) validate
	@$(COMPOSE) build serviceregistry authentication
	@$(COMPOSE) up -d --wait serviceregistry authentication
	@# Authentication creates Sysop (bootstrap password file) on an empty identity store; then the other identities.
	@./scripts/provision-authentication-identities.sh
	@./scripts/configure-authentication-mtls-registry.sh
	@./scripts/register-authentication-services.sh
	@./scripts/register-amqp-interface-templates.sh
	@./scripts/provision-gatekeeper-identity.sh
	@./scripts/provision-gatetunnel-identity.sh
	@./scripts/provision-sysmonitor-identity.sh
	@./scripts/provision-timemanager-identity.sh
	@./scripts/provision-plantdescriptionengine-identity.sh
	@./scripts/provision-configuration-identity.sh
	@./scripts/provision-choreographer-identity.sh
	@./scripts/provision-aigym-identity.sh
	@./scripts/provision-smoke-client-identity.sh
	@$(COMPOSE) up -d --wait consumerauthorization datamanager
	@./scripts/configure-orchestration-security-policies.sh
	@./scripts/configure-random-producer-policy.sh
	@# Blacklist check (J12) before the systems with a Blacklist filter serve other systems
	@./scripts/configure-blacklist-policy.sh
	@$(COMPOSE) up -d --wait
	@./scripts/configure-gatekeeper-policy.sh
	@./scripts/configure-gatetunnel-policy.sh
	@./scripts/configure-sysmonitor-policy.sh
	@./scripts/configure-all-sysmonitor-policies.sh
	@./scripts/configure-timemanager-policy.sh
	@./scripts/configure-eventhandler-policy.sh
	@./scripts/configure-plantdescriptionengine-policy.sh
	@./scripts/configure-pde-dso-policy.sh
	@./scripts/configure-configuration-policy.sh
	@./scripts/configure-choreographer-policy.sh
	@./scripts/configure-onboarding-policy.sh
	@./scripts/configure-aigym-policy.sh
	@./scripts/configure-translation-policy.sh
	@./scripts/configure-datamanager-monitoring-policy.sh
	@./scripts/configure-intercloud.sh

# Former Java core/support bootstrap (rollback only: restore upgrade-backups/go-full-20261017/compose.yaml first)
up-java-legacy: $(DATAMANAGER_JAR) | $(JAVA_JARS)
	@./scripts/rotate-secrets.sh generate
	@./scripts/generate-x509.sh
	@$(MAKE) validate
	@# Build here as well: a later rebuild would recreate ServiceRegistry and drop the interfaces added below.
	@$(COMPOSE) up -d --build --wait serviceregistry authentication-db authentication
	@# The outsourced ServiceRegistry can verify tokens only after its own identity exists: provision first.
	@./scripts/provision-authentication-identities.sh
	@./scripts/configure-authentication-mtls-registry.sh
	@$(COMPOSE) restart authentication
	@./scripts/register-authentication-services.sh
	@./scripts/register-amqp-interface-templates.sh
	@./scripts/provision-gatekeeper-identity.sh
	@./scripts/provision-gatetunnel-identity.sh
	@./scripts/provision-sysmonitor-identity.sh
	@./scripts/provision-timemanager-identity.sh
	@./scripts/provision-plantdescriptionengine-identity.sh
	@./scripts/provision-configuration-identity.sh
	@./scripts/provision-choreographer-identity.sh
	@./scripts/provision-aigym-identity.sh
	@./scripts/provision-smoke-client-identity.sh
	@# DSO aborts at startup without the generalManagement grant, and the producer
	@# health check needs DSO plus its historian grant, so grant both before --wait.
	@$(COMPOSE) up -d --build --wait consumerauthorization datamanager
	@./scripts/configure-orchestration-security-policies.sh
	@./scripts/configure-random-producer-policy.sh
	@$(COMPOSE) up -d --build --wait
	@./scripts/configure-gatekeeper-policy.sh
	@./scripts/configure-gatetunnel-policy.sh
	@./scripts/configure-sysmonitor-policy.sh
	@./scripts/configure-all-sysmonitor-policies.sh
	@./scripts/configure-timemanager-policy.sh
	@./scripts/configure-eventhandler-policy.sh
	@./scripts/configure-plantdescriptionengine-policy.sh
	@./scripts/configure-pde-dso-policy.sh
	@./scripts/configure-configuration-policy.sh
	@./scripts/configure-choreographer-policy.sh
	@./scripts/migrate-onboarding-db.sh
	@./scripts/configure-onboarding-policy.sh
	@./scripts/configure-aigym-policy.sh
	@./scripts/configure-datamanager-monitoring-policy.sh
	@# neighbour clouds and inter-cloud grants (exchanges need the relay: make -C ../Arrowhead-relay up)
	@./scripts/configure-intercloud.sh

up-simple:
	@./scripts/generate-x509.sh
	@$(MAKE) validate
	@$(COMPOSE) --profile simple up -d --wait

up-auth: up

up-monitor:
	@./scripts/generate-x509.sh
	@$(MAKE) validate
	@$(COMPOSE) up -d --build --wait cloud-monitor-api cloud-monitor-ui

up-orchestration-manager:
	@./scripts/generate-x509.sh
	@$(MAKE) validate
	@$(COMPOSE) --profile simple up -d --wait serviceorchestration-simple-db serviceorchestration-simple
	@$(COMPOSE) up -d --build --wait cloud-monitor-api cloud-monitor-ui

up-onboarding:
	@./scripts/generate-x509.sh
	@$(MAKE) validate
	@$(COMPOSE) up -d --wait serviceregistry authentication-db authentication consumerauthorization onboarding-db
	@./scripts/provision-authentication-identities.sh
	@./scripts/configure-authentication-mtls-registry.sh
	@./scripts/migrate-onboarding-db.sh
	@./scripts/configure-onboarding-policy.sh
	@$(COMPOSE) up -d --build --wait onboarding cloud-monitor-api cloud-monitor-ui

up-datamanager: $(DATAMANAGER_JAR) validate
	@./scripts/configure-datamanager-policies.sh
	@$(COMPOSE) up -d --build --wait datamanager cloud-monitor-api cloud-monitor-ui

up-random-producer:
	@./scripts/generate-x509.sh
	@$(MAKE) validate
	@$(COMPOSE) up -d --build --wait datamanager consumerauthorization serviceorchestration-dynamic
	@./scripts/configure-random-producer-policy.sh
	@$(COMPOSE) up -d --build --wait datamanager random-data-producer cloud-monitor-api cloud-monitor-ui

up-sysmonitor:
	@./scripts/generate-x509.sh
	@$(MAKE) validate
	@./scripts/provision-sysmonitor-identity.sh
	@$(COMPOSE) up -d --build --wait mqtt-broker amqp-broker sysmonitor
	@./scripts/configure-sysmonitor-policy.sh
	@./scripts/configure-datamanager-monitoring-policy.sh
	@$(COMPOSE) restart sysmonitor
	@$(COMPOSE) up -d --build --wait random-data-producer cloud-monitor-api cloud-monitor-ui

up-timemanager: | ../ah5-support-java-spring/TimeManager/target/arrowhead-timemanager-5.2.2.jar
	@./scripts/generate-x509.sh
	@$(MAKE) validate
	@./scripts/provision-timemanager-identity.sh
	@$(COMPOSE) up -d --build --wait timemanager
	@./scripts/configure-timemanager-policy.sh

up-eventhandler: | ../ah5-support-java-spring/EventHandler/target/arrowhead-eventhandler-5.2.2.jar
	@./scripts/generate-x509.sh
	@$(MAKE) validate
	@./scripts/provision-authentication-identities.sh
	@$(COMPOSE) up -d --build --wait eventhandler
	@./scripts/configure-eventhandler-policy.sh
	@./scripts/configure-all-sysmonitor-policies.sh

up-plantdescriptionengine:
	@./scripts/generate-x509.sh
	@./scripts/provision-plantdescriptionengine-identity.sh
	@./scripts/deploy-pde-dso.sh
	@./scripts/configure-plantdescriptionengine-policy.sh
	@./scripts/configure-sysmonitor-policy.sh
	@./scripts/configure-all-sysmonitor-policies.sh

.PHONY: deploy-pde-dso
deploy-pde-dso:
	@./scripts/deploy-pde-dso.sh

up-configuration: | ../ah5-support-java-spring/Configuration/target/arrowhead-configuration-5.2.2.jar
	@./scripts/generate-x509.sh
	@$(MAKE) validate
	@./scripts/provision-configuration-identity.sh
	@$(COMPOSE) up -d --build --wait configuration
	@./scripts/configure-configuration-policy.sh

up-choreographer: | ../ah5-support-java-spring/Choreography/target/arrowhead-choreographer-5.2.2.jar
	@./scripts/generate-x509.sh
	@$(MAKE) validate
	@./scripts/provision-choreographer-identity.sh
	@$(COMPOSE) up -d --build --wait choreographer
	@./scripts/configure-choreographer-policy.sh

up-aigym:
	@./scripts/generate-x509.sh
	@$(MAKE) validate
	@$(COMPOSE) up -d --wait serviceregistry authentication consumerauthorization serviceorchestration-dynamic datamanager mqtt-broker amqp-broker sysmonitor
	@./scripts/provision-aigym-identity.sh
	@./scripts/provision-smoke-client-identity.sh
	@./scripts/configure-aigym-policy.sh
	@$(COMPOSE) up -d --build --wait aigym cloud-monitor-api cloud-monitor-ui

up-all:
	@./scripts/generate-x509.sh
	@$(MAKE) validate
	@$(COMPOSE) --profile all up -d --wait

status:
	@$(COMPOSE) --profile all ps

smoke:
	@./scripts/smoke-test.sh

# Translation bridge end to end (2026-10-24): TranslationManager + TestTranslation, DataManager senml -> simpleJson
smoke-translation:
	@./scripts/smoke-translation.sh

configure-translation-policy:
	@./scripts/configure-translation-policy.sh

smoke-aigym:
	@./scripts/smoke-aigym.sh

# Onboarding procedure end to end with the demo device: approve, onboard device and system, register, orchestrate, off-board.
smoke-onboarding-procedure:
	@./scripts/smoke-onboarding-procedure.sh

smoke-onboarding:
	@SMOKE_ONBOARDING_ONLY=1 ./scripts/smoke-test.sh

smoke-all:
	@SMOKE_ALL=1 ./scripts/smoke-test.sh

configure-orchestration-security-policies:
	@./scripts/configure-orchestration-security-policies.sh

configure-blacklist-policy:
	@./scripts/configure-blacklist-policy.sh

configure-gatekeeper-policy:
	@./scripts/configure-gatekeeper-policy.sh

configure-gatetunnel-policy:
	@./scripts/configure-gatetunnel-policy.sh

configure-sysmonitor-policy:
	@./scripts/configure-sysmonitor-policy.sh

configure-all-sysmonitor-policies:
	@./scripts/configure-all-sysmonitor-policies.sh

configure-timemanager-policy:
	@./scripts/configure-timemanager-policy.sh

configure-eventhandler-policy:
	@./scripts/configure-eventhandler-policy.sh

configure-plantdescriptionengine-policy:
	@./scripts/configure-plantdescriptionengine-policy.sh
	@./scripts/configure-pde-dso-policy.sh

configure-configuration-policy:
	@./scripts/configure-configuration-policy.sh

configure-choreographer-policy:
	@./scripts/configure-choreographer-policy.sh

configure-aigym-policy:
	@./scripts/configure-aigym-policy.sh

configure-datamanager-monitoring-policy:
	@./scripts/configure-datamanager-monitoring-policy.sh

intercloud:
	@./scripts/configure-intercloud.sh

logs:
	@$(COMPOSE) --profile all logs -f --tail=100

down:
	@$(COMPOSE) --profile all down

# Explicitly destructive: removes all database volumes as well as containers.
clean:
	@$(COMPOSE) --profile all down --volumes --remove-orphans

# Regenerates amqp/definitions.json from amqp/acl and loads it into the running AMQP broker (users and their
# publish/subscribe rights). Removed users are not deleted by the import; delete them with rabbitmqctl delete_user.
amqp-acl:
	@python3 scripts/generate-amqp-definitions.py
	@$(COMPOSE) exec -T amqp-broker rabbitmqctl -q import_definitions /etc/rabbitmq/definitions.json
	@./scripts/prune-amqp-users.sh

# Per-cloud secrets (H2): `secrets` adds missing values to .env; `rotate-secrets` replaces all of them on the running
# cloud (identities, database users, keystores) and recreates it in bootstrap order.
secrets:
	@./scripts/rotate-secrets.sh generate

rotate-secrets:
	@./scripts/rotate-secrets.sh rotate
	@./scripts/rotate-secrets.sh apply
	@./scripts/rotate-secrets.sh restart

console-password:
	@SECRETS_ENV_FILE=.env; . ./scripts/lib-secrets.sh && secret CONSOLE_PASSWORD && echo

# Security regression test for H1 (console), H2 (no default credentials) and H3 (revocation at the brokers and relay)
smoke-security:
	@./scripts/smoke-security.sh

# MQTT API of the Go core systems (2026-10-24)
smoke-mqtt:
	@./scripts/smoke-mqtt.sh

# HTTPS <-> MQTT translation bridges (TestTranslation, 2026-10-24)
smoke-translation-mqtt:
	@./scripts/smoke-translation-mqtt.sh

# Java Blacklist with its MQTT API in place of the Go Blacklist (2026-10-24); the Go state volume stays for the restore
# (blacklist-java with its own database blacklist-java-db; the Go Blacklist's entries are not carried over)
swap-java-blacklist:
	@./scripts/rotate-secrets.sh generate
	@./scripts/make-java-blacklist-bundle.sh
	@$(COMPOSE) stop blacklist
	@./scripts/revoke-system-registration.sh Blacklist
	@# reload inside the container: `compose kill` would mark the broker manually stopped and disable its restart policy (SOS-15)
	@$(COMPOSE) exec -T mqtt-broker kill -HUP 1
	@$(COMPOSE) --profile java-blacklist up -d --wait blacklist-java-db blacklist-java
restore-go-blacklist:
	@$(COMPOSE) --profile java-blacklist stop blacklist-java blacklist-java-db
	@./scripts/revoke-system-registration.sh Blacklist
	@$(COMPOSE) up -d --wait blacklist

# Rust TimeManager (ah5-support-rust) in place of the Go TimeManager (2026-10-24); the Go state volume stays
swap-rust-timemanager:
	@./scripts/make-rust-bundle.sh timemanager timemanager AH_PW_TMG
	@docker volume create $$(docker compose config --format json | jq -r .name)_rust-timemanager-state >/dev/null
	@docker run --rm --user 0 --entrypoint sh -v $$(docker compose config --format json | jq -r .name)_rust-timemanager-state:/data arrowhead-rust-candidate:5.2.2-wi6efg-20261023 -c 'chown 65532:65532 /data'
	@$(COMPOSE) stop timemanager
	@./scripts/revoke-system-registration.sh TimeManager
	@$(COMPOSE) --profile rust-timemanager up -d --wait timemanager-rust
restore-go-timemanager:
	@$(COMPOSE) --profile rust-timemanager stop timemanager-rust
	@./scripts/revoke-system-registration.sh TimeManager
	@$(COMPOSE) up -d --wait timemanager

# Rust SysMonitor (ah5-support-rust) in place of the Go SysMonitor (2026-10-24); the Go history volume stays
swap-rust-sysmonitor:
	@./scripts/make-rust-bundle.sh sysmonitor sysmonitor AH_PW_SM
	@docker volume create $$(docker compose config --format json | jq -r .name)_rust-sysmonitor-state >/dev/null
	@docker run --rm --user 0 --entrypoint sh -v $$(docker compose config --format json | jq -r .name)_rust-sysmonitor-state:/data arrowhead-rust-candidate:5.2.2-wi6efg-20261023 -c 'chown 65532:65532 /data'
	@$(COMPOSE) stop sysmonitor
	@./scripts/revoke-system-registration.sh SysMonitor
	@$(COMPOSE) --profile rust-sysmonitor up -d --wait sysmonitor-rust
restore-go-sysmonitor:
	@$(COMPOSE) --profile rust-sysmonitor stop sysmonitor-rust
	@./scripts/revoke-system-registration.sh SysMonitor
	@$(COMPOSE) up -d --wait sysmonitor

# Rust DataManager (ah5-support-rust) in place of the Go DataManager (2026-10-24); the Go SenML history volume stays
swap-rust-datamanager:
	@./scripts/make-rust-bundle.sh datamanager datamanager AH_PW_DM
	@docker volume create $$(docker compose config --format json | jq -r .name)_rust-datamanager-state >/dev/null
	@docker run --rm --user 0 --entrypoint sh -v $$(docker compose config --format json | jq -r .name)_rust-datamanager-state:/data arrowhead-rust-candidate:5.2.2-gocloud-datamodels-20261024 -c 'chown 65532:65532 /data'
	@$(COMPOSE) stop datamanager
	@./scripts/revoke-system-registration.sh DataManager
	@$(COMPOSE) --profile rust-datamanager up -d --wait datamanager-rust
restore-go-datamanager:
	@$(COMPOSE) --profile rust-datamanager stop datamanager-rust
	@./scripts/revoke-system-registration.sh DataManager
	@$(COMPOSE) up -d --wait datamanager
