import json
from pathlib import Path
import sys
import unittest
from types import SimpleNamespace


REPOSITORY = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPOSITORY / "scripts"))

from rbac_exception_scopes import (  # noqa: E402
    exception_scope_matches,
    load_management_group_descendants,
)


CRIME = "/providers/Microsoft.Management/managementGroups/Crime"


class ExceptionScopeMatchingTests(unittest.TestCase):
    def test_management_group_exception_covers_descendants(self):
        descendants = {"crime": {
            "/subscriptions/sub-a",
            "/providers/microsoft.management/managementgroups/crime-child",
        }}
        for scope in (
            CRIME,
            "/subscriptions/SUB-A",
            "/subscriptions/sub-a/resourceGroups/rg",
            "/providers/Microsoft.Management/managementGroups/Crime-Child",
        ):
            with self.subTest(scope=scope):
                self.assertTrue(exception_scope_matches(CRIME, scope, descendants))
        for scope in ("/subscriptions/sub-b", "/subscriptions/sub-ab"):
            with self.subTest(scope=scope):
                self.assertFalse(exception_scope_matches(CRIME, scope, descendants))

    def test_existing_prefix_matching_is_unchanged(self):
        self.assertTrue(exception_scope_matches("/", "/subscriptions/sub-a", {}))
        self.assertTrue(exception_scope_matches(
            "/subscriptions/sub-a", "/subscriptions/sub-a/resourceGroups/rg", {}
        ))
        self.assertFalse(exception_scope_matches("/subscriptions/sub-a", "/subscriptions/sub-b", {}))

    def test_descendant_lookup_follows_pagination(self):
        pages = {
            "page-1": {"value": [{"name": "SUB-A", "type": "Microsoft.Management/managementGroups/subscriptions"}],
                       "nextLink": "page-2"},
            "page-2": {"value": [{"name": "Child", "type": "Microsoft.Management/managementGroups"}]},
        }
        calls = []

        def run(command, **_):
            uri = command[command.index("--uri") + 1]
            calls.append(uri)
            page = pages["page-2" if uri == "page-2" else "page-1"]
            return SimpleNamespace(returncode=0, stdout=json.dumps(page), stderr="")

        descendants = load_management_group_descendants(
            [CRIME, CRIME.lower() + "/", "/subscriptions/sub-a"], run=run
        )

        self.assertEqual(len(calls), 2)
        self.assertIn("/managementGroups/Crime/descendants", calls[0])
        self.assertEqual(descendants, {"crime": {
            "/subscriptions/sub-a",
            "/providers/microsoft.management/managementgroups/child",
        }})

    def test_descendant_lookup_failure_raises(self):
        def run(*_, **__):
            return SimpleNamespace(returncode=1, stdout="", stderr="Forbidden")

        with self.assertRaisesRegex(RuntimeError, "Crime"):
            load_management_group_descendants([CRIME], run=run)


if __name__ == "__main__":
    unittest.main()
