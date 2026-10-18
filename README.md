# Busenfreunde

Kleine PWA für zwei (oder mehr) Kumpels: Ausflüge und Kochabende gemeinsam planen.

- **Kalender** mit Monatsansicht und „Demnächst“-Liste
- **Ideen** für „irgendwann mal“: Einträge ohne Datum, per „Einplanen“ in den Kalender
- **Kommentare** an jedem Eintrag
- **Titelbild** der Gruppe, liegt in einem privaten Speicher (nur nach Login sichtbar)

Live: https://schrontz.github.io/busenfreunde/

## Aufbau

- `index.html`: die ganze App (HTML, CSS, JS in einer Datei)
- `manifest.webmanifest`, `icon*.{svg,png}`: Installierbarkeit als App
- `supabase/busenfreunde_v1.sql`: Datenbank-Schema

## Backend

Läuft im Supabase-Projekt von Nest, aber komplett getrennt:

- eigene Tabellen mit Präfix `bf_` (Gruppen, Mitglieder, Einträge, Kommentare)
- Zugriff nur für Gruppenmitglieder (RLS); Nest-Daten sind für Busenfreunde-Mitglieder unsichtbar und umgekehrt
- geteilt wird nur das Konto (Login) und das Profil (Anzeigename)
- Bilder im privaten Bucket `busenfreunde`, Pfad `<gruppe_id>/…`

Datenmodell: Ein Eintrag **ohne Datum ist eine Idee**, mit Datum ein Termin.

## Ideen für Version 2

- Push-Benachrichtigungen für Termine
- Vorlauf-Erinnerungen (z. B. Sauerbraten drei Tage vorher einlegen)
