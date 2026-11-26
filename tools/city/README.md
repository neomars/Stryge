# Cartes réelles de Paris — convertisseur

Ce dossier fabrique les cinq secteurs du jeu (`data/cities/*.json`, format `pnc-city-2`) à partir de données
géographiques réelles de Paris et de la petite couronne. Le jeu lit seulement les JSON ; ces scripts ne servent
qu'à les régénérer.

## Sources (lecture seule, extraits tiers hébergés sur GitHub)

| Donnée | Fichier utilisé | Origine | Licence |
|---|---|---|---|
| Bâtiments (emprises, hauteurs), monuments, eau | `paris.bin` (format « PRS2 ») dans le dépôt `nave20/foundry-wod-control-room`, commit `add26b25a747970d10f18c77a440f45310ac6211` | IGN BD TOPO | Licence Ouverte 2.0 |
| Rues, ponts, parcs, eau (Paris + zone de La Défense) | `paris-osm.bin` (format « PAO3 ») dans `kik0s/paris-map-template`, commit `a1cf0d625f412fd70c341a2fe34ea1d4e91041b3` | OpenStreetMap | ODbL — © contributeurs OpenStreetMap |
| Stations de métro (lignes 1 à 6 et 14) | `metro/line_*.json` dans `atom-84/fluctuat-nec-mergitur-d3`, commit `1406a5d7063faf6fe3a4b6218309788d18cb090a` (données de 2016) | non précisée | aucune licence dans le dépôt : seules les **positions** des stations sont utilisées (faits géographiques) |

Les noms de repères (`landmarks.py`) sont écrits à la main ; un repère n'est conservé que si une donnée réelle (bâtiment,
parc ou plan d'eau) existe à proximité.

## Régénérer

```
pip install numpy scipy shapely pyproj mapbox-earcut numba scikit-image opencv-python-headless networkx skan matplotlib
python3 tools/city/make_city.py                      # les 5 secteurs -> data/cities/
python3 tools/city/make_city.py halles --preview /tmp/apercus   # un secteur + image d'aperçu
```

Les chemins des sources se règlent avec `--prs`, `--osm`, `--metro` (ou les variables `PNC_PRS`, `PNC_OSM`, `PNC_METRO`).
La génération est déterministe (graines dans `CFG`) : mêmes sources, mêmes fichiers.

## Ce que fait le convertisseur

1. **Bâtiments** : chaque emprise est décomposée en rectangles orientés (rectangle minimal si l'emprise est assez
   rectangulaire, sinon extraction gloutonne de rectangles maximaux sur une grille de 1 m). Les monuments (Notre-Dame,
   Louvre, Sacré-Cœur, Opéra…) sont fusionnés depuis la couche `monuments`, qui n'est pas dans `batiments`.
2. **Rues** : les tracés OSM sont noeudés (jonctions en T forcées, ponts rattachés), simplifiés, élagués ; la largeur
   de chaussée est estimée par la distance aux bâtiments. Hors de la zone couverte par l'extrait OSM (Saint-Denis,
   Aubervilliers, Puteaux…), les rues sont **déduites des vides entre bâtiments** (squelette des espaces libres) : elles
   sont donc approximatives, à la différence de celles de Paris intra-muros.
3. **Eau et parcs** : maillages triangulés (earcut) dessinés comme sols colorés ; îles de la Seine conservées.
4. **Occupants** : calculés d'après la surface et le nombre d'étages, avec des multiplicateurs par secteur (`CFG`) réglés pour
   l'équilibrage (La Défense est moins peuplée : 24 occupants au plus par tour). Ce sont des valeurs de **jeu**, pas des données de population.
5. **Stade de France** : l'anneau est reconstitué en tribunes (4 bâtiments de 100, 100, 70 et 70 occupants, `STAND_OCC` ;
   les assauts du secteur 5 les visent grâce à `min_occ` 60 dans `data/mission_05.json`).
6. **Points d'évacuation** (9 par secteur), **bouches de métro** (8 par secteur), **repères nommés**. Le jeu ne se joue que dans une **zone de 600 m de rayon** (clé `zone` des missions ; centre décalé de 300 m vers le nord pour le Stade de France, entouré d'un grand vide) : `rezone.py` place donc les points d'évacuation (grille 3 × 3 resserrée) et les bouches de métro dans cette zone. Les bouches sont les vraies stations des lignes 1 à 6 et 14 qui s'y trouvent (une ou deux bouches par station, avec leur nom), complétées par des carrefours sans nom : La Défense n'a qu'une station dans ces lignes, le Stade de France aucune (sa station est sur le RER B). `python3 rezone.py` corrige les cartes déjà converties sans refaire la conversion (déterministe, idempotent).

## Limites connues

- Les hauteurs viennent de la BD TOPO (précision de l'ordre du mètre) ; les toits sont plats (boîtes).
- Les rectangles remplacent les formes réelles : la fidélité est celle d'une vue thermique à 2 500 – 3 000 m d'altitude.
- Les rues déduites (Stade de France, périphérie de La Défense) ne sont pas les vraies rues ; les grands ensembles et
  les voies ferrées peuvent y apparaître comme de simples chemins.
- Les stations de métro sont celles de 2016, lignes 1 à 6 et 14 uniquement.
