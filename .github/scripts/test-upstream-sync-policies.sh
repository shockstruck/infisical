#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly PREPARE_SCRIPT="$SCRIPT_DIR/prepare-upstream-sync.sh"
readonly RELEASE_SCRIPT="$SCRIPT_DIR/resolve-fork-release.sh"
readonly IMAGE="ghcr.io/shockstruck/infisical"

die() {
  printf 'test-upstream-sync-policies: %s\n' "$*" >&2
  exit 1
}

expect_failure() {
  local name="$1"
  shift

  if "$@" >"$ROOT/$name.stdout" 2>"$ROOT/$name.stderr"; then
    die "$name unexpectedly succeeded"
  fi
}

write_base_tree() {
  mkdir -p backend/src/ee/services/license .github/workflows
  printf 'canonical upstream license\n' > LICENSE
  printf 'enterprise notice\n' > backend/src/ee/LICENSE.md
  printf 'upstream=base\nshared-a\nshared-b\nshared-c\nfork=base\n' > backend/src/ee/services/license/license-fns.ts
  printf 'refresh=base\nshared-a\nshared-b\nshared-c\noverride=base\n' > backend/src/ee/services/license/license-service.ts
  printf 'feature=base\n' > backend/src/ee/services/license/license-types.ts
  printf 'base\n' > unexpected.txt
  git add .
  git commit -m base >/dev/null
}

prepare_fixture() {
  mkdir -p "$ROOT/source"
  git -C "$ROOT/source" init -b main >/dev/null
  git -C "$ROOT/source" config user.name fixture
  git -C "$ROOT/source" config user.email fixture@example.com

  (
    cd "$ROOT/source"
    write_base_tree
  )
  BASE_SHA="$(git -C "$ROOT/source" rev-parse HEAD)"

  git -C "$ROOT/source" switch -c fork >/dev/null
  printf 'fork license policy\n' > "$ROOT/source/LICENSE"
  git -C "$ROOT/source" rm backend/src/ee/LICENSE.md >/dev/null
  printf 'upstream=base\nshared-a\nshared-b\nshared-c\nfork=enterprise\n' > "$ROOT/source/backend/src/ee/services/license/license-fns.ts"
  printf 'refresh=base\nshared-a\nshared-b\nshared-c\noverride=enterprise\n' > "$ROOT/source/backend/src/ee/services/license/license-service.ts"
  printf 'feature=enterprise\n' > "$ROOT/source/backend/src/ee/services/license/license-types.ts"
  printf 'enterprise test\n' > "$ROOT/source/backend/src/ee/services/license/license-fns.test.ts"
  printf 'fork publisher\n' > "$ROOT/source/.github/workflows/release-fork-ghcr.yml"
  git -C "$ROOT/source" add .
  git -C "$ROOT/source" commit -m fork >/dev/null
  FORK_SHA="$(git -C "$ROOT/source" rev-parse HEAD)"

  git -C "$ROOT/source" switch -c fork-conflict >/dev/null
  printf 'fork conflict\n' > "$ROOT/source/unexpected.txt"
  git -C "$ROOT/source" add unexpected.txt
  git -C "$ROOT/source" commit -m fork-conflict >/dev/null
  FORK_CONFLICT_SHA="$(git -C "$ROOT/source" rev-parse HEAD)"

  git -C "$ROOT/source" switch -c upstream "$BASE_SHA" >/dev/null
  printf 'upstream=target\nshared-a\nshared-b\nshared-c\nfork=base\n' > "$ROOT/source/backend/src/ee/services/license/license-fns.ts"
  printf 'refresh=target\nshared-a\nshared-b\nshared-c\noverride=base\n' > "$ROOT/source/backend/src/ee/services/license/license-service.ts"
  printf 'feature=target\n' > "$ROOT/source/backend/src/ee/services/license/license-types.ts"
  printf 'upstream target\n' > "$ROOT/source/upstream-only.txt"
  git -C "$ROOT/source" add .
  git -C "$ROOT/source" commit -m upstream >/dev/null
  UPSTREAM_SHA="$(git -C "$ROOT/source" rev-parse HEAD)"
  git -C "$ROOT/source" tag v0.162.15 "$UPSTREAM_SHA"

  git -C "$ROOT/source" switch -c upstream-conflict "$BASE_SHA" >/dev/null
  printf 'upstream=next\nshared-a\nshared-b\nshared-c\nfork=base\n' > "$ROOT/source/backend/src/ee/services/license/license-fns.ts"
  printf 'refresh=next\nshared-a\nshared-b\nshared-c\noverride=base\n' > "$ROOT/source/backend/src/ee/services/license/license-service.ts"
  printf 'feature=next\n' > "$ROOT/source/backend/src/ee/services/license/license-types.ts"
  printf 'upstream conflict\n' > "$ROOT/source/unexpected.txt"
  git -C "$ROOT/source" add .
  git -C "$ROOT/source" commit -m upstream-conflict >/dev/null
  CONFLICT_SHA="$(git -C "$ROOT/source" rev-parse HEAD)"
  git -C "$ROOT/source" tag v0.162.16 "$CONFLICT_SHA"

  git init --bare "$ROOT/fork.git" >/dev/null
  git init --bare "$ROOT/upstream.git" >/dev/null
  git -C "$ROOT/source" push "$ROOT/fork.git" "$FORK_SHA:refs/heads/main" >/dev/null
  git -C "$ROOT/source" push "$ROOT/upstream.git" \
    refs/tags/v0.162.15 refs/tags/v0.162.16 >/dev/null
  git --git-dir="$ROOT/fork.git" symbolic-ref HEAD refs/heads/main
  git clone --bare "$ROOT/fork.git" "$ROOT/fork-pristine.git" >/dev/null
  git clone --branch main "$ROOT/fork.git" "$ROOT/work" >/dev/null
}

run_prepare() {
  local repo="$1"
  local remote="$2"
  local tag="$3"
  local upstream_sha="$4"
  local fork_sha="$5"
  local output_prefix="$6"

  (
    cd "$repo"
    ALLOW_LOCAL_FIXTURE_URL=1 \
      UPSTREAM_URL="$ROOT/upstream.git" \
      UPSTREAM_TAG="$tag" \
      EXPECTED_UPSTREAM_SHA="$upstream_sha" \
      EXPECTED_FORK_TIP="$fork_sha" \
      ORIGIN_REMOTE="$remote" \
      EVIDENCE_PATH="$ROOT/$output_prefix.json" \
      PR_BODY_PATH="$ROOT/$output_prefix.md" \
      WORK_ROOT="$ROOT" \
      "$PREPARE_SCRIPT"
  )
}

clone_scenario() {
  local name="$1"

  git clone --bare "$ROOT/fork-pristine.git" "$ROOT/$name.git" >/dev/null
  git clone --branch main "$ROOT/$name.git" "$ROOT/$name-work" >/dev/null
}

make_tampered_merge() {
  local repo="$1"
  local mutation="$2"
  local output_ref="$3"
  local tree
  local commit

  git -C "$repo" fetch "$ROOT/work" "$VALID_BASELINE" >/dev/null
  git -C "$repo" switch --detach "$VALID_BASELINE" >/dev/null
  case "$mutation" in
    ee-license)
      git -C "$repo" restore --source="$UPSTREAM_SHA" --staged --worktree -- backend/src/ee/LICENSE.md
      ;;
    root-license)
      printf 'tampered\n' > "$repo/LICENSE"
      git -C "$repo" add LICENSE
      ;;
    runtime)
      printf 'tampered\n' > "$repo/backend/src/ee/services/license/license-fns.ts"
      git -C "$repo" add backend/src/ee/services/license/license-fns.ts
      ;;
    extra-delta)
      printf 'unclassified\n' > "$repo/unclassified.txt"
      git -C "$repo" add unclassified.txt
      ;;
    *) die "unknown tamper mutation: $mutation" ;;
  esac

  tree="$(git -C "$repo" write-tree)"
  commit="$(printf 'merge: sync upstream v0.162.15\n' | \
    GIT_AUTHOR_NAME='upstream-sync[bot]' \
    GIT_AUTHOR_EMAIL='upstream-sync[bot]@users.noreply.github.com' \
    GIT_COMMITTER_NAME='upstream-sync[bot]' \
    GIT_COMMITTER_EMAIL='upstream-sync[bot]@users.noreply.github.com' \
    git -C "$repo" commit-tree "$tree" -p "$FORK_SHA" -p "$UPSTREAM_SHA")"
  git -C "$repo" push origin "$commit:$output_ref" >/dev/null
}

test_prepare_policy() {
  run_prepare "$ROOT/work" origin v0.162.15 "$UPSTREAM_SHA" "$FORK_SHA" first
  jq -e '
    .decision == "prepare" and
    .upstreamSha == $u and
    .forkTip == $f and
    (.protectedPaths | length) == 7 and
    ([.classifiedBaselineDelta[].path] | sort) == (["LICENSE", "backend/src/ee/LICENSE.md", ".github/workflows/release-fork-ghcr.yml"] | sort)
  ' --arg u "$UPSTREAM_SHA" --arg f "$FORK_SHA" "$ROOT/first.json" >/dev/null
  if git --git-dir="$ROOT/fork.git" show-ref --verify --quiet refs/heads/sync/upstream-v0.162.15; then
    die "no-push preparation changed the fixture remote"
  fi

  VALID_BASELINE="$(git -C "$ROOT/work" rev-parse refs/heads/sync/upstream-v0.162.15)"
  git -C "$ROOT/work" push origin refs/heads/sync/upstream-v0.162.15 >/dev/null
  run_prepare "$ROOT/work" origin v0.162.15 "$UPSTREAM_SHA" "$FORK_SHA" rerun
  jq -e '.decision == "noop"' "$ROOT/rerun.json" >/dev/null

  clone_scenario moved
  git -C "$ROOT/moved-work" config user.name fixture
  git -C "$ROOT/moved-work" config user.email fixture@example.com
  printf 'moved\n' > "$ROOT/moved-work/moved.txt"
  git -C "$ROOT/moved-work" add moved.txt
  git -C "$ROOT/moved-work" commit -m moved >/dev/null
  git -C "$ROOT/moved-work" push origin HEAD:refs/heads/main >/dev/null
  expect_failure moved-target run_prepare "$ROOT/moved-work" origin v0.162.15 "$UPSTREAM_SHA" "$FORK_SHA" moved-target

  clone_scenario collision
  git -C "$ROOT/collision-work" push origin "$FORK_SHA:refs/heads/sync/upstream-v0.162.15" >/dev/null
  expect_failure branch-collision run_prepare "$ROOT/collision-work" origin v0.162.15 "$UPSTREAM_SHA" "$FORK_SHA" branch-collision

  clone_scenario unexpected
  git -C "$ROOT/unexpected-work" fetch "$ROOT/source" "$FORK_CONFLICT_SHA" >/dev/null
  git -C "$ROOT/unexpected-work" push origin "$FORK_CONFLICT_SHA:refs/heads/main" >/dev/null
  expect_failure unexpected-conflict run_prepare "$ROOT/unexpected-work" origin v0.162.16 "$CONFLICT_SHA" "$FORK_CONFLICT_SHA" unexpected-conflict

  clone_scenario tag-mismatch
  expect_failure tag-sha-mismatch run_prepare "$ROOT/tag-mismatch-work" origin v0.162.15 "0000000000000000000000000000000000000000" "$FORK_SHA" tag-mismatch

  local scenario
  local mutation
  for scenario in recreated-ee changed-license changed-runtime extra-delta; do
    clone_scenario "$scenario"
    case "$scenario" in
      recreated-ee) mutation=ee-license ;;
      changed-license) mutation=root-license ;;
      changed-runtime) mutation=runtime ;;
      extra-delta) mutation=extra-delta ;;
    esac
    make_tampered_merge "$ROOT/$scenario-work" "$mutation" refs/heads/sync/upstream-v0.162.15
    expect_failure "$scenario" run_prepare "$ROOT/$scenario-work" origin v0.162.15 "$UPSTREAM_SHA" "$FORK_SHA" "$scenario"
  done

  jq 'del(.protectedPaths[0])' "$ROOT/first.json" > "$ROOT/omitted.json"
  expect_failure omitted-manifest env VALIDATE_MANIFEST_PATH="$ROOT/omitted.json" "$PREPARE_SCRIPT"
  expect_failure unresolved-adaptation env VALIDATE_MANIFEST_PATH="$ROOT/first.json" REQUIRE_FINAL_MANIFEST=true "$PREPARE_SCRIPT"
}

test_release_policy() {
  local stable="$ROOT/stable.json"
  local prerelease="$ROOT/prerelease.json"

  env DRY_RUN=1 IMAGE="$IMAGE" UPSTREAM_TAG=v0.162.15 UPSTREAM_SHA="$UPSTREAM_SHA" \
    FORK_SHA="$FORK_SHA" REGISTRY_FIXTURE=absent "$RELEASE_SCRIPT" > "$stable"
  jq -e --arg f "$FORK_SHA" '
    .stable and .decision == "publish" and
    .tags == [
      "ghcr.io/shockstruck/infisical:v0.162.15",
      "ghcr.io/shockstruck/infisical:sha-" + $f,
      "ghcr.io/shockstruck/infisical:latest"
    ]
  ' "$stable" >/dev/null

  env DRY_RUN=1 IMAGE="$IMAGE" UPSTREAM_TAG=v0.162.15-nightly-20260730 UPSTREAM_SHA="$UPSTREAM_SHA" \
    FORK_SHA="$FORK_SHA" REGISTRY_FIXTURE=absent "$RELEASE_SCRIPT" > "$prerelease"
  jq -e '(.stable | not) and (.tags | index("ghcr.io/shockstruck/infisical:latest") | not)' "$prerelease" >/dev/null

  env DRY_RUN=1 IMAGE="$IMAGE" UPSTREAM_TAG=v0.162.15 UPSTREAM_SHA="$UPSTREAM_SHA" \
    FORK_SHA="$FORK_SHA" REGISTRY_FIXTURE=signed-matching "$RELEASE_SCRIPT" |
    jq -e '.decision == "noop"' >/dev/null

  expect_failure release-conflict env DRY_RUN=1 IMAGE="$IMAGE" UPSTREAM_TAG=v0.162.15 \
    UPSTREAM_SHA="$UPSTREAM_SHA" FORK_SHA="$FORK_SHA" REGISTRY_FIXTURE=conflicting "$RELEASE_SCRIPT"
  expect_failure invalid-oci env DRY_RUN=1 IMAGE="$IMAGE" UPSTREAM_TAG=v0.162.15+build.1 \
    UPSTREAM_SHA="$UPSTREAM_SHA" FORK_SHA="$FORK_SHA" REGISTRY_FIXTURE=absent "$RELEASE_SCRIPT"
}

main() {
  command -v git >/dev/null 2>&1 || die "git is required"
  command -v jq >/dev/null 2>&1 || die "jq is required"

  ROOT="$(mktemp -d "${TMPDIR:-/tmp}/upstream-sync-policy.XXXXXX")"
  trap 'rm -rf "$ROOT"' EXIT
  BASE_SHA=""
  FORK_SHA=""
  FORK_CONFLICT_SHA=""
  UPSTREAM_SHA=""
  CONFLICT_SHA=""
  VALID_BASELINE=""

  prepare_fixture
  test_prepare_policy
  test_release_policy
  printf 'All guarded upstream sync policy fixtures passed.\n'
}

main "$@"
