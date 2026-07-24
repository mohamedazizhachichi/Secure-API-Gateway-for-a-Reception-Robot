# CI/CD — Notes d'installation et points de vigilance

## 1. GitHub Secrets à créer AVANT de pousser (Settings → Secrets and variables → Actions)

Sans eux, le job `integration-rbac` échoue à la première étape (`.env` généré avec des valeurs vides).

| Secret | Valeur |
|---|---|
| `KONG_PG_PASSWORD` | Nouveau mot de passe, différent de ton `.env` local si tu veux (c'est un environnement CI éphémère) |
| `KEYCLOAK_PG_PASSWORD` | idem |
| `KEYCLOAK_ADMIN_PASSWORD` | idem |
| `ROBOT_CLIENT_SECRET` | **Utilise le secret régénéré**, pas l'ancien qui a été exposé |
| `DASHBOARD_CLIENT_SECRET` | idem |
| `DEMO_ADMIN_PASSWORD` | idem |
| `DEMO_OPERATOR_PASSWORD` | idem |
| `REDIS_PASSWORD` | idem |

Tu peux utiliser des valeurs différentes de ton `.env` local — c'est même recommandé (isolation environnement CI vs dev local), du moment qu'elles sont cohérentes entre elles côté CI.

## 2. Le risque le plus sérieux, à tester AVANT de compter dessus en CI

`keycloak/robot-realm.json` utilise des placeholders `${env.DEMO_ADMIN_PASSWORD}` etc. pour les mots de passe des utilisateurs de démo. Cette résolution automatique par Keycloak au moment de l'import **n'a jamais été vérifiée sur un environnement 100% frais** dans nos échanges — jusqu'ici, ton Keycloak tourne en continu depuis plusieurs sprints, donc ce chemin de code n'a jamais été réellement testé "from scratch".

Un runner GitHub part toujours d'un environnement neuf (aucun volume Docker persistant). Si la résolution `${env.X}` ne marche pas comme attendu, `demo-admin`/`demo-operator` se retrouveront avec un mot de passe littéral égal à la chaîne `${env.DEMO_ADMIN_PASSWORD}` plutôt que la vraie valeur — et `test-rbac.sh` échouera dès l'obtention du token, pour une raison qui n'a rien à voir avec RBAC.

**Recommandation concrète avant de pousser ce pipeline** :
```bash
docker compose down -v   # supprime aussi les volumes, simule un environnement neuf
docker compose up -d --build
# attendre que Keycloak soit healthy, puis vérifier manuellement
# que demo-admin peut se connecter avec DEMO_ADMIN_PASSWORD
```
Si ça échoue en local dans ces conditions, ça échouera pareil en CI — mieux vaut le découvrir maintenant, en local, où c'est plus facile à déboguer qu'au milieu d'un run GitHub Actions.

## 3. Le job `build-and-scan` va probablement échouer au premier run — et c'est normal

Trivy est configuré en `severity: CRITICAL,HIGH` + `exit-code: 1`, donc **le pipeline bloque** s'il trouve une CVE critique/haute non corrigée dans `python:3.12-slim` ou les dépendances. C'est voulu (c'est le principe même du container scanning), mais concrètement, il y a de bonnes chances que ça bloque au premier essai — les images de base ont presque toujours quelques CVEs connues.

Si ça bloque : ce n'est pas un bug du pipeline, c'est le pipeline qui fait exactement son travail. Deux réponses possibles, à documenter dans ton rapport de stage plutôt qu'à contourner en silence :
- Mettre à jour l'image de base / les dépendances concernées si un correctif existe
- Si aucun correctif n'existe encore (CVE sans patch), ajouter une exception documentée et justifiée (Trivy supporte un fichier `.trivyignore` avec commentaire expliquant pourquoi), plutôt que de juste baisser la sévérité du scan pour le faire taire

## 4. Pourquoi `integration-rbac` dépend de tous les autres jobs (`needs: [...]`)

C'est le "fail fast" du DevSecOps : pas la peine de démarrer 9 conteneurs (le job le plus long, ~5-6 min) si le lint échoue en 20 secondes. Pour ta soutenance, c'est un bon point à mentionner explicitement — ça montre que le pipeline est pensé pour donner un feedback rapide, pas juste empilé dans l'ordre.

## 5. Fichiers livrés

| Fichier | Rôle |
|---|---|
| `.github/workflows/ci.yml` | Le pipeline complet, 6 jobs |
| `scripts/setup-kong.sh` | **Remplace l'ancien** — intègre le fix `azp` dès le départ, pas besoin du script de correctif séparé pour un environnement neuf |
| `tests/test_rbac.py` | Vrais tests unitaires (9/9 vérifiés localement avant livraison) |

`scripts/setup-rbac.sh` et `scripts/test-rbac.sh` restent ceux que tu as déjà (Sprint 4) — le pipeline les réutilise tels quels.
