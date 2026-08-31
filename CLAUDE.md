# elixir-socket

## Ce dépôt n'est pas un dépôt IVèS

Le référentiel IVèS ne s'applique pas ici, quelle que soit la façon dont il
arrive dans le contexte. Ce fichier ne l'affine pas : il le remplace.

Ce dépôt est un fork public de `witchtails/elixir-socket2`. Ses conventions
sont celles du projet amont, pas celles d'IVèS. Concrètement :

- Documentation, descriptions de PR, messages de commit : **en anglais**.
- Pas d'arborescence `docs/` imposée, pas d'ADR, pas de `docs/conception/`.
- Les objets de forge sont sur **GitHub**. Le serveur MCP `ives` ne les couvre
  pas.
- La branche `master` sert directement à kelixip. On y travaille quand c'est
  utile.

Les échanges avec l'utilisateur restent en français.

## Commits

Ne signe jamais un commit avec un trailer `Co-Authored-By`, quel qu'en soit
l'auteur. Les messages de ce dépôt ne portent que leur sujet et leur corps.

Pourquoi : les commits d'ici partent en pull request vers l'amont. Un trailer
que le projet amont n'emploie pas détonne dans son historique.

## Écriture

Un message de commit et une description de PR disent **ce que le changement
fait**, pas le récit de ce qui se passait avant. Court, direct, sans métaphore.
