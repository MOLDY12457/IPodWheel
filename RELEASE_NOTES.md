## IPodWheel 0.1.0

Première version publiée : interface iPod classic complète pour iPhone 4 sous iOS 6.

### Nouveautés
- Optimisation complète : listes rendues par fenêtre de 7 lignes, état de lecture poussé par le natif, caches de la bibliothèque.
- Musique : Compilations, Compositeurs, Livres audio, Top 25, Écoutés récemment, Artistes › albums, ligne « Lecture aléatoire ».
- On-The-Go (maintenir le centre sur un morceau).
- Lecture en cours : pochette, « x sur y », modes Volume / Défilement / Aléatoire / Répéter, avance et retour rapides.
- Molette accélérée avec lettre de l'alphabet.
- Radio : station suivante / précédente, écran verrouillé, reprise après un appel.
- Extras : réveil, chronomètre, minuterie de veille, jeu Brick.
- Réglages : rétroéclairage, clicker, menu principal personnalisable, à propos, réinitialisation.
- Tweak **écran d'accueil** (nécessite Cydia Substrate). Sortie : Home + Volume+ + Volume−.

### Installation
- Paquet compilé : `dpkg -i com.tanguytar.ipodwheel_*.deb && killall SpringBoard` sur l'iPhone.
- Depuis les sources : `make package install` (voir le README).

### À savoir
- Testé à la compilation et à l'installation ; le tweak écran d'accueil et les flux radio restent à valider sur l'appareil.
