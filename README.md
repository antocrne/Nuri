# Nuri

**Un navigateur léger, sans compte, sans pisteur.** Version **0.1.5**. *Nuri* veut dire « le monde » en coréen.

- App macOS native : Swift, SwiftUI et AppKit, sur WebKit (le moteur déjà présent dans le Mac). Pas de Chromium, pas d'Electron, aucune dépendance.
- macOS 14 minimum, Apple silicon.
- 2 Mo sur le disque (build Release).
- Une seule barre, en haut. Pas de barre latérale.

## Compiler et lancer

Prérequis : Xcode et [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`project.yml` décrit le projet, `Nuri.xcodeproj` en est généré).

```bash
xcodegen generate
```

```bash
open Nuri.xcodeproj
```

Pour compiler en Release et installer dans `/Applications` :

```bash
./scripts/install.sh
```

Compiler avec un dossier de build hors de `~/Documents` : iCloud y ajoute des attributs qui font échouer la signature (le script le fait déjà).

## Ce qui rend Nuri léger

- Une seule vue web est créée au lancement : celle de l'onglet affiché. Les autres dorment jusqu'au clic.
- Les onglets inactifs se mettent en veille après 30 min (5 min si la mémoire baisse, tout de suite si elle est critique). Ils gardent leur place, leur historique et leur défilement. Restent éveillés ceux qui jouent du son, sont en appel, contiennent du texte saisi ou sont en mode lecture.
- Un onglet qui n'est pas à l'écran est retiré de la fenêtre, et WebKit le ralentit.
- Le bloqueur est une liste compilée une fois par WebKit : aucun script par page.
- Rien ne tourne en continu : un seul minuteur (une fois par minute, pour la veille), aucune animation permanente, un fond dessiné une fois.

## Fonctionnalités

| Quoi | Comment |
|---|---|
| Pas de compte | Rien à créer, rien n'est envoyé. Le réseau de Nuri lui-même : les versions publiées (mises à jour, désactivable), les taux de la BCE (à la première conversion de devises) et le Chrome Web Store (seulement pour ajouter ou mettre à jour une extension) |
| Publicités et pisteurs | Bloqués avant chargement. Réglages → Confidentialité, ou le bouclier de la barre d'adresse pour un seul site. Les paramètres de suivi (`utm_*`, `fbclid`…) sont retirés des liens cliqués |
| Fenêtre privée | ⌘⇧N. Stockage en mémoire, détruit à la fermeture ; rien dans l'historique |
| Favoris et signets | L'étoile de la barre d'adresse ou ⌘D garde la page ; ⌥⌘B les montre. Un favori s'affiche aussi sur la page d'un nouvel onglet. Chaque espace a les siens, et la barre de commande les retrouve |
| Vue partagée | ⌥⌘S, clic droit sur un onglet, ou glisser un onglet sur la moitié gauche ou droite de la page. Le séparateur se tire (double-clic : moitié-moitié). Pointeur en haut d'une page : une poignée pour échanger les côtés, et son × pour retirer la page. Dans la barre, les deux onglets forment un seul bloc, qui se déplace d'un tenant |
| Hublot (*Porthole*) | ⌥-clic sur un lien, ou son menu : un aperçu sans quitter la page. Échap le ferme ; il peut devenir un onglet ou passer en vue partagée |
| Espaces | Le point de couleur de la barre. Onglets, connexions, cookies et historique séparés ; une couleur si on veut. ⌃⌘← ⌃⌘→ |
| Son | Une enceinte sur l'onglet qui joue : clic pour couper, re-clic pour remettre. Aussi dans le menu de l'onglet, et ⌃M |
| Onglets | S'ouvrent au relâchement du clic. Se déplacent au glisser-déposer. Clic milieu pour fermer. L'onglet actif est la barre d'adresse : il s'étire, et un clic édite l'adresse |
| Barre masquée | ⌃⌘B : elle revient quand le pointeur touche le bord haut, et on peut en glisser un onglet |
| Raccourcis | Réglages → Raccourcis (modifiables), ou taper « raccourcis » / « shortcuts » dans la barre de commande |
| Barre de commande | ⌘T au milieu de la fenêtre, ⌘L dans la barre d'adresse qui s'étend : adresse, recherche, onglets ouverts, historique de l'espace, commandes de Nuri |
| Calculs et conversions | Dans la barre de commande : `12*4+3`, `20 % de 150`, `10 km en miles`, `100 usd en eur` |
| Dossiers d'onglets | À côté du point de l'espace. Clic droit sur un onglet, ou le glisser sur un dossier. Un onglet rangé s'endort, un clic le réveille ; il ne se ferme que si on le demande. Clic droit sur le dossier : son nom, son icône et sa couleur, qui devient son fond |
| Pages sans HTTPS | Une page servie en HTTP depuis Internet attend une réponse : Retour, ou Continuer vers le site HTTP (retenu jusqu'à ce que Nuri quitte, ou que la fenêtre privée se ferme). Une adresse qui redirige vers HTTPS passe sans question, comme le réseau local |
| Fenêtres sans clic | Bloquées (WebKit seul le ferait sans un mot) : une pastille au-dessus de la page propose d'ouvrir, ou d'autoriser le site. Réglages → Confidentialité pour revenir sur un choix |
| Notifications des sites | Une pastille demande, une fois par site, et macOS les affiche avec le nom du site ; un clic ramène à l'onglet. Pas de Web Push (rien n'arrive quand le site n'est pas ouvert), jamais dans les fenêtres privées |
| Imprimer | ⌘P, et les boutons « Imprimer » des pages (`window.print()`) |
| Nouveaux onglets | ⌘-clic, clic milieu, `target=_blank`, menu du lien (nouvel onglet, hublot, vue partagée, fenêtre privée) : un seul onglet à chaque fois |
| Mode lecture | ⌘⇧R : article et images (même chargées tardivement), sans JavaScript, taille du texte réglable |
| Picture in Picture | ⌘⇧P, et automatique en quittant un onglet qui joue |
| Réunion flottante | Pendant un appel, quitter l'onglet place la page entière dans une petite fenêtre au-dessus des apps, dézoomée à 75 % ; elle revient au retour, par son bouton, ou en raccrochant |
| Partage d'écran | La question « Partager votre écran ? » propose une seule fenêtre ou l'écran entier, puis macOS laisse choisir laquelle. « Partager aussi le son » : les autres apps et les autres onglets, jamais l'appel |
| Fermer | ⌥⌘W tous ; clic droit sur un onglet : tous sauf celui-ci. Les onglets des dossiers restent. ⌘⇧T rouvre |
| Extensions | La pièce de puzzle de la barre. Depuis le Chrome Web Store (sur la page d'une extension, ou son adresse dans Réglages → Extensions), ou reprises du dossier de Chrome, Brave, Edge, Arc, Vivaldi. L'épingle d'une ligne du panneau lui donne son propre bouton dans la barre, juste avant la pièce de puzzle (clic droit dessus pour la retirer). Il faut macOS 15.4. Jamais dans les fenêtres privées. Un VPN (Proton VPN…) demande la première fois de faire passer la navigation par ses serveurs, ce qui se change dans Réglages → Extensions → VPN |
| Téléchargements | Anneau de progression et vitesse dans la barre, panneau avec barre animée, pause et reprise, quarantaine Gatekeeper, noms nettoyés |
| Langue | Celle du système, ou français / anglais dans les Réglages, appliqué aussitôt (les textes du système, comme le menu de WebKit, suivent au prochain lancement) |
| Historique | ⌘Y : recherche, par espace, par jour. Effacer la dernière heure, le dernier jour, les 30 derniers jours, la dernière année ou tout |
| Premier lancement | Langue, thème, couleur, transparence, confidentialité, un second espace. Rejouable dans les Réglages |
| Mises à jour | Au lancement puis toutes les 6 h, désactivable. Rien n'est téléchargé sans accord ; une version n'est installée que si sa signature est celle de Nuri |

Hors de la 0.1.5 : gestionnaire de mots de passe intégré (ils passent par les extensions), import des favoris et de l'historique d'autres navigateurs.

Extensions essayées (`-NuriSelfTestOnly extensions -NuriSelfTestStore id,id`) : Dark Reader, uBlock Origin Lite, SponsorBlock, Grammarly, Proton Pass et Bitwarden ouvrent leur fenêtre ; 1Password ouvre sa page d'accueil dans un onglet (sa fenêtre vient une fois un compte ajouté) ; Return YouTube Dislike se charge. Proton Pass a été essayé avec un vrai compte (0.1.3) ; pour Bitwarden et 1Password, connexion et remplissage restent à essayer.
Ce qui rapproche WebKit de Chrome, repris de Void : la copie d'une extension gardée par Nuri reçoit `extension-shim.js`, exécuté en premier dans son arrière-plan, ses pages, ses scripts de contenu et les scripts qu'elle injecte. Il garde à WebKit ses objets `chrome` et `browser` (Proton Pass les remplace, et WebKit ne pouvait plus rien lui transmettre), fournit des substituts aux API absentes et `requestIdleCallback`, et répond comme Chrome à `tabs.getCurrent()` dans un popup. WebKit perd aussi le service worker d'une extension chargée au lancement, quelques secondes plus tard : Nuri l'interroge, et appelle `runtime.reload()` s'il ne répond plus (`-NuriSelfTestOnly lancement -NuriSelfTestDir dossier`, deux fois de suite, le montre). Les fenêtres des extensions sont redimensionnables, par le coin en bas à droite. Les mises à jour : une fois par jour, désactivable, ou à la demande dans les Réglages.
VPN : WebKit n'a pas `chrome.proxy`. Le shim le donne aux extensions qui le demandent et le relie à Nuri par `runtime.sendNativeMessage`, auquel Nuri répond lui-même (aucune app du Mac n'est jointe) ; Nuri fait alors passer pages, fenêtres privées, mode lecture, téléchargements et icônes par le serveur choisi (`WKWebsiteDataStore.proxyConfigurations`, HTTP, HTTPS ou SOCKS5). Le mot de passe du serveur vient de `webRequest.onAuthRequired` de l'extension, que WebKit n'appelle jamais : Nuri le demande au branchement, toutes les 3 minutes (ceux de Proton durent 20 minutes) et quand une page échoue faute du bon mot de passe. Le shim accorde aussi la permission `proxy` du manifeste comme Chrome à l'installation, et garde l'ordre des appels à `chrome.storage` (sans quoi Proton VPN se croit bloqué par le réseau). Limites : un script PAC est réduit au serveur qu'il donne pour un site ordinaire (le tunnel « seulement ces sites » est refusé) ; une connexion ouverte avant le VPN, un site déjà chargé, peut rester directe jusqu'à ce qu'elle se ferme (WebKit ne sait les couper qu'en arrêtant son processus réseau, ce qui laisse les arrière-plans des extensions muets) : au lancement, le VPN est en place avant la première page. `-NuriSelfTestOnly vpn` essaie tout cela avec un serveur local qui demande un mot de passe.
## Design

Chaleureux, pastel, léger. Tout est dans `Nuri/App/Theme.swift`, y compris le nom (`NuriWordmark`) : le serif du système (New York) pris en contours, le point du i à la couleur du thème ou de l'espace. L'icône : le n du nom et ce point (`scripts/make-icon.swift`). La fenêtre est du verre flouté (`NSVisualEffectView`) sous un voile crème ou cacao, réglable (Réglages → Apparence → Transparence). Les halos doux, clin d'œil à Firn, tiennent dans une seule vue (`ChromeGlow`) et un réglage (`softGlows`) : c'est là qu'il faut les retirer s'ils ne restent pas.

## Architecture

```
project.yml            Le projet (XcodeGen)
Config/                Info.plist, entitlements (Hardened Runtime, pas de sandbox)
Nuri/
  App/                 Démarrage, réglages, langues, thème, commandes et menus, mises à jour
  Browser/             Modèle : Tab (vue web paresseuse), Space, dossiers, vue partagée, session
  Web/                 Configuration WebKit, délégués, menu contextuel, APIs internes gardées
  UI/                  Fenêtre, barre du haut, onglets, zone de page, barre de commande, réglages
  Features/            Bloqueur, conversions, historique, téléchargements, PiP, partage du son,
                       mode lecture, hublot, extensions, premier lancement
  Resources/Scripts/   Scripts injectés, dans un monde JavaScript isolé
  SelfTest/            Auto-tests (Debug seulement)
scripts/               Icône, installation, publication
```

- **Textes** : `L("français", "English")`, à côté du code. Rien ne peut rester sans traduction, et changer de langue s'applique aussitôt. Une troisième langue demandera de passer à un vrai catalogue.
- **Fenêtres** : AppKit hébergeant SwiftUI, sans scène SwiftUI. Une fenêtre privée vit exactement aussi longtemps que son modèle.
- **Couche WebKit** : reprise de Void (un même propriétaire, des pièges déjà résolus) ; interface, modèle d'onglets et design sont propres à Nuri.

Les données sont dans `~/Library/Application Support/Nuri/`, et celles des sites dans un stockage WebKit par espace.

## Auto-tests

Compilés en Debug seulement. Ils travaillent dans un dossier temporaire et ne touchent ni à la session ni à l'historique.

```bash
~/Library/Developer/Xcode/DerivedData/Nuri-cli/Build/Products/Debug/Nuri.app/Contents/MacOS/Nuri -NuriSelfTest features -NuriSelfTestOut /tmp/nuri.md
```

`-NuriSelfTestOnly split,hublot` limite à certaines sections : `session, onglets, porter, glisser, liens, split, hublot, espaces, dossiers, adresse, menus, fermer, son, veille, prive, calcul, commandes, focus, extensions, lancement, vpn, lecture, historique, signets, telechargements, pistage, permissions, http, bloqueur, langue, raccourcis, barre, mise-a-jour, reunion, partage-son, pip, apercu`.

Le rapport compte les tests réussis, échoués et **non vérifiés** : des clics simulés se perdent quand une autre app est au premier plan, ce qui ne dit rien de Nuri. Pour tout vérifier, lancer les tests et laisser Nuri devant, sans toucher à la souris. Le contenu d'un menu ne dit pas ce qui s'affiche (le menu de WebKit ignore l'image de ses éléments) : `-NuriSelfTestOnly menus -NuriSelfTestHoldMenu 30` le garde ouvert pour le regarder. `pip`, `http`, `bloqueur` et `extensions` ont besoin du réseau. `attente -NuriSelfTestHold 45` garde une page ouverte pour essayer avec le vrai pointeur et le vrai clavier, ce qu'aucun événement simulé ne remplace : le bug du + n'apparaissait qu'ainsi, et seulement une fois un client d'accessibilité passé sur l'app (`app_screenshot`, Raycast…). `reunion` simule un appel et `partage-son` un écran : aucun vrai appel Meet, Teams ou Zoom n'est passé, et le son des autres apps n'est pas testé (macOS demanderait l'autorisation).

## Publier une version

Changer `MARKETING_VERSION` dans `project.yml`, puis :

```bash
./scripts/release.sh notes.md
```

Il faut d'abord créer le dépôt GitHub indiqué dans `Updater.repository` : tant qu'il n'existe pas, Nuri ne trouve aucune version. Pour distribuer l'app à d'autres Mac, il faudra une signature *Developer ID* et la notarisation.
