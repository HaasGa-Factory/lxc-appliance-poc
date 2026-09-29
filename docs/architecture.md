# Architecture

## Faisabilité et contraintes vérifiées

Un template de conteneur Proxmox est une archive tar du système de fichiers racine. Proxmox accepte
notamment les archives compressées en Zstandard et utilise `/etc/os-release` pour reconnaître Debian.
Le template est placé dans un stockage de type `vztmpl`, habituellement sous `template/cache/`, puis
fourni directement à `pct create`.

Debian 13 (`trixie`) est pris en charge par `debootstrap`, et Proxmox publie lui-même un template
Debian 13 en `.tar.zst`. Un service systemd `oneshot` fonctionne dans un conteneur LXC Proxmox non
privilégié. `network-online.target` ne garantit toutefois pas l'accès Internet : le bootstrap vérifie
donc lui-même route, DNS et téléchargement avec délais et reprises.

## Séparation

Le template contient Debian minbase, systemd, ca-certificates, curl, iproute2, ifupdown, le client
DHCP `dhcpcd-base`, minisign, jq, le bootstrap, la clé publique de release et
`appliance-firstboot.service`. Il ne contient ni l'application, ni Python, ni checksum applicatif.

La release applicative contient `app.py`, `VERSION`, `install.sh` et `appliance.service`. Le bootstrap
télécharge `release.json` et `release.json.sig`, authentifie d'abord le manifeste avec la clé publique
intégrée, puis utilise le SHA256 signé pour vérifier l'archive avant toute exécution.

## Signature et format du manifeste

Minisign utilise Ed25519 et répond au besoin de signature de fichiers sans trousseau ni infrastructure
GPG. Sous Debian 13, son binaire installé représente environ 50 kB ; jq représente environ 125 kB hors
bibliothèques. Ce petit coût évite un parseur JSON artisanal et garde Python hors du bootstrap.

Le manifeste contient exactement six champs : `schema`, `channel`, `version`, `filename`, `sha256` et
`size`. Le bootstrap accepte actuellement uniquement `schema: 1` et `channel: stable`. Le nom doit
être exactement `appliance-app-VERSION.tar.gz`, ce qui exclut chemin absolu et path traversal.

La clé privée n'est jamais copiée dans le template. La clé publique forme la racine de confiance
stable : une rotation de clé exige un nouveau template, une release applicative normale non.

## Build

1. Créer un rootfs Debian 13 `minbase` avec `debootstrap`.
2. Ajouter le bootstrap, minisign, jq, l'URL du manifeste et la clé publique.
3. Vider machine-id, caches APT, fichiers temporaires et journaux.
4. Archiver la racine avec propriétaires numériques, ACL et attributs étendus, puis compresser en zstd.

La publication applicative est séparée : empaqueter, calculer SHA256/taille, générer `release.json`, le
signer avec la clé privée, puis publier archive, signature et manifeste. Elle ne relance pas le build.

## Premier démarrage

1. Ne rien faire si `/var/lib/appliance/installed` existe.
2. Valider l'URL de manifeste et la présence de la clé publique.
3. Attendre une route par défaut et la résolution DNS.
4. Télécharger le manifeste et sa signature avec `curl` et reprises.
5. Vérifier la signature minisign avant de lire le JSON.
6. Valider strictement schema, channel, version, filename, SHA256 et taille.
7. Télécharger l'archive dans le répertoire temporaire et vérifier taille puis SHA256 signé.
8. Extraire et lancer l'installateur.
9. Installer Python, l'utilisateur système, l'application et son unité.
10. Activer le service et vérifier son état puis `GET /health`.
11. Créer atomiquement le marqueur `installed` et afficher l'URL.

Toute erreur produit un code non nul. Systemd retente après 60 secondes et à chaque démarrage tant
que le marqueur final n'existe pas. Une signature invalide ou un manifeste incorrect arrête le flux
avant le téléchargement et l'exécution de l'application.

L'installateur applicatif est le seul code distant exécuté en root, car il doit appeler APT et créer
l'utilisateur et l'unité systemd. Le serveur Web s'exécute ensuite sous l'utilisateur système dédié
`appliance`, avec des restrictions systemd.

## Références vérifiées

- [Proxmox VE `pct(1)` — Container Images](https://pve.proxmox.com/pve-docs/pct.1.html)
- [Catalogue officiel de templates Proxmox](https://download.proxmox.com/images/system/)
- [Debian 13 `debootstrap(8)`](https://manpages.debian.org/trixie/debootstrap/debootstrap.8.en.html)
- [Debian 13 `ifupdown`](https://packages.debian.org/trixie/ifupdown)
- [Debian 13 `dhcpcd-base`](https://packages.debian.org/trixie/dhcpcd-base)
- [Debian 13 `minisign`](https://packages.debian.org/trixie/minisign)
- [Debian 13 `jq`](https://packages.debian.org/trixie/jq)
- [Debian 13 `systemd-networkd-wait-online(8)`](https://manpages.debian.org/trixie/systemd/systemd-networkd-wait-online.8.en.html)
