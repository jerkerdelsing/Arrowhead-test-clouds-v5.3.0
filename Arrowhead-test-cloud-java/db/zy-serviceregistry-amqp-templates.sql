-- Database initialization (docker-entrypoint-initdb.d, first start of an empty volume only), added 2026-10-17.
-- The released serviceregistry-db image knows only HTTP and MQTT interface templates, but the ServiceRegistry registers
-- its own sysMonitor offer over generic_amqps at startup, so the templates must exist before its first start.
-- Copied from ah5-core-java-spring/serviceregistry/src/main/resources/database/default_inserts.sql.
USE `ah_serviceregistry`;

-- AMQP 0-9-1 interfaces (sysMonitor): a topic exchange and the routing-key prefix of the provider

INSERT IGNORE INTO `service_interface_template` (`name`, `protocol`) VALUES ('generic_amqp', 'amqp');
INSERT IGNORE INTO `service_interface_template` (`name`, `protocol`) VALUES ('generic_amqps', 'amqps');

INSERT IGNORE INTO `service_interface_template_property` (`service_interface_template_id`, `property_name`, `mandatory`, `validator`)
	SELECT `id`, 'accessAddresses', 1, 'NOT_EMPTY_ADDRESS_LIST' FROM `service_interface_template` WHERE `name` IN ('generic_amqp', 'generic_amqps');
INSERT IGNORE INTO `service_interface_template_property` (`service_interface_template_id`, `property_name`, `mandatory`, `validator`)
	SELECT `id`, 'accessPort', 1, 'PORT' FROM `service_interface_template` WHERE `name` IN ('generic_amqp', 'generic_amqps');
INSERT IGNORE INTO `service_interface_template_property` (`service_interface_template_id`, `property_name`, `mandatory`)
	SELECT `id`, 'exchange', 1 FROM `service_interface_template` WHERE `name` IN ('generic_amqp', 'generic_amqps');
INSERT IGNORE INTO `service_interface_template_property` (`service_interface_template_id`, `property_name`, `mandatory`)
	SELECT `id`, 'baseRoutingKey', 1 FROM `service_interface_template` WHERE `name` IN ('generic_amqp', 'generic_amqps');
INSERT IGNORE INTO `service_interface_template_property` (`service_interface_template_id`, `property_name`, `mandatory`, `validator`)
	SELECT `id`, 'operations', 1, 'NOT_EMPTY_STRING_SET|OPERATION' FROM `service_interface_template` WHERE `name` IN ('generic_amqp', 'generic_amqps');
