# mobilizon-helm

A minimal Helm chart for [Mobilizon](https://mobilizon.org). No subcharts or external chart dependencies: one Deployment for Mobilizon and, optionally, one PostGIS StatefulSet.

```sh
helm install mobilizon ./charts/mobilizon \
  --set mobilizon.host=events.example.org \
  --set ingress.enabled=true --set ingress.tlsSecretName=events-tls
```

Then create the first administrator:

```sh
kubectl exec deploy/mobilizon -- /bin/mobilizon_ctl users.new admin@example.org --admin --password 'change-me'
```

## What it deploys

| Object | Notes |
| --- | --- |
| Deployment | `kaihuri/mobilizon` (the official image, now maintained by Kaihuri). The image entrypoint waits for the database, creates `pg_trgm` and `unaccent`, runs migrations, then starts on port 4000. One replica with `Recreate`, because uploads are on a ReadWriteOnce volume. |
| PVC | Uploads at `/var/lib/mobilizon/uploads`. Kept on uninstall. |
| StatefulSet + Service | Bundled `postgis/postgis`, on by default. |
| Secret | Only for values you did not supply from an existing Secret. |
| Ingress / HTTPRoute | Off by default. |

Mobilizon always generates `https://<mobilizon.host>` URLs, so put TLS in front of it (Ingress, Gateway or another proxy).

## Using existing Secrets

Every credential can come from a Secret you already manage. Key names are configurable.

```yaml
mobilizon:
  existingSecret: mobilizon-keys        # keys: secret-key-base, secret-key
database:
  existingSecret: mobilizon-db          # key: password
smtp:
  enabled: true
  host: smtp.example.org
  existingSecret: mobilizon-smtp        # key: password
  secretKeys:
    username: username                  # optional: read the username from the Secret too
```

Anything the chart does not generate is left alone. When a value is neither set nor in an existing Secret, the chart creates it (random for the instance keys and database password) and reuses it on upgrade through `lookup`. `lookup` does not run under `helm template` or Argo CD, so use `existingSecret` there.

Generate the instance keys with, for example, `openssl rand -base64 48`.

## External PostgreSQL

Mobilizon needs PostgreSQL with the **PostGIS** extension; plain PostgreSQL fails on migrate.

```yaml
postgresql:
  enabled: false
database:
  host: mobilizon-db-rw.databases.svc
  existingSecret: mobilizon-db-app
  secretKeys:
    password: password
    username: username
```

The example above matches the `<cluster>-app` Secret of a CloudNativePG cluster. On an external server, create the `postgis` extension in the database beforehand (it needs a superuser), for example with CloudNativePG's `postInitApplicationSQL: ["CREATE EXTENSION IF NOT EXISTS postgis"]`.

## Other settings

Any other variable the image reads (see `config.exs` in the image, for example `MOBILIZON_LOGLEVEL`, `MOBILIZON_INSTANCE_DEFAULT_LANGUAGE`, `MOBILIZON_GEOSPATIAL_*`) goes in `mobilizon.env`. Secret ones go in `extraEnv` with `valueFrom`, or in `extraEnvFrom`.

The bundled `postgis/postgis` image is published for amd64 only. On arm64, point `postgresql.image` at an arm64 PostGIS build or use an external database.

See [`values.yaml`](charts/mobilizon/values.yaml) for all options.
