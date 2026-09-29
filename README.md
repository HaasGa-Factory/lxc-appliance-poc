# LXC Appliance POC

Template générique Debian 13 pour Proxmox VE : le `.tar.zst` ne contient pas l'application. Au premier
démarrage, le conteneur authentifie avec sa clé publique un manifeste minisign, télécharge la release
stable décrite par ce manifeste, vérifie son SHA256 et ne se marque prêt qu'après un health check HTTP.
Une nouvelle release applicative ne nécessite pas de reconstruire le template.

Voir [docs/architecture.md](docs/architecture.md) pour les choix et les limites de validation.

## Prérequis de build

Construire sur un hôte Debian 13/Proxmox VE amd64 en root :

```bash
apt-get update
apt-get install --no-install-recommends debootstrap zstd ca-certificates python3 minisign jq
```

Les commandes Linux doivent s'exécuter sous Debian. Sur ce poste Windows, WSL2 Debian est configuré et
le wrapper `scripts/build-in-wsl.ps1` installe les prérequis, teste, empaquette, construit et vérifie le
template. Il doit être lancé depuis un PowerShell administrateur :

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-in-wsl.ps1
```

## Développement local

```bash
python3 application/app.py
# puis http://127.0.0.1:8080, /health et /version
python3 -m unittest -v tests/test_app.py
```

## Générer la clé de développement une fois

```bash
./scripts/generate-dev-signing-key.sh
```

Le script crée `keys/release.key`, privée, sans mot de passe et ignorée par Git, ainsi que
`keys/release.pub`, publique et intégrée au template. Cette paire sert uniquement au POC : une clé de
production doit être protégée hors du dépôt et fournie avec `SIGNING_KEY=/chemin/cle`.

## Publier une release applicative

```bash
chmod +x scripts/*.sh build/*.sh bootstrap/*.sh application/*.sh
./scripts/package-app.sh
ls -l dist/releases/
```

Publier ces trois fichiers, sans les renommer :

```text
appliance-app-0.1.1.tar.gz
release.json
release.json.sig
```

`release.json` contient schema, channel, version, filename, SHA256 et taille. Sa signature est
obligatoire, même en mode LAN. Lors d'un envoi vers un serveur, publier dans cet ordre : archive,
signature, puis `release.json` en dernier.

Pour un test LAN sans publication Internet, depuis la machine de build :

```bash
./scripts/serve-releases.sh
# utiliser l'IP LAN de cette machine, pas 127.0.0.1
```

HTTP n'est accepté que pour ce test privé. Une vraie publication doit utiliser HTTPS.

## Construire le template

```bash
sudo RELEASE_BASE_URL=https://downloads.example.org/appliance/releases \
  ./build/build-lxc.sh
```

Pour le serveur de test LAN :

```bash
sudo RELEASE_BASE_URL=http://192.168.1.237:8000 ./build/build-lxc.sh
```

Résultat : `dist/appliance-poc_0.1.0_amd64.tar.zst`, suivi à l'écran de sa taille et son SHA256.
Le template embarque seulement `keys/release.pub` et l'URL stable de `release.json`. Il ne contient ni
version, ni nom d'archive, ni checksum applicatif. Tant que la clé publique et l'URL restent identiques,
les nouvelles releases signées sont indépendantes du template.

`debootstrap` utilise par défaut les dépôts Debian courants. Pour des octets reproductibles dans le
temps, fournir un miroir snapshot immuable et une date fixe :

```bash
sudo DEBIAN_MIRROR=https://votre-miroir-snapshot/debian \
  SOURCE_DATE_EPOCH=1756684800 RELEASE_BASE_URL=https://downloads.example.org/releases \
  ./build/build-lxc.sh
```

L'ajout de la chaîne de confiance installe dans le template `minisign`, `jq` et leurs petites
bibliothèques. Debian 13 annonce environ 50 kB installés pour le binaire minisign et 125 kB pour jq,
hors bibliothèques partagées. Python reste absent du template.

## Tests de sécurité de release

```bash
./tests/test-release-security.sh
```

Ils vérifient : bonne signature, manifeste modifié, mauvaise clé, archive valide/modifiée, path
traversal et manifeste incomplet.

## Import et création dans Proxmox

Copier le template dans un stockage acceptant le contenu `vztmpl` :

```bash
scp dist/appliance-poc_0.1.0_amd64.tar.zst root@PVE:/var/lib/vz/template/cache/
```

Il apparaît ensuite dans **local > CT Templates**. Création CLI équivalente :

```bash
pct create 120 local:vztmpl/appliance-poc_0.1.0_amd64.tar.zst \
  --hostname appliance01 --rootfs local-lvm:4 --memory 256 --cores 1 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp,type=veth --unprivileged 1
pct start 120
pct console 120
```

Le GUI permet les mêmes choix : CT ID, hostname, stockage, CPU/RAM, bridge et DHCP.

## Observer et vérifier le premier démarrage

Dans le conteneur (`pct enter 120`) :

```bash
systemctl status appliance-firstboot --no-pager
journalctl -u appliance-firstboot -f
tail -f /var/log/appliance-bootstrap.log
systemctl status appliance --no-pager
journalctl -u appliance -f
curl -i http://127.0.0.1:8080/health
curl http://127.0.0.1:8080/version
cat /var/lib/appliance/installed
```

Depuis un PC : `http://IP_DU_LXC:8080`.

## Échec et reprise

Le fichier `/var/lib/appliance/installed` n'est créé qu'après service actif et réponse `200 / OK`.
En cas d'échec, consulter le journal ci-dessus. Après correction du réseau ou du dépôt :

```bash
systemctl restart appliance-firstboot
# ou redémarrer le conteneur
```

L'installateur est relançable : APT, l'utilisateur, les fichiers et l'unité systemd convergent vers le
même état. Ne créer jamais manuellement le marqueur. Pour rejouer volontairement une installation
réussie, supprimer le marqueur puis redémarrer `appliance-firstboot` (opération d'administration).

## A. Reconstruire le template/bootstrap

Requis uniquement si le bootstrap, sa clé publique ou l'URL du manifeste change :

```bash
sudo RELEASE_BASE_URL=https://downloads.example.org/appliance/releases ./build/build-lxc.sh
```

## B. Publier une nouvelle application sans reconstruire le template

Modifier l'application et incrémenter seulement `application/VERSION`, puis :

```bash
./scripts/package-app.sh
# publier la nouvelle archive, release.json.sig, puis release.json en dernier
```

Un nouveau LXC créé depuis l'ancien `.tar.zst` installera cette nouvelle version stable. Modifier
`release.json` sans le signer de nouveau provoque un refus avant tout téléchargement applicatif.

Le POC n'implémente volontairement ni auto-update, ni Git dans le template, ni Docker, ni base de
données. La validation finale reste un essai réel sur un nœud Proxmox VE.
