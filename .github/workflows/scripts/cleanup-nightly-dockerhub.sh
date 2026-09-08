#!/bin/bash
set -euo pipefail
# Delete Docker Hub tags belonging to nightly runs older than the cutoff.
#
# Environment:
#   DISTRIBUTIONS     whitespace-separated list of image names
#   MAX_NIGHTLY_RUNS  number of nightly runs to delete per invocation
#   DRY_RUN           "true" to log what would be deleted without deleting it
#   DOCKERHUB_ORG     Docker Hub org owning the repositories
#   DOCKER_TOKEN      Docker Hub access token, sent as a bearer token
#
# Authentication note: this deliberately does not call /v2/users/login/. That endpoint
# authenticates *user* accounts, and the credentials used here belong to the `otel`
# organization, so the login call cannot succeed and fails with an empty token. Tag
# listing needs no authentication at all, so only the deletes are authenticated, by
# sending the access token directly as a bearer token.

CUTOFF=$(date -u -d '2 weeks ago' +%Y-%m-%dT%H:%M:%SZ)

for IMAGE in $DISTRIBUTIONS; do
  echo "Processing Docker Hub image: ${DOCKERHUB_ORG}/${IMAGE}"

  # Collect all old nightly tags across pages, then group into runs and cap.
  OLD_TAGS="[]"
  PAGE=1
  while true; do
    # Listing public tags needs no authentication.
    RESPONSE=$(curl -s \
      "https://hub.docker.com/v2/repositories/${DOCKERHUB_ORG}/${IMAGE}/tags/?page_size=100&page=${PAGE}")

    COUNT=$(echo "$RESPONSE" | jq '.results | length')
    if [ "$COUNT" -eq 0 ]; then
      break
    fi

    # Container tags come from goreleaser's nightly version_template
    # ("{{ incpatch .Version }}-nightly.{{ .ShortCommit }}"), so unlike the git tags
    # they carry no leading "v". The suffix after "nightly." is a short commit sha on
    # current tags and a timestamp on older ones, hence [0-9a-f]+. Not anchoring the
    # end matches the per-architecture variants such as "-amd64" too, while the moving
    # `nightly` and `nightly-amd64` tags do not match and are therefore never deleted.
    BATCH=$(echo "$RESPONSE" | jq --arg cutoff "$CUTOFF" '[.results[] | select(
      (.name | test("^v?[0-9]+\\.[0-9]+\\.[0-9]+-nightly\\.[0-9a-f]+")) and
      (.last_updated < $cutoff)
    ) | {
      name: .name,
      last_updated: .last_updated,
      run: (.name | capture("nightly\\.(?<ts>[0-9a-f]+)") | .ts)
    }]')
    OLD_TAGS=$(jq -n --argjson a "$OLD_TAGS" --argjson b "$BATCH" '$a + $b')

    NEXT=$(echo "$RESPONSE" | jq -r '.next')
    if [ "$NEXT" = "null" ] || [ -z "$NEXT" ]; then
      break
    fi
    PAGE=$((PAGE + 1))
  done

  while IFS=$'\t' read -r TAG_NAME UPDATED; do
    if [ "$DRY_RUN" = "true" ]; then
      echo "  DRY RUN: would delete Docker Hub tag: ${DOCKERHUB_ORG}/${IMAGE}:${TAG_NAME} (updated: $UPDATED)"
      continue
    fi

    echo "  Deleting Docker Hub tag: ${DOCKERHUB_ORG}/${IMAGE}:${TAG_NAME} (updated: $UPDATED)"
    STATUS=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
      -H "Authorization: Bearer ${DOCKER_TOKEN}" \
      "https://hub.docker.com/v2/repositories/${DOCKERHUB_ORG}/${IMAGE}/tags/${TAG_NAME}/")
    if [ "$STATUS" != "204" ] && [ "$STATUS" != "202" ]; then
      echo "    Failed to delete ${DOCKERHUB_ORG}/${IMAGE}:${TAG_NAME} (HTTP $STATUS)" >&2
      exit 1
    fi
  # Order runs by date, not by run key: a short commit sha carries no chronology, so
  # sorting on it would pick an arbitrary set of runs rather than the oldest ones.
  # Each run is dated by its earliest tag so a run is kept or removed as a whole.
  done < <(echo "$OLD_TAGS" | jq -r --argjson max "$MAX_NIGHTLY_RUNS" '
    group_by(.run)
    | map({at: (map(.last_updated) | min), items: .})
    | sort_by(.at)
    | .[:$max]
    | map(.items[])
    | .[]
    | [.name, .last_updated] | @tsv')
done
