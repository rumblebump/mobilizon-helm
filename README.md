# mobilizon-helm

[![Artifact Hub](https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/mobilizon)](https://artifacthub.io/packages/search?repo=mobilizon)

A minimal Helm chart for [Mobilizon](https://mobilizon.org). No subcharts or external chart dependencies: one Deployment for Mobilizon and, optionally, one PostGIS StatefulSet.

```sh
kubectl create secret generic mobilizon-keys \
  --from-literal=secret-key-base="$(openssl rand -base64 48)" \
  --from-literal=secret-key="$(openssl rand -base64 48)"
kubectl create secret generic mobilizon-db --from-literal=password="$(openssl rand -base64 24)"

helm install mobilizon ./charts/mobilizon \
  --set mobilizon.host=events.example.org \
  --set mobilizon.existingSecret=mobilizon-keys \
  --set database.existingSecret=mobilizon-db \
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
| Secret | Only for credentials given inline in values instead of an existing Secret. |
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

The chart never generates secrets, so every render is identical and GitOps tools such as Argo CD never rotate them. If you would rather not create Secrets yourself, set `mobilizon.secretKeyBase`, `mobilizon.secretKey`, `database.password` and `smtp.password` inline and the chart puts them in its own Secret. Rendering fails with a clear message when a required one is missing.

Generate the instance keys with, for example, `openssl rand -base64 48`. Changing them logs everyone out. The bundled Postgres only reads its password on first start, so change `database.password` on an existing install by also changing it inside the database.

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

## Installing from GHCR

Once lint and the [helm-unittest](https://github.com/helm-unittest/helm-unittest) suite in `charts/mobilizon/tests` pass, CI publishes the chart to `oci://ghcr.io/rumblebump/charts/mobilizon`:

- Every push to `main` publishes `0.0.0-dev`, overwriting the previous dev build.
- Pushing a tag `vX.Y.Z` (for example `git tag v1.2.3 && git push origin v1.2.3`) publishes version `X.Y.Z`. The `version` in `Chart.yaml` is ignored; the tag decides.

```sh
helm pull oci://ghcr.io/rumblebump/charts/mobilizon --version 0.0.0-dev      # latest main
helm install mobilizon oci://ghcr.io/rumblebump/charts/mobilizon --version 1.2.3 -f my-values.yaml
```

With Argo CD, register `ghcr.io/rumblebump/charts` as a Helm repository with `enableOCI: "true"` (no credentials needed while the package is public), then point the application at it. The `repoURL` has no `oci://` prefix:

```yaml
source:
  repoURL: ghcr.io/rumblebump/charts
  chart: mobilizon
  targetRevision: 1.2.3   # or 0.0.0-dev to follow main
```

When following `0.0.0-dev`, the tag never changes, so Argo CD keeps serving its cached render after a new push. Hard refresh the application to pick up the latest build.

## Artifact Hub

The chart is listed on [Artifact Hub](https://artifacthub.io) straight from GHCR. Artifact Hub polls the registry, so a new tag shows up there on its next scan with no extra step. `0.0.0-dev` is marked as a pre-release. Chart annotations (license, images, links) live in [`Chart.yaml`](charts/mobilizon/Chart.yaml); when you bump `appVersion` or the PostGIS image, update `artifacthub.io/images` too.

Repository metadata lives in [`artifacthub-repo.yml`](artifacthub-repo.yml). Once it has a `repositoryID`, each release also pushes it to GHCR as the `artifacthub.io` tag, which earns the Verified Publisher badge.

To cut a release, push a tag: `git tag v0.1.0 && git push origin v0.1.0`.

Run the unit tests locally with `helm plugin install https://github.com/helm-unittest/helm-unittest` and `helm unittest charts/mobilizon`.
