"""
test_rbac.py — Vrais tests unitaires pour la logique RBAC (rbac.py).

Contrairement au test d'intégration (test-rbac.sh, qui a besoin de Kong +
Keycloak + tous les conteneurs en vie), ces tests s'exécutent en quelques
millisecondes, sans Docker, en simulant juste le request.state.jwt_claims
que jwt_middleware.py aurait normalement rempli.

USAGE:
    pip install pytest --break-system-packages
    pytest tests/test_rbac.py -v

Nécessite que services/robot/rbac.py (ou dashboard) soit sur le PYTHONPATH.
"""

import sys
import os
import pytest
from fastapi import HTTPException
from unittest.mock import Mock

# Ajuste le chemin selon où ce fichier est exécuté depuis (racine du repo)
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "services", "robot"))

from rbac import get_roles, require_role  # noqa: E402


def make_request(roles: list[str] | None):
    """Fabrique un objet Request factice avec des claims JWT simulés."""
    request = Mock()
    if roles is None:
        request.state = Mock(spec=[])  # pas d'attribut jwt_claims
    else:
        request.state.jwt_claims = {"realm_access": {"roles": roles}}
    return request


class TestGetRoles:
    def test_extracts_roles_from_valid_claims(self):
        request = make_request(["admin", "operator"])
        assert get_roles(request) == {"admin", "operator"}

    def test_empty_roles_list(self):
        request = make_request([])
        assert get_roles(request) == set()

    def test_missing_claims_fails_closed(self):
        """Si jwt_middleware n'a pas tourné (pas de claims), on doit refuser
        l'accès (401), jamais laisser passer par défaut."""
        request = make_request(None)
        with pytest.raises(HTTPException) as exc_info:
            get_roles(request)
        assert exc_info.value.status_code == 401


class TestRequireRole:
    def test_allows_matching_role(self):
        request = make_request(["admin"])
        dependency = require_role("admin", "operator")
        dependency(request)  # ne doit pas lever d'exception

    def test_allows_when_one_of_multiple_roles_matches(self):
        request = make_request(["operator"])
        dependency = require_role("admin", "operator")
        dependency(request)  # operator est dans la liste autorisée

    def test_denies_wrong_role(self):
        """Cas central de la matrice de permissions : operator ne doit
        jamais pouvoir modifier les paramètres du robot."""
        request = make_request(["operator"])
        dependency = require_role("admin")
        with pytest.raises(HTTPException) as exc_info:
            dependency(request)
        assert exc_info.value.status_code == 403

    def test_denies_robot_from_reading_logs(self):
        """Cas de la matrice : robot (M2M) ne peut pas lire les logs
        visiteurs."""
        request = make_request(["robot"])
        dependency = require_role("admin", "operator")
        with pytest.raises(HTTPException) as exc_info:
            dependency(request)
        assert exc_info.value.status_code == 403

    def test_denies_no_roles_at_all(self):
        request = make_request([])
        dependency = require_role("admin")
        with pytest.raises(HTTPException) as exc_info:
            dependency(request)
        assert exc_info.value.status_code == 403

    def test_fails_closed_without_middleware(self):
        """Défense en profondeur : si jwt_middleware n'a pas tourné,
        require_role doit refuser (401), pas planter silencieusement ou
        laisser passer."""
        request = make_request(None)
        dependency = require_role("admin")
        with pytest.raises(HTTPException) as exc_info:
            dependency(request)
        assert exc_info.value.status_code == 401
