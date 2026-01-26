# Documentation du Pipeline CircleCI

## Table des matières
1. [Vue d'ensemble](#vue-densemble)
2. [Architecture du pipeline](#architecture-du-pipeline)
3. [Executors](#executors)
4. [Jobs](#jobs)
5. [Workflows](#workflows)
6. [Variables d'environnement](#variables-denvironnement)
7. [Gestion des secrets](#gestion-des-secrets)

---

## Vue d'ensemble

Ce pipeline CircleCI v2.1 automatise le processus de :
- **Build** : Installation des dépendances PHP
- **Qualité du code** : Vérification de la conformité et de la documentation
- **Tests** : Exécution des tests unitaires
- **Métriques** : Génération de rapports de qualité
- **Sécurité** : Vérification des vulnérabilités
- **Déploiement** : Construction d'images Docker et déploiement vers staging/production

---

## Architecture du pipeline

### Flux global du workflow "main"

```
Récupération des secrets Infisical (setup-infisical-secrets)
        ↓
Configuration des dépendances PHP (build-setup)
        ↓
┌───────┬───────┬───────┬───────┬───────┬───────┬───────┐
│ phpcs │security│phpunit│metrics│metrics│  phpmd  │php-doc│
│       │ check  │       │metrics│phploc │         │ check │
└───────┴───────┴───────┴───────┴───────┴───────┴───────┘
        ↓
   Création de l'image Docker (build-docker-image) (si branche release/*)
        ↓
  Déploiement en production (deploy-ssh-production) (si branche release/*)
```

---

### Flux global du workflow "staging_deploy"
```
validation manuelle (hold) (si branche "feature/*" ou "bugfix/*")
         ↓
   récupération des secrets Infisical
         ↓
   build-docker-image
         ↓
   déploiement sur l'environnement staging
```
---

## Executors

Les executors définissent l'environnement d'exécution pour chaque job.

### 1. **php-executor**
- **Image Docker** : `cimg/php:8.2`
- **Classe de ressource** : small
- **Shell** : /bin/bash
- **Utilisation** : Jobs PHP standard (lint, tests, métriques)

### 2. **builder-executor**
- **Image Docker** : `cimg/php:8.2-node`
- **Classe de ressource** : small
- **Shell** : /bin/bash
- **Utilisation** : Construction d'images Docker (PHP + Node.js)

### 3. **simple-executor**
- **Image Docker** : `cimg/base:stable`
- **Classe de ressource** : small
- **Shell** : /bin/bash
- **Utilisation** : Déploiement SSH simple

### 4. **node-executor**
- **Image Docker** : `cimg/node:20.11`
- **Classe de ressource** : small
- **Shell** : /bin/bash
- **Utilisation** : Gestion des secrets via Infisical

---

## Jobs

### 1. **debug-info**
**Executeur** : php-executor

**Description** : Job de diagnostic affichant les informations système.

**Étapes** :
- Affiche l'utilisateur courant
- Affiche le répertoire home
- Affiche le shell utilisé
- Affiche les informations du système d'exploitation
- Affiche le PATH
- Affiche le répertoire de travail
- Affiche la date/heure
- Affiche toutes les variables d'environnement

---

### 2. **setup-infisical-secrets**
**Executeur** : node-executor

**Description** : Initialisation et récupération des secrets via Infisical.

**Étapes** :
1. Installation de la CLI Infisical via npm (`@infisical/cli`)
2. Export des secrets Infisical vers un fichier `.infisical_env`
   - Variables nécessaires :
     - `INFISICAL_TOKEN` : Token d'authentification
     - `INFISICAL_PROJECT_ID` : ID du projet Infisical
   - Domaine : `https://eu.infisical.com`
3. Persiste le workspace pour utilisation par d'autres jobs

**Sortie** : Fichier `.infisical_env` contenant toutes les variables d'environnement

---

### 3. **build-setup**
**Executeur** : php-executor

**Description** : Installation des dépendances PHP du projet.

**Étapes** :
1. Clone le repository
2. Restaure le cache des dépendances (basé sur `composer.json`)
   - Clé primaire : `v1-dependencies-{{ checksum "composer.json" }}`
   - Fallback : `v1-dependencies-`
3. Installe les dépendances avec Composer
   ```bash
   composer install --no-interaction --no-ansi --prefer-dist
   ```
4. Sauvegarde le répertoire `vendor` dans le cache
5. Persiste le workspace

**Dépendances** : `setup-infisical-secrets`

**Durée estimée** : 1-2 minutes (selon le cache)

---

### 4. **lint-phpcs**
**Executeur** : php-executor

**Description** : Vérification de la conformité du code avec PHP_CodeSniffer.

**Étapes** :
1. Installe PHP_CodeSniffer et PHPCompatibility
2. Exécute phpcs avec la configuration `phpcs.xml`
   ```bash
   ./vendor/bin/phpcs --standard=phpcs.xml --report-file=phpcs-report.txt \
     --report=checkstyle --extensions=php --ignore=vendor/ .
   ```
3. Les erreurs (résultat 1 ou 2) ne bloquent pas le pipeline
4. Génère un rapport stocké en artefact : `phpcs-report.txt`

**Dépendances** : `build-setup`

**Rapport** : `phpcs-report` (artifact)

---

### 5. **security-check-dependencies**
**Executeur** : php-executor

**Description** : Vérification des vulnérabilités de sécurité dans les dépendances.

**Étapes** :
1. Télécharge `local-php-security-checker` v2.0.6
2. Exécute le vérificateur de sécurité
   ```bash
   ./local-php-security-checker --format=json --no-dev > security-report.json
   ```
3. Génère un rapport JSON stocké en artefact

**Dépendances** : `build-setup`

**Rapport** : `security-report` (artifact)

**Note** : Ne bloque pas le pipeline si des vulnérabilités sont détectées

---

### 6. **test-phpunit**
**Executeur** : php-executor

**Description** : Exécution des tests unitaires PHP.

**Étapes** :
1. Vérifie la présence du fichier `phpunit.xml`
   - Si absent, le job est ignoré (halte)
2. Installe PHPUnit via Composer
3. Exécute la suite de tests unitaires
   ```bash
   ./vendor/bin/phpunit --testsuite=Unit
   ```

**Dépendances** : `build-setup`

**Note** : Peut être ignoré si aucun fichier de configuration PHPUnit n'existe

---

### 7. **metrics-phpmetrics**
**Executeur** : php-executor

**Description** : Génération de métriques de qualité du code.

**Étapes** :
1. Installe PHPMetrics
2. Génère un rapport HTML
   ```bash
   ./vendor/bin/phpmetrics --report-html=phpmetrics-report \
     --extensions=php --exclude=vendor src/
   ```
3. Stocke le rapport en artefact

**Dépendances** : `build-setup`

**Rapport** : `phpmetrics-report` (artifact - répertoire HTML)

---

### 8. **metrics-phploc**
**Executeur** : php-executor

**Description** : Analyse des lignes de code et de la complexité.

**Étapes** :
1. Télécharge PHPLOC (outil d'analyse de code)
2. Exécute l'analyse
   ```bash
   ./phploc.phar --count-tests --exclude=vendor --log-csv=phploc-report.csv src/
   ```
3. Stocke le rapport CSV en artefact

**Dépendances** : `build-setup`

**Rapport** : `phploc-report` (artifact - fichier CSV)

---

### 9. **lint-phpmd**
**Executeur** : php-executor

**Description** : Détection des problèmes de code (MessDetector).

**Étapes** :
1. Installe PHPMD (PHP Mess Detector)
2. Analyse le code avec les règles suivantes :
   - cleancode
   - codesize
   - design
   - naming
   - unusedcode
3. Génère un rapport JSON
   ```bash
   ./vendor/bin/phpmd src/ json cleancode,codesize,design,naming,unusedcode \
     --exclude=vendor --report-file=phpmd-report.json 
   ```

**Dépendances** : `build-setup`

**Rapport** : `phpmd-report` (artifact - fichier JSON)

---

### 10. **lint-php-doc-check**
**Executeur** : php-executor

**Description** : Vérification de la documentation PHP (DocBlocks).

**Étapes** :
1. Installe PHP-Doc-Check
2. Vérifie que toutes les classes/méthodes sont documentées
   ```bash
   ./vendor/bin/php-doc-check src/ --format=json \
     --reportFile=php-doc-check-report.json --exclude=vendor
   ```
3. Génère un rapport JSON

**Dépendances** : `build-setup`

**Rapport** : `php-doc-check-report` (artifact - fichier JSON)

---

### 11. **build-docker-image**
**Executeur** : builder-executor

**Description** : Construction et publication de l'image Docker.

**Étapes** :
1. Récupère les secrets depuis `.infisical_env`
2. Peut être ignorée si `SKIP_BUILD` est défini
3. Sanitize les noms :
   - Convertit en minuscules
   - Supprime les underscores
   - Limite le tag à 128 caractères
4. Se connecte au GitHub Container Registry (GHCR)
5. Construit l'image Docker avec les arguments :
   - `BUILD_DATE` : Timestamp ISO 8601
   - `TAG` : Tag de la branche (sanitizé)
   - `GIT_COMMIT` : Commit SHA
   - `GIT_URL` : URL du repository GitHub
   - `SQLITE_VERSION` : 3430200
   - `SQLITE_YEAR` : 2023
   - `PROJECT_USERNAME` : Utilisateur CircleCI
6. Pousse l'image vers GHCR

**Dockerfile** : `docker/Dockerfile`

**Dépendances** : `test-phpunit`, `lint-phpcs`, `security-check-dependencies`, `metrics-phpmetrics`, `metrics-phploc`, `lint-phpmd`, `lint-php-doc-check`

**Filtres** : Branches `release/*` uniquement

**Variables requises** :
- `GHCR_USERNAME` : Nom d'utilisateur GHCR
- `GHCR_PAT` : Token d'authentification GHCR
- `GITHUB_REPO_USERNAME` : Username du repository GitHub
- `GITHUB_REPO_NAME` : Nom du repository GitHub

---

### 12. **deploy-ssh-staging**
**Executeur** : simple-executor

**Description** : Déploiement sur le serveur de staging.

**Étapes** :
1. Utilise la commande réutilisable `deploy_to_host`
2. Paramètres utilisés :
   - `ssh_private_key` : `${STAGING_SSH_PRIVATE_KEY}`
   - `ssh_user` : `${STAGING_SSH_USER}`
   - `ssh_host` : `${STAGING_SSH_HOST}`
   - `ssh_port` : `${STAGING_SSH_PORT}`

**Dépendances** : `build-docker-image` (dans staging_deploy_workflow)

---

### 13. **deploy-ssh-production**
**Executeur** : simple-executor

**Description** : Déploiement sur le serveur de production.

**Étapes** :
1. Utilise la commande réutilisable `deploy_to_host`
2. Paramètres utilisés :
   - `ssh_private_key` : `${PRODUCTION_SSH_PRIVATE_KEY}`
   - `ssh_user` : `${PRODUCTION_SSH_USER}`
   - `ssh_host` : `${PRODUCTION_SSH_HOST}`
   - `ssh_port` : `${PRODUCTION_SSH_PORT}`

**Dépendances** : `build-docker-image` (dans main_workflow)

---

## Commande `deploy_to_host`

**Description** : Commande réutilisable pour déployer l'application sur un serveur distant.

**Paramètres** :
- `ssh_private_key` : Clé privée SSH
- `ssh_user` : Nom d'utilisateur SSH
- `ssh_host` : Adresse du serveur
- `ssh_port` : Port SSH

**Processus de déploiement** :
1. Charge les variables d'environnement depuis `.infisical_env`
2. Construit les noms :
   - REPOSITORY : `ghcr.io/$GHCR_USERNAME/$CIRCLE_PROJECT_USERNAME` (minuscules, sans underscores)
   - TAG : Nom de la branche (sanitizé)
3. Sauvegarde la clé privée SSH temporairement
4. Se connecte au serveur distant via SSH
5. Se connecte à GHCR avec le token `GHCR_PAT`
6. Arrête le conteneur précédent (s'il existe)
7. Supprime le conteneur précédent (s'il existe)
8. Supprime l'image précédente (s'il existe)
9. Télécharge la nouvelle image Docker
10. Lance le conteneur
    - Port : 80:80
    - Mode : détaché (-d)
    - Nom : `$CIRCLE_PROJECT_REPONAME`

---

## Workflows

### 1. **main_workflow**

Exécuté sur : **Toutes les branches**

**Ordre d'exécution** :

```
1. debug-info (parallèle)
   setup-infisical-secrets (parallèle)
   
2. build-setup
   ├── Dépend de : setup-infisical-secrets
   
3. Parallèle :
   ├── lint-phpcs
   ├── security-check-dependencies
   ├── test-phpunit
   ├── metrics-phpmetrics
   ├── metrics-phploc
   ├── lint-phpmd
   └── lint-php-doc-check
   └── Dépendent tous de : build-setup
   
4. build-docker-image
   ├── Dépend de : test-phpunit, lint-phpcs, security-check-dependencies, metrics-phpmetrics, metrics-phploc, lint-phpmd, lint-php-doc-check
   ├── Filtres : Branches release/* seulement
   
5. deploy-ssh-production
   └── Dépend de : build-docker-image
```

**Caractéristiques** :
- Tous les jobs de qualité (lint, test, sécurité, métriques) doivent réussir avant la construction Docker
- Le déploiement en production n'est déclenché que si :
  - Les branches commencent par `release/`
  - Les tests unitaires passent
  - PHP_CodeSniffer ne détecte pas d'erreurs critiques
  - Aucune vulnérabilité de sécurité n'est détectée

---

### 2. **staging_deploy_workflow**

Exécuté sur : **Branches `feature/*` et `fix/*`**

**Ordre d'exécution** :

```
1. hold
   ├── Type : Approval (approbation manuelle)
   ├── Filtres : Branches feature/*, fix/* seulement
   
2. setup-infisical-secrets
   └── Dépend de : hold
   
3. build-docker-image
   └── Dépend de : setup-infisical-secrets
   
4. deploy-ssh-staging
   └── Dépend de : build-docker-image
```

**Caractéristiques** :
- Nécessite une approbation manuelle avant de commencer
- Pas de restriction sur les branches (feature/* et fix/*)
- Permet de tester les nouvelles fonctionnalités sur staging
- Utile pour vérifier l'aspect visuel et le comportement avant la production

---

## Variables d'environnement

### Variables CircleCI intégrées

- `$CIRCLE_BRANCH` : Nom de la branche
- `$CIRCLE_USERNAME` : Nom d'utilisateur CircleCI
- `$CIRCLE_PROJECT_USERNAME` : Propriétaire du projet
- `$CIRCLE_PROJECT_REPONAME` : Nom du repository
- `$CIRCLE_COMMIT` : Hash du commit (non utilisé directement, mais calculé via git)

### Variables à définir dans CircleCI

#### Pour Infisical
- `INFISICAL_TOKEN` : Token d'authentification Infisical
- `INFISICAL_PROJECT_ID` : ID du projet Infisical

#### Pour GHCR (GitHub Container Registry)
- `GHCR_USERNAME` : Nom d'utilisateur GHCR
- `GHCR_PAT` : Personal Access Token GHCR
- `GITHUB_REPO_USERNAME` : Propriétaire du repository GitHub
- `GITHUB_REPO_NAME` : Nom du repository GitHub

#### Pour SSH (Staging)
- `STAGING_SSH_PRIVATE_KEY` : Clé privée SSH (format PEM)
- `STAGING_SSH_USER` : Utilisateur SSH du serveur de staging
- `STAGING_SSH_HOST` : Adresse IP/hostname du serveur de staging
- `STAGING_SSH_PORT` : Port SSH (généralement 22)

#### Pour SSH (Production)
- `PRODUCTION_SSH_PRIVATE_KEY` : Clé privée SSH (format PEM)
- `PRODUCTION_SSH_USER` : Utilisateur SSH du serveur de production
- `PRODUCTION_SSH_HOST` : Adresse IP/hostname du serveur de production
- `PRODUCTION_SSH_PORT` : Port SSH (généralement 22)

---

## Gestion des secrets

### Infisical

**Infisical** est un gestionnaire de secrets centralisé utilisé pour :
- Récupérer les secrets depuis un coffre-fort sécurisé
- Les exporter comme variables d'environnement
- Les utiliser dans les jobs du pipeline

**Processus** :
1. Le job `setup-infisical-secrets` est exécuté en premier
2. Il installe la CLI Infisical
3. Exporte tous les secrets vers `.infisical_env`
4. Ce fichier est persisté pour les autres jobs
5. Les jobs chargent ce fichier avec `source .infisical_env`

**Configuration requise** :
- Compte Infisical actif
- `INFISICAL_TOKEN` et `INFISICAL_PROJECT_ID` définis dans CircleCI

---

## Artefacts générés

| Job | Artefact | Type | Description |
|-----|----------|------|-------------|
| lint-phpcs | phpcs-report.txt | TXT | Rapport de conformité du code |
| security-check-dependencies | security-report.json | JSON | Rapport des vulnérabilités |
| metrics-phpmetrics | phpmetrics-report/ | HTML | Rapport de métriques de code |
| metrics-phploc | phploc-report.csv | CSV | Analyse des lignes de code |
| lint-phpmd | phpmd-report.json | JSON | Rapport des problèmes de code |
| lint-php-doc-check | php-doc-check-report.json | JSON | Rapport de documentation |

---

## Conventions de nommage

Le pipeline suit les conventions de nommage suivantes :

| Préfixe | Usage | Exemple |
|---------|-------|---------|
| `build-` | Construction / Installation | `build-setup` |
| `lint-` | Vérification qualité du code | `lint-phpcs`, `lint-phpmd` |
| `test-` | Tests | `test-phpunit` |
| `security-` | Sécurité | `security-check-dependencies` |
| `metrics-` | Métriques / Analyses | `metrics-phpmetrics` |
| `deploy-` | Déploiement | `deploy-ssh-staging` |
| `setup-` | Configuration | `setup-infisical-secrets` |
| `debug-` | Débogage | `debug-info` |

---

## Branchement

### main_workflow
- **Déclencheur** : Toutes les branches
- **Déploiement production** : Branches `release/*` uniquement

### staging_deploy_workflow
- **Déclencheur** : Branches `feature/*` et `fix/*`
- **Approbation manuelle** : Requise avant déploiement

### Schéma de branchement recommandé
```
main (branche principale)
├── release/v1.0.0 (déclenche déploiement production)
├── release/v1.0.1
├── feature/nouvelle-fonctionnalite (déclenche déploiement staging avec approbation)
└── fix/bug-critique (déclenche déploiement staging avec approbation)
```

---

## Troubleshooting

### Le pipeline s'arrête à setup-infisical-secrets
- Vérifier que `INFISICAL_TOKEN` est défini
- Vérifier que `INFISICAL_PROJECT_ID` est défini
- Vérifier que le token a les permissions nécessaires

### Le build Docker échoue
- Vérifier que le fichier `docker/Dockerfile` existe
- Vérifier que `GHCR_USERNAME` et `GHCR_PAT` sont définis
- Vérifier la validité du token GHCR

### Le déploiement SSH échoue
- Vérifier que les clés SSH privées sont définies correctement
- Vérifier que l'adresse IP/hostname du serveur est correcte
- Vérifier que le port SSH est accessible
- Vérifier les permissions de la clé privée (mode 600)

---

## Ressources

- [CircleCI Documentation](https://circleci.com/docs/)
- [CircleCI Environment Variables](https://circleci.com/docs/2.0/env-vars/)
- [Infisical](https://infisical.com/)
- [PHP_CodeSniffer](https://github.com/squizlabs/PHP_CodeSniffer)
- [PHPUnit](https://phpunit.de/)
- [PHPMD](https://phpmd.org/)

