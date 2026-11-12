USE `ah_serviceorchestration_dynamic`;

-- Active PDE snapshot; replacing the single row is atomic. Empty provider lists remain managed scopes.
CREATE TABLE IF NOT EXISTS `orchestration_plant_rules` (
  `id` int NOT NULL,
  `payload` mediumtext NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

GRANT SELECT, INSERT, UPDATE, DELETE ON `ah_serviceorchestration_dynamic`.`orchestration_plant_rules` TO 'serviceorchestration-dynamic'@'%';
