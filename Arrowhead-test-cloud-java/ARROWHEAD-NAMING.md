# Names shown by LocalCloudManager

LocalCloudManager displays ServiceRegistry system names and service-definition names exactly as registered. Microsystems use PascalCase, service definitions use camelCase, and operations use lowercase kebab-case. The API validates the live inventory and reports naming violations as incidents.

Docker Compose service keys remain internal runtime identifiers. The runtime view shows the canonical Arrowhead name first and the Compose key as secondary technical detail. For example, `DynamicServiceOrchestration` is displayed for the `serviceorchestration-dynamic` container.

The standard telemetry contract is `sysMonitor.observe` over `generic_amqps` (local-cloud AMQP broker). HTTPS health or liveness interfaces use `echo.echo`.
