# Gestion DNS local, SSL wildcard & reverse proxy
Ce dépôt propose un script Bash pour:

- Créer un DNS local Bind9 avec zone wildcard (par ex. `*.domaine.local`).
- Générer un certificat SSL wildcard auto-signé.
- Configurer automatiquement un reverse proxy HTTPS avec Apache2 ou Nginx.

Il permet d’ajouter ou de supprimer une configuration complète en quelques questions interactives.

![OS](https://img.shields.io/badge/OS-Debian%2FUbuntu-blue)
![Shell](https://img.shields.io/badge/Shell-bash-4EAA25)
![Bind9](https://img.shields.io/badge/DNS-Bind9-informational)
![Web](https://img.shields.io/badge/Reverse%20Proxy-Apache2%20%7C%20Nginx-orange)

---

## Sommaire
- [Fonctionnalités](#fonctionnalités)
- [Prérequis](#prérequis)
- [Installation](#installation)
- [Utilisation](#utilisation)
  - [Ajouter une configuration](#ajouter-une-configuration)
  - [Supprimer une configuration](#supprimer-une-configuration)
- [Après installation](#après-installation)
- [Exemple](#exemple)
- [Notes](#notes)
- [Dépannage](#dépannage)
- [Support / Contribution](#support--contribution)

---

## Fonctionnalités
- Installation et configuration de Bind9 avec zone wildcard (`*.domaine.local`).
- Configuration d’Apache2 ou Nginx comme reverse proxy HTTPS.
- Génération d’un certificat SSL wildcard auto-signé.
- Ajout automatique du certificat aux autorités de confiance sous Linux (`update-ca-certificates`).
- Ajout et suppression d’une config complète (DNS + SSL + reverse proxy).
- Redirection vers un port local (ex: `127.0.0.1:8080`).

## Prérequis
- Debian/Ubuntu avec accès `root` ou `sudo`.
- Connexion Internet pour installer les paquets.
- Accès à la configuration DHCP du réseau (pour pointer les clients vers ce serveur DNS).

## Installation
Cloner le dépôt puis rendre le script exécutable:

```bash
git clone https://github.com/Achaire-Zogo/zaza-dns-ssl-reverse-proxy.git
cd zaza-dns-ssl-reverse-proxy
chmod +x dns_ssl_reverse_proxy.sh
```

## Utilisation
Lancer le script principal:

```bash
sudo bash dns_ssl_reverse_proxy.sh
```

Vous serez guidé(e) par des questions interactives.

### Ajouter une configuration
Répondez `a` lorsqu’on vous demande l’action, puis fournissez:

- __Nom de domaine interne__: ex. `monprojet.local`
- __Adresse IP cible__ pour Bind9: ex. `192.168.0.50`
- __Serveur web__: `apache2` ou `nginx`
- __Port local__ vers lequel le reverse proxy redirige: ex. `8080`

Le script:

- Installe Bind9, OpenSSL et Apache2/Nginx si nécessaire.
- Crée la zone Bind9 wildcard pointant vers l’IP cible.
- Génère un certificat wildcard auto-signé sous `/etc/ssl/local_certs/<domaine>/`.
- Configure Apache2 ou Nginx en HTTPS et proxifie vers `127.0.0.1:<port>`.

### Supprimer une configuration
Répondez `s`, puis indiquez:

- __Nom de domaine__ à supprimer
- __Serveur web__ utilisé (`apache2` ou `nginx`)

Le script supprime la zone Bind9, les certificats locaux, et la configuration du serveur web sélectionné.

## Après installation
- Configure le DHCP pour que les clients utilisent l’IP du serveur Bind9 comme DNS primaire.
- Pour HTTPS sur les clients (Linux/macOS/Windows), ajoute le certificat aux autorités de confiance pour éviter les alertes:
  - Linux: déjà ajouté automatiquement via `update-ca-certificates`.
  - macOS/Windows: import manuel du certificat `/.crt` situé dans `/etc/ssl/local_certs/<domaine>/<domaine>.crt`.

## Exemple
Ajouter une config pour `monprojet.local`:

```
Nom de domaine interne : monprojet.local
Adresse IP cible : 192.168.0.50
Serveur web : nginx
Port local : 3000
```

Résultat:

- Bind9 répond pour `*.monprojet.local` vers `192.168.0.50`.
- Certificat wildcard `*.monprojet.local` auto-signé généré et installé localement.
- Nginx configuré en HTTPS, proxy → `http://127.0.0.1:3000`.

## Notes
- Le wildcard DNS résout tous les sous-domaines `*.domaine.local` vers la même IP.
- Le reverse proxy redirige tout le trafic HTTPS vers `127.0.0.1:<port>` où votre app doit écouter.
- Un script avancé alternatif existe (`install.sh`) centré sur Apache/Bind9 avec options Laravel; utilisez plutôt `dns_ssl_reverse_proxy.sh` pour la gestion DNS + SSL wildcard + reverse proxy simple.

## Dépannage
- __Ports en usage__: si `:80`/`:443`/port d’app sont occupés, adaptez la config de votre service ou arrêtez le service en conflit.
- __Bind9 ne redémarre pas__: vérifier `named-checkconf` et `named-checkzone` pour les erreurs de zone.
- __Certificat non reconnu sur client__: importer manuellement `/etc/ssl/local_certs/<domaine>/<domaine>.crt` dans les autorités de confiance du système.
- __Nginx/Apache ne redémarre pas__: vérifiez la syntaxe (`nginx -t`, `apachectl configtest`) puis rechargez le service.

## Support / Contribution
Pour toute question, problème ou suggestion, ouvrez une issue ou une PR.