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
| Caddy | Off by default. TLS termination with automatic certificates, see below. |
| Dex | Off by default. Login with local users through OpenID Connect, see below. |

Mobilizon always generates `https://<mobilizon.host>` URLs, so put TLS in front of it (Ingress, Gateway or another proxy). `mobilizon.host` is required and is written into the database on first start (local actor URLs, including the internal relay actor), so set it before the first install. Changing it afterwards leads to errors such as `Relay actor not found`.

## TLS with the bundled Caddy

Without an Ingress controller or Gateway, the chart can run [Caddy](https://caddyserver.com) in front of Mobilizon. It gets a Let's Encrypt certificate for `mobilizon.host`, redirects HTTP to HTTPS and proxies to the Mobilizon Service. Its Service is a `LoadBalancer` on 80/443 (plus 443/UDP inside the pod for HTTP/3); point the DNS record at it.

```yaml
caddy:
  enabled: true
  email: admin@example.org              # ACME account
  service:
    loadBalancerIP: 203.0.113.10        # optional
  # Directives inside the mobilizon.host site block, before reverse_proxy:
  siteConfig: |
    encode gzip
    header Strict-Transport-Security "max-age=31536000"
  # Extra global options and whole extra site blocks:
  globalOptions: |
    servers {
      trusted_proxies static private_ranges
    }
  extraSites: |
    status.example.org {
      respond "ok"
    }
```

Certificates and the ACME account live on a 1Gi PVC (kept on uninstall), so restarts do not hit Let's Encrypt rate limits. Caddy runs as a non-root user on 8080/8443 with a read-only root filesystem.

For anything the options above cannot express, set `caddy.caddyfile` (replaces the generated file, run through `tpl`) or `caddy.existingConfigMap` (a ConfigMap with a `Caddyfile` key). Keep `http_port 8080` and `https_port 8443` in the global options.

Plugins such as geoblocking (for example `caddy-maxmind-geolocation`) or DNS-01 providers need a custom build. Build one with `xcaddy` (`FROM caddy:builder` then `xcaddy build --with ...`), set `caddy.image`, and add the directives in `siteConfig` or `globalOptions` (for example `order geoip first`). Secrets for them, such as DNS API tokens or a MaxMind licence key, go in `caddy.extraEnv` / `caddy.extraEnvFrom` and are referenced as `{env.NAME}`. `externalTrafficPolicy: Local` is the default so Caddy sees real client IPs, which geoblocking needs.

**Caddy or your existing Gateway?** If a cluster already terminates TLS (for example HAProxy in front of Envoy Gateway with cert-manager), keep using `httpRoute` or `ingress`: one entry point, one place for certificates, and no extra public IP. The bundled Caddy suits clusters without that, or when you want Caddy-specific features for this one site. Do not put both in the path, since Caddy cannot get a certificate over HTTP-01 when another proxy answers port 80 for the host.

## Login with Dex or another OIDC provider

`dex.enabled` runs [Dex](https://dexidp.io) with a local user database and adds a login button for it to Mobilizon. Dex is served on the same host under `/dex` (issuer `https://<mobilizon.host>/dex`), and the chart routes that path to Dex in the default HTTPRoute, Ingress and Caddy config.

```yaml
dex:
  enabled: true
  staticPasswords:
    - email: admin@example.org
      # htpasswd -nbBC 10 "" 'the-password' | cut -d: -f2
      hash: "$2a$10$2b2cU8CPhOTaGrs1HRQuAueS7JTT5ZHsHSzYiFPm1leZck7Mc8T4W"
      username: admin
      userID: 08a8684b-db88-4b73-90a9-3cd1661f5466
oidc:
  existingSecret: mobilizon-oidc        # key: oidc-client-secret, shared by Dex and Mobilizon
```

The generated Dex config, hashes included, is stored in a Secret. To keep the hashes out of values, put a complete Dex `config.yaml` in your own Secret and set `dex.existingSecret`. It needs a static client with id `mobilizon`, `secretEnv: DEX_CLIENT_SECRET` and redirect URI `https://<mobilizon.host>/auth/keycloak/callback`. `dex.config` is merged over the generated config for anything else (expiry, connectors). Dex keeps sessions in memory, so a restart only means logging in to Dex again.

Any other provider works the same way without Dex: set `oidc.enabled`, `oidc.issuer`, `oidc.clientId`, `oidc.label` and the client secret, and register `https://<mobilizon.host>/auth/keycloak/callback` at the provider. The path says `keycloak` because Mobilizon's login page only draws buttons for a fixed list of provider ids, and `oidc` isn't one of them; the provider is generic OIDC with your label. The chart then mounts a `config.exs` that imports the image's own config and adds the provider, through `MOBILIZON_CONFIG_PATH`.

Things to know:

- Mobilizon matches accounts by email only and ignores groups or other claims. An existing account with the same email is logged in.
- An OIDC login creates the account even when `registrationsOpen` is false, and skips email confirmation. Everyone the provider lets in gets an account.
- Mobilizon fetches the issuer's discovery document from inside the cluster, so the pod must be able to reach `https://<mobilizon.host>/dex`. Admin rights are still granted with `mobilizon_ctl users.modify <email> --admin`.

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
