#!/usr/bin/env bash

set -Eeuo pipefail

readonly DEFAULT_UPSTREAM_URL="https://github.com/Infisical/infisical.git"
readonly DEFAULT_ORIGIN_REMOTE="origin"
readonly UPSTREAM_RELEASE_ENDPOINT="repos/Infisical/infisical/releases?per_page=100"
readonly EXPECTED_CONFLICT="backend/src/ee/services/license/license-types.ts"

readonly LICENSE_PATH="LICENSE"
readonly EE_LICENSE_PATH="backend/src/ee/LICENSE.md"
readonly LICENSE_TEST_PATH="backend/src/ee/services/license/license-fns.test.ts"
readonly LICENSE_FNS_PATH="backend/src/ee/services/license/license-fns.ts"
readonly LICENSE_SERVICE_PATH="backend/src/ee/services/license/license-service.ts"
readonly LICENSE_TYPES_PATH="backend/src/ee/services/license/license-types.ts"
readonly PUBLISH_WORKFLOW_PATH=".github/workflows/release-fork-ghcr.yml"
readonly PREPARE_SCRIPT_PATH=".github/scripts/prepare-upstream-sync.sh"
readonly RELEASE_SCRIPT_PATH=".github/scripts/resolve-fork-release.sh"
readonly POLICY_TEST_PATH=".github/scripts/test-upstream-sync-policies.sh"
readonly SYNC_WORKFLOW_PATH=".github/workflows/sync-upstream.yml"
readonly -a REVIEWED_BASE_PATHS=(
  "$PREPARE_SCRIPT_PATH"
  "$RELEASE_SCRIPT_PATH"
  "$POLICY_TEST_PATH"
  "$SYNC_WORKFLOW_PATH"
  "$PUBLISH_WORKFLOW_PATH"
)

WORKTREE_TO_REMOVE=""
BRANCH_TO_DELETE=""
PREPARE_SUCCEEDED=0

cleanup() {
  if [[ -n "$WORKTREE_TO_REMOVE" ]]; then
    git worktree remove --force "$WORKTREE_TO_REMOVE" >/dev/null 2>&1 || true
  fi
  if [[ -n "$BRANCH_TO_DELETE" && "$PREPARE_SUCCEEDED" != "1" ]]; then
    git branch -D "$BRANCH_TO_DELETE" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

die() {
  printf 'prepare-upstream-sync: %s\n' "$*" >&2
  exit 1
}

log() {
  printf 'prepare-upstream-sync: %s\n' "$*" >&2
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_full_sha() {
  local name="$1"
  local value="$2"

  [[ "$value" =~ ^[0-9a-f]{40}$ ]] || die "$name must be a lowercase full 40-character commit SHA"
}

require_stable_tag() {
  local tag="$1"

  [[ "$tag" =~ ^v0\.[0-9]+\.[0-9]+$ ]] ||
    die "discovered upstream release tag must be an exact stable v0.x.y tag"
  git check-ref-format "refs/tags/$tag" >/dev/null 2>&1 || die "invalid upstream Git tag: $tag"
}

read_remote_tag_object() {
  local output_variable="$1"
  local upstream_url="$2"
  local upstream_tag="$3"
  local phase="$4"
  local fixture=""
  local output
  local object
  local ref

  case "$phase" in
    initial) fixture="${UPSTREAM_REMOTE_TAG_OBJECT_INITIAL_FIXTURE:-}" ;;
    final) fixture="${UPSTREAM_REMOTE_TAG_OBJECT_FINAL_FIXTURE:-}" ;;
    *) die "unknown remote tag verification phase: $phase" ;;
  esac

  if [[ -n "$fixture" ]]; then
    [[ "${ALLOW_LOCAL_FIXTURE_URL:-0}" == "1" ]] ||
      die "remote tag object fixtures are allowed only for local policy tests"
    require_full_sha "UPSTREAM_REMOTE_TAG_OBJECT_${phase^^}_FIXTURE" "$fixture"
    printf -v "$output_variable" '%s' "$fixture"
    return 0
  fi

  output="$(git ls-remote --refs "$upstream_url" "refs/tags/$upstream_tag")" ||
    die "failed to resolve canonical upstream tag $upstream_tag"
  [[ "$(awk 'NF { count++ } END { print count + 0 }' <<<"$output")" == "1" ]] ||
    die "canonical upstream tag $upstream_tag is absent or ambiguous"
  read -r object ref <<<"$output"
  require_full_sha "canonical upstream tag object" "$object"
  [[ "$ref" == "refs/tags/$upstream_tag" ]] || die "canonical upstream returned an unexpected tag ref"
  printf -v "$output_variable" '%s' "$object"
}

discover_upstream_release() {
  local output_tag_variable="$1"
  local output_release_id_variable="$2"
  local output_release_url_variable="$3"
  local output_published_at_variable="$4"
  local fixture_path="${UPSTREAM_RELEASE_FIXTURE_PATH:-}"
  local releases_json
  local release_json
  local tag
  local release_id
  local release_url
  local published_at

  if [[ -n "$fixture_path" ]]; then
    [[ "${ALLOW_LOCAL_FIXTURE_URL:-0}" == "1" ]] ||
      die "release API fixtures are allowed only for local policy tests"
    [[ -f "$fixture_path" ]] || die "release API fixture does not exist: $fixture_path"
    releases_json="$(<"$fixture_path")"
  else
    require_command gh
    releases_json="$(gh api --hostname github.com --method GET --paginate --slurp "$UPSTREAM_RELEASE_ENDPOINT")" ||
      die "canonical release discovery failed"
  fi

  jq -e 'type == "array" and all(.[]; type == "array")' <<<"$releases_json" >/dev/null ||
    die "canonical release API returned an invalid paginated response"
  release_json="$(jq -ce '
    [
      .[][] |
      select(
        type == "object" and
        .draft == false and
        .prerelease == false and
        (.id | type) == "number" and
        (.tag_name | type) == "string" and
        (.tag_name | test("^v0\\.[0-9]+\\.[0-9]+$")) and
        (.html_url | type) == "string" and
        (.published_at | type) == "string"
      )
    ] |
    sort_by(.published_at, .id) |
    last // empty
  ' <<<"$releases_json")" || die "no published stable v0.x.y upstream release was found"

  tag="$(jq -r '.tag_name' <<<"$release_json")"
  release_id="$(jq -r '.id | tostring' <<<"$release_json")"
  release_url="$(jq -r '.html_url' <<<"$release_json")"
  published_at="$(jq -r '.published_at' <<<"$release_json")"
  require_stable_tag "$tag"
  [[ "$release_url" == "https://github.com/Infisical/infisical/releases/tag/$tag" ]] ||
    die "latest release URL does not identify the canonical Infisical tag"

  printf -v "$output_tag_variable" '%s' "$tag"
  printf -v "$output_release_id_variable" '%s' "$release_id"
  printf -v "$output_release_url_variable" '%s' "$release_url"
  printf -v "$output_published_at_variable" '%s' "$published_at"
}

blob_at() {
  local repo="$1"
  local commit="$2"
  local path="$3"

  if git -C "$repo" cat-file -e "$commit:$path" 2>/dev/null; then
    git -C "$repo" rev-parse "$commit:$path"
  else
    printf 'absent\n'
  fi
}

require_regular_blob() {
  local repo="$1"
  local commit="$2"
  local path="$3"
  local optional="${4:-false}"
  local entry
  local mode
  local type

  entry="$(git -C "$repo" ls-tree "$commit" -- "$path")"
  if [[ -z "$entry" ]]; then
    [[ "$optional" == "true" ]] && return 0
    die "$path is absent from $commit"
  fi

  read -r mode type _ <<<"$entry"
  [[ "$type" == "blob" && ( "$mode" == "100644" || "$mode" == "100755" ) ]] ||
    die "$path at $commit must be a regular file, not mode=$mode type=$type"
}

restore_exact_path() {
  local repo="$1"
  local source="$2"
  local path="$3"

  if git -C "$repo" cat-file -e "$source:$path" 2>/dev/null; then
    require_regular_blob "$repo" "$source" "$path"
    git -C "$repo" restore --source="$source" --staged --worktree -- "$path"
  else
    git -C "$repo" rm -f --ignore-unmatch -- "$path" >/dev/null
  fi
}

sorted_unique_lines() {
  LC_ALL=C sort -u
}

reviewed_base_paths() {
  printf '%s\n' "${REVIEWED_BASE_PATHS[@]}" | sorted_unique_lines
}

assert_reviewed_base() {
  local repo="$1"
  local reviewed_base_tip="$2"
  local fork_tip="$3"
  local stage_a_merge="$4"
  local stage_a_head="$5"
  local parent_count
  local expected_paths
  local final_paths
  local history_paths
  local path

  git -C "$repo" cat-file -e "$fork_tip^{commit}" 2>/dev/null || die "immutable F0 is not available"
  git -C "$repo" cat-file -e "$stage_a_merge^{commit}" 2>/dev/null || die "reviewed Stage A merge is not available"
  git -C "$repo" cat-file -e "$stage_a_head^{commit}" 2>/dev/null || die "reviewed Stage A head is not available"

  parent_count="$(git -C "$repo" rev-list --parents -n 1 "$stage_a_merge" | awk '{print NF - 1}')"
  [[ "$parent_count" == "2" ]] || die "reviewed Stage A must be one merge commit"
  [[ "$(git -C "$repo" rev-parse "$stage_a_merge^1")" == "$fork_tip" ]] ||
    die "reviewed Stage A first parent is not immutable F0"
  [[ "$(git -C "$repo" rev-parse "$stage_a_merge^2")" == "$stage_a_head" ]] ||
    die "reviewed Stage A second parent is not the approved Stage A head"
  git -C "$repo" merge-base --is-ancestor "$stage_a_merge" "$reviewed_base_tip" ||
    die "reviewed base does not descend from the exact Stage A merge"

  expected_paths="$(reviewed_base_paths)"
  final_paths="$(git -C "$repo" diff --name-only "$fork_tip" "$reviewed_base_tip" | sorted_unique_lines)"
  history_paths="$(git -C "$repo" log -m --format= --name-only "$fork_tip..$reviewed_base_tip" | awk 'NF' | sorted_unique_lines)"
  [[ "$final_paths" == "$expected_paths" ]] || {
    printf 'Expected reviewed-base delta paths:\n%s\nActual final delta paths:\n%s\n' \
      "$expected_paths" "${final_paths:-<empty>}" >&2
    die "reviewed-base final delta is not the approved five-path Stage A surface"
  }
  [[ "$history_paths" == "$expected_paths" ]] || {
    printf 'Expected reviewed-base history paths:\n%s\nActual history paths:\n%s\n' \
      "$expected_paths" "${history_paths:-<empty>}" >&2
    die "reviewed-base history contains a change outside the approved Stage A surface"
  }

  for path in "${REVIEWED_BASE_PATHS[@]}"; do
    require_regular_blob "$repo" "$reviewed_base_tip" "$path"
  done
}

assert_stage_a_survives_pr_merge() {
  local repo="$1"
  local reviewed_base_tip="$2"
  local baseline_commit="$3"
  local merge_output
  local synthetic_tree
  local path

  if ! merge_output="$(git -C "$repo" merge-tree --write-tree "$reviewed_base_tip" "$baseline_commit" 2>&1)"; then
    printf '%s\n' "$merge_output" >&2
    die "generated baseline does not merge cleanly into the reviewed base"
  fi
  synthetic_tree="$(printf '%s\n' "$merge_output" | awk 'NR == 1 {print $1}')"
  [[ "$synthetic_tree" =~ ^[0-9a-f]{40}$ ]] || die "synthetic merge did not produce a full tree SHA"
  git -C "$repo" cat-file -e "$synthetic_tree^{tree}" 2>/dev/null || die "synthetic merge tree is unavailable"

  for path in "${REVIEWED_BASE_PATHS[@]}"; do
    assert_path_matches "$repo" "$reviewed_base_tip" "$synthetic_tree" "$path"
  done
  printf '%s\n' "$synthetic_tree"
}

assert_expected_conflicts() {
  local repo="$1"
  local actual

  actual="$(git -C "$repo" diff --name-only --diff-filter=U | sorted_unique_lines)"
  [[ "$actual" == "$EXPECTED_CONFLICT" ]] || {
    printf 'Expected conflict set:\n%s\nActual conflict set:\n%s\n' "$EXPECTED_CONFLICT" "${actual:-<empty>}" >&2
    die "unexpected merge conflict set; inventory review is required"
  }
}

assert_path_matches() {
  local repo="$1"
  local expected_commit="$2"
  local actual_commit="$3"
  local path="$4"

  [[ "$(blob_at "$repo" "$expected_commit" "$path")" == "$(blob_at "$repo" "$actual_commit" "$path")" ]] ||
    die "$path does not match required source $expected_commit"
}

assert_baseline_delta() {
  local repo="$1"
  local upstream_sha="$2"
  local baseline_commit="$3"
  local actual
  local expected

  expected="$(printf 'D\t%s\nM\t%s\nA\t%s\n' \
    "$EE_LICENSE_PATH" "$LICENSE_PATH" "$PUBLISH_WORKFLOW_PATH" | sorted_unique_lines)"
  actual="$(git -C "$repo" diff --name-status "$upstream_sha" "$baseline_commit" | sorted_unique_lines)"

  [[ "$actual" == "$expected" ]] || {
    printf 'Expected baseline delta:\n%s\nActual baseline delta:\n%s\n' "$expected" "${actual:-<empty>}" >&2
    die "baseline contains an unclassified delta"
  }
}

assert_baseline_commit() {
  local repo="$1"
  local baseline_commit="$2"
  local fork_tip="$3"
  local upstream_sha="$4"
  local upstream_tag="$5"
  local parent_count

  parent_count="$(git -C "$repo" rev-list --parents -n 1 "$baseline_commit" | awk '{print NF - 1}')"
  [[ "$parent_count" == "2" ]] || die "baseline must be one non-squashed merge commit"
  [[ "$(git -C "$repo" rev-parse "$baseline_commit^1")" == "$fork_tip" ]] ||
    die "baseline first parent is not the verified fork tip"
  [[ "$(git -C "$repo" rev-parse "$baseline_commit^2")" == "$upstream_sha" ]] ||
    die "baseline second parent is not the verified upstream commit"
  [[ "$(git -C "$repo" show -s --format=%s "$baseline_commit")" == "merge: sync upstream $upstream_tag" ]] ||
    die "baseline commit subject is not the generated sync subject"
  [[ "$(git -C "$repo" show -s --format=%an "$baseline_commit")" == "upstream-sync[bot]" ]] ||
    die "baseline commit author is not the sync bot"
  [[ "$(git -C "$repo" show -s --format=%ae "$baseline_commit")" == "upstream-sync[bot]@users.noreply.github.com" ]] ||
    die "baseline commit author email is not the sync bot"

  assert_path_matches "$repo" "$fork_tip" "$baseline_commit" "$LICENSE_PATH"
  [[ "$(blob_at "$repo" "$baseline_commit" "$EE_LICENSE_PATH")" == "absent" ]] ||
    die "$EE_LICENSE_PATH must remain absent"
  assert_path_matches "$repo" "$upstream_sha" "$baseline_commit" "$LICENSE_TEST_PATH"
  assert_path_matches "$repo" "$upstream_sha" "$baseline_commit" "$LICENSE_FNS_PATH"
  assert_path_matches "$repo" "$upstream_sha" "$baseline_commit" "$LICENSE_SERVICE_PATH"
  assert_path_matches "$repo" "$upstream_sha" "$baseline_commit" "$LICENSE_TYPES_PATH"
  assert_path_matches "$repo" "$fork_tip" "$baseline_commit" "$PUBLISH_WORKFLOW_PATH"
  assert_baseline_delta "$repo" "$upstream_sha" "$baseline_commit"
}

write_manifest() {
  local repo="$1"
  local output_path="$2"
  local upstream_tag="$3"
  local release_id="$4"
  local release_url="$5"
  local release_published_at="$6"
  local tag_object="$7"
  local upstream_sha="$8"
  local fork_tip="$9"
  local reviewed_base_tip="${10}"
  local stage_a_merge="${11}"
  local stage_a_head="${12}"
  local baseline_commit="${13}"
  local synthetic_merge_tree="${14}"
  local merge_base="${15}"
  local divergence="${16}"
  local decision="${17}"
  local branch="${18}"

  jq -n \
    --arg schemaVersion "1" \
    --arg upstreamTag "$upstream_tag" \
    --arg upstreamReleaseId "$release_id" \
    --arg upstreamReleaseUrl "$release_url" \
    --arg upstreamReleasePublishedAt "$release_published_at" \
    --arg upstreamTagObject "$tag_object" \
    --arg upstreamSha "$upstream_sha" \
    --arg forkTip "$fork_tip" \
    --arg reviewedBaseTip "$reviewed_base_tip" \
    --arg stageAMerge "$stage_a_merge" \
    --arg stageAHead "$stage_a_head" \
    --arg baselineCommit "$baseline_commit" \
    --arg syntheticMergeTree "$synthetic_merge_tree" \
    --arg mergeBase "$merge_base" \
    --arg divergence "$divergence" \
    --arg branch "$branch" \
    --arg decision "$decision" \
    --arg licenseFork "$(blob_at "$repo" "$fork_tip" "$LICENSE_PATH")" \
    --arg licenseUpstream "$(blob_at "$repo" "$upstream_sha" "$LICENSE_PATH")" \
    --arg licenseFinal "$(blob_at "$repo" "$baseline_commit" "$LICENSE_PATH")" \
    --arg eeFork "$(blob_at "$repo" "$fork_tip" "$EE_LICENSE_PATH")" \
    --arg eeUpstream "$(blob_at "$repo" "$upstream_sha" "$EE_LICENSE_PATH")" \
    --arg eeFinal "$(blob_at "$repo" "$baseline_commit" "$EE_LICENSE_PATH")" \
    --arg testFork "$(blob_at "$repo" "$fork_tip" "$LICENSE_TEST_PATH")" \
    --arg testUpstream "$(blob_at "$repo" "$upstream_sha" "$LICENSE_TEST_PATH")" \
    --arg testFinal "$(blob_at "$repo" "$baseline_commit" "$LICENSE_TEST_PATH")" \
    --arg fnsFork "$(blob_at "$repo" "$fork_tip" "$LICENSE_FNS_PATH")" \
    --arg fnsUpstream "$(blob_at "$repo" "$upstream_sha" "$LICENSE_FNS_PATH")" \
    --arg fnsFinal "$(blob_at "$repo" "$baseline_commit" "$LICENSE_FNS_PATH")" \
    --arg serviceFork "$(blob_at "$repo" "$fork_tip" "$LICENSE_SERVICE_PATH")" \
    --arg serviceUpstream "$(blob_at "$repo" "$upstream_sha" "$LICENSE_SERVICE_PATH")" \
    --arg serviceFinal "$(blob_at "$repo" "$baseline_commit" "$LICENSE_SERVICE_PATH")" \
    --arg typesFork "$(blob_at "$repo" "$fork_tip" "$LICENSE_TYPES_PATH")" \
    --arg typesUpstream "$(blob_at "$repo" "$upstream_sha" "$LICENSE_TYPES_PATH")" \
    --arg typesFinal "$(blob_at "$repo" "$baseline_commit" "$LICENSE_TYPES_PATH")" \
    --arg workflowFork "$(blob_at "$repo" "$fork_tip" "$PUBLISH_WORKFLOW_PATH")" \
    --arg workflowUpstream "$(blob_at "$repo" "$upstream_sha" "$PUBLISH_WORKFLOW_PATH")" \
    --arg workflowFinal "$(blob_at "$repo" "$baseline_commit" "$PUBLISH_WORKFLOW_PATH")" \
    '{
      schemaVersion: ($schemaVersion | tonumber),
      targetSelection: "latest-published-stable-release",
      upstreamTag: $upstreamTag,
      upstreamReleaseId: $upstreamReleaseId,
      upstreamReleaseUrl: $upstreamReleaseUrl,
      upstreamReleasePublishedAt: $upstreamReleasePublishedAt,
      upstreamTagObject: $upstreamTagObject,
      upstreamSha: $upstreamSha,
      forkTip: $forkTip,
      reviewedBaseTip: $reviewedBaseTip,
      stageAMerge: $stageAMerge,
      stageAHead: $stageAHead,
      baselineCommit: $baselineCommit,
      syntheticMergeTree: $syntheticMergeTree,
      mergeBase: $mergeBase,
      divergence: $divergence,
      branch: $branch,
      decision: $decision,
      conflicts: ["backend/src/ee/services/license/license-types.ts"],
      protectedPaths: [
        {path: "LICENSE", forkBlob: $licenseFork, upstreamBlob: $licenseUpstream, finalBlob: $licenseFinal, policy: "exact-fork-blob", disposition: "exact-fork-blob", validation: "byte-for-byte blob equality with forkTip"},
        {path: "backend/src/ee/LICENSE.md", forkBlob: $eeFork, upstreamBlob: $eeUpstream, finalBlob: $eeFinal, policy: "absent", disposition: "absent", validation: "final path is absent"},
        {path: "backend/src/ee/services/license/license-fns.test.ts", forkBlob: $testFork, upstreamBlob: $testUpstream, finalBlob: $testFinal, policy: "upstream-baseline", disposition: "pending-adaptation", validation: "must be freshly adapted or documented upstream-equivalent before review-ready"},
        {path: "backend/src/ee/services/license/license-fns.ts", forkBlob: $fnsFork, upstreamBlob: $fnsUpstream, finalBlob: $fnsFinal, policy: "upstream-baseline", disposition: "pending-adaptation", validation: "feature-set tests required"},
        {path: "backend/src/ee/services/license/license-service.ts", forkBlob: $serviceFork, upstreamBlob: $serviceUpstream, finalBlob: $serviceFinal, policy: "upstream-baseline", disposition: "pending-adaptation", validation: "license initialization-path tests required"},
        {path: "backend/src/ee/services/license/license-types.ts", forkBlob: $typesFork, upstreamBlob: $typesUpstream, finalBlob: $typesFinal, policy: "upstream-baseline", disposition: "pending-adaptation", validation: "complete schema and typecheck proof required"},
        {path: ".github/workflows/release-fork-ghcr.yml", forkBlob: $workflowFork, upstreamBlob: $workflowUpstream, finalBlob: $workflowFinal, policy: "fork-publisher", disposition: "pending-hardening", validation: "immutable T/U/F workflow review and fixtures required"}
      ],
      classifiedBaselineDelta: [
        {path: "LICENSE", status: "modified", classification: "licensing-policy"},
        {path: "backend/src/ee/LICENSE.md", status: "deleted", classification: "licensing-policy"},
        {path: ".github/workflows/release-fork-ghcr.yml", status: "added", classification: "fork-publisher"}
      ]
    }' >"$output_path"

  validate_manifest "$output_path" false
}

validate_manifest() {
  local manifest_path="$1"
  local require_final="${2:-false}"

  jq -e --argjson requireFinal "$require_final" '
    .targetSelection == "latest-published-stable-release" and
    (.upstreamTag | test("^v0\\.[0-9]+\\.[0-9]+$")) and
    (.upstreamReleaseId | test("^[0-9]+$")) and
    .upstreamReleaseUrl == ("https://github.com/Infisical/infisical/releases/tag/" + .upstreamTag) and
    (.upstreamReleasePublishedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")) and
    (.upstreamTagObject | test("^[0-9a-f]{40}$")) and
    (.upstreamSha | test("^[0-9a-f]{40}$")) and
    (.protectedPaths | length) == 7 and
    ([.protectedPaths[].path] | length == (unique | length)) and
    ([.protectedPaths[].path] == [
      "LICENSE",
      "backend/src/ee/LICENSE.md",
      "backend/src/ee/services/license/license-fns.test.ts",
      "backend/src/ee/services/license/license-fns.ts",
      "backend/src/ee/services/license/license-service.ts",
      "backend/src/ee/services/license/license-types.ts",
      ".github/workflows/release-fork-ghcr.yml"
    ]) and
    (all(.protectedPaths[]; (.forkBlob | type) == "string" and (.upstreamBlob | type) == "string" and (.finalBlob | type) == "string")) and
    (if $requireFinal then all(.protectedPaths[]; (.disposition | startswith("pending-") | not)) else true end)
  ' "$manifest_path" >/dev/null || die "protected-path manifest is incomplete or has unresolved dispositions"
}

write_pr_body() {
  local manifest_path="$1"
  local output_path="$2"

  jq -r '
    "## Guarded upstream baseline\n\n" +
    "This draft contains only the mechanically prepared whole-tree merge baseline. It must remain draft until every pending protected-path disposition is resolved and the full validation matrix passes.\n\n" +
    "| Identity | Value |\n| --- | --- |\n" +
    "| Upstream tag | `" + .upstreamTag + "` |\n" +
    "| Target selection | Latest published stable release, frozen at run start |\n" +
    "| Upstream release ID | `" + .upstreamReleaseId + "` |\n" +
    "| Upstream release published | `" + .upstreamReleasePublishedAt + "` |\n" +
    "| Upstream tag object | `" + .upstreamTagObject + "` |\n" +
    "| Upstream commit (U) | `" + .upstreamSha + "` |\n" +
    "| Immutable fork tip (F0) | `" + .forkTip + "` |\n" +
    "| Reviewed base tip | `" + .reviewedBaseTip + "` |\n" +
    "| Reviewed Stage A merge | `" + .stageAMerge + "` |\n" +
    "| Reviewed Stage A head | `" + .stageAHead + "` |\n" +
    "| Merge base | `" + .mergeBase + "` |\n" +
    "| Divergence (fork/upstream) | `" + .divergence + "` |\n" +
    "| Baseline merge | `" + .baselineCommit + "` |\n" +
    "| Synthetic main merge tree | `" + .syntheticMergeTree + "` |\n\n" +
    "### Protected paths\n\n| Path | Fork blob | Upstream blob | Final blob | Disposition | Validation |\n| --- | --- | --- | --- | --- | --- |\n" +
    ([.protectedPaths[] | "| `" + .path + "` | `" + .forkBlob + "` | `" + .upstreamBlob + "` | `" + .finalBlob + "` | `" + .disposition + "` | " + .validation + " |"] | join("\n")) +
    "\n\n### Classified baseline delta\n\n" +
    ([.classifiedBaselineDelta[] | "- `" + .status + "` `" + .path + "`: " + .classification] | join("\n")) +
    "\n\n### Required before review-ready\n\n" +
    "- Obtain the approved values for every new `TFeatureSet` field and freshly adapt all four Enterprise Mode paths.\n" +
    "- Harden and test the fork publisher under the immutable `T/U/F` contract.\n" +
    "- Classify every additional `U..F` path and replace all pending dispositions with tested final dispositions.\n" +
    "- Complete migration rehearsal, backend validation, Docker build, canary, rollback, and release-owner gates.\n\n" +
    "The automation cannot approve, merge, tag, publish, deploy, force-push, or bypass branch protection."
  ' "$manifest_path" >"$output_path"
}

main() {
  require_command git
  require_command jq
  require_command sort

  if [[ -n "${VALIDATE_MANIFEST_PATH:-}" ]]; then
    validate_manifest "$VALIDATE_MANIFEST_PATH" "${REQUIRE_FINAL_MANIFEST:-false}"
    return 0
  fi

  local expected_fork_tip="${EXPECTED_FORK_TIP:-}"
  local expected_reviewed_base_tip="${EXPECTED_REVIEWED_BASE_TIP:-}"
  local expected_stage_a_merge="${EXPECTED_STAGE_A_MERGE:-}"
  local expected_stage_a_head="${EXPECTED_STAGE_A_HEAD:-}"
  local upstream_url="${UPSTREAM_URL:-$DEFAULT_UPSTREAM_URL}"
  local origin_remote="${ORIGIN_REMOTE:-$DEFAULT_ORIGIN_REMOTE}"
  local base_branch="${BASE_BRANCH:-main}"
  local evidence_path="${EVIDENCE_PATH:-$PWD/upstream-sync-evidence.json}"
  local pr_body_path="${PR_BODY_PATH:-$PWD/upstream-sync-pr-body.md}"
  local work_root="${WORK_ROOT:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}}"
  local sync_branch
  local upstream_ref
  local remote_sync_ref
  local remote_branch_output
  local remote_branch_head
  local remote_branch_ref
  local final_remote_branch_output
  local final_remote_branch_head
  local final_remote_branch_ref
  local upstream_tag
  local upstream_release_id
  local upstream_release_url
  local upstream_release_published_at
  local initial_tag_object
  local final_tag_object
  local tag_object
  local upstream_sha
  local fork_tip
  local reviewed_base_tip
  local merge_base
  local divergence
  local worktree
  local baseline_commit
  local synthetic_merge_tree
  local index_tree
  local decision

  [[ -n "$expected_fork_tip" ]] || die "EXPECTED_FORK_TIP is required"
  [[ -n "$expected_reviewed_base_tip" ]] || die "EXPECTED_REVIEWED_BASE_TIP is required"
  [[ -n "$expected_stage_a_merge" ]] || die "EXPECTED_STAGE_A_MERGE is required"
  [[ -n "$expected_stage_a_head" ]] || die "EXPECTED_STAGE_A_HEAD is required"
  require_full_sha EXPECTED_FORK_TIP "$expected_fork_tip"
  require_full_sha EXPECTED_REVIEWED_BASE_TIP "$expected_reviewed_base_tip"
  require_full_sha EXPECTED_STAGE_A_MERGE "$expected_stage_a_merge"
  require_full_sha EXPECTED_STAGE_A_HEAD "$expected_stage_a_head"
  [[ "$upstream_url" == "$DEFAULT_UPSTREAM_URL" || "${ALLOW_LOCAL_FIXTURE_URL:-0}" == "1" ]] ||
    die "UPSTREAM_URL must remain the canonical Infisical repository"
  [[ "$origin_remote" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid origin remote name"
  [[ "$base_branch" == "main" || "$base_branch" == "dev" ]] || die "BASE_BRANCH must be main or dev"

  discover_upstream_release upstream_tag upstream_release_id upstream_release_url upstream_release_published_at
  read_remote_tag_object initial_tag_object "$upstream_url" "$upstream_tag" initial

  sync_branch="sync/upstream-$upstream_tag"
  git check-ref-format "refs/heads/$sync_branch" >/dev/null 2>&1 || die "invalid sync branch: $sync_branch"
  upstream_ref="refs/upstream-sync/tags/$upstream_tag-$initial_tag_object"
  remote_sync_ref="refs/remotes/$origin_remote/$sync_branch"

  [[ -z "$(git status --porcelain --untracked-files=no)" ]] || die "tracked worktree changes are not allowed"
  git fetch --no-tags "$origin_remote" "+refs/heads/$base_branch:refs/remotes/$origin_remote/$base_branch"
  reviewed_base_tip="$(git rev-parse "refs/remotes/$origin_remote/$base_branch^{commit}")"
  [[ "$reviewed_base_tip" == "$expected_reviewed_base_tip" ]] ||
    die "reviewed base moved: expected $expected_reviewed_base_tip, found $reviewed_base_tip; fresh confirmation is required"
  fork_tip="$expected_fork_tip"
  assert_reviewed_base "$PWD" "$reviewed_base_tip" "$fork_tip" "$expected_stage_a_merge" "$expected_stage_a_head"

  if ! git show-ref --verify --quiet "$upstream_ref"; then
    git fetch --no-tags "$upstream_url" "refs/tags/$upstream_tag:$upstream_ref"
  fi
  tag_object="$(git rev-parse "$upstream_ref")"
  [[ "$tag_object" == "$initial_tag_object" ]] ||
    die "canonical upstream tag object changed while it was being fetched"
  upstream_sha="$(git rev-parse "$upstream_ref^{commit}")"
  require_full_sha "discovered peeled upstream commit" "$upstream_sha"
  read_remote_tag_object final_tag_object "$upstream_url" "$upstream_tag" final
  [[ "$final_tag_object" == "$initial_tag_object" ]] ||
    die "canonical upstream tag moved during discovery; no target was frozen"

  require_regular_blob "$PWD" "$fork_tip" "$LICENSE_PATH"
  require_regular_blob "$PWD" "$fork_tip" "$PUBLISH_WORKFLOW_PATH"
  require_regular_blob "$PWD" "$upstream_sha" "$LICENSE_TEST_PATH" true
  require_regular_blob "$PWD" "$upstream_sha" "$LICENSE_FNS_PATH"
  require_regular_blob "$PWD" "$upstream_sha" "$LICENSE_SERVICE_PATH"
  require_regular_blob "$PWD" "$upstream_sha" "$LICENSE_TYPES_PATH"

  merge_base="$(git merge-base "$fork_tip" "$upstream_sha")"
  divergence="$(git rev-list --left-right --count "$fork_tip...$upstream_sha" | tr '\t' '/')"

  remote_branch_output="$(git ls-remote --heads "$origin_remote" "refs/heads/$sync_branch")" ||
    die "failed to determine whether protected sync branch $sync_branch exists"
  if [[ -n "$remote_branch_output" ]]; then
    [[ "$(awk 'NF { count++ } END { print count + 0 }' <<<"$remote_branch_output")" == "1" ]] ||
      die "protected sync branch $sync_branch resolved ambiguously"
    read -r remote_branch_head remote_branch_ref <<<"$remote_branch_output"
    require_full_sha "remote sync branch head" "$remote_branch_head"
    [[ "$remote_branch_ref" == "refs/heads/$sync_branch" ]] || die "origin returned an unexpected sync branch ref"
    git fetch --no-tags "$origin_remote" "+refs/heads/$sync_branch:$remote_sync_ref" ||
      die "failed to fetch existing protected sync branch"
    baseline_commit="$(git rev-parse "$remote_sync_ref^{commit}")"
    [[ "$baseline_commit" == "$remote_branch_head" ]] || die "fetched sync branch does not match its observed head"
    assert_baseline_commit "$PWD" "$baseline_commit" "$fork_tip" "$upstream_sha" "$upstream_tag"
    final_remote_branch_output="$(git ls-remote --heads "$origin_remote" "refs/heads/$sync_branch")" ||
      die "failed to revalidate protected sync branch $sync_branch"
    read -r final_remote_branch_head final_remote_branch_ref <<<"$final_remote_branch_output"
    [[ "$final_remote_branch_head" == "$remote_branch_head" && "$final_remote_branch_ref" == "$remote_branch_ref" ]] ||
      die "protected sync branch moved during verification"
    decision="noop"
    log "verified existing generated branch $sync_branch at $baseline_commit"
  else
    git update-ref -d "$remote_sync_ref"
    [[ ! -e "$evidence_path" ]] || die "evidence output already exists: $evidence_path"
    [[ ! -e "$pr_body_path" ]] || die "PR body output already exists: $pr_body_path"
    [[ ! -e "$work_root/upstream-sync-$upstream_tag" ]] || die "worktree path already exists"
    if git show-ref --verify --quiet "refs/heads/$sync_branch"; then
      die "local branch collision at refs/heads/$sync_branch"
    fi

    worktree="$work_root/upstream-sync-$upstream_tag"
    git worktree add --detach "$worktree" "$fork_tip" >/dev/null
    WORKTREE_TO_REMOVE="$worktree"
    git -C "$worktree" switch -c "$sync_branch" >/dev/null
    BRANCH_TO_DELETE="$sync_branch"

    if git -C "$worktree" \
      -c user.name="upstream-sync[bot]" \
      -c user.email="upstream-sync[bot]@users.noreply.github.com" \
      merge --no-ff --no-commit "$upstream_sha"; then
      die "expected reviewed conflict $EXPECTED_CONFLICT was not produced; inventory review is required"
    fi
    [[ -f "$worktree/.git/MERGE_HEAD" || -f "$(git -C "$worktree" rev-parse --git-path MERGE_HEAD)" ]] ||
      git -C "$worktree" rev-parse --verify -q MERGE_HEAD >/dev/null || die "merge did not enter a resolvable conflict state"
    assert_expected_conflicts "$worktree"

    restore_exact_path "$worktree" "$fork_tip" "$LICENSE_PATH"
    git -C "$worktree" rm -f --ignore-unmatch -- "$EE_LICENSE_PATH" >/dev/null
    restore_exact_path "$worktree" "$upstream_sha" "$LICENSE_TEST_PATH"
    restore_exact_path "$worktree" "$upstream_sha" "$LICENSE_FNS_PATH"
    restore_exact_path "$worktree" "$upstream_sha" "$LICENSE_SERVICE_PATH"
    restore_exact_path "$worktree" "$upstream_sha" "$LICENSE_TYPES_PATH"
    restore_exact_path "$worktree" "$fork_tip" "$PUBLISH_WORKFLOW_PATH"

    [[ -z "$(git -C "$worktree" diff --name-only --diff-filter=U)" ]] || die "unmerged paths remain"
    git -C "$worktree" diff --check "$upstream_sha" -- \
      "$LICENSE_PATH" "$EE_LICENSE_PATH" "$PUBLISH_WORKFLOW_PATH"
    index_tree="$(git -C "$worktree" write-tree)"
    assert_path_matches "$worktree" "$fork_tip" "$index_tree" "$LICENSE_PATH"
    [[ "$(blob_at "$worktree" "$index_tree" "$EE_LICENSE_PATH")" == "absent" ]] || die "$EE_LICENSE_PATH was recreated"
    assert_path_matches "$worktree" "$upstream_sha" "$index_tree" "$LICENSE_TEST_PATH"
    assert_path_matches "$worktree" "$upstream_sha" "$index_tree" "$LICENSE_FNS_PATH"
    assert_path_matches "$worktree" "$upstream_sha" "$index_tree" "$LICENSE_SERVICE_PATH"
    assert_path_matches "$worktree" "$upstream_sha" "$index_tree" "$LICENSE_TYPES_PATH"
    assert_path_matches "$worktree" "$fork_tip" "$index_tree" "$PUBLISH_WORKFLOW_PATH"
    assert_baseline_delta "$worktree" "$upstream_sha" "$index_tree"

    git -C "$worktree" \
      -c user.name="upstream-sync[bot]" \
      -c user.email="upstream-sync[bot]@users.noreply.github.com" \
      commit -m "merge: sync upstream $upstream_tag" >/dev/null
    baseline_commit="$(git -C "$worktree" rev-parse HEAD)"
    assert_baseline_commit "$worktree" "$baseline_commit" "$fork_tip" "$upstream_sha" "$upstream_tag"
    decision="prepare"
    log "prepared $sync_branch at $baseline_commit without pushing"
  fi

  synthetic_merge_tree="$(assert_stage_a_survives_pr_merge "$PWD" "$reviewed_base_tip" "$baseline_commit")"

  write_manifest "$PWD" "$evidence_path" "$upstream_tag" "$upstream_release_id" "$upstream_release_url" \
    "$upstream_release_published_at" "$tag_object" "$upstream_sha" "$fork_tip" "$reviewed_base_tip" \
    "$expected_stage_a_merge" "$expected_stage_a_head" "$baseline_commit" \
    "$synthetic_merge_tree" "$merge_base" "$divergence" "$decision" "$sync_branch"
  write_pr_body "$evidence_path" "$pr_body_path"

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      printf 'decision=%s\n' "$decision"
      printf 'branch=%s\n' "$sync_branch"
      printf 'baseline_commit=%s\n' "$baseline_commit"
      printf 'upstream_tag=%s\n' "$upstream_tag"
      printf 'upstream_release_id=%s\n' "$upstream_release_id"
      printf 'upstream_tag_object=%s\n' "$tag_object"
      printf 'upstream_sha=%s\n' "$upstream_sha"
      printf 'fork_tip=%s\n' "$fork_tip"
      printf 'reviewed_base_tip=%s\n' "$reviewed_base_tip"
      printf 'synthetic_merge_tree=%s\n' "$synthetic_merge_tree"
      printf 'evidence_path=%s\n' "$evidence_path"
      printf 'pr_body_path=%s\n' "$pr_body_path"
    } >>"$GITHUB_OUTPUT"
  fi

  PREPARE_SUCCEEDED=1
}

main "$@"
