"""Repères nommés par secteur (positions approximatives, recalées sur les données au moment de la génération).

kind : monument / gare / stade (accroché au plus gros bâtiment proche), parc (doit tomber dans un parc OSM),
       eau (doit tomber dans l'eau), place (libre), auto_eau (points répartis dans la plus grande nappe d'eau du secteur).
Un repère sans donnée à proximité est écarté à la génération : mieux vaut pas de nom qu'un faux nom.
"""
LANDMARKS = {
    "quartier_latin": [
        {"name": "Notre-Dame", "lon": 2.34998, "lat": 48.85296, "kind": "monument", "min_area": 800},
        {"name": "Panthéon", "lon": 2.34645, "lat": 48.84625, "kind": "monument", "min_area": 800},
        {"name": "La Sorbonne", "lon": 2.34300, "lat": 48.84870, "kind": "monument", "min_area": 1500},
        {"name": "Jardin du Luxembourg", "lon": 2.33710, "lat": 48.84640, "kind": "parc", "r": 300},
        {"name": "Place Saint-Michel", "lon": 2.34390, "lat": 48.85335, "kind": "place"},
        {"name": "Institut du monde arabe", "lon": 2.35610, "lat": 48.84920, "kind": "monument", "min_area": 1500},
        {"name": "Jardin des Plantes", "lon": 2.35970, "lat": 48.84380, "kind": "parc", "r": 260},
        {"name": "Hôtel de Ville", "lon": 2.35220, "lat": 48.85660, "kind": "monument", "min_area": 1500},
        {"name": "Palais de Justice", "lon": 2.34510, "lat": 48.85530, "kind": "monument", "min_area": 1500},
        {"name": "Île Saint-Louis", "lon": 2.35650, "lat": 48.85170, "kind": "place"},
        {"name": "La Seine", "lon": 0, "lat": 0, "kind": "auto_eau", "r": 230},
    ],
    "montmartre": [
        {"name": "Sacré-Cœur", "lon": 2.34310, "lat": 48.88670, "kind": "monument", "min_area": 800},
        {"name": "Place du Tertre", "lon": 2.34080, "lat": 48.88650, "kind": "place"},
        {"name": "Moulin Rouge", "lon": 2.33230, "lat": 48.88410, "kind": "monument", "min_area": 120},
        {"name": "Gare du Nord", "lon": 2.35530, "lat": 48.88090, "kind": "gare", "min_area": 2000},
        {"name": "Cimetière de Montmartre", "lon": 2.33000, "lat": 48.88770, "kind": "parc", "r": 200},
        {"name": "Place Pigalle", "lon": 2.33740, "lat": 48.88220, "kind": "place"},
        {"name": "Place des Abbesses", "lon": 2.33850, "lat": 48.88440, "kind": "place"},
        {"name": "Place de Clichy", "lon": 2.32770, "lat": 48.88370, "kind": "place"},
        {"name": "Barbès", "lon": 2.34950, "lat": 48.88350, "kind": "place"},
    ],
    "halles": [
        {"name": "Forum des Halles", "lon": 2.34600, "lat": 48.86250, "kind": "monument", "min_area": 1500},
        {"name": "Saint-Eustache", "lon": 2.34530, "lat": 48.86340, "kind": "monument", "min_area": 600},
        {"name": "Centre Pompidou", "lon": 2.35220, "lat": 48.86060, "kind": "monument", "min_area": 2000},
        {"name": "Musée du Louvre", "lon": 2.33760, "lat": 48.86060, "kind": "monument", "min_area": 3000},
        {"name": "Palais-Royal", "lon": 2.33720, "lat": 48.86370, "kind": "monument", "min_area": 1000},
        {"name": "Opéra Garnier", "lon": 2.33160, "lat": 48.87200, "kind": "monument", "min_area": 2000},
        {"name": "Bourse de Commerce", "lon": 2.34270, "lat": 48.86280, "kind": "monument", "min_area": 1000},
        {"name": "Palais Brongniart", "lon": 2.34150, "lat": 48.86890, "kind": "monument", "min_area": 800},
        {"name": "Place des Victoires", "lon": 2.34110, "lat": 48.86580, "kind": "place"},
        {"name": "Bibliothèque nationale", "lon": 2.33690, "lat": 48.86790, "kind": "monument", "min_area": 1500},
        {"name": "Châtelet", "lon": 2.34700, "lat": 48.85840, "kind": "place"},
    ],
    "defense": [
        {"name": "Grande Arche", "lon": 2.23580, "lat": 48.89180, "kind": "monument", "min_area": 1500},
        {"name": "Parvis de La Défense", "lon": 2.23900, "lat": 48.89210, "kind": "place"},
        {"name": "La Seine", "lon": 0, "lat": 0, "kind": "auto_eau", "r": 230},
    ],
    "stade": [
        {"name": "Stade de France", "lon": 2.36010, "lat": 48.92450, "kind": "stade", "min_area": 4000, "r": 200},
        {"name": "Canal Saint-Denis", "lon": 0, "lat": 0, "kind": "auto_eau", "r": 200},
    ],
}
