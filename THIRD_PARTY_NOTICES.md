# Licences des composants tiers

La licence MIT du fichier `LICENSE` couvre le **code** et le **contenu original** de Stryge. Elle ne remplace pas les
licences ci-dessous : elles restent applicables aux données et aux composants concernés, y compris dans les exécutables
(`.exe`, `.deb`, `.dmg`) qui les embarquent.

## Moteur Godot (embarqué dans chaque exécutable)

Godot Engine 4.7.2, https://godotengine.org.

> Copyright (c) 2014-present Godot Engine contributors.
> Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.
>
> Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
> documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
> rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit
> persons to whom the Software is furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all copies or substantial portions of the
> Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
> WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
> COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
> OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

Le moteur contient lui-même des composants tiers sous d'autres licences. Leur liste complète est dans les fichiers
`COPYRIGHT.txt` et `LICENSE.txt` du dépôt `godotengine/godot` (étiquette `4.7.2-stable`).

## Cartes de Paris (`data/cities/*.json`)

Ces fichiers sont des **données dérivées** : ils restent soumis aux licences de leurs sources, pas à la licence MIT.

| Donnée | Origine | Licence |
|---|---|---|
| Bâtiments (emprises, hauteurs), monuments, eau | IGN, BD TOPO | Licence Ouverte 2.0 |
| Rues, ponts, parcs, eau (Paris et La Défense) | OpenStreetMap | ODbL : © contributeurs OpenStreetMap |
| Positions des stations de métro (lignes 1 à 6 et 14, données de 2016) | extrait de dépôt GitHub tiers | **aucune licence indiquée** par ce dépôt : seules les positions sont utilisées |

Attribution à conserver si vous redistribuez le jeu : « Données : IGN BD TOPO (Licence Ouverte 2.0) ; © contributeurs
OpenStreetMap (ODbL) ». Les licences n'ont pas été vérifiées au-delà de ce que les dépôts sources indiquent : à contrôler
avant toute diffusion publique ou commerciale (en particulier l'effet de l'ODbL sur une base de données dérivée, et
l'absence de licence sur les positions du métro).

## Voix de la radio (`audio/radio/voices.wav`)

Voix de synthèse produites avec Piper (https://github.com/rhasspy/piper), à partir des modèles français
`fr-siwis-medium` et `fr-gilles-low`, puis déformées (voir `tools/audio/make_voices.py`). Chaque modèle de voix a sa propre
licence, liée à son jeu de données d'entraînement : **à vérifier sur la fiche de chaque modèle avant toute diffusion
commerciale**. Ce contrôle n'a pas été fait.

## Sons des armes (`audio/sfx/`)

Synthétisés par `tools/audio/make_sfx.py` : aucun échantillon tiers.
