# SecurityKane Secrets Detection Action

A GitHub Action that uses [Gitleaks](https://github.com/gitleaks/gitleaks) to scan your repository for secrets and uploads the results to your SecurityKane backend.

## Features

- 🔍 Scans git history for leaked secrets using Gitleaks
- 🔐 Secure OIDC-based authentication (no sharing of GitHub tokens)
- 📦 Uploads results to S3 via presigned URLs
- 🔄 Automatic retry logic with exponential backoff
- ✅ Comprehensive error handling

## Security Architecture

### Authentication Flow

This action uses **OIDC (OpenID Connect) ID tokens** for secure authentication instead of passing GitHub tokens to external services:

1. **GitHub Actions** generates a cryptographically signed OIDC ID token
2. **Action** sends the OIDC token to your backend (NOT the GITHUB_TOKEN)
3. **Backend** verifies the token signature and claims server-side
4. **Backend** returns a presigned S3 URL for uploading results
5. **Action** uploads the scan results to S3

### Why OIDC Instead of GITHUB_TOKEN?

- ✅ **GITHUB_TOKEN is repo-scoped** - it grants access to your repository
- ✅ **GITHUB_TOKEN proves nothing** about caller identity to external services
- ✅ **OIDC tokens are cryptographically signed** by GitHub and can be verified
- ✅ **OIDC tokens contain claims** (repository, workflow, actor, etc.) that prove the workflow's identity
- ✅ **OIDC tokens expire quickly** and cannot be reused
- ✅ **Best practice** - Keep GITHUB_TOKEN for GitHub API calls only, use OIDC for your backend

## Usage

### 1. Configure Workflow Permissions

Your workflow MUST have `id-token: write` permission to request OIDC tokens:

```yaml
name: Security Scan

on:
  push:
    branches: [main]
  pull_request:

# REQUIRED: Grant OIDC token permission
permissions:
  id-token: write    # Required for OIDC authentication
  contents: read     # Required for checking out code

jobs:
  security-scan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0  # Required for full git history scan

      - uses: SecurityKane/secrets-detection-action@main
        env:
          SK_TENANT_ID: ${{ secrets.SK_TENANT_ID }}
```

### 2. Configure Backend to Verify OIDC Tokens

Your backend service **MUST verify the OIDC ID token** to ensure security. The token is sent in the `id_token` field (NOT `token`).

#### Token Verification Steps (Backend)

1. **Get GitHub's OIDC public keys**
   ```
   GET https://token.actions.githubusercontent.com/.well-known/jwks
   ```

2. **Verify the JWT signature** using the public key

3. **Validate required claims**:
   ```json
   {
     "iss": "https://token.actions.githubusercontent.com",
     "aud": "securitykane",  // Must match your expected audience
     "repository": "owner/repo",
     "workflow": "Security Scan",
     "actor": "username",
     "exp": 1234567890,  // Must not be expired
     ...
   }
   ```

4. **Check the repository claim** matches expected repositories

#### Example Verification (Python)

```python
import jwt
import requests

def verify_github_oidc_token(id_token, expected_repository):
    # Fetch GitHub's OIDC public keys
    jwks_url = "https://token.actions.githubusercontent.com/.well-known/jwks"
    jwks = requests.get(jwks_url).json()

    # Verify and decode the token
    try:
        claims = jwt.decode(
            id_token,
            jwks,
            algorithms=["RS256"],
            audience="securitykane",  # Your audience
            issuer="https://token.actions.githubusercontent.com"
        )

        # Verify repository claim
        if claims.get("repository") != expected_repository:
            raise ValueError("Repository mismatch")

        return claims

    except jwt.InvalidTokenError as e:
        raise ValueError(f"Invalid OIDC token: {e}")
```

#### Example Verification (Node.js)

```javascript
const jwt = require('jsonwebtoken');
const jwksClient = require('jwks-rsa');

const client = jwksClient({
  jwksUri: 'https://token.actions.githubusercontent.com/.well-known/jwks'
});

function getKey(header, callback) {
  client.getSigningKey(header.kid, (err, key) => {
    const signingKey = key.publicKey || key.rsaPublicKey;
    callback(null, signingKey);
  });
}

function verifyGitHubOIDCToken(idToken, expectedRepository) {
  return new Promise((resolve, reject) => {
    jwt.verify(idToken, getKey, {
      audience: 'securitykane',
      issuer: 'https://token.actions.githubusercontent.com',
      algorithms: ['RS256']
    }, (err, decoded) => {
      if (err) {
        reject(new Error(`Invalid OIDC token: ${err.message}`));
        return;
      }

      if (decoded.repository !== expectedRepository) {
        reject(new Error('Repository mismatch'));
        return;
      }

      resolve(decoded);
    });
  });
}
```

### 3. Backend Response Format

Your backend should return a JSON response with a presigned S3 URL:

```json
{
  "presigned_url": "https://your-bucket.s3.amazonaws.com/path/to/results.json?X-Amz-Algorithm=..."
}
```

The action will validate that `presigned_url` exists and is not null before attempting upload.

## Error Handling

The action includes comprehensive error handling:

- ✅ **Automatic retries** with exponential backoff (2s, 4s, 8s)
- ✅ **Connection timeouts** on all HTTP requests
- ✅ **Presigned URL validation** before upload
- ✅ **HTTP status code checking** with `-f` flag (fail on 4xx/5xx)
- ✅ **Clear error messages** for debugging

## Development vs Production

### ⚠️ smee.io Warning

The current implementation uses `smee.io` endpoint for development:

```bash
https://smee.io/J0WcDeqyS7aQ7m5x/api/integrations/github/tenant-info/
```

**Important Notes:**
- ✅ **smee.io is fine for development** - Great for testing webhooks and local development
- ❌ **DO NOT use smee.io in production** - It can see your entire payload including tokens
- ✅ **Replace with your own backend** for production use

### Production Setup

Replace the smee.io URL in `action.yml` line 109 with your production backend:

```bash
https://api.your-domain.com/api/integrations/github/tenant-info/
```

## How It Works

1. **Install Gitleaks** - Downloads and installs the latest Gitleaks scanner
2. **Run Scan** - Scans git history for secrets (exits with 0 to not fail workflow)
3. **Merge Results** - Combines findings into a single JSON report
4. **Build Report** - Adds metadata (commit SHA, workflow URL, timestamps, etc.)
5. **Request OIDC Token** - Obtains secure ID token from GitHub Actions
6. **Get Presigned URL** - Sends OIDC token to backend, receives S3 URL
7. **Upload Results** - Uploads report to S3 using presigned URL

## Environment Variables

- `SK_TENANT_ID` - (Optional) Your SecurityKane tenant identifier
- `GITLEAKS_VERSION` - (Optional) Gitleaks version to install (default: v8.18.4)

## Output Format

The action produces a JSON report with the following structure:

```json
{
  "tenant_id": "your-tenant-id",
  "repository": "owner/repo",
  "commit_sha": "abc123...",
  "run_id": "1234567890",
  "run_attempt": "1",
  "ref": "refs/heads/main",
  "ref_name": "main",
  "actor": "username",
  "run_url": "https://github.com/owner/repo/actions/runs/1234567890",
  "generated_at": "2025-01-15T10:30:00Z",
  "findings": [
    {
      "Description": "AWS Access Key",
      "StartLine": 42,
      "EndLine": 42,
      "StartColumn": 15,
      "EndColumn": 35,
      "Match": "AKIAIOSFODNN7EXAMPLE",
      "Secret": "AKIAIOSFODNN7EXAMPLE",
      "File": "config/aws.yml",
      "Commit": "abc123...",
      "Entropy": 3.5,
      "Author": "developer@example.com",
      "Date": "2025-01-15T09:00:00Z",
      "Message": "Add AWS configuration",
      "RuleID": "aws-access-token"
    }
  ]
}
```

## Security Best Practices

### For GitHub Actions (Using This Action)
- ✅ Always set `id-token: write` permission
- ✅ Use `contents: read` for minimal permissions
- ✅ Never expose `GITHUB_TOKEN` to external services
- ✅ Use `fetch-depth: 0` for full history scanning

### For Backend Services (Receiving Tokens)
- ✅ Always verify OIDC token signatures
- ✅ Validate all JWT claims (issuer, audience, expiry)
- ✅ Check repository claim matches expected repos
- ✅ Generate presigned URLs with minimal permissions
- ✅ Set short expiry times on presigned URLs (e.g., 5 minutes)
- ✅ Use HTTPS for all endpoints

### For S3 Presigned URLs
- ✅ Match Content-Type header between pre-signing and upload
- ✅ Use presigned PUT (not POST) for simpler client-side handling
- ✅ Consider ignoring extra headers if needed (configurable in backend)
- ✅ Set appropriate bucket policies and CORS if needed

## Troubleshooting

### "Failed to obtain OIDC ID token"
- Check that your workflow has `id-token: write` permission
- Verify the workflow is running on a GitHub Actions runner (not self-hosted without OIDC support)

### "Presigned URL is missing or null"
- Check backend logs to see if OIDC token verification failed
- Ensure backend is returning the correct JSON format with `presigned_url` field
- Verify backend is reachable and responding correctly

### "Failed to upload to S3"
- Check that presigned URL hasn't expired
- Verify S3 bucket permissions allow PUT operations
- Ensure Content-Type header matches what was pre-signed
- Check S3 bucket CORS configuration if needed

### Network Failures
- The action includes automatic retry logic with exponential backoff
- Check GitHub Actions service status if persistent failures occur
- Verify backend and S3 endpoints are accessible from GitHub Actions runners

## License

[Your License Here]

## Support

For issues and questions:
- GitHub Issues: [Create an issue](https://github.com/SecurityKane/secrets-detection-action/issues)
- Documentation: [SecurityKane Docs](https://docs.securitykane.com)

## References

- [GitHub Actions OIDC Documentation](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/about-security-hardening-with-openid-connect)
- [Gitleaks Documentation](https://github.com/gitleaks/gitleaks)
- [AWS S3 Presigned URLs](https://docs.aws.amazon.com/AmazonS3/latest/userguide/PresignedUrlUploadObject.html)
