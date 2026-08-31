# Plan de remontée vers upstream

Dépôt amont : `witchtails/elixir-socket2` (remote `upstream`).
Fork : `neutrino38/elixir-socket` (remote `origin`).

## Situation de départ

Le fork est **18 commits en avance et 0 en retard**. La base commune est
`6a7134a` (« v2.1.3 »), qui est aussi la pointe d'upstream.

Conséquence pratique : chaque PR peut partir directement de `upstream/master`
sans rebase préalable. Aucun conflit avec du travail amont n'est possible
aujourd'hui.

État mesuré (Elixir 1.18.3 / OTP 26, la machine de développement) :

| | `mix format --check-formatted` | `mix compile --warnings-as-errors` | `mix test` |
|---|---|---|---|
| `upstream/master` | passe | **échoue** (5 sites) | non mesuré |
| fork `master` | passe | passe | 27 tests, 0 échec |

Deux remarques factuelles :

1. Upstream est déjà formaté. **Ne pas proposer de PR de formatage seul.** Le
   commit `7cb1381` n'a pas d'effet net sur `lib/socket.ex` par rapport à
   upstream ; ce qu'il reformate dans `web.ex` porte sur du code ajouté par le
   fork. Il se dissout dans les PR concernées.
2. La CI d'upstream tourne sur OTP 24 et Elixir 1.12.3 à 1.15.3. Nos mesures
   sont faites sur OTP 26 / Elixir 1.18.3. **Rien n'est vérifié sur la matrice
   d'upstream** : c'est le premier travail à faire (voir « Avant de soumettre »).

## Découpage proposé

Dix PR. L'ordre est un ordre de soumission : il va du risque nul vers le
risque réel, et chaque PR se justifie seule.

---

### PR 1 — Compiler sans avertissement

**Ce que ça corrige.** Upstream ne compile pas avec `--warnings-as-errors` sur
un Elixir récent. Sa propre CI le lui dira dès qu'elle montera de version.
Trois causes, toutes réelles :

- `Socket.Helpers.defbang` dépliait un `case` au site d'appel. Quand la
  fonction enveloppée a un type de retour plus étroit, une clause devient
  morte : « the following clause will never match » sur `Socket.TCP.accept!/1`,
  `accept!/2` et `Socket.Port.open!/1`, `open!/2`. Le dépliage part dans une
  fonction d'exécution, `Socket.Helpers.bang/1`.
- `Socket.Web.connect/3` a un `rescue` sur `Socket.TCP.Error` et
  `Socket.SSL.Error`. Ces deux modules n'existent pas. La clause ne peut jamais
  se déclencher. Elle est supprimée.
- `Socket.Web.accept/2` renvoie `{:error, e.code}` sur un `Socket.Error`, qui
  ne définit que `:message`. C'est un plantage à l'exécution, pas seulement un
  avertissement.

**Commits sources.** `9c9fb4d` (partie `helpers.ex`), `d7f7c38` (parties
`connect/3` et `accept/2`).

**Fichiers.** `lib/socket/helpers.ex`, `lib/socket/web.ex`.

**Ne pas inclure.** Les autres morceaux de `9c9fb4d` et `d7f7c38` touchent le
`defimpl Socket.Protocol` du fork, qui n'existe pas en amont. Ils partent en
PR 9.

**Test.** La CI d'upstream elle-même : ajouter `--warnings-as-errors` est déjà
dans son workflow. Le passage du rouge au vert est la preuve.

**Risque.** Nul. Aucun changement de comportement, sauf `e.code` → `e.message`
qui remplace un plantage par une valeur.

**Dépendances.** Aucune. À soumettre en premier.

---

### PR 2 — WebSocket : deux plantages sur des trames légales

**Prête.** Branche `fix/websocket-frame-crashes`, deux commits partant de
`upstream/master` : `7461b5b` (`forge/2`) et `a5f58b0` (`close_code/1`).
Description dans `pr-2-description.md`.

**Ce que ça corrige.**

- `forge/2` ne connaissait que `mask` à `nil` ou entier. `send/3` et `close/3`
  documentent pourtant une option `mask:`, et `mask: false` y est la façon de
  dire « trame non masquée », ce que la RFC 6455 §5.3 impose à un serveur.
  `false` tombait dans la clause de la clé et arrivait sur `Bitwise.bxor/2` :
  `send!(socket, {:text, "x"}, mask: false)` levait `ArithmeticError`.
- `close_code/1` n'accepte que les codes enregistrés. La RFC 6455 §7.4.2 laisse
  la plage 3000-4999 aux applications. La fonction sert des deux côtés du fil :
  fermer avec 4000 lève, et lire la fermeture propre d'un pair qui porte un tel
  code lève aussi.

**Commits sources.** `9c9fb4d` (partie `forge/2`), `d7c3f07` (la clause
`close_code(code) when is_integer(code)` seule).

**Fichiers.** `lib/socket/web.ex`, `test/web_test.exs` (nouveau, 5 tests).

**Tests.** `test/web_test.exs`, bloc `describe "passive mode"` : un aller-retour
binaire, un envoi avec `mask: false`, un message fragmenté, une fermeture avec
le code applicatif 4000 et une avec un code enregistré. Le harnais (`listen/0`,
`serve/2`) est repris tel quel par la PR 9.

Les deux mordent, c'est mesuré sur cette branche. En rétrécissant `forge/2` à sa
seule clause `nil`, le test `mask: false` échoue en `ArithmeticError`. En
retirant la clause de `close_code/1`, le test du code 4000 échoue en
`FunctionClauseError`.

**Attention à la justification de `forge/2`.** Contre upstream, « tout envoi
côté serveur plantait » est faux : `accept!` construit son `%W{}` sans champ
`:mask`, donc `mask` vaut `nil` et `forge(nil, …)` a sa clause. Le défaut
`mask: false` vient du `defstruct` réécrit par le fork, qui part en **PR 9**.
Sur upstream, le seul chemin atteignable est l'option `mask: false`, et c'est
lui que le test emprunte. Le « 15 tests sur 17 » mesuré au départ l'a été sur le
fork : il ne se transfère pas.

**Risque.** Faible. Élargissement de deux motifs, aucun rétrécissement.

**Dépendances.** Aucune, vérifié. Les zones touchées dans `web.ex` sont
disjointes de celles de la PR 1 (`connect/3` ~199 et `accept/2` ~447), `web.ex`
n'utilise pas `defbang`, et le harnais de test appelle `accept!/1`, jamais
`accept/2`. Les deux PR fusionnent dans n'importe quel ordre.

**État de la compilation.** `mix compile --warnings-as-errors` échoue sur cette
branche, avec exactement les neuf avertissements que porte déjà
`upstream/master`, aux mêmes endroits. C'est la PR 1 qui les traite.

---

### PR 3a — Adresse : lire un IPv6reference

**Ouverte en amont : #7.** Branche `fix/address-ipv6reference`, un commit
partant de `upstream/master` : `c7c649c`. Description dans
`pr-3a-description.md`.

**Ce que ça corrige.** `Socket.Address.parse/1` répondait `nil` sur
`"[::1]"`, la forme qu'une autorité d'URI ou un en-tête `Host` porte (RFC 3986
§3.2.2). Chaque appelant tenant une adresse issue d'une URI devait retirer les
crochets lui-même, et celui qui l'oubliait dialogue dans la mauvaise famille
sans diagnostic.

**Commits sources.** `bd15c41` (partie `address.ex`), `b5e7063`.

**Fichiers.** `lib/socket/address.ex` (12 lignes), `test/ipv6_test.exs`
(nouveau, 1 test).

**Tests.** Le test mord : sans la clause, `parse("[::1]")` rend `nil` et il
échoue.

**Risque.** Faible. `parse/1` répond sur une entrée où il répondait `nil` ;
`"[127.0.0.1]"` reste `nil`, seul l'IPv6 s'écrit ainsi.

**Dépendances.** Aucune. C'est la base des PR 4, 5 et 6.

**`to_uri_host/1` n'est plus ici.** La fonction n'a qu'un seul appelant dans
tout le fork, `web.ex:353`, qui est la PR 6. La sortir seule reviendrait à
demander au mainteneur d'accepter une fonction publique que personne n'appelle.
Elle voyage donc avec la PR 6.

### PR 4 — TCP et SSL : une adresse IP littérale est une adresse

**Prête.** Branche `fix/tcp-ip-literal`, deux commits posés **sur la branche de
la PR 3a** : `6e22ff2` (`tcp.ex`) et `5fa426a` (`ssl.ex`). Description dans
`pr-4-description.md`.

**Ce que ça corrige.** Passée en charlist à `:gen_tcp.connect/4`, une adresse
littérale part en résolution de nom dans la famille du socket. `"::1"` revient
donc `:nxdomain` sur un socket que personne n'a déclaré `:inet6`. Le tuple, lui,
porte sa famille. On analyse avant, on ne retombe en charlist que pour ce qui est
vraiment un nom d'hôte.

Corrige aussi le `@spec` de `connect/3` et `connect!/3` dans `tcp.ex`, qui
annonçaient déjà `:inet.ip_address()` sans que le code sache le traiter.

**Commits sources.** `b44613d` puis `bd15c41` (parties `tcp.ex` et la ligne de
`ssl.ex`). `bd15c41` réécrit la zone que `b44613d` avait touchée : les deux ne
sont pas rejoués, la zone est réécrite à la main.

**Fichiers.** `lib/socket/tcp.ex`, `lib/socket/ssl.ex`, `test/ipv6_test.exs`
(2 tests ajoutés).

**Tests.** Les deux mordent, mesuré. Sans le correctif `tcp.ex`, le test TCP
échoue sur `{:error, :nxdomain}`. Sans celui de `ssl.ex`, le test SSL lit
`:nxdomain` là où il attend autre chose.

Le test SSL lit un **échec**, pas un succès : aucun serveur TLS ne répond en
face. Avec le correctif la connexion se fait et la poignée de main expire
(`{:error, :timeout}`) ; sans lui l'appel ne quitte jamais le résolveur
(`{:error, :nxdomain}`). C'est cette différence qui est vérifiée. Un vrai
serveur TLS demanderait le PKI de la PR 8.

**Risque.** Faible, mais réel : un appelant qui aurait un nom d'hôte
ressemblant à une adresse IP change de chemin. En pratique, aucun nom d'hôte ne
ressemble à une adresse IP.

**Dépendances.** PR 3a, ouverte en amont sous le numéro **#7**. La branche part
de `fix/address-ipv6reference`, pas de `upstream/master` : la PR se soumet donc
avec `#7` pour base, ou après sa fusion.

---

### PR 5 — UDP et datagrammes en IPv6

**Prête.** Branche `fix/udp-ipv6`, deux commits posés **sur la branche de la
PR 4** : `e4ccdb3` (`datagram.ex`) et `21e9151` (`udp.ex`). Description dans
`pr-5-description.md`.

**Ce que ça apporte.** Deux points, deux commits dans une seule PR.

- `Socket.Datagram.send/3` accepte une destination sous toutes les formes de
  `Socket.Address.t()`, et un littéral part en tuple. La forme entre crochets
  d'une URI atteint donc son pair, et une destination littérale ne coûte plus
  aucune résolution, sur aucun datagramme.
- `Socket.UDP.open/2` accepte `v6only:`, qui se traduit en `ipv6_v6only`.
  C'était le dernier réglage IPv6 que l'enveloppe ne savait pas exprimer, et une
  option hors de son vocabulaire lève. L'appelant qui en avait besoin devait
  abandonner l'enveloppe pour `:gen_udp.open/2`, et perdre au passage l'adresse
  de bind et la traduction de famille.

Un socket IPv6 qui accepte aussi l'IPv4 reçoit de ces pairs sous
`::ffff:a.b.c.d`, et tout ce qui écrit une adresse de pair dans un message de
protocole porte ensuite cette forme. Seul le socket peut être réglé autrement.

**Commits sources.** `9f6d1a7`, `1551e30`.

**Fichiers.** `lib/socket/datagram.ex`, `lib/socket/udp.ex`,
`test/ipv6_test.exs` (2 tests ajoutés).

**Tests.** Les deux mordent, mesuré. Sans le correctif `datagram.ex` :
`sending to "[::1]" failed`. Sans la clause `udp.ex` :
`** (FunctionClauseError) no function clause matching in anonymous fn/1 in
Socket.arguments/1`.

**Un troisième test écarté.** « a UDP socket binds the address it is given »
(`local: [address: "[::1]"]`) passe déjà sans les changements de cette PR :
`Socket.UDP.arguments/1` appelait déjà `Socket.Address.parse/1`, donc ce test
mesure la PR 3a, pas celle-ci. Il ne prouve rien ici.

**Note.** Ne pas transformer ça en passe-plat générique.
`Socket.arguments/1` applique `put_new(:mode, :passive)` : un `{:active, true}`
brut arriverait à côté du `{:active, false}` dérivé de ce défaut, et l'ordre
déciderait du gagnant.

**Risque.** Faible. Deux élargissements, aucun rétrécissement.

**Dépendances.** PR 3a (#7) pour la forme entre crochets. La branche part de
`fix/tcp-ip-literal` (PR 4) et non de `fix/address-ipv6reference` : les deux PR
ajoutent des tests à la fin de `test/ipv6_test.exs`, et les enchaîner évite un
conflit au mainteneur. Le contenu, lui, ne dépend pas de la PR 4 : un rebase sur
`fix/address-ipv6reference` suffirait à l'en détacher.

---

### PR 6 — WebSocket : en-tête `Host` correct en IPv6

**Prête.** Branche `fix/websocket-host-ipv6`, un commit posé **sur la branche de
la PR 5** : `db8ad0c`. Description dans `pr-6-description.md`.

**Ce que ça apporte.** La poignée de main écrit `Host: [::1]:443` en IPv6, la
forme qu'une autorité d'URI porte (RFC 3986 §3.2.2). Sans les crochets,
l'en-tête donne `::1:443`, qu'aucun pair ne sait couper en adresse et port.

**Porte aussi `to_uri_host/1`**, qui rend la forme canonique (RFC 5952) entre
crochets pour l'IPv6 et laisse le reste tel quel. C'est la seule PR qui
l'appelle, elle l'apporte donc avec son appelant.

**Commits sources.** `bd15c41` (parties `web.ex` et `address.ex`), `b5e7063`
(partie `to_uri_host/1`).

**Fichiers.** `lib/socket/address.ex`, `lib/socket/web.ex`, `test/ipv6_test.exs`
(2 tests ajoutés).

**Tests.** Les deux mordent, mesuré. Le test de poignée de main lit l'en-tête
`Host` reçu côté serveur : sans la ligne de `web.ex`, `"::1:33845"` contre
`"[::1]:33845"`.

Le test de la branche fork faisait seulement un aller-retour de message. Il
passait sans le correctif : rien côté serveur ne relit `Host`. Il est remplacé
par celui-ci.

**Risque.** Nul en IPv4 : `to_uri_host/1` rend l'entrée inchangée.

**Dépendances.** PR 3a (#7) pour `parse/1`, et la PR 4 pour joindre `::1` en
TCP. La branche part de `fix/udp-ipv6` (PR 5) pour la même raison que les
précédentes : toutes ajoutent des tests à la fin de `test/ipv6_test.exs`.

---

### PR 7 — SSL : exposer `transport_accept`

**Ce que ça ajoute.** `accept/2` attend un client et fait la poignée de main
sous un seul délai. Un serveur ne peut pas s'en servir : l'attente d'un client
n'a pas de borne, alors qu'une poignée de main doit en avoir une, sinon un pair
qui se connecte puis se tait bloque la boucle d'acceptation aussi longtemps
qu'il veut. Avec un délai borné, le même appel répond `{:error, :timeout}` à
chaque intervalle creux, et une boucle d'acceptation ne peut pas distinguer ça
d'une vraie panne.

`:ssl` a toujours eu les deux étapes ; seule l'enveloppe les fusionnait.

Corrige aussi le `@spec` de `handshake/2`, qui annonçait `:ok` alors que la
fonction rend `{:ok, socket}`.

**Commits sources.** `825353d`.

**Fichiers.** `lib/socket/ssl.ex`, `test/ssl_test.exs` (2 tests).

**Risque.** Faible. Addition d'API ; `accept/2` passe par la nouvelle fonction
mais garde son comportement.

**Dépendances.** Aucune. Peut partir en parallèle des PR 3a à 6.

---

### PR 8 — SSL : le TLS mutuel, des deux côtés

C'est la PR la plus lourde, et celle qui demande le plus d'explications au
mainteneur amont. Trois manques, chacun mesuré sur une vraie poignée de main.

**1. Un serveur qui vérifie était inexprimable.** `verify: true` émettait
`customize_hostname_check`, qui est réservé au client. `:ssl` refusait donc le
`listen` avec `{:option, :client_only, :customize_hostname_check}`. La
vérification du nom devient une option à part, `hostname_check:`, que
`connect/3` fournit et qu'un `listen` ne voit jamais. Un serveur vérifie une
identité ; il ne vérifie pas un nom d'hôte.

**2. `fail_if_no_peer_cert` n'avait aucune orthographe.** Sans lui,
`verify_peer` sur un serveur ne fait que *demander* un certificat : un client
qui n'en présente aucun termine la poignée de main. C'est un écouteur mTLS qui
accepte les clients anonymes. `verify: :required` est la vérification plus
cette option.

**3. Nommer une autorité ne remplaçait pas le magasin de confiance.**
`connect/3` posait le paquet public `:certifi` sans condition, et `:ssl` laisse
`cacerts` écraser `cacertfile` en silence. Un appelant nommant sa CA privée
recevait le paquet public **à la place**. Ce n'est pas une vérification
affaiblie : le mTLS contre une CA privée ne pouvait pas fonctionner. Le paquet
devient un défaut, appliqué seulement si ni `:authorities` ni `:cacerts` n'a
été donné. Passer les deux continue de faire confiance aux deux.

Au passage, les défauts client existaient en double et une copie avait dérivé :
le chemin adresse/port, celui que tout appelant emprunte, n'avait jamais reçu
les deux premières corrections. Ils sont une seule fonction.

**Ce point est un changement de comportement visible.** Un appelant qui passe
`authorities:` et comptait sur le paquet public en plus voit sa confiance se
réduire. C'est l'intention, mais **il faut l'annoncer explicitement dans la
description de la PR** et laisser le mainteneur décider s'il veut une version
majeure.

**Commits sources.** `eb1b083`, `2cf1140`.

**Fichiers.** `lib/socket/ssl.ex`, `test/mtls_test.exs` (7 tests),
`test/support/test_pki.ex`, `test/test_helper.exs`.

**Tests.** Une vraie CA, un certificat serveur et un certificat client qu'elle
a signés, et un qu'elle n'a pas signé. Le PKI est généré par `openssl` dans un
répertoire temporaire à chaque exécution : aucun matériel de clé dans le dépôt,
aucun certificat qui expire à une date que personne ne surveille. Les tests sont
exclus, et non échoués, là où `openssl` est absent.

**Dépendances.** PR 7, pour l'ordre de cherry-pick dans `ssl.ex`. Le contenu
lui-même est indépendant.

---

### PR 9 — WebSocket : le mode actif

La plus grosse, la plus risquée, et la moins prête. À garder pour la fin.

**Ce que ça ajoute.** Réception des données en messages Erlang
(`{:web, socket, data}`), keepalive automatique, `defimpl Socket.Protocol` pour
`%Socket.Web{}`, options `mode: :active` et `process: pid`.

Le commit `d7c3f07` complète la boucle de lecture : elle ne traitait que quatre
formes de retour de `recv/2` sur les huit possibles. Un pong, une trame
binaire, un message fragmenté (§5.4) et **toute fermeture propre** levaient
`CaseClauseError`, ce qui tuait le processus lecteur — et avec lui une
connexion en bonne santé, puisque le propriétaire le surveille. Le pong répondant
à un ping porte maintenant les données du ping, comme §5.5.3 l'exige : un pong
vide fait conclure à un pair qui compare son propre témoin que la connexion est
morte.

**Commits sources.** `e814e8a`, `e013d80`, `d7f7c38` (reste), `9c9fb4d`
(reste), `d7c3f07` (reste), `7cb1381` (reformatage de ces ajouts), et pour le
README `d53ac3c`, `c14cadc`, `97f4b66`.

**Fichiers.** `lib/socket/web.ex`, `README.md`.

**Tests.** Écrits, dans `test/web_test.exs`, bloc `describe "active mode"` :
texte, binaire, réassemblage d'un message fragmenté, ping répondu par un pong
portant le même témoin, pong remonté au propriétaire, fermeture propre avec sa
raison, disparition du pair sans trame de fermeture, et survie du lecteur à une
trame qu'il ne transmet pas.

Ils mordent : en remettant `lib/socket/web.ex` dans son état d'avant `d7c3f07`,
8 tests sur 13 échouent.

**Ce qui reste à régler avant de soumettre.**

1. **Le socket porté par les messages n'est pas celui que `connect!` rend.**
   `active/2` lance le lecteur avec `spawn(fn -> active_websocket_process(self) end)`
   *avant* de poser `active_pid` dans la struct. Le lecteur travaille donc sur une
   copie où `active_pid` vaut `nil`, et c'est cette copie qu'il met dans
   `{:web, socket, data}`. Un propriétaire qui suit plusieurs sockets ne peut pas
   filtrer sur celui qu'il détient — or c'est exactement ce que le README montre.
   Mesuré : les tests ont dû s'ancrer sur le transport (`%Socket.Web{socket: ^transport}`)
   au lieu du socket entier.
2. **`active(self, false)` n'arrête rien.** Elle envoie `:stop` au lecteur, mais
   le lecteur est bloqué dans `recv/2` et ne lit jamais sa boîte aux lettres. Le
   processus continue de tourner et de livrer des messages. Aucun test ne le
   couvre : en écrire un ferait échouer la suite, et corriger le défaut dépasse
   ce qui était demandé.
3. **`Socket.Protocol.accept/2`** est réimplémenté avec un argument par défaut
   dans le `defimpl`. À relire : le protocole déclare déjà le défaut.

**Régression corrigée.** Le passage à la syntaxe `defstruct` par mots-clés avait
écrit `headers: {}` là où upstream a `headers: %{}` : un tuple vide, pas une
carte vide, et tout accès `socket.headers["x"]` sur un socket issu de `connect`
levait. Corrigé et replié dans `e814e8a` avec son test de non-régression, dans
`test/socket_test.exs`.

**Dépendances.** PR 1 et PR 2, dont elle réutilise le terrain dans `web.ex`.

---

### PR 10 — Rendre la suite de tests fiable

Cette PR ne vient pas du fork. Elle corrige un défaut d'upstream, découvert en
faisant tourner sa suite.

**Ce que ça corrige.** `test/socket_test.exs` lance son serveur avec
`Task.start_link(fn -> server(12_345) end)` puis se connecte tout de suite. Rien
ne garantit que le `listen` a eu lieu quand le client compose. Mesuré :
**4 échecs sur 25 exécutions**, répartis sur `test "connect path"` et
`test "env"` (`test/port_test.exs`), avec `** (Socket.Error) connection refused`.

Le remède tient en trois lignes par test : créer l'écouteur dans le processus de
test avec `Socket.Web.listen!(0)`, lire le port avec `Socket.local!/1`, et ne
lancer la tâche qu'ensuite. C'est le motif déjà employé par `test/ipv6_test.exs`
et par `test/web_test.exs`.

**Fichiers.** `test/socket_test.exs`, `test/port_test.exs`.

**Pourquoi la sortir en premier.** Une CI qui échoue une fois sur six apprend au
mainteneur à relancer sans lire. Toutes les autres PR passent par cette CI.

**Risque.** Nul. Aucun code de production touché.

**Dépendances.** Aucune. À soumettre avec la PR 1, ou juste après.

---

## Correspondance commits → PR

| Commit | PR |
|---|---|
| `b44613d` Added the ability to directly specify an IP address | 4 |
| `e814e8a` Active web socket implemenation | 9 |
| `d53ac3c` Improved WebSocket doc | 9 |
| `c14cadc` Small formatting | 9 |
| `97f4b66` Update README.md. Typo | 9 |
| `203bc0e` Merge branch master into feat/active-ws | — (fusion, à ne pas rejouer) |
| `d7f7c38` Fix error tuples in accept/connect | 1 et 9 (à couper) |
| `e013d80` removed some warning | 9 |
| `9c9fb4d` Fix websocket bugs and silence warnings | 1, 2 et 9 (à couper) |
| `7cb1381` Run mix format on the codebase | 9 (se dissout ; sans effet net ailleurs) |
| `d7c3f07` Active reader: handle every frame | 2 et 9 (à couper) |
| `bd15c41` IPV6 compatibility | 3a, 4 et 6 (à couper) |
| `b5e7063` Address: parse an IPv6reference | 3a et 6 (à couper) |
| `9f6d1a7` Datagram: a destination given as an IP literal | 5 |
| `1551e30` UDP: a v6only option | 5 |
| `825353d` SSL: expose transport_accept | 7 |
| `eb1b083` SSL: what mutual TLS needs, on both ends | 8 |
| `2cf1140` format: run mix format on the two files | 8 |

Quatre commits doivent être coupés. Le plus simple est de ne pas les
cherry-picker : partir de `upstream/master`, ouvrir le fichier au bon endroit et
réappliquer à la main le morceau qui appartient à la PR. Les diffs sont petits.

## Avant de soumettre quoi que ce soit

1. **Vérifier sur la matrice d'upstream.** Sa CI teste OTP 24 avec Elixir
   1.12.3, 1.13.3, 1.14.3 et 1.15.3. Nous avons mesuré sur OTP 26 / Elixir
   1.18.3. Deux points concrets à contrôler : les tests mTLS (le comportement
   TLS 1.3 d'OTP 24 n'est pas celui d'OTP 26) et `--warnings-as-errors` (les
   avertissements de typage qui échouent chez nous n'existent qu'à partir
   d'Elixir 1.17). Le fichier `.tool-versions` du dépôt annonce 1.15.7, ce qui
   n'est pas la version installée ici.
2. ~~Corriger la régression `headers: {}`~~ — fait, replié dans `e814e8a`.
3. ~~Écrire les tests WebSocket des PR 2 et 9~~ — fait. Le bloc
   `describe "passive mode"` et le harnais sont dans la branche
   `fix/websocket-frame-crashes`. **Le bloc `describe "active mode"` (8 tests)
   n'est pas encore dans le dépôt** : il est à réécrire ou à récupérer au moment
   de préparer la PR 9, avec le même harnais.
4. **Relire l'asymétrie de `Socket.SSL.handshake/2`** (PR 8) : les défauts
   client sont posés dans `connect/3`, pas dans `arguments/1`. Un client qui
   diffère sa poignée de main et appelle `handshake(socket, verify: true)`
   n'obtient donc pas `hostname_check`, et perd le contournement des noms
   génériques. À décider : documenter, ou poser le défaut aussi là.
5. **Traiter l'instabilité de la suite** (PR 10) avant de demander à qui que ce
   soit de regarder une CI.
6. **Décider de la stratégie de soumission** avec le mainteneur. Dix PR d'un
   coup sur un dépôt peu actif, c'est beaucoup. Ouvrir d'abord les PR 1 et 10 :
   elles rendent sa CI verte et fiable, ne changent aucun comportement, et sa
   réponse dira à quel rythme envoyer la suite.

## Note sur les commandes

Le `README.md` ne documente pas les commandes de compilation et de test. Elles
ont été lues dans `.github/workflows/test.yml` :

```
mix deps.get
mix compile --warnings-as-errors
mix format --check-formatted
mix test
```

Les ajouter au README serait une petite PR utile en soi.
