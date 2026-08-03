# Secure API Gateway pour Robot de Réception

## 📋 Description

API Gateway sécurisé pour un robot de réception. Gère l'authentification (OAuth2/JWT), l'autorisation (RBAC), le rate limiting et la journalisation des requêtes.

**Projet réalisé dans le cadre du stage chez TEK-UP.**

---

## 🏗️ Architecture

| Composant | Rôle | Port |
| :--- | :--- | :--- |
| **Kong** | API Gateway | 8000 (proxy) / 8001 (admin) |
| **Keycloak** | Authentification OAuth2/JWT | 8080 |
| **FastAPI (Robot)** | API du robot simulé | 8002 |
| **FastAPI (Dashboard)** | API du dashboard | 8003 |
| **PostgreSQL** | Base de données (Kong + Keycloak) | 5432 / 5433 |
| **Redis** | Cache (rate limiting) | 6379 |
| **Grafana** | Visualisation des logs | 3000 |
| **Loki** | Stockage des logs | 3100 |
| **Promtail** | Collecte des logs | 9080 |

---

## 🚀 Installation rapide

### Prérequis

| Logiciel | Version |
| :--- | :--- |
| Docker | ≥ 24.x |
| Docker Compose | ≥ 2.x |
| Git | ≥ 2.x |

### Installation

```bash
# 1. Cloner le dépôt
git clone https://github.com/R0B0-TEK/msbot-reception-academy.git
cd msbot-reception-academy
git checkout MP-18-Secure-API-Gateway-Mohamed-Aziz-Hachichi

# 2. Créer le fichier .env
cp .env.example .env

# 3. Lancer les services
docker compose up -d --build

# 4. Configurer les services
bash scripts/fix-keycloak-client-secrets.sh
bash scripts/setup-kong.sh
bash scripts/setup-rbac.sh
