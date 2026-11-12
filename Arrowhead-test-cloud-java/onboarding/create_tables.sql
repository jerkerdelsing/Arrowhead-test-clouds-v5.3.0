USE `ah_onboarding`;

CREATE TABLE IF NOT EXISTS `logs` (
  `log_id` varchar(100) NOT NULL,
  `entry_date` timestamp(3) NULL DEFAULT NULL,
  `logger` varchar(100) DEFAULT NULL,
  `log_level` varchar(100) DEFAULT NULL,
  `message` mediumtext,
  `exception` mediumtext,
  PRIMARY KEY (`log_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


-- Devices approved by an operator for onboarding, and the systems each may host (Arrowhead 5.2.2 onboarding procedure).
CREATE TABLE IF NOT EXISTS `device_enrollment` (
  `device_name` varchar(63) NOT NULL,
  `bootstrap_fingerprint` char(64) NOT NULL,
  `approved_systems` varchar(2048) NOT NULL,
  `state` varchar(20) NOT NULL,
  `onboarding_certificate_id` bigint DEFAULT NULL,
  `onboarding_certificate_serial` varchar(64) DEFAULT NULL,
  `device_certificate_id` bigint DEFAULT NULL,
  `device_certificate_serial` varchar(64) DEFAULT NULL,
  `device_certificate_expires_at` varchar(40) DEFAULT NULL,
  `approved_by` varchar(63) NOT NULL,
  `approved_at` timestamp(3) NOT NULL,
  `updated_at` timestamp(3) NOT NULL,
  `last_message` varchar(1024) DEFAULT NULL,
  PRIMARY KEY (`device_name`),
  UNIQUE KEY `bootstrap_fingerprint` (`bootstrap_fingerprint`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `system_enrollment` (
  `system_name` varchar(63) NOT NULL,
  `device_name` varchar(63) NOT NULL,
  `certificate_id` bigint NOT NULL,
  `certificate_expires_at` varchar(40) NOT NULL,
  `issued_at` timestamp(3) NOT NULL,
  PRIMARY KEY (`system_name`),
  KEY `system_enrollment_device` (`device_name`),
  CONSTRAINT `fk_system_enrollment_device` FOREIGN KEY (`device_name`) REFERENCES `device_enrollment` (`device_name`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
