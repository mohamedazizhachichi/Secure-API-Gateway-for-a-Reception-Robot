# Secure API Gateway pour Robot de Réception

> API Gateway sécurisée pour un robot de réception — Authentification OAuth2/JWT, autorisation RBAC, rate limiting et journalisation centralisée.

![Statut](https://img.shields.io/badge/statut-terminé-success)
![Stage](https://img.shields.io/badge/stage-6%20semaines-blue)
![Docker](https://img.shields.io/badge/Docker-10%20conteneurs-2496ED?logo=docker&logoColor=white)
![Kong](https://img.shields.io/badge/Kong-3.7-003459?logo=kong&logoColor=white)
![Keycloak](https://img.shields.io/badge/Keycloak-25.0-4D4D4D?logo=keycloak&logoColor=white)

---

## 📋 Description

Ce projet a été réalisé dans le cadre d'un **stage de 6 semaines chez ROBOTEK**. Il consiste à concevoir et implémenter une **API Gateway sécurisée** pour un robot de réception.

Le système agit comme une **porte d'entrée unique** entre les clients (dashboard, robot, utilisateurs) et les services internes, en appliquant les bonnes pratiques de cybersécurité (OWASP API Security Top 10) et de DevSecOps.

**Décision de périmètre :** Le projet est développé et démontré **exclusivement en environnement de simulation** (services conteneurisés via Docker). Aucun déploiement sur robot physique réel n'est prévu dans le cadre du stage.

---

## 🎯 Objectifs

| Objectif | Statut |
| :--- | :--- |
| Authentification centralisée (OAuth2/JWT) | ✅ |
| Autorisation par rôles (RBAC) | ✅ |
| Rate limiting (contrôle de trafic) | ✅ |
| Journalisation et supervision | ✅ |
| Conteneurisation (Docker Compose) | ✅ |
| Pipeline CI/CD (DevSecOps) | ✅ |

---

## 🏗️ Architecture

```mermaid
flowchart TB
    subgraph Clients["👤 CLIENTS"]
        U["Utilisateur / Dashboard"]
        R["Robot (M2M)"]
    end

    subgraph Gateway["🚪 API GATEWAY (Kong)"]
        K["Kong Gateway"]
        J["🔑 JWT Validation"]
        A["🛡️ ACL (RBAC)"]
        L["⏱️ Rate Limiting"]
    end

    subgraph Auth["🔐 AUTHENTIFICATION"]
        KC["Keycloak<br/>OAuth2 / OIDC"]
        PG1["PostgreSQL"]
    end

    subgraph Services["⚙️ SERVICES (FastAPI)"]
        RS["Robot Service"]
        DS["Dashboard Service"]
    end

    subgraph Data["💾 DONNÉES"]
        PG2["PostgreSQL (Kong)"]
        RD["Redis"]
    end

    subgraph Obs["📊 OBSERVABILITÉ"]
        GF["Grafana"]
        LK["Loki"]
    end

    U --> K
    R --> K
    K --> J --> A --> L
    K --> RS
    K --> DS
    K --> KC
    KC --> PG1
    K --> PG2
    K --> RD
    K --> LK
    LK --> GF
