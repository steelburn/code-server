#!/usr/bin/env bash
set -euo pipefail

main() {
  cd "$(dirname "$0")/../.."
  source ./ci/lib.sh
  source ./ci/steps/steps-lib.sh

  ## Authentication tokens
  # Needed to publish on NPM
  if ! is_env_var_set "NPM_TOKEN"; then
    echo "NPM_TOKEN is not set. Cannot publish to npm without credentials."
    exit 1
  fi

  # NOTE@jsjoeio - only needed if we use the download_artifact
  # because we talk to the GitHub API.
  # Needed to use GitHub API
  if ! is_env_var_set "GITHUB_TOKEN"; then
    echo "GITHUB_TOKEN is not set. Cannot download npm release artifact without GitHub credentials."
    exit 1
  fi

  ## Environment
  # This string is used to determine how we should tag the npm release.
  # Environment can be one of three choices:
  # "development" - this means we tag with the PR number, allowing
  # a developer to install this version with `yarn add code-server@<pr-number>`
  # "staging" - this means we tag with `beta`, allowing
  # a developer to install this version with `yarn add code-server@beta`
  # "production" - this means we tag with `latest` (default), allowing
  # a developer to install this version with `yarn add code-server@latest`
  if ! is_env_var_set "NPM_ENVIRONMENT"; then
    echo "NPM_ENVIRONMENT is not set. Cannot determine npm tag without NPM_ENVIRONMENT."
    exit 1
  fi

  ## Publishing Information
  # All the variables below are used to determine how we should publish
  # the npm package. We also use this information for bumping the version.
  # This is because npm won't publish your package unless it's a new version.
  # i.e. for development, we bump the version to <current version>-<pr number>-<commit sha>
  # example: "version": "4.0.1-4769-ad7b23cfe6ffd72914e34781ef7721b129a23040"
  # We need the current package.json VERSION
  if ! is_env_var_set "VERSION"; then
    echo "VERSION is not set. Cannot publish to npm without VERSION."
    exit 1
  fi

  # We use this to grab the PR_NUMBER
  if ! is_env_var_set "GITHUB_REF"; then
    echo "GITHUB_REF is not set. Are you running this locally? We rely on values provided by GitHub."
    exit 1
  fi

  # We use this to grab the branch name
  if ! is_env_var_set "GITHUB_REF_NAME"; then
    echo "GITHUB_REF_NAME is not set. Are you running this locally? We rely on values provided by GitHub."
    exit 1
  fi

  # We use this when setting NPM_VERSION
  if ! is_env_var_set "GITHUB_SHA"; then
    echo "GITHUB_SHA is not set. Are you running this locally? We rely on values provided by GitHub."
    exit 1
  fi

  # This allows us to publish to npm in CI workflows
  if [[ ${CI-} ]]; then
    echo "//registry.npmjs.org/:_authToken=${NPM_TOKEN}" > ~/.npmrc
  fi

  # Note: if this runs on a push to main or a release workflow
  # There is no BRANCH so branch will be empty which is why
  # we set a default.
  # Source:https://docs.github.com/en/actions/learn-github-actions/environment-variables#default-environment-variables
  BRANCH="${GITHUB_REF_NAME-main}"
  download_artifact npm-package ./release-npm-package "$NPM_ENVIRONMENT" "$BRANCH"
  # https://github.com/actions/upload-artifact/issues/38
  tar -xzf release-npm-package/package.tar.gz

  # Ignore symlink when publishing npm package
  # See: https://github.com/cdr/code-server/pull/3935
  echo "node_modules.asar" > release/.npmignore

  # NOTES:@jsjoeio
  # We only need to run npm version for "development" and "staging".
  # This is because our release:prep script automatically bumps the version
  # in the package.json and we commit it as part of the release PR.
  if [[ "$NPM_ENVIRONMENT" == "production" ]]; then
    NPM_VERSION="$VERSION"
    # This means the npm version will be published as "stable"
    # and installed when a user runs `yarn install code-server`
    NPM_TAG="latest"
  else
    COMMIT_SHA="$GITHUB_SHA"
    echo "Not a production environment"
    echo "Found environment: $NPM_ENVIRONMENT"
    echo "Manually bumping npm version..."

    if [[ "$NPM_ENVIRONMENT" == "staging" ]]; then
      NPM_VERSION="$VERSION-beta-$COMMIT_SHA"
      # This means the npm version will be tagged with "beta"
      # and installed when a user runs `yarn install code-server@beta`
      NPM_TAG="beta"
    fi

    if [[ "$NPM_ENVIRONMENT" == "development" ]]; then
      # Source: https://github.com/actions/checkout/issues/58#issuecomment-614041550
      PR_NUMBER=$(echo "$GITHUB_REF" | awk 'BEGIN { FS = "/" } ; { print $3 }')
      NPM_VERSION="$VERSION-$PR_NUMBER-$COMMIT_SHA"
      # This means the npm version will be tagged with "<pr number>"
      # and installed when a user runs `yarn install code-server@<pr number>`
      NPM_TAG="$PR_NUMBER"
    fi

    echo "using tag: $NPM_TAG"

    # We modify the version in the package.json
    # to be the current version + the PR number + commit SHA
    # or we use current version + beta + commit SHA
    # Example: "version": "4.0.1-4769-ad7b23cfe6ffd72914e34781ef7721b129a23040"
    # Example: "version": "4.0.1-beta-ad7b23cfe6ffd72914e34781ef7721b129a23040"
    pushd release
    # NOTE:@jsjoeio
    # I originally tried to use `yarn version` but ran into issues and abandoned it.
    npm version "$NPM_VERSION"
    popd
  fi

  # We need to make sure we haven't already published the version.
  # This is because npm view won't exit with non-zero so we have
  # to check the output.
  local hasVersion
  hasVersion=$(npm view "code-server@$NPM_VERSION" version)
  if [[ $hasVersion == "$NPM_VERSION" ]]; then
    echo "$NPM_VERSION is already published"
    return
  fi

  yarn publish --non-interactive release --tag "$NPM_TAG"
}

main "$@"
