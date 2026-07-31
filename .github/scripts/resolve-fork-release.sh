#!/usr/bin/env bash

set -Eeuo pipefail

readonly EXPECTED_IMAGE="ghcr.io/shockstruck/infisical"
readonly EXPECTED_REPOSITORY="shockstruck/infisical"
readonly PUBLISHER_WORKFLOW="shockstruck/infisical/.github/workflows/release-fork-ghcr.yml"
readonly CANONICAL_UPSTREAM_URL="https://github.com/Infisical/infisical.git"

die() {
  printf 'resolve-fork-release: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_full_sha() {
  local name="$1"
  local value="$2"

  [[ "$value" =~ ^[0-9a-f]{40}$ ]] || die "$name must be a lowercase full 40-character commit SHA"
}

registry_digest() {
  local reference="$1"
  local output

  if output="$(crane digest "$reference" 2>&1)"; then
    [[ "$output" =~ ^sha256:[0-9a-f]{64}$ ]] || die "registry returned an invalid digest for $reference"
    printf '%s\n' "$output"
    return 0
  fi

  if grep -Eqi 'manifest unknown|name unknown|not found|404' <<<"$output"; then
    return 1
  fi

  printf '%s\n' "$output" >&2
  die "registry lookup failed for $reference"
}

verify_labels() {
  local digest="$1"
  local upstream_tag="$2"
  local upstream_sha="$3"
  local fork_sha="$4"

  crane config "$EXPECTED_IMAGE@$digest" | jq -e \
    --arg t "$upstream_tag" \
    --arg u "$upstream_sha" \
    --arg f "$fork_sha" '
      .config.Labels["org.opencontainers.image.version"] == $t and
      .config.Labels["org.opencontainers.image.revision"] == $f and
      .config.Labels["io.infisical.upstream.tag"] == $t and
      .config.Labels["io.infisical.upstream.revision"] == $u and
      .config.Labels["io.infisical.fork.revision"] == $f
    ' >/dev/null || die "existing digest labels do not match T/U/F"
}

verify_buildkit_provenance() {
  local digest="$1"
  local upstream_tag="$2"
  local upstream_sha="$3"
  local fork_sha="$4"
  local index_json
  local attestation_digest
  local attestation_manifest
  local layer_digest
  local predicate

  index_json="$(crane manifest "$EXPECTED_IMAGE@$digest")"
  attestation_digest="$(jq -r '
    [.manifests[]? |
      select(.annotations["vnd.docker.reference.type"] == "attestation-manifest") |
      .digest][0] // empty
  ' <<<"$index_json")"
  [[ -n "$attestation_digest" ]] || die "existing digest has no BuildKit attestation manifest"

  attestation_manifest="$(crane manifest "$EXPECTED_IMAGE@$attestation_digest")"
  layer_digest="$(jq -r '
    [.layers[]? |
      select(.mediaType == "application/vnd.in-toto+json") |
      .digest][0] // empty
  ' <<<"$attestation_manifest")"
  [[ -n "$layer_digest" ]] || die "BuildKit attestation has no in-toto provenance layer"

  predicate="$(crane blob "$EXPECTED_IMAGE@$layer_digest")"
  jq -e \
    --arg t "$upstream_tag" \
    --arg u "$upstream_sha" \
    --arg f "$fork_sha" '
      (.predicateType | startswith("https://slsa.dev/provenance/")) and
      (.predicate.invocation.parameters.args // {}) as $args |
      ($args["build-arg:UPSTREAM_TAG"] // $args.UPSTREAM_TAG) == $t and
      ($args["build-arg:UPSTREAM_COMMIT_SHA"] // $args.UPSTREAM_COMMIT_SHA) == $u and
      ($args["build-arg:FORK_COMMIT_SHA"] // $args.FORK_COMMIT_SHA) == $f
    ' <<<"$predicate" >/dev/null || die "BuildKit provenance does not contain exact T/U/F build arguments"
}

verify_signed_existing_image() {
  local digest="$1"
  local upstream_tag="$2"
  local upstream_sha="$3"
  local fork_sha="$4"
  local release_ref="$5"

  verify_labels "$digest" "$upstream_tag" "$upstream_sha" "$fork_sha"
  verify_buildkit_provenance "$digest" "$upstream_tag" "$upstream_sha" "$fork_sha"
  gh attestation verify "oci://$EXPECTED_IMAGE@$digest" \
    --repo "$EXPECTED_REPOSITORY" \
    --signer-workflow "$PUBLISHER_WORKFLOW" \
    --source-ref "$release_ref" \
    --source-digest "$fork_sha" >/dev/null || die "GitHub-signed package attestation verification failed"
}

emit_json() {
  local upstream_tag="$1"
  local upstream_sha="$2"
  local fork_sha="$3"
  local release_ref="$4"
  local stable="$5"
  local decision="$6"
  local digest="${7:-}"
  shift 7
  local tags=("$@")
  local tags_json

  tags_json="$(printf '%s\n' "${tags[@]}" | jq -R . | jq -s .)"
  jq -n \
    --arg upstreamTag "$upstream_tag" \
    --arg upstreamSha "$upstream_sha" \
    --arg forkSha "$fork_sha" \
    --arg releaseRef "$release_ref" \
    --argjson stable "$stable" \
    --arg decision "$decision" \
    --arg digest "$digest" \
    --argjson tags "$tags_json" '
      {
        upstreamTag: $upstreamTag,
        upstreamSha: $upstreamSha,
        forkSha: $forkSha,
        releaseRef: $releaseRef,
        tags: $tags,
        stable: $stable,
        decision: $decision,
        digest: (if $digest == "" then null else $digest end)
      }
    '
}

main() {
  require_command git
  require_command jq

  local image="${IMAGE:-}"
  local upstream_tag="${UPSTREAM_TAG:-}"
  local upstream_sha="${UPSTREAM_SHA:-}"
  local fork_sha="${FORK_SHA:-}"
  local release_ref="${RELEASE_REF:-refs/tags/fork/${UPSTREAM_TAG:-}}"
  local expected_release_ref
  local canonical_verify_ref
  local stable=false
  local fixture="${REGISTRY_FIXTURE:-}"
  local dry_run="${DRY_RUN:-0}"
  local validate_only="${VALIDATE_ONLY:-0}"
  local verify_git="${VERIFY_GIT:-0}"
  local exact_tag
  local sha_tag
  local latest_tag
  local exact_digest=""
  local sha_digest=""
  local latest_digest=""
  local decision
  local -a tags

  [[ "$image" == "$EXPECTED_IMAGE" ]] || die "IMAGE must be exactly $EXPECTED_IMAGE"
  [[ -n "$upstream_tag" ]] || die "UPSTREAM_TAG is required"
  [[ -n "$upstream_sha" ]] || die "UPSTREAM_SHA is required"
  [[ -n "$fork_sha" ]] || die "FORK_SHA is required"
  require_full_sha UPSTREAM_SHA "$upstream_sha"
  require_full_sha FORK_SHA "$fork_sha"

  [[ "$upstream_tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] ||
    die "UPSTREAM_TAG is not losslessly representable as an OCI tag"
  git check-ref-format "refs/tags/$upstream_tag" >/dev/null 2>&1 || die "invalid canonical upstream Git tag"
  expected_release_ref="refs/tags/fork/$upstream_tag"
  [[ "$release_ref" == "$expected_release_ref" ]] ||
    die "release ref must be exactly $expected_release_ref"

  if [[ "$upstream_tag" =~ ^v0\.[0-9]+\.[0-9]+$ ]]; then
    stable=true
  fi

  exact_tag="$image:$upstream_tag"
  sha_tag="$image:sha-$fork_sha"
  latest_tag="$image:latest"
  tags=("$exact_tag" "$sha_tag")
  [[ "$stable" == "true" ]] && tags+=("$latest_tag")

  if [[ "$verify_git" == "1" ]]; then
    [[ "${GITHUB_REPOSITORY:-}" == "$EXPECTED_REPOSITORY" ]] || die "workflow repository is not $EXPECTED_REPOSITORY"
    [[ "${GITHUB_REF:-}" == "$release_ref" ]] || die "GITHUB_REF does not match the immutable fork release ref"
    [[ "${GITHUB_SHA:-}" == "$fork_sha" ]] || die "GITHUB_SHA does not match F"
    canonical_verify_ref="refs/upstream-release/tags/$upstream_tag-$upstream_sha"
    if ! git show-ref --verify --quiet "$canonical_verify_ref"; then
      git fetch --no-tags "$CANONICAL_UPSTREAM_URL" "refs/tags/$upstream_tag:$canonical_verify_ref"
    fi
    [[ "$(git rev-parse "refs/tags/$upstream_tag")" == "$(git rev-parse "$canonical_verify_ref")" ]] ||
      die "fork canonical tag object does not match canonical upstream"
    [[ "$(git rev-parse "refs/tags/$upstream_tag^{commit}")" == "$upstream_sha" ]] ||
      die "canonical upstream tag does not peel to U"
    [[ "$(git cat-file -t "$release_ref")" == "commit" ]] || die "fork release ref must be a lightweight tag"
    [[ "$(git rev-parse "$release_ref")" == "$fork_sha" ]] || die "fork release ref object is not F"
    [[ "$(git rev-parse "$release_ref^{commit}")" == "$fork_sha" ]] ||
      die "fork release ref does not peel to F"
    git merge-base --is-ancestor "$upstream_sha" "$fork_sha" || die "U is not an ancestor of F"
  fi

  if [[ "$validate_only" == "1" ]]; then
    emit_json "$upstream_tag" "$upstream_sha" "$fork_sha" "$release_ref" "$stable" validate "" "${tags[@]}"
    return 0
  fi

  if [[ "$dry_run" == "1" && -z "$fixture" ]]; then
    die "DRY_RUN=1 requires REGISTRY_FIXTURE=absent, signed-matching, or conflicting"
  fi

  case "$fixture" in
    absent)
      decision=publish
      ;;
    signed-matching)
      decision=noop
      exact_digest="sha256:$(printf '%064d' 0)"
      ;;
    conflicting)
      die "fixture represents a conflicting or unsigned existing package"
      ;;
    "")
      require_command crane
      require_command gh

      if exact_digest="$(registry_digest "$exact_tag")"; then
        sha_digest="$(registry_digest "$sha_tag")" || die "exact T exists but full sha-F tag is absent"
        [[ "$sha_digest" == "$exact_digest" ]] || die "exact T and full sha-F resolve to different digests"
        if [[ "$stable" == "true" ]]; then
          latest_digest="$(registry_digest "$latest_tag")" || die "stable T exists but latest is absent"
          [[ "$latest_digest" == "$exact_digest" ]] || die "stable T and latest resolve to different digests"
        fi
        verify_signed_existing_image "$exact_digest" "$upstream_tag" "$upstream_sha" "$fork_sha" "$release_ref"
        decision=noop
      else
        if sha_digest="$(registry_digest "$sha_tag")"; then
          die "full sha-F already exists while exact T is absent"
        fi
        decision=publish
      fi
      ;;
    *)
      die "unknown REGISTRY_FIXTURE: $fixture"
      ;;
  esac

  emit_json "$upstream_tag" "$upstream_sha" "$fork_sha" "$release_ref" "$stable" "$decision" "$exact_digest" "${tags[@]}"
}

main "$@"
