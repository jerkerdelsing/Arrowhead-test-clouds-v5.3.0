SHELL := /bin/sh
COMPOSE := docker compose
DATAMANAGER_SRC := ../ah5-support-java-spring/DataManager
DATAMANAGER_JAR := $(DATAMANAGER_SRC)/target/arrowhead-datamanager-5.2.2.jar
# GraphDBManager: DataManager copy on Ontotext GraphDB, a standalone folder beside this workspace
GRAPHDBMANAGER_SRC := ../../Eclipse-Arrowhead/ah5-GraphDBManager-java-spring
GRAPHDBMANAGER_JAR := $(GRAPHDBMANAGER_SRC)/target/arrowhead-graphdbmanager-5.2.2.jar

.PHONY: jars init validate pull up up-simple up-auth up-monitor up-orchestration-manager up-onboarding up-datamanager up-graphdbmanager up-random-producer up-sysmonitor up-timemanager up-eventhandler up-plantdescriptionengine up-configuration up-choreographer up-aigym up-all status smoke smoke-graphdbmanager smoke-aigym smoke-onboarding smoke-all configure-orchestration-security-policies configure-orchestration-dependency-policies configure-gatekeeper-policy configure-gatetunnel-policy configure-sysmonitor-policy configure-all-sysmonitor-policies configure-aigym-policy configure-timemanager-policy configure-deviceqosevaluator-policy configure-eventhandler-policy configure-plantdescriptionengine-policy configure-configuration-policy configure-choreographer-policy configure-datamanager-monitoring-policy configure-graphdbmanager-policies configure-localcloudconfigurator-policy intercloud logs down clean amqp-acl smoke-onboarding-procedure secrets rotate-secrets console-password smoke-security

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
	$(GRAPHDBMANAGER_JAR) \
	onboarding/app.jar

jars:
	@./scripts/build-java-jars.sh

$(JAVA_JARS):
	@./scripts/build-java-jars.sh

up: $(DATAMANAGER_JAR) | $(JAVA_JARS)
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
	@# every system orchestrates its dependencies: grant them before the systems start using them
	@./scripts/configure-orchestration-dependency-policies.sh
	@./scripts/configure-random-producer-policy.sh
	@$(COMPOSE) up -d --build --wait serviceorchestration-dynamic-db
	@./scripts/migrate-dso-plant-rules-db.sh
	@$(COMPOSE) up -d --build --wait
	@./scripts/configure-gatekeeper-policy.sh
	@./scripts/configure-gatetunnel-policy.sh
	@./scripts/configure-sysmonitor-policy.sh
	@./scripts/configure-all-sysmonitor-policies.sh
	@./scripts/configure-timemanager-policy.sh
	@./scripts/configure-deviceqosevaluator-policy.sh
	@./scripts/configure-eventhandler-policy.sh
	@./scripts/configure-plantdescriptionengine-policy.sh
	@./scripts/configure-configuration-policy.sh
	@./scripts/configure-choreographer-policy.sh
	@./scripts/migrate-onboarding-db.sh
	@./scripts/configure-onboarding-policy.sh
	@./scripts/configure-aigym-policy.sh
	@./scripts/configure-datamanager-monitoring-policy.sh
	@./scripts/configure-graphdbmanager-policies.sh
	@./scripts/configure-localcloudconfigurator-policy.sh
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

# GraphDBManager and its GraphDB on a running cloud (identity, broker ACL, grants, then the containers)
up-graphdbmanager: | $(GRAPHDBMANAGER_JAR)
	@./scripts/generate-x509.sh
	@$(MAKE) validate
	@./scripts/provision-authentication-identities.sh
	@$(MAKE) amqp-acl
	@./scripts/configure-graphdbmanager-policies.sh
	@./scripts/configure-orchestration-dependency-policies.sh
	@./scripts/configure-all-sysmonitor-policies.sh
	@# build and start only these two: --build on a plain up would rebuild their running dependencies too
	@$(COMPOSE) build graphdbmanager-graphdb graphdbmanager
	@$(COMPOSE) up -d --no-deps --wait graphdbmanager-graphdb graphdbmanager

configure-graphdbmanager-policies:
	@./scripts/configure-graphdbmanager-policies.sh

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

up-plantdescriptionengine: | ../ah5-support-java-spring/PlantDescriptionEngine/target/arrowhead-plantdescriptionengine-5.2.2.jar
	@./scripts/generate-x509.sh
	@$(MAKE) validate
	@./scripts/provision-plantdescriptionengine-identity.sh
	@$(COMPOSE) up -d --build --wait serviceorchestration-dynamic-db
	@./scripts/migrate-dso-plant-rules-db.sh
	@./scripts/configure-orchestration-dependency-policies.sh
	@$(COMPOSE) up -d --build --wait serviceorchestration-dynamic plantdescriptionengine
	@./scripts/configure-plantdescriptionengine-policy.sh
	@./scripts/configure-sysmonitor-policy.sh
	@./scripts/configure-all-sysmonitor-policies.sh

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

# GraphDBManager end to end through orchestration (put/get round trip on both services, RDF in GraphDB)
smoke-graphdbmanager:
	@./scripts/smoke-graphdbmanager.sh

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

configure-orchestration-dependency-policies:
	@./scripts/configure-orchestration-dependency-policies.sh

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

configure-deviceqosevaluator-policy:
	@./scripts/configure-deviceqosevaluator-policy.sh

configure-eventhandler-policy:
	@./scripts/configure-eventhandler-policy.sh

configure-plantdescriptionengine-policy:
	@./scripts/configure-plantdescriptionengine-policy.sh

configure-configuration-policy:
	@./scripts/configure-configuration-policy.sh

configure-choreographer-policy:
	@./scripts/configure-choreographer-policy.sh

configure-aigym-policy:
	@./scripts/configure-aigym-policy.sh

configure-datamanager-monitoring-policy:
	@./scripts/configure-datamanager-monitoring-policy.sh

# LC view of the console: LocalCloudManager may use LocalCloudConfigurator's localCloudConfiguration
configure-localcloudconfigurator-policy:
	@./scripts/configure-localcloudconfigurator-policy.sh

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

# the console password is in the keychain, not in .env (J7)
console-password:
	@SECRETS_ENV_FILE=.env; . ./scripts/lib-secrets.sh && secret CONSOLE_PASSWORD && echo

# Security regression test for H1 (console), H2 (no default credentials) and H3 (revocation at the brokers and relay)
smoke-security:
	@./scripts/smoke-security.sh
