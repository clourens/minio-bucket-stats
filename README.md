# MinIO Bucket Statistics

`minio-bucket-stats.sh` geeft een overzicht van opslag- en gebruiksstatistieken van één MinIO S3-bucket.

## Vereisten

- Bash
- MinIO Client (`mc`)
- `jq`
- optioneel `numfmt` voor leesbare KiB/MiB/GiB/TiB-waarden

Controleer de installatie:

```bash
mc --version
jq --version
```

## MinIO alias aanmaken

```bash
mc alias set minio https://minio.example.nl ACCESSKEY SECRETKEY
mc alias list
mc ls minio
mc stat minio/backups
```

> Access- en secret keys zijn credentials. Zet ze niet in scripts, Git-repositories of documentatie.

## Script installeren

```bash
chmod +x minio-bucket-stats.sh
./minio-bucket-stats.sh --help
```

## Gebruik

```bash
./minio-bucket-stats.sh <alias> <bucket>
./minio-bucket-stats.sh --top 30 minio backups
./minio-bucket-stats.sh --no-objects minio backups
./minio-bucket-stats.sh --traffic-only minio backups
./minio-bucket-stats.sh --json minio backups
./minio-bucket-stats.sh --json --include-objects minio backups
```

## Opties

| Optie | Betekenis |
|---|---|
| `-h`, `--help` | Toon ingebouwde help |
| `-t N`, `--top N` | Toon de N grootste objecten; standaard 15 |
| `--no-objects` | Sla de volledige recursieve objectinventarisatie over |
| `--traffic-only` | Toon alleen API- en dataverkeerstatistieken |
| `--json` | Machine-leesbare JSON-output |
| `--include-objects` | Voeg alle objecten met metadata toe aan de JSON-output; vereist `--json` |
| `--version` | Toon de scriptversie |

## Beschikbare statistieken

Een volledige run toont onder meer huidig bucketgebruik, gebruik inclusief versies indien beschikbaar, aantal objecten, totale en gemiddelde objectgrootte, kleinste/grootste object, object-size distribution en opslag per top-level prefix. Daarnaast worden versioning, lifecycle/ILM en quota opgevraagd.

Als MinIO Prometheus v3 metrics toegankelijk zijn, toont het script ontvangen en verzonden bytes, 4xx/5xx errors en counters voor veelgebruikte S3 API-operaties.

## Grote buckets

Een volledige objectanalyse gebruikt:

```bash
mc ls --recursive --json
```

Bij miljoenen objecten kan dit lang duren. Gebruik dan eerst:

```bash
./minio-bucket-stats.sh --no-objects minio backups
```

## Trafficmetrics

Het script gebruikt hiervoor een commando in deze vorm:

```bash
mc admin prometheus metrics minio api \
    --bucket backups \
    --api-version v3
```

Dit kan aanvullende adminrechten vereisen.

## JSON

```bash
./minio-bucket-stats.sh --json minio backups | jq .
./minio-bucket-stats.sh --json minio backups | jq '.storage.total_bytes'
./minio-bucket-stats.sh --json minio backups | jq '.traffic.sent_bytes'
```

### Alle objecten in JSON

Om naast de samenvatting ook ieder object in de bucket op te nemen:

```bash
./minio-bucket-stats.sh --json --include-objects minio backups > bucket-stats.json
```

De JSON bevat dan een `objects`-array. Per object worden, waar beschikbaar, onder meer de key, grootte in bytes, laatste wijzigingsdatum, ETag en type opgenomen.

Bijvoorbeeld:

```json
{
  "objects": [
    {
      "key": "backup/database.sql.gz",
      "size_bytes": 123456789,
      "last_modified": "2026-10-01T10:30:00Z",
      "etag": "...",
      "type": "file"
    }
  ]
}
```

Deze optie kan grote JSON-bestanden opleveren en vereist een volledige recursieve objectlisting. Daarom kan `--include-objects` niet samen met `--no-objects` of `--traffic-only` worden gebruikt.

## Historische statistieken

Het script is bedoeld voor ad-hoc analyse en actuele/cumulatieve statistieken. Voor vragen zoals dataverkeer per dag, storagegroei per week of requests per uur moeten de MinIO-metrics historisch worden opgeslagen, bijvoorbeeld met Prometheus en gevisualiseerd met Grafana.

```text
S3 clients
    |
    v
+---------+
|  MinIO  |
+----+----+
     | metrics
     v
+------------+
| Prometheus |
+-----+------+
      |
      v
+---------+
| Grafana |
+---------+
```
