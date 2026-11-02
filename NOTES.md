# IPodWheel : notes du projet (a re-fournir a Claude avec le zip)

Application iOS (Theos, armv7, iOS 6.0+) : interface iPod classic avec click wheel dans une UIWebView,
+ tweak SpringBoard optionnel "ecran d'accueil" (mode kiosque), livre dans le meme paquet.
Cible : iPhone 4, iOS 6.1.2, jailbreak. SDK 9.3, cible 6.0. Version actuelle : 0.1.0.

## Installation (commande de reference)
    cd ~/Downloads
    rm -rf IPodWheel
    unzip IPodWheel.zip
    cd IPodWheel
    make package install
(SpringBoard redemarre a la fin de l'installation : c'est normal, c'est pour charger le tweak.)

## Arborescence
- Resources/index.html : toute l'interface (ES5 uniquement : iOS 6 n'accepte ni let, ni =>, ni \u{...}).
- AppDelegate.m / .h   : natif (bibliotheque MPMedia + caches, lecture, pochettes, radio, reveil, minuterie,
                         luminosite / retroeclairage, batterie, Hold, reglages NSUserDefaults).
- Kiosk/               : tweak IPodWheelKiosk (SpringBoard) = l'app remplace l'ecran d'accueil.
- Makefile             : app + SUBPROJECTS Kiosk (aggregate.mk) + respring apres installation.

## Pont JS <-> natif
- JS -> natif : send(cmd) met "commande?x=y" en file ; une iframe unique passe a ipod://flush/N ;
  le natif lit toute la file avec window.__drain() et appelle handleCommand pour chaque ligne.
- Natif -> JS : window.onList, onNP (pousse par notifications MPMusicPlayer, pochette seulement quand le
  morceau change), onRadio, onBright, onStats, onToast, onAlarm, onSleepDone, loadPrefs, wake,
  setBattery, setHold.
- Commandes : click, setpref, list, play, shuffle, mode, playpause, pause, next, prev, seek, seekfwd,
  seekbwd, seekend, np, vol, bright, dim, idle, radio, radiotoggle, radiost, video, otgadd, otgclear,
  sleep, alarm, alarmtest, stats.

## Reglages (NSUserDefaults, fichier /var/mobile/Library/Preferences/com.tanguytar.ipodwheel.plist)
theme, clicker, backlight (10/30/60/120/0=toujours), hidden (entrees masquees du menu principal),
kiosk, diag, brick (meilleur score), alarmOn, alarmH, alarmM, otg (liste On-The-Go, persistentID).

## Fonctions (v0.1.0)
- Menu principal : Musique, Videos, Podcasts, Radio, Extras, Reglages, Lecture aleatoire,
  Lecture en cours (seulement si une lecture existe). Personnalisable (Reglages > Menu principal).
- Musique : Playlists (+ On-The-Go), Artistes > albums > morceaux (+ "Tous les morceaux"), Albums,
  Morceaux, Genres, Compilations, Compositeurs, Livres audio, Top 25, Ecoutes recemment.
  Ligne "Lecture aleatoire" en tete des listes de morceaux.
- On-The-Go : maintenir le bouton central sur un morceau l'ajoute ; "Effacer la liste" en bas.
- Lecture en cours : pochette, titre/artiste/album, "x sur y", progression ; le centre fait defiler
  les modes Volume > Defilement (dans le morceau) > Aleatoire > Repeter (retour au volume apres 6 s).
- Boutons : ◀◀ = debut du morceau si > 3 s, sinon precedent ; maintenir ◀◀/▶▶ = retour/avance rapide ;
  maintenir MENU = menu principal ; maintenir ▶❚❚ = pause + veille de l'ecran.
- Molette : acceleration quand on tourne vite (x3, x8) dans les listes de plus de 40 elements,
  avec grande lettre de l'alphabet au centre.
- Radio : webradios Radio France (tableau RADIOS dans index.html), ▶▶/◀◀ = station suivante/precedente,
  nom sur l'ecran verrouille, reprise apres un appel, telecommande des ecouteurs.
- Extras : Horloge, Reveil (notification locale quotidienne + musique aleatoire si l'app est ouverte),
  Chronometre (tours), Minuterie de veille (15 a 120 min), Jeux > Brick (casse-briques, meilleur score).
- Reglages : A propos (nb de morceaux/albums/artistes/videos, capacite, espace libre), Aleatoire,
  Repeter, Retroeclairage, Luminosite, Minuterie, Clicker, Theme clair/sombre, Menu principal,
  Ecran d'accueil, Diagnostic, Reinitialiser.
- Batterie reelle, mode Hold par l'interrupteur silencieux (voir versions precedentes).

## Optimisations (v0.1.0)
- Listes : 7 lignes creees une fois puis seulement mises a jour (rien n'est reconstruit a chaque cran).
- Lecture en cours / radio / horloge / chrono : DOM construit une fois, mise a jour des seuls textes.
- Plus d'interrogation chaque seconde : le natif pousse les changements ; position interpolee en JS.
- Caches natifs des requetes MPMedia (vides a chaque synchro iTunes et en cas de memoire faible).
- Lignes envoyees en tableaux compacts ; limite portee a 4000 lignes.
- Centre de la molette mesure une fois (plus de getBoundingClientRect a chaque mouvement).
- Ligne de diagnostic desactivee par defaut (Reglages > Diagnostic).

## Ecran d'accueil (tweak Kiosk)
- Desactive par defaut. Activer : Reglages > Ecran d'accueil > Oui.
- Kiosque actif : l'app se relance des que l'ecran d'accueil apparait ; Home et double Home bloques.
- Sortie : Home + Volume+ + Volume- (vibre) ; ou Reglages > Ecran d'accueil > Non dans l'app.
- Secours : mode sans echec (Volume+ pendant le respring) ; fichier
  /var/mobile/Library/Preferences/ipodwheel.kiosk.disable (le creer par SSH desactive le tweak) ;
  coupure automatique apres 8 relances en 60 s ; 5 appuis Home en 3 s si la combinaison n'a pas pu
  etre installee (voir "IPodWheelKiosk: home=.. combo=.." dans le journal syslog).
- Maintenir Home longtemps ouvre toujours le Controle vocal d'iOS 6 (non bloque).

## Non teste sur l'appareil (a verifier en priorite)
- Compilation (pas de Theos dans l'environnement de Claude) et tout le natif.
- Noms de methodes SpringBoard iOS 6 utilises par le tweak.
- URL exactes des flux radio.
- La minuterie de veille ne se declenche que si l'app tourne (premier plan, ou radio en fond).

## Historique
- 0.0.2 : appuis centre fiables, file de commandes, crashs JSON corriges, Hold ameliore.
- 0.0.3 : radio, theme sombre, garde-fous.
- 0.1.0 : grosse optimisation + fonctions iPod (ci-dessus) + ecran d'accueil.
