act push -W .github/workflows/self-test.yml \
  --container-architecture linux/amd64 \
  -P ubuntu-latest=ghcr.io/catthehacker/ubuntu:act-22.04 \
  --reuse \
  --artifact-server-path ./artifacts
