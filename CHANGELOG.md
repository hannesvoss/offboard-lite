# Changelog — husky-offboard-lite

Was sich wann geändert hat. Der aktuelle Stand steht in der [README](README.md).

Das Format folgt [Keep a Changelog](https://keepachangelog.com/de/1.1.0/),
die Versionierung [Semantic Versioning](https://semver.org/lang/de/).

## [Unreleased]

### Behoben
- **"Clear octomap" rief den Dienst unter dem falschen Namen.** Das
  MotionPlanning-Plugin haengt "Move Group Namespace" an jeden seiner
  Service-Clients -- ausser an den fuer `clear_octomap`. Am 2026-08-20 am
  laufenden RViz nachgemessen (`ros2 node info /rviz`): vier Clients auf
  `/a200_0553/...`, einer auf dem globalen `/clear_octomap`. Der Server sitzt
  unter `/a200_0553/clear_octomap`, der Knopf endete also in
  "Failed to call clear_octomap_service". Ein `-r`-Remap zieht den Client auf
  den Namen des Servers, wie es fuer `/tf` schon geschah.

  Im Container-Mock faellt das nicht auf: der Knopf ist grau, solange die
  Planungsszene keine Octomap traegt (gemessen: kein octomap-Knoten, Octomap im
  `monitored_planning_scene` mit leerem Stempel). Am Roboter fuettert
  `octomap_feed` sie -- deshalb kam die Meldung aus `husky-offboard-lite`,
  obwohl beide Images dieselbe RViz-Config benutzen.

### Doku-Abgleich
- **Die Modellquelle stand falsch in Skript und README.** Beide sagten, das
  URDF komme vom `robot_state_publisher`. `moveit-rviz` fragt seit laengerem
  zuerst den `move_group`: er ist der Knoten, der mit dem Modell PLANT, was er
  ausliefert ist also per Definition das Modell, gegen das die Goals laufen --
  und das SRDF gibt es ohnehin nur dort. Der `robot_state_publisher` bleibt
  Fallback fuers URDF, als Vorsicht gegen ein Teil-URDF. Am 2026-08-20 im
  Container-Mock nachgemessen sind beide Quellen gleich gross (49691 Bytes),
  eine Abweichung am echten Roboter ist hier also nicht belegt.
- **Woher das Greifermodell kommt, stand nirgends.** Die README sagt jetzt,
  dass Planungsgruppe, Named States und Kollisionsmatrix des Greifers aus der
  SRDF des ROBOTERS stammen, also aus dessen `rg6_moveit_patch` -- dieses
  Image baut nur `rg6_description` fuer die Meshes. Wer hier eine
  Greiferstellung nicht geplant bekommt, sucht auf dem Roboter, nicht im
  Container.
- **Die Aussage zu `clearlog.sh` war ein Datumsversprechen.** Sie behauptete,
  die Datei sei "noch nicht" im gepushten GHCR-Base, weil die CI nicht neu
  gebaut habe. Nachgemessen ist die GHCR-Base vom 2026-08-05 08:49 UTC und der
  clearlog-Commit vom selben Tag 08:44 UTC. Statt das Datum zu pflegen steht
  dort jetzt der Ist-Zustand: `moveit-rviz` sourct die Datei, wenn die Base sie
  traegt, und definiert sonst `echo`-Ersatz -- es startet so oder so. Der
  Verweis auf `scripts/moveit-rviz:13-22` ist weg; die Zeilennummern waren
  laengst verrutscht (der Block stand bei 17-26).
- **Die eigene Source-Kette ist als Absicht benannt.** Sie sieht neben dem
  `scripts/ros-env` des grossen `husky-offboard` wie eine vergessene Kopie
  aus, ist aber keine: dort sind es drei Overlays und `RMW_IMPLEMENTATION`
  muss um das generierte `/clearpath/setup.bash` herumgerettet werden. Dieses
  Image hat weder `clearpath_ws` noch `/clearpath` -- zwei Overlays sind hier
  die vollstaendige Kette, und `rmw_zenoh` ist der richtige Default.

## [0.2.0] - 2026-08-19

- **SemVer eingeführt.** Version auf `0.2.0`, dieses Changelog folgt
  [Keep a Changelog](https://keepachangelog.com/de/1.1.0/), Tag `v0.2.0`.
  Ältere Abschnitte behalten ihre Datumsüberschrift — ihnen nachträglich
  Versionsnummern zu geben, würde eine Release-Historie erfinden.
- **README nach dem Workspace-Schema** (readme.so): Features · Tech Stack ·
  Installation · Usage · Running Tests · Related · Versioning · License. Die
  vorhandene Prosa ist erhalten und unter den passenden Abschnitt gewandert.

---

**Vor der Einführung von SemVer (2026-08-19)** wurde nach Datum geführt.

## 2026-08-06

- clearlog im Container übernommen, Logwachstum gedeckelt.

