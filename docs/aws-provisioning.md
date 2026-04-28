# AWS Provisioning

The release workflows authenticate to AWS with GitHub OIDC and read two
Secrets Manager entries:

- `appstore/connect-api`
- `appstore/distribution-cert`

## OIDC Trust Policy

Create one IAM role per AWS account used for App Store releases. The role ARN is
stored in the consuming repo secret `AWS_RELEASE_ROLE_ARN`.

Trust policy template:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": [
            "repo:sunnypurewal/<app>:*"
          ]
        }
      }
    }
  ]
}
```

For multiple apps, add multiple `repo:sunnypurewal/<app>:*` entries.

## IAM Permissions

Scope the role to the two release secrets:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["secretsmanager:GetSecretValue"],
      "Resource": [
        "arn:aws:secretsmanager:us-east-1:<account-id>:secret:appstore/connect-api-*",
        "arn:aws:secretsmanager:us-east-1:<account-id>:secret:appstore/distribution-cert-*"
      ]
    }
  ]
}
```

## `appstore/connect-api`

Secret shape:

```json
{
  "key_id": "ABC123DEFG",
  "issuer_id": "00000000-0000-0000-0000-000000000000",
  "private_key": "-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----"
}
```

Create or update it:

```bash
aws secretsmanager create-secret \
  --name appstore/connect-api \
  --region us-east-1 \
  --secret-string file://asc-connect-api.json
```

Update an existing secret:

```bash
aws secretsmanager put-secret-value \
  --secret-id appstore/connect-api \
  --region us-east-1 \
  --secret-string file://asc-connect-api.json
```

## `appstore/distribution-cert`

Secret shape:

```json
{
  "p12_base64": "<base64-encoded p12>",
  "password": "<p12 password>"
}
```

Migrate an existing P12:

```bash
export P12_PATH=/path/to/distribution.p12
export P12_PASSWORD='<password>'

jq -n \
  --arg p12_base64 "$(base64 -i "$P12_PATH" | tr -d '\n')" \
  --arg password "$P12_PASSWORD" \
  '{p12_base64: $p12_base64, password: $password}' \
  > distribution-cert.json

aws secretsmanager create-secret \
  --name appstore/distribution-cert \
  --region us-east-1 \
  --secret-string file://distribution-cert.json
```

Update an existing cert:

```bash
aws secretsmanager put-secret-value \
  --secret-id appstore/distribution-cert \
  --region us-east-1 \
  --secret-string file://distribution-cert.json
```

Verify both secrets:

```bash
aws secretsmanager get-secret-value \
  --secret-id appstore/connect-api \
  --region us-east-1 \
  --query SecretString \
  --output text | jq 'keys'

aws secretsmanager get-secret-value \
  --secret-id appstore/distribution-cert \
  --region us-east-1 \
  --query SecretString \
  --output text | jq 'keys'
```
