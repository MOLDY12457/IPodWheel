# IPodWheel

Interface **iPod classic à click wheel** pour **iPhone 4 jailbreaké sous iOS 6**, avec un tweak optionnel qui en fait l'écran d'accueil de l'iPhone.

![Version](https://img.shields.io/badge/version-0.1.0-blue) ![iOS](https://img.shields.io/badge/iOS-6.0%2B-lightgrey) ![Theos](https://img.shields.io/badge/build-Theos-orange)

## Fonctions

- **Molette tactile** fidèle : défilement sur la couronne (avec accélération et grande lettre de l'alphabet dans les longues listes), bouton central, MENU, ◀◀ ▶▶ ▶❚❚, appuis longs.
- **Musique** : Playlists (+ On-The-Go), Artistes › albums, Albums, Morceaux, Genres, Compilations, Compositeurs, Livres audio, Top 25, Écoutés récemment, Vidéos, Podcasts.
- **Lecture en cours** : pochette, « x sur y », progression ; le centre fait défiler Volume › Défilement › Aléatoire › Répéter. Avance / retour rapides en maintenant ◀◀ ▶▶.
- **On-The-Go** : maintenir le centre sur un morceau pour l'ajouter.
- **Radio** : webradios Radio France (Wi-Fi), station suivante / précédente, écran verrouillé, télécommande des écouteurs.
- **Extras** : horloge, réveil, chronomètre avec tours, minuterie de veille, jeu **Brick**.
- **Réglages** : à propos (bibliothèque, capacité), aléatoire, répéter, rétroéclairage, luminosité, clicker, thème clair / sombre, menu principal personnalisable, écran d'accueil, réinitialisation.
- **Batterie réelle** dans la barre (rouge ≤ 20 %, éclair en charge) et **mode Hold** avec l'interrupteur silencieux.

## Prérequis

- iPhone 4 (armv7) sous iOS 6, jailbreaké, accessible en SSH.
- Mac ou Linux avec [Theos](https://theos.dev) et un SDK iOS (testé avec le SDK 9.3, cible iOS 6.0).
- Optionnel, pour l'écran d'accueil : **Cydia Substrate** (`mobilesubstrate`) sur l'iPhone.

## Installation

```bash
cd ~/Downloads
rm -rf IPodWheel
unzip IPodWheel.zip
cd IPodWheel
make package install
```

`THEOS_DEVICE_IP` doit pointer vers l'iPhone. SpringBoard redémarre à la fin de l'installation (pour charger le tweak).

Paquet `.deb` déjà compilé : voir les [Releases](../../releases), puis sur l'iPhone `dpkg -i com.tanguytar.ipodwheel_*.deb && killall SpringBoard`.

## Écran d'accueil (mode kiosque)

Désactivé par défaut. Dans l'app : **Réglages › Écran d'accueil › Oui** (nécessite Cydia Substrate).

- L'iPod se relance dès que l'écran d'accueil apparaît ; Home et double Home sont bloqués.
- **Sortir** : **Home + Volume+ + Volume−** (l'iPhone vibre), ou Réglages › Écran d'accueil › Non.
- **Secours** : maintenir Volume+ pendant le redémarrage de SpringBoard (mode sans échec), ou créer par SSH le fichier `/var/mobile/Library/Preferences/ipodwheel.kiosk.disable`. Le mode se coupe aussi seul après 8 relances en 60 s.

Aucun fichier système n'est remplacé.

## Organisation du code

| Chemin | Rôle |
|---|---|
| `Resources/index.html` | Interface complète (HTML, CSS, JavaScript **ES5** : iOS 6 n'accepte pas l'ES6) |
| `AppDelegate.m` / `.h` | Partie native : bibliothèque MPMedia (avec caches), lecture, pochettes, radio AVPlayer, réveil, luminosité, batterie, Hold, réglages |
| `Kiosk/` | Tweak SpringBoard `IPodWheelKiosk` (écran d'accueil) |
| `Resources/silence.wav` | Son silencieux de 0,4 s servant à détecter l'interrupteur |
| `NOTES.md` | Notes techniques détaillées (pont JS ↔ natif, commandes, réglages) |

Le JavaScript met ses commandes en file d'attente et prévient le natif via `ipod://flush/N` ; le natif lit la file avec `window.__drain()` et répond par `window.onNP`, `onList`, `onRadio`, etc.

## Limites connues

- La musique doit être dans la bibliothèque iOS (synchronisée par iTunes / Finder) : des fichiers copiés à la main ne sont pas visibles.
- La minuterie de veille ne se déclenche que si l'app tourne (premier plan, ou radio en arrière-plan).
- Le tweak utilise des méthodes privées de SpringBoard iOS 6 ; il n'est pas prévu pour d'autres versions.

## Licence

Projet personnel, tous droits réservés.
