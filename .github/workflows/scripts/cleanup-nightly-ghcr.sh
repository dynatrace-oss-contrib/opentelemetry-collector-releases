#!/bin/bash
set -euo pipefail
# Delete GHCR container versions belonging to nightly runs older than the cutoff.
#
# Environment:
#   DISTRIBUTIONS     whitespace-separated list of image names
#   MAX_NIGHTLY_RUNS  number of nightly runs to delete per invocation
#   DRY_RUN           "true" to log what would be deleted without deleting it
#   ORG               GitHub org owning the packages
#   GHCR_REPO         repository segment of the package name
#   GH_TOKEN          token used by `gh api`

CUTOFF=$(date -u -d '2 weeks ago' +%Y-%m-%dT%H:%M:%SZ)

for IMAGE in $DISTRIBUTIONS; do
  # Images are published under ghcr.io/<org>/<repo>/<image>, so the package name
  # includes the repo segment and its slash has to be percent-encoded for the API.
  PACKAGE="${GHCR_REPO}%2F${IMAGE}"
  echo "Processing GHCR package: ${GHCR_REPO}/${IMAGE}"

  # Collect all old nightly versions across pages, then group into runs and cap.
  OLD_VERSIONS="[]"
  PAGE=1
  while true; do
    VERSIONS=$(gh api \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "/orgs/${ORG}/packages/container/${PACKAGE}/versions?per_page=100&page=${PAGE}")

    COUNT=$(echo "$VERSIONS" | jq 'length')
    if [ "$COUNT" -eq 0 ]; then
      break
    fi

    # Container tags come from goreleaser's nightly version_template
    # ("{{ incpatch .Version }}-nightly.{{ .ShortCommit }}"), so unlike the git tags
    # they carry no leading "v". The suffix after "nightly." is a short commit sha on
    # current tags and a timestamp on older ones, hence [0-9a-f]+. Optional -<arch>
    # suffixes are matched by not anchoring the end.
    #
    # `all` rather than `any`: a version that also carries a moving tag such as
    # `nightly`, `nightly-amd64` or `latest` is left alone, which is what keeps the
    # current nightly image from being deleted. `run` groups the per-architecture
    # versions of one nightly run together.
    BATCH=$(echo "$VERSIONS" | jq --arg cutoff "$CUTOFF" '[.[] | select(
      (.metadata.container.tags | length > 0) and
      (.metadata.container.tags | all(test("^v?[0-9]+\\.[0-9]+\\.[0-9]+-nightly\\.[0-9a-f]+"))) and
      (.updated_at < $cutoff)
    ) | {
      id: .id,
      tags: .metadata.container.tags,
      updated_at: .updated_at,
      run: (.metadata.container.tags[0] | capture("nightly\\.(?<ts>[0-9a-f]+)") | .ts)
    }]')
    OLD_VERSIONS=$(jq -n --argjson a "$OLD_VERSIONS" --argjson b "$BATCH" '$a + $b')

    PAGE=$((PAGE + 1))
  done

  while IFS=$'\t' read -r VERSION_ID TAGS UPDATED; do
    if [ "$DRY_RUN" = "true" ]; then
      echo "  DRY RUN: would delete GHCR version $VERSION_ID (tags: $TAGS, updated: $UPDATED)"
      continue
    fi

    echo "  Deleting GHCR version $VERSION_ID (tags: $TAGS, updated: $UPDATED)"
    gh api \
      --method DELETE \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "/orgs/${ORG}/packages/container/${PACKAGE}/versions/${VERSION_ID}"
  # Order runs by date, not by run key: a short commit sha carries no chronology, so
  # sorting on it would pick an arbitrary set of runs rather than the oldest ones.
  # Each run is dated by its earliest version so a run is kept or removed as a whole.
  done < <(echo "$OLD_VERSIONS" | jq -r --argjson max "$MAX_NIGHTLY_RUNS" '
    group_by(.run)
    | map({at: (map(.updated_at) | min), items: .})
    | sort_by(.at)
    | .[:$max]
    | map(.items[])
    | .[]
    | [.id, (.tags | join(", ")), .updated_at] | @tsv')
done
