import os
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))
from producer import data_path, random_value, secret_env


class ProducerTests(unittest.TestCase):
    def test_random_values_are_inclusive_range(self):
        values = [random_value() for _ in range(1000)]
        self.assertTrue(all(0 <= value <= 100 for value in values))

    def test_data_path_fills_datahistorian_template(self):
        self.assertEqual(data_path("/systems/{systemName}/services/{serviceName}/data"),
                         "/systems/RandomDataProducer/services/randomNumberProducer/data")

    def test_secret_env_reads_file_when_variable_unset(self):
        with tempfile.NamedTemporaryFile("w", delete=False) as handle:
            handle.write("from-file\n")
        try:
            with mock.patch.dict(os.environ, {"FIXTURE_SECRET_FILE": handle.name}, clear=False):
                os.environ.pop("FIXTURE_SECRET", None)
                self.assertEqual(secret_env("FIXTURE_SECRET"), "from-file")
                with mock.patch.dict(os.environ, {"FIXTURE_SECRET": "direct"}):
                    self.assertEqual(secret_env("FIXTURE_SECRET"), "direct")
        finally:
            os.unlink(handle.name)


if __name__ == "__main__":
    unittest.main()
