# App Store Connect Provisioning

## Create or Confirm the API Key

In App Store Connect:

1. Open `Users and Access`.
2. Open `Integrations` or `Keys`.
3. Create a team-level API key with access to apps, builds, TestFlight, and
   metadata delivery.
4. Download the `.p8` file once.
5. Record the key ID and issuer ID.

Store the key in AWS Secrets Manager as described in
[aws-provisioning.md](aws-provisioning.md).

## Query `APPLE_APP_ID`

The workflows use Apple's numeric app ID, not the bundle ID.

```bash
export BUNDLE_ID=com.riddimsoftware.justplayit
export ASC_KEY_ID=<key-id>
export ASC_ISSUER_ID=<issuer-id>
export ASC_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
```

Generate a token and query the app:

```bash
python3 - <<'PY'
import os
import time
import jwt
import requests

bundle_id = os.environ["BUNDLE_ID"]
with open(os.environ["ASC_KEY_PATH"]) as f:
    private_key = f.read()
now = int(time.time())
token = jwt.encode(
    {
        "iss": os.environ["ASC_ISSUER_ID"],
        "iat": now,
        "exp": now + 1200,
        "aud": "appstoreconnect-v1",
    },
    private_key,
    algorithm="ES256",
    headers={"kid": os.environ["ASC_KEY_ID"]},
)
resp = requests.get(
    "https://api.appstoreconnect.apple.com/v1/apps",
    headers={"Authorization": f"Bearer {token}"},
    params={"filter[bundleId]": bundle_id, "fields[apps]": "bundleId,name"},
    timeout=30,
)
resp.raise_for_status()
for app in resp.json()["data"]:
    print(app["id"], app["attributes"]["name"], app["attributes"]["bundleId"])
PY
```

Set the printed ID as `APPLE_APP_ID` in GitHub:

```bash
gh variable set APPLE_APP_ID --repo sunnypurewal/<app> --body "<printed-id>"
```

## Authorize the App Store Release Environment

Create the environment:

```bash
gh api --method PUT \
  "repos/sunnypurewal/<app>/environments/app-store-release" \
  --field wait_timer=0
```

Then use GitHub UI to add required reviewers:

`Settings -> Environments -> app-store-release -> Required reviewers`.

The reusable `release-app-store.yml` workflow pauses at this environment after
it finds the matching TestFlight build and before it submits to App Store
review.
