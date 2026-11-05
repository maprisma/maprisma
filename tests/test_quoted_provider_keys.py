"""Review 063 round 5: a Hermes or Oh My Pi provider whose YAML key is quoted is the same entry when it is
rewritten (a Repair of a moved local LLM), so the file never gets the key twice."""
import sys
import unittest
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import adapter_data  # noqa: E402

hermes = adapter_data.hooks_module("hermes")


class QuotedProviderKeyTest(unittest.TestCase):
    def test_a_quoted_hermes_provider_is_rewritten_not_doubled(self):
        for key in ("workstation", '"workstation"', "'workstation'"):
            with self.subTest(key=key):
                before = ("model:\n  default: qwen\n  provider: openai\nproviders:\n"
                          f"  {key}:\n    name: workstation\n    base_url: http://127.0.0.1:8080/v1\n")
                after = hermes.llm_text(before, "workstation", "workstation", "http://127.0.0.1:9090/v1",
                                        ["qwen"], {}, "qwen", False)
                providers = yaml.safe_load(after)["providers"]
                self.assertEqual(list(providers), ["workstation"])
                self.assertNotIn("127.0.0.1:8080", after)


if __name__ == "__main__":
    unittest.main()
